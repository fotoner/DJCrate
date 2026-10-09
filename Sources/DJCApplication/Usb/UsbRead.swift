import DJCDomain
import Foundation

/// USB(마운트된 볼륨 또는 USB 모양 폴더)를 읽기만 해서 무엇이 있는지·건강한지 본다(`djc usb-info`·앱 사이드바).
/// DB는 `UsbSnapshot`으로 뜬 사본에서만 열고, 분석 파일은 DB가 가리키는 파일만 읽는다. USB에는 아무것도 쓰지 않고
/// 열지 않는 경로(`UsbLayout.neverRead`)는 열지도 이름을 내보내지도 않는다.
/// 입출력은 포트(`UsbLibraryEngine.Read`·`UsbDevice`)로만 한다. 이 타입은 읽는 순서와 경고 판정을 맡는다.
public struct UsbRead: Sendable {
    /// 폴더 대상(Mac 시동·데이터 볼륨)의 마운트 지점
    static let startupMounts: Set<String> = ["/", "/System/Volumes/Data"]

    let engine: UsbLibraryEngine
    let device: UsbDevice

    /// 엔진(USB 읽기)·이 Mac의 일(경로·볼륨·사본 폴더)은 조립 지점(앱·CLI)이 넘긴다
    public init(engine: UsbLibraryEngine, device: UsbDevice) {
        self.engine = engine
        self.device = device
    }

    /// 대상 경로가 든 볼륨. 마운트 지점이 아닌 하위 폴더여도 그 볼륨으로 본다(실물 볼륨 안 폴더로 비켜 가지 못하게).
    /// 시동 볼륨(Mac 데이터 볼륨의 폴더)이면 nil. 마운트 지점을 알 수 없으면 읽지 않는다
    public func volume(for root: URL) throws -> UsbVolumeInfo? {
        guard let real = device.realPath(root.path) else {
            throw UsbError.readFailed(detail: "realpath \(root.path)")
        }
        guard let mount = device.mountedOn(real) else { throw UsbError.readFailed(detail: "statfs \(root.path)") }
        if Self.startupMounts.contains(mount) { return nil }
        return try device.volumeInfo(URL(filePath: real))
    }

    /// 사본을 떠서(UsbSnapshot) 읽는다. USB에 아무것도 쓰지 않는다. neverRead를 열지 않는다.
    /// - volume: 대상이 든 볼륨(`volume(for:)`), 폴더 대상이면 nil. 실물 USB도 등록 없이 읽는다.
    ///   nil이면 대상이 정말 Mac 시동·데이터 볼륨 위인지 다시 보고, 아니면 `volumeNotChecked`를 던진다(볼륨 정보를 빠뜨린 채 읽지 않게)
    /// - scratch: 사본을 뜰 Mac 쪽 폴더(없거나 비어 있어야 한다. 아니면 `scratch not empty`). 끝나면 이 호출이 뜬 사본만 지운다
    public func info(root: URL, scratch: URL, volume: UsbVolumeInfo?) throws -> UsbInfo {
        if volume == nil {
            guard let real = device.realPath(root.path), let mount = device.mountedOn(real), Self.startupMounts.contains(mount) else {
                throw UsbError.readFailed(detail: "volumeNotChecked")
            }
        }
        // 이미 무엇이 든 폴더(USB 루트 포함)를 사본 폴더로 받으면 끝낼 때 남의 파일을 지울 수 있다
        if device.exists(scratch), device.names(scratch)?.isEmpty != true {
            throw UsbError.readFailed(detail: "scratch not empty")
        }
        var info = UsbInfo(root: root.path)
        info.volume = volume.map(Self.volumePart)
        let version = device.appVersion()
        info.localCompatibility = UsbInfo.Local(rekordboxVersion: version, verified: device.isVerified(version))

        let names = try engine.read.rekordboxFileNames(root)
        let hasOneLibrary = names.contains((UsbLayout.oneLibrary as NSString).lastPathComponent)
        let hasPdb = names.contains((UsbLayout.exportPdb as NSString).lastPathComponent)
        info.formats = (hasOneLibrary ? [UsbFormat.oneLibrary.rawValue] : []) + (hasPdb ? [UsbFormat.deviceLibrary.rawValue] : [])
        info.settings = engine.read.settings(root)
        if info.settings.contains(where: { $0.status == .invalid || $0.status == .unreadable }) {
            info.warnings.append(UsbInfo.Warning(code: "settingsInvalid",
                message: String(ui: "설정 파일을 확인하지 못했으므로 rekordbox에서 기기 설정을 다시 저장한 뒤 USB로 내보내세요")))
        }
        guard hasOneLibrary || hasPdb else { return info }

        let createdScratch = !device.exists(scratch)
        let databaseCopy = scratch.appending(path: "db"), pdbCopy = scratch.appending(path: "pdb")
        defer {
            for url in [databaseCopy, pdbCopy] { device.remove(url) }
            if createdScratch { device.remove(scratch) }
        }

        var warnings = info.warnings
        func warn(_ code: String, _ message: String) { warnings.append(UsbInfo.Warning(code: code, message: message)) }
        var oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?
        var report: PdbReadReport?
        var roundTrip: [String]?

        do {
            let snapshot = try engine.read.copyDatabases(root, databaseCopy)
            if let copy = snapshot.oneLibrary {
                var part = UsbInfo.OneLibraryPart(schemaOK: true, headerMode: snapshot.rollbackHeader ? "rollback" : "wal",
                                                  walPresent: snapshot.walPresent, journalPresent: snapshot.journalPresent,
                                                  integrityOK: true, tracks: 0, playlists: 0, myTags: 0, histories: 0)
                do {
                    let library = try engine.read.oneLibrary(copy)
                    oneLibrary = library
                    part.tracks = library.tracks.count
                    part.playlists = library.playlists.count
                    part.myTags = library.myTags.count
                    part.histories = library.histories.count
                } catch let error as UsbError {
                    guard case .formatUnsupported = error else { throw error }
                    part.schemaOK = false
                    warn("oneLibraryUnsupported", String(ui: "이 USB의 OneLibrary는 DJCrate가 확인하지 않은 모양입니다. DJCrate 업데이트를 확인하세요"))
                }
                info.oneLibrary = part
            }
            report = try readDeviceLibrary(snapshot.exportPdb.map { ($0, snapshot.exportExtPdb) }, into: &deviceLibrary,
                                           roundTrip: &roundTrip, warn: warn)
        } catch let error as UsbError where hasOneLibrary && Self.isOneLibraryFailure(error) {
            // OneLibrary 사본이 온전하지 않다(무결성·암호). Device Library는 따로 떠서 읽는다
            info.oneLibrary = UsbInfo.OneLibraryPart(schemaOK: false, headerMode: "unknown",
                                                     walPresent: engine.read.exists(root, UsbLayout.oneLibrary + "-wal"),
                                                     journalPresent: engine.read.exists(root, UsbLayout.oneLibrary + "-journal"),
                                                     integrityOK: false, tracks: 0, playlists: 0, myTags: 0, histories: 0)
            warn("oneLibraryUnreadable", String(ui: "OneLibrary(exportLibrary.db)가 손상돼 읽지 못했습니다. rekordbox로 USB를 다시 내보내세요"))
            report = try readDeviceLibrary(try engine.read.copyPdb(root, pdbCopy).map { ($0.export, $0.ext) }, into: &deviceLibrary,
                                           roundTrip: &roundTrip, warn: warn)
        }

        if let part = info.oneLibrary, part.walPresent || part.journalPresent {
            warn("oneLibrarySidecar", String(ui: "OneLibrary에 기기가 쓰다 남긴 파일(-wal·-journal)이 있습니다. 기기에서 USB를 정상적으로 꺼낸 뒤 다시 읽으세요"))
        }
        if let report {
            info.deviceLibrary = Self.deviceLibraryPart(report, library: deviceLibrary, roundTrip: roundTrip)
            if report.exportHeader.flag10 != 5 || (report.extHeader.map { $0.flag10 != 5 } ?? false) {
                warn("pdbOpenFlag", String(ui: "rekordbox에 이 USB를 연결했다가 정상적으로 꺼낸 뒤 다시 시도하세요"))
            }
            if let part = info.deviceLibrary {
                if part.unknownTableRows > 0 {
                    warn("unknownTableRows", String(ui: "Device Library에 DJCrate가 모르는 표의 행이 있습니다. 고치기 전에 rekordbox로 USB를 다시 내보내세요"))
                }
                if part.structureIssues > 0 {
                    warn("pdbStructure", String(ui: "Device Library 구조에 문제가 있습니다. rekordbox로 USB를 다시 내보내세요"))
                }
                if let roundTrip, !roundTrip.isEmpty {
                    // 문제 수만 적는다(곡 제목·경로·칸 값 없이)
                    warn("pdbRoundTripFailed", String(ui: "이 USB의 Device Library는 DJCrate가 다시 쓸 수 없는 모양입니다(문제 \(roundTrip.count)개). 고치려면 rekordbox로 USB를 다시 내보내세요"))
                }
            }
        }

        info.consistency = Self.consistency(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
        if info.consistency.editBlocked {
            warn("formatMismatch", String(ui: "두 형식(OneLibrary·Device Library)의 곡이나 재생 목록이 서로 달라 이 USB는 고칠 수 없습니다. rekordbox로 USB를 다시 내보내세요"))
        }
        info.analysis = analysis(root, oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
        if info.analysis.missingFiles > 0 {
            warn("analysisMissing", String(ui: "분석 파일이 없는 곡이 있습니다. rekordbox로 USB를 다시 내보내세요"))
        }
        if info.analysis.ppthMismatches > 0 {
            warn("analysisPathMismatch", String(ui: "분석 파일에 적힌 곡 경로가 DB와 다른 곡이 있습니다. rekordbox로 USB를 다시 내보내세요"))
        }
        info.media = Self.media(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary) { engine.read.isRegularFile(root, $0) }
        if info.media.missingFiles > 0 {
            warn("mediaMissing", String(ui: "음원 파일이 없는 곡이 있으므로 rekordbox로 USB를 다시 내보내세요"))
        }
        info.warnings = warnings
        return info
    }

    // MARK: - 부분

    static func volumePart(_ volume: UsbVolumeInfo) -> UsbInfo.Volume {
        let export = UsbVolumePolicy.problems(volume, purpose: .export).map(\.code)
        let edit = UsbVolumePolicy.problems(volume, purpose: .edit).map(\.code)
        var problems: [String] = []
        for code in export + edit where !problems.contains(code) { problems.append(code) }
        return UsbInfo.Volume(fileSystem: volume.fileSystem.displayName, partitionScheme: volume.partitionScheme.rawValue,
                              isDiskImage: volume.isDiskImage, writableForExport: export.isEmpty, writableForEdit: edit.isEmpty,
                              problems: problems)
    }

    /// `UsbSnapshot.take`가 OneLibrary 사본을 확인하다 멈춘 오류(무결성·암호·WAL 합치기)
    static func isOneLibraryFailure(_ error: UsbError) -> Bool {
        guard case let .readFailed(detail) = error else { return false }
        let name = (UsbLayout.oneLibrary as NSString).lastPathComponent
        return ["integrity_check", "cipher_integrity_check", "wal_checkpoint busy", name].contains { detail.hasPrefix($0) }
    }

    /// pdb 사본을 읽는다. 머리가 달라 읽지 못하면 경고만 남긴다.
    /// 읽었으면 왕복 검사(읽기 → 모델 → 다시 쓰기 → 다시 읽기, `PdbRoundTrip`)의 문제 목록도 채운다(빈 배열 = 통과)
    func readDeviceLibrary(_ files: (URL, URL?)?, into library: inout UsbLibrary?, roundTrip: inout [String]?,
                           warn: (String, String) -> Void) throws -> PdbReadReport? {
        guard let (export, ext) = files else { return nil }
        do {
            let read = try engine.read.deviceLibrary(export, ext)
            library = read.library
            do {
                roundTrip = try engine.read.roundTrip(export, ext)
            } catch {
                roundTrip = ["unreadable"]
            }
            return read.report
        } catch let error as UsbError {
            guard case .readFailed = error else { throw error }
            warn("deviceLibraryUnreadable", String(ui: "Device Library(export.pdb)를 읽지 못했습니다. rekordbox로 USB를 다시 내보내세요"))
            return nil
        }
    }

    static func deviceLibraryPart(_ report: PdbReadReport, library: UsbLibrary?, roundTrip: [String]?) -> UsbInfo.DeviceLibraryPart {
        let history = [PdbTableType.historyPlaylists.name, PdbTableType.historyEntries.name].reduce(0) { $0 + (report.tableCounts[$1]?.live ?? 0) }
        return UsbInfo.DeviceLibraryPart(
            exportFlag10: Int(report.exportHeader.flag10), extFlag10: report.extHeader.map { Int($0.flag10) },
            roundTripChecked: roundTrip != nil, roundTripOK: roundTrip.map(\.isEmpty),
            tracks: library?.tracks.count ?? 0, playlists: library?.playlists.count ?? 0, historyRows: history,
            unknownTableRows: report.unknownRows.filter { $0.format == .deviceLibrary }.reduce(0) { $0 + $1.liveRows },
            structureIssues: report.issues.count)
    }

    static func consistency(oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?) -> UsbInfo.Consistency {
        let (_, mismatches) = UsbLibrary.merge(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
        var playlists: Set<Int> = []
        var result = UsbInfo.Consistency()
        for mismatch in mismatches {
            switch mismatch {
            case .trackOnlyIn: result.trackIDsMatch = false
            case .trackPathDiffers: result.pathsMatch = false
            case let .playlistConflict(id), let .playlistEntriesDiffer(id), let .playlistOnlyIn(_, id): playlists.insert(id)
            default: break
            }
        }
        result.playlistMismatches = playlists.count
        result.editBlocked = mismatches.contains(where: \.blocksEditing)
        let tracks = (oneLibrary?.tracks ?? []) + (deviceLibrary?.tracks ?? [])
        result.masterDbIdConsistent = Set(tracks.map(\.masterDbId)).count <= 1
        if let oneLibrary, let deviceLibrary {
            result.myTagMasterDBIDConsistent = oneLibrary.property.myTagMasterDBID == deviceLibrary.property.myTagMasterDBID
        }
        return result
    }

    /// 곡마다 두 DB가 가리키는 분석 파일(같은 경로는 한 번): 셋의 존재, .DAT PPTH = 곡 경로, 파일 번호 > 0
    func analysis(_ root: URL, oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?) -> UsbInfo.Analysis {
        let tracks = (oneLibrary?.tracks ?? []) + (deviceLibrary?.tracks ?? [])
        var result = UsbInfo.Analysis(tracksChecked: Set(tracks.map(\.id)).count)
        var seen: Set<String> = [], ppthBad: Set<Int> = []
        for track in tracks {
            let path = track.analysisDataPath
            guard seen.insert("\(track.id)\u{0}\(path)\u{0}\(UsbLayout.nfc(track.path))").inserted else { continue }
            let relative = String(path.drop { $0 == "/" })
            let base = relative.uppercased().hasSuffix(".DAT") ? String(relative.dropLast(4)) : relative
            if let number = Self.slotNumber(base), number > 0 { result.slotCollisions += 1 }
            for ext in [".DAT", ".EXT", ".2EX"] where path.isEmpty || !engine.read.isRegularFile(root, base + ext) { result.missingFiles += 1 }
            guard !path.isEmpty, engine.read.isRegularFile(root, base + ".DAT") else { continue }
            let ppth = engine.read.analysisTrackPath(root, base + ".DAT")
            if ppth.map(UsbLayout.nfc) != UsbLayout.nfc(track.path) { ppthBad.insert(track.id) }
        }
        result.ppthMismatches = ppthBad.count
        return result
    }

    /// "…/ANLZ000N" → N(16진)
    static func slotNumber(_ base: String) -> Int? {
        let name = (base as NSString).lastPathComponent.uppercased()
        guard name.hasPrefix("ANLZ") else { return nil }
        return Int(name.dropFirst(4), radix: 16)
    }
}
