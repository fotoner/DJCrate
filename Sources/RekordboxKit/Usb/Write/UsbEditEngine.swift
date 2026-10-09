import DJCDomain
import Foundation

extension UsbEditResult {
    /// 쓰기 뒤 검증기: 목표 지문 · 쓴 형식의 모델 · 불변식(한 형식이 막혔으면 두 형식 곡 수 비교는 뺀다, 쓰기 전부터 있던 문제는 뺀다).
    /// preexistingAppleDoubles: 쓰기 직전 USB의 `._*`(`UsbInvariantVerifier.appleDoubles(on:)`)
    public func verifiers(preexistingAppleDoubles: Set<String> = []) -> [any UsbWriteVerifier] {
        var result: [any UsbWriteVerifier] = [UsbFingerprintVerifier()]
        if formatsWritten.contains(.oneLibrary), let applied { result.append(OneLibraryVerifier(expected: applied)) }
        if formatsWritten.contains(.deviceLibrary), let pdbWritten { result.append(PdbVerifier(expected: pdbWritten)) }
        result.append(UsbInvariantVerifier(preexistingAppleDoubles: preexistingAppleDoubles, preexistingProblems: preexistingProblems,
                                           checkFormatCounts: formatsBlocked.isEmpty, audioSizeFromDatabase: audioSizeFromDatabase))
        return result
    }
}

/// 편집할 USB를 읽은 것: DB 사본, 두 형식 모델과 합친 모델, 편집 전체·형식별 막힘
public struct UsbEditSource: Sendable {
    public var snapshot: UsbSnapshot?
    /// USB에 있고 읽은 형식
    public var formats: Set<UsbFormat>
    /// 두 형식을 합친 모델(`UsbLibrary.merge`)
    public var current: UsbLibrary
    public var mismatches: [UsbFormatMismatch]
    public var pdbReport: PdbReadReport?
    /// USB 전체 편집 막힘
    public var blocks: [UsbBlock]
    /// 그 형식만 막힘
    public var formatsBlocked: [UsbFormat: UsbBlock]
    public var notes: [String]
    /// USB의 Device Library에 작성기가 NFC로 바꿔 쓸 이름·제목(rekordbox가 쓴 NFD 등)이 있다(#233).
    /// 그러면 쓰는 편집이 모델이 바뀌지 않아도 Device Library를 다시 만들어 CDJ에서 보이게 고친다
    public var deviceLibraryNeedsNFC: Bool

    public init(snapshot: UsbSnapshot?, formats: Set<UsbFormat>, current: UsbLibrary, mismatches: [UsbFormatMismatch],
                pdbReport: PdbReadReport?, blocks: [UsbBlock], formatsBlocked: [UsbFormat: UsbBlock], notes: [String],
                deviceLibraryNeedsNFC: Bool = false) {
        self.snapshot = snapshot
        self.formats = formats
        self.current = current
        self.mismatches = mismatches
        self.pdbReport = pdbReport
        self.blocks = blocks
        self.formatsBlocked = formatsBlocked
        self.notes = notes
        self.deviceLibraryNeedsNFC = deviceLibraryNeedsNFC
    }

    /// 이번에 고칠 수 있는 형식
    public var writable: Set<UsbFormat> {
        blocks.isEmpty ? formats.subtracting(formatsBlocked.keys) : []
    }
}

/// 이미 라이브러리가 있는 USB 수정(곡 더하기·빼기·갱신, 재생 목록 편집)을 계획한다.
/// 편집을 모델에 차례로 적용하고, OneLibrary는 USB DB 사본에 SQL로(`OneLibraryWriter.apply`, 편집마다 한 단계),
/// Device Library는 적용 결과 모델에서 새로 만든다(`PdbWriter`). 파일(분석 파일·아트워크·음원)은 준비 폴더에 만들고
/// 지울 파일은 편집 전후 참조 차이로 정한다. USB에는 쓰지 않는다(쓰기는 `UsbWriter.write` 한 곳).
public enum UsbEditEngine {
    // MARK: - 읽기와 전제

    /// USB DB 사본을 뜨고 읽는다. OneLibrary 사본이 손상돼 뜨지 못하면 USB 전체 막힘으로 돌려준다(던지지 않는다)
    public static func load(root: UsbRoot, into directory: URL) throws -> UsbEditSource {
        let snapshot: UsbSnapshot
        do {
            snapshot = try UsbSnapshot.take(root: root, into: directory)
        } catch let error as UsbError where isCorrupt(error) {
            return UsbEditSource(snapshot: nil, formats: [], current: .empty, mismatches: [], pdbReport: nil, blocks: [corruptBlock],
                                 formatsBlocked: [:], notes: [])
        }
        return try read(snapshot)
    }

    /// 뜬 사본을 읽어 합치고 편집 전제를 본다
    public static func read(_ snapshot: UsbSnapshot) throws -> UsbEditSource {
        var notes: [String] = [], blocks: [UsbBlock] = []
        if snapshot.flags.walMerged || snapshot.flags.journalRolledBack {
            notes.append(String(ui: "USB에 남은 -wal·-journal을 사본에서 합쳐 읽었습니다(쓸 때 USB의 남은 파일은 지웁니다)"))
        }
        var oneLibrary: UsbLibrary?
        if let copy = snapshot.oneLibrary {
            do {
                oneLibrary = try OneLibraryReader.read(copyAt: copy)
            } catch let error as UsbError {
                guard case .formatUnsupported = error else { throw error }
                blocks.append(UsbBlock(code: "oneLibraryUnsupported", scope: .format(.oneLibrary),
                                       message: String(ui: "rekordbox 새 버전이 만든 USB라 아직 고칠 수 없습니다")))
            }
        }
        var deviceLibrary: UsbLibrary?, report: PdbReadReport?
        do {
            if let read = try PdbReader.read(snapshot: snapshot) { (deviceLibrary, report) = (read.0, read.1) }
        } catch let error as UsbError {
            guard case .readFailed = error else { throw error }
            blocks.append(corruptBlock)
        }
        if snapshot.oneLibrary == nil, snapshot.exportPdb == nil {
            blocks.append(UsbBlock(code: "noLibrary", scope: .volume,
                                   message: String(ui: "이 USB에는 rekordbox 라이브러리가 없습니다. 빈 USB면 USB로 내보내기를 쓰세요")))
        }
        let formats = Set([oneLibrary.map { _ in UsbFormat.oneLibrary }, deviceLibrary.map { _ in UsbFormat.deviceLibrary }].compactMap { $0 })
        let (current, mismatches) = UsbLibrary.merge(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
        if mismatches.contains(where: { if case .playlistConflict = $0 { false } else { $0.blocksEditing } }) {
            blocks.append(UsbBlock(code: "formatTrackMismatch", scope: .volume,
                                   message: String(ui: "두 형식의 곡 번호가 달라 고칠 수 없습니다. rekordbox에서 다시 내보내세요")))
        }
        if mismatches.contains(where: { if case .playlistConflict = $0 { true } else { false } }) {
            // 맨 위에서 닿지 않는 목록은 대표 번호·부모를 정할 수 없어 고쳐 쓰면 다른 자리로 갈 수 있다.
            // 번호만 다른 같은 목록·같은 번호의 다른 목록은 짝지어 읽으므로 막지 않는다(#233)
            blocks.append(UsbBlock(code: "formatPlaylistConflict", scope: .volume,
                                   message: String(ui: "부모 폴더를 찾을 수 없는 재생 목록이 있어 고칠 수 없습니다. rekordbox에서 USB를 다시 내보내세요")))
        }
        var formatsBlocked: [UsbFormat: UsbBlock] = [:]
        if let deviceLibrary, let report, let block = try deviceLibraryBlock(deviceLibrary, report: report, snapshot: snapshot) {
            formatsBlocked[.deviceLibrary] = block
        }
        let differing = mismatches.filter { if case .playlistEntriesDiffer = $0 { true } else { false } }.count
        if differing > 0 { notes.append(String(ui: "형식 사이 목록 불일치 \(differing)")) }
        return UsbEditSource(snapshot: snapshot, formats: formats, current: current, mismatches: mismatches, pdbReport: report,
                             blocks: unique(blocks), formatsBlocked: formatsBlocked, notes: notes,
                             deviceLibraryNeedsNFC: deviceLibrary.map(PdbWriter.needsNFC) ?? false)
    }

    /// Device Library만 막는 조건(그 형식만 고치지 않고 OneLibrary는 쓴다)
    static func deviceLibraryBlock(_ model: UsbLibrary, report: PdbReadReport, snapshot: UsbSnapshot) throws -> UsbBlock? {
        if report.exportHeader.flag10 != PdbVerifier.closedFlag || (report.extHeader.map { $0.flag10 != PdbVerifier.closedFlag } ?? false) {
            return UsbBlock(code: "pdbNotClosed", scope: .format(.deviceLibrary),
                            message: String(ui: "rekordbox에 이 USB를 연결했다가 정상적으로 꺼낸 뒤 다시 시도하세요"))
        }
        if !model.histories.isEmpty || !model.unknownRows.isEmpty {
            let rule = UsbProvisionalRule.carriedDeviceRows
            return UsbBlock(code: rule.rawValue, scope: .format(.deviceLibrary),
                            message: String(ui: "CDJ가 쓴 기록·목록이 있어 Device Library는 아직 고칠 수 없습니다"), rule: rule)
        }
        guard let export = snapshot.exportPdb, let ext = snapshot.exportExtPdb else {
            return roundTripBlock("exportExt missing")
        }
        let problems = try PdbRoundTrip.check(export: Data(contentsOf: export), exportExt: Data(contentsOf: ext))
        return problems.first.map { roundTripBlock(problems.count > 1 ? "\($0) +\(problems.count - 1)" : $0) }
    }

    static func roundTripBlock(_ detail: String) -> UsbBlock {
        UsbBlock(code: "pdbRoundTripFailed", scope: .format(.deviceLibrary),
                 message: String(ui: "이 USB의 Device Library는 DJCrate가 다시 쓸 수 없는 모양입니다(\(detail))"))
    }

    static var corruptBlock: UsbBlock {
        UsbBlock(code: "libraryCorrupt", scope: .volume, message: String(ui: "USB 라이브러리가 손상됐습니다. rekordbox에서 USB를 점검한 뒤 다시 시도하세요"))
    }

    /// 사본을 뜨다 난 오류 중 OneLibrary 사본이 온전하지 않은 것(무결성·암호·체크포인트)
    static func isCorrupt(_ error: UsbError) -> Bool {
        guard case let .readFailed(detail) = error else { return false }
        let name = (UsbLayout.oneLibrary as NSString).lastPathComponent
        return ["integrity_check", "cipher_integrity_check", "wal_checkpoint busy", name].contains { detail.hasPrefix($0) }
    }

    static func unique(_ blocks: [UsbBlock]) -> [UsbBlock] {
        var seen: Set<UsbBlock> = []
        return blocks.filter { seen.insert($0).inserted }
    }
}
