import CryptoKit
import DJCDomain
import Foundation

/// Device Library(`export.pdb`)만 있는 USB에 OneLibrary(`exportLibrary.db`)를 더하는 옮기기(#46, `djc usb-migrate`).
/// pdb에서 읽은 모델에 OneLibrary 몫(곡·목록·My Tag 연결의 소속, OneLibrary에만 있는 칸, b 아트워크 경로)을 채워 두 형식 모델을 만들고,
/// 준비 폴더에 새 `exportLibrary.db`와 b 아트워크(같은 폴더 a 그림의 바이트 사본)를 만든다. 원래 파일(pdb 둘·분석 파일·음원·a 그림)은 바꾸지 않는다.
/// 칸 대응은 rekordbox 7.2.18이 두 형식을 함께 내보낸 골든(2026-09-26)에서 본 것이고, rekordbox의 "Convert from Device Library" 결과와는
/// 아직 견주지 못했다(`deviceLibraryMigration`). USB에는 쓰지 않는다(쓰기는 `UsbWriter.write` 한 곳).
public enum UsbMigration {
    /// OneLibrary content.analysedBits. pdb에는 이 칸이 없다
    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기): 모든 곡이 이 값
    public static let analysedBits = 105

    /// 변경 묶음 이름(저널·백업 폴더 이름에 쓰인다)
    public static let label = "migrate"

    // MARK: - 모델

    /// pdb에서 읽은 모델 → 두 형식 모델. Device Library 투영은 입력과 같고, OneLibrary 몫은 아래처럼 채운다.
    /// - 곡: 두 형식 모두. contentLink = 0x0C0700 | 보컬(USB `.2EX` PVDI에 본문이 있음 → 0x100000), analysedBits = 105,
    ///   artist_id_lyricist 0, hasModified 0, 기기 칸(평점·재생 수)은 pdb 값
    /// - 그림: b 경로 = pdb a 경로의 같은 폴더 `b{id}.jpg`. 목록: 순서·항목은 pdb 그대로. My Tag 연결: 두 형식 모두
    /// - property: createdDate = pdb 표 19 날짜, deviceName '', backGroundColorType 0, 곡 수 = 곡 행 수
    /// - vocal: USB `.2EX`의 PVDI에 본문이 있는 곡 id
    public static func model(from deviceLibrary: UsbLibrary, vocal: Set<Int>) -> UsbLibrary {
        var model = deviceLibrary.projected(to: .deviceLibrary)
        model.formats = UsbFormat.defaultSet
        for index in model.tracks.indices {
            var track = model.tracks[index]
            track.presentIn = UsbFormat.defaultSet
            track.lyricistArtistID = 0
            track.analysedBits = analysedBits
            track.contentLink = UsbLibraryBuilder.contentLinkBase | (vocal.contains(track.id) ? UsbLibraryBuilder.contentLinkPVDI : 0)
            track.hasModified = 0
            let device = track.deviceFields[.deviceLibrary]
            track.deviceFields[.oneLibrary] = UsbTrackDeviceFields(rating: device?.rating ?? track.rating,
                                                                   playCount: device?.playCount ?? track.djPlayCount, hasModified: 0)
            model.tracks[index] = track
        }
        for index in model.images.indices {
            model.images[index].oneLibraryPath = model.images[index].pdbPath.flatMap { oneLibraryArtworkPath($0, imageID: model.images[index].id) }
        }
        for index in model.playlists.indices {
            model.playlists[index].presentIn = UsbFormat.defaultSet
            model.playlists[index].sortOrder[.oneLibrary] = model.playlists[index].sortOrder[.deviceLibrary]
            model.playlists[index].entries[.oneLibrary] = model.playlists[index].entries[.deviceLibrary]
        }
        for index in model.myTagLinks.indices { model.myTagLinks[index].presentIn = UsbFormat.defaultSet }
        model.property.deviceName = ""
        model.property.createdDate = model.property.pdbDate ?? ""
        model.property.backgroundColorType = 0
        model.property.numberOfContents = model.tracks.count
        return model.canonicalized()
    }

    /// USB의 `.2EX`에서 보컬 곡을 찾아 변환한다(골든 대조 lab용: 이미 OneLibrary가 있는 USB에서도 막지 않는다)
    public static func model(deviceLibrary: UsbLibrary, root: UsbRoot, fileSystem: any UsbFileSystem = PosixUsbFileSystem()) throws -> UsbLibrary {
        model(from: deviceLibrary, vocal: try vocalTracks(deviceLibrary, root: root, fileSystem: fileSystem))
    }

    /// pdb 그림 경로 `/PIONEER/Artwork/nnnnn/a{id}.jpg` → 같은 폴더의 `/…/b{id}.jpg`. 모양이 다르면 nil
    public static func oneLibraryArtworkPath(_ pdbPath: String, imageID: Int) -> String? {
        let parts = pdbPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let root = UsbLayout.artworkRoot.split(separator: "/").map(String.init)
        guard parts.count == root.count + 3, parts[0].isEmpty,
              zip(parts[1...root.count], root).allSatisfy({ UsbLayout.collisionKey($0) == UsbLayout.collisionKey($1) }) else { return nil }
        let folder = parts[root.count + 1], file = parts[root.count + 2]
        guard folder.count == 5, folder.allSatisfy({ $0.isASCII && $0.isNumber }),
              UsbLayout.collisionKey(file) == UsbLayout.collisionKey("a\(imageID).jpg") else { return nil }
        return (parts.dropLast() + ["b\(imageID).jpg"]).joined(separator: "/")
    }

    // MARK: - 계획

    /// USB DB 사본(`UsbSnapshot`)을 읽어 옮기기를 계획하고 준비 폴더(`staging`)에 `exportLibrary.db`·b 아트워크를 만든다.
    /// 막히면 `changes`가 nil이고 준비 폴더는 지운다. USB 파일은 읽기만 한다(그림·`.2EX`·불변식 확인).
    public static func plan(snapshot: UsbSnapshot, root: UsbRoot, fileSystem: any UsbFileSystem, staging: URL,
                            session: String) throws -> UsbMigrationResult {
        var result = UsbMigrationResult()
        // 1. 이미 OneLibrary가 있으면(사이드카만 남았어도) 옮기지 않는다. rekordbox의 변환은 덮어쓰지만 여기서는 덮지 않는다
        let sidecar = try UsbLayout.oneLibrarySidecarSuffixes.contains { try fileSystem.stat(root.url.appending(path: UsbLayout.oneLibrary + $0)) != nil }
        if sidecar || snapshot.oneLibrary != nil || snapshot.fingerprint.files.keys.contains(where: { $0.hasPrefix(UsbLayout.oneLibrary) }) {
            result.blocks = [Blocks.oneLibraryExists]
            return result
        }
        // 2. Device Library 읽기와 전제
        let read: (UsbLibrary, PdbReadReport)
        do {
            guard let found = try PdbReader.read(snapshot: snapshot) else {
                result.blocks = [Blocks.noDeviceLibrary]
                return result
            }
            read = found
        } catch let error as UsbError {
            guard case .readFailed = error else { throw error }
            result.blocks = [UsbEditEngine.corruptBlock]
            return result
        }
        let (deviceLibrary, report) = read
        result.blocks = deviceLibraryBlocks(deviceLibrary, report: report)
        guard result.blocks.isEmpty else { return result }

        // 3. b 그림: 같은 폴더 a 그림의 사본. a가 없거나 경로 모양이 다르면 막는다
        let artwork = try artworkCopies(deviceLibrary, root: root, fileSystem: fileSystem)
        guard artwork.blocks.isEmpty else {
            result.blocks = artwork.blocks
            return result
        }

        // 4. 변환과 불변식 미리 보기: OneLibrary를 더해 새로 생기는 문제(쓴 뒤 검증이 되돌릴 것)가 있으면 막는다
        let vocal = try vocalTracks(deviceLibrary, root: root, fileSystem: fileSystem)
        let model = model(from: deviceLibrary, vocal: vocal)
        let oneLibrary = model.projected(to: .oneLibrary)
        let mismatches = UsbLibrary.merge(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary).1
        let before = Set(try UsbInvariantVerifier.libraryProblems(oneLibrary: nil, deviceLibrary: deviceLibrary, root: root,
                                                                  fileSystem: fileSystem, checkFormatCounts: true))
        // b 그림은 이번 쓰기가 만든다
        let planned = Set(artwork.copies.map { "missing artwork image \($0.imageID) onelibrary" })
        let after = Set(try UsbInvariantVerifier.libraryProblems(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary, root: root,
                                                                 fileSystem: fileSystem, checkFormatCounts: true)).subtracting(planned)
        let added = after.subtracting(before)
        guard mismatches.isEmpty, added.isEmpty else {
            result.blocks = [Blocks.filesMismatch(detail: (mismatches.map { "\($0)" } + added.sorted()).prefix(3).joined(separator: "; "))]
            return result
        }
        result.library = model
        result.preexistingProblems = before
        result.trackCount = model.tracks.count
        result.playlistCount = model.playlists.count
        result.artworkFiles = artwork.copies.filter { $0.disposition != .reuse }.count

        // 5. 준비: 새 DB와 b 그림. 실패하면 준비 폴더를 지운다
        do {
            result.changes = try stage(model, artwork: artwork.copies, snapshot: snapshot, root: root, fileSystem: fileSystem, staging: staging,
                                       session: session, rules: rules(model, hasExportExt: snapshot.exportExtPdb != nil))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return result
    }

    /// Device Library 상태 막힘: 정상으로 닫지 않은 파일, 읽지 못한 행(확인 못 한 먼 모양 My Tag 행 포함), 기기 기록·모르는 표 행, 모르는 버전, 곡 없음.
    /// 아티스트·앨범 먼 모양 행은 칸을 모두 읽으므로 막지 않는다(rekordbox 7.2.x 경계 실험, 2026-10-08)
    static func deviceLibraryBlocks(_ library: UsbLibrary, report: PdbReadReport) -> [UsbBlock] {
        if report.exportHeader.flag10 != PdbVerifier.closedFlag || (report.extHeader.map { $0.flag10 != PdbVerifier.closedFlag } ?? false) {
            return [UsbBlock(code: "pdbNotClosed", scope: .format(.deviceLibrary),
                             message: String(ui: "rekordbox에 이 USB를 연결했다가 정상적으로 꺼낸 뒤 다시 시도하세요"))]
        }
        // 읽기는 구조 문제가 있으면 읽은 데까지만 모델에 넣는다. 그대로 옮기면 OneLibrary에서 행이 조용히 빠진다
        if !report.issues.isEmpty {
            return [UsbBlock(code: "pdbUnreadableRows", scope: .format(.deviceLibrary),
                             message: String(ui: "이 USB의 Device Library에 읽지 못한 행이 있어 옮기지 않았습니다. rekordbox에서 USB를 다시 내보내세요"))]
        }
        if !library.histories.isEmpty || !library.unknownRows.isEmpty {
            let rule = UsbProvisionalRule.carriedDeviceRows
            return [UsbBlock(code: rule.rawValue, scope: .format(.deviceLibrary),
                             message: String(ui: "CDJ가 쓴 기록·목록이 있어 아직 옮길 수 없습니다. rekordbox에서 USB를 다시 내보내세요"), rule: rule)]
        }
        if library.property.dbVersion != OneLibraryCompatibility.databaseVersion {
            return [UsbBlock(code: "pdbVersionUnsupported", scope: .format(.deviceLibrary),
                             message: String(ui: "이 USB의 Device Library 버전은 아직 옮길 수 없습니다. rekordbox에서 USB를 다시 내보내세요"))]
        }
        if library.tracks.isEmpty {
            return [UsbBlock(code: "noTracks", scope: .volume, message: String(ui: "이 USB의 Device Library에 곡이 없어 옮길 것이 없습니다"))]
        }
        return []
    }

    /// 확인 안 된 규칙: 옮기기 자체 + 두 형식 내보내기와 같은 칸 규칙
    static func rules(_ model: UsbLibrary, hasExportExt: Bool) -> Set<UsbProvisionalRule> {
        var rules: Set<UsbProvisionalRule> = [.deviceLibraryMigration]
        if !model.myTagLinks.isEmpty { rules.insert(.myTagLinks) }
        // exportExt.pdb가 없으면 My Tag 마스터 DB ID를 모른다(0으로 둔다)
        if !hasExportExt { rules.insert(.myTagMasterDBID) }
        if model.tracks.contains(where: { $0.imageID == nil }) { rules.insert(.artworkMissing) }
        if !model.playlists.isEmpty { rules.insert(.playlistSiblingBase) }
        if model.playlists.contains(where: { $0.attribute == 1 }) { rules.insert(.playlistFolderRow) }
        for track in model.tracks {
            let flags = UsbTrackMetadataFlags(hasLabel: track.labelID != nil, hasRemixer: track.remixerID != nil,
                                              hasOriginalArtist: track.originalArtistID != nil, hasLyricist: !track.lyricist.isEmpty,
                                              hasColor: track.colorID != 0, hasRating: track.rating != 0, hasSubtitle: !track.subtitle.isEmpty)
            if flags.hasAny { rules.insert(.metadataSeenEmptyOnly) }
        }
        return rules
    }

    // MARK: - 파일

    /// b 그림 하나(a 그림의 사본)
    struct ArtworkCopy {
        var imageID: Int
        /// USB 상대 경로
        var source: String
        var destination: String
        var disposition: UsbDisposition
    }

    /// 그림마다 a → b, a_m → b_m(a_m이 있을 때만). b 자리에 같은 바이트가 있으면 다시 쓰지 않고, 다른 파일이 있으면 막는다
    static func artworkCopies(_ library: UsbLibrary, root: UsbRoot, fileSystem: any UsbFileSystem) throws -> (copies: [ArtworkCopy], blocks: [UsbBlock]) {
        var copies: [ArtworkCopy] = []
        func relative(_ path: String) -> String { String(path.drop { $0 == "/" }) }
        func file(_ path: String) throws -> UsbFileStat? {
            guard UsbEditPlanner.isArtworkFile(path), let info = try fileSystem.stat(try root.url(for: path)), info.kind == .file else { return nil }
            return info
        }
        for image in library.images.sorted(by: { $0.id < $1.id }) {
            guard let pdbPath = image.pdbPath, let bPath = oneLibraryArtworkPath(pdbPath, imageID: image.id),
                  try file(relative(pdbPath)) != nil else {
                return ([], [Blocks.artworkMissing])
            }
            let pairs = [(relative(pdbPath), relative(bPath)),
                         (relative(UsbEditPlanner.mediumArtworkPath(pdbPath)), relative(UsbEditPlanner.mediumArtworkPath(bPath)))]
            for (index, (source, destination)) in pairs.enumerated() {
                // 작은 그림(a)은 위에서 확인했다. 중간 그림(a_m)은 있을 때만 옮긴다
                let present = try index == 0 || file(source) != nil
                guard present else { continue }
                var disposition = UsbDisposition.create
                if let existing = try fileSystem.stat(try root.url(for: destination)) {
                    guard existing.kind == .file, try fileSystem.sha256(try root.url(for: destination), uncached: true)
                        == fileSystem.sha256(try root.url(for: source), uncached: true) else { return ([], [Blocks.artworkExists]) }
                    disposition = .reuse
                }
                copies.append(ArtworkCopy(imageID: image.id, source: source, destination: destination, disposition: disposition))
            }
        }
        return (copies, [])
    }

    /// USB `.2EX`(곡의 분석 경로에서 확장자만 바꾼 것)의 PVDI에 본문이 있는 곡. 없거나 읽지 못하면 보컬이 아닌 것으로 본다
    static func vocalTracks(_ library: UsbLibrary, root: UsbRoot, fileSystem: any UsbFileSystem) throws -> Set<Int> {
        var vocal: Set<Int> = []
        for track in library.tracks {
            let dat = String(track.analysisDataPath.drop { $0 == "/" })
            guard dat.uppercased().hasSuffix(".DAT"), let url = try? root.url(for: String(dat.dropLast(4)) + ".2EX"),
                  let info = try fileSystem.stat(url), info.kind == .file, info.size <= maxAnalysisBytes,
                  let file = try? AnlzFile(data: try fileSystem.read(url, maxBytes: Int(info.size))) else { continue }
            if let pvdi = file.tag("PVDI"), pvdi.bytes.count > AnlzMasks.emptyPVDI.count { vocal.insert(track.id) }
        }
        return vocal
    }

    /// 분석 파일 하나를 읽는 한계(그보다 큰 파일은 분석 파일이 아니다)
    static let maxAnalysisBytes: Int64 = 64 << 20

    /// 준비 폴더에 새 DB와 b 그림을 만들고 변경 묶음을 적는다
    static func stage(_ model: UsbLibrary, artwork: [ArtworkCopy], snapshot: UsbSnapshot, root: UsbRoot, fileSystem: any UsbFileSystem,
                      staging: URL, session: String, rules: Set<UsbProvisionalRule>) throws -> UsbChangeSet {
        let fm = FileManager.default
        let database = staging.appending(path: UsbLayout.oneLibrary)
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try OneLibraryWriter.create(model, at: database)
        let databaseData = try Data(contentsOf: database)
        var target: [String: UsbTreeStamp] = [:]
        // 원래 pdb는 바뀌지 않아야 한다
        for (path, stamp) in snapshot.fingerprint.files { target[path] = UsbTreeStamp(size: stamp.size, sha256: stamp.sha256) }
        let replacement = UsbDatabaseReplacement(format: .oneLibrary, destination: UsbLayout.oneLibrary, staged: database.path,
                                                 sha256: sha256(databaseData), size: Int64(databaseData.count))
        target[UsbLayout.oneLibrary] = UsbTreeStamp(size: replacement.size, sha256: replacement.sha256)

        var writes: [UsbFileWrite] = []
        for copy in artwork {
            let source = try root.url(for: copy.source)
            guard let info = try fileSystem.stat(source), info.kind == .file else { throw UsbError.readFailed(detail: "artwork \(copy.imageID)") }
            let data = try fileSystem.read(source, maxBytes: Int(info.size))
            let staged = staging.appending(path: copy.destination)
            if copy.disposition == .create {
                try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: staged, options: .withoutOverwriting)
            }
            let hash = sha256(data)
            writes.append(UsbFileWrite(staged: staged.path, destination: copy.destination, sha256: hash, size: Int64(data.count),
                                       modificationDate: info.modificationDate, disposition: copy.disposition))
            target[copy.destination] = UsbTreeStamp(size: Int64(data.count), sha256: hash)
        }
        return UsbChangeSet(session: session, label: label, purpose: .edit, formats: [.oneLibrary], requiredRules: rules,
                            databases: [replacement], copies: [], writes: writes, removals: [], base: snapshot.fingerprint,
                            target: UsbTargetFingerprint(mustExist: target, mustNotExist: []), stagingDirectory: staging.path,
                            idHighWater: [:])
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: - 막힘 문구

    public enum Blocks {
        public static var oneLibraryExists: UsbBlock {
            UsbBlock(code: "oneLibraryExists", scope: .format(.oneLibrary),
                     message: String(ui: "이 USB에는 이미 OneLibrary가 있습니다. 옮기지 않고 USB 수정으로 고치세요"))
        }

        static var noDeviceLibrary: UsbBlock {
            UsbBlock(code: "noDeviceLibrary", scope: .volume,
                     message: String(ui: "이 USB에는 Device Library(export.pdb)가 없습니다. 빈 USB면 USB로 내보내기를 쓰세요"))
        }

        static var artworkMissing: UsbBlock {
            UsbBlock(code: "artworkMissingOnUsb", scope: .volume,
                     message: String(ui: "USB의 앨범아트 파일이 없거나 경로 모양이 달라 옮기지 않았습니다. rekordbox에서 USB를 다시 내보내세요"))
        }

        static var artworkExists: UsbBlock {
            UsbBlock(code: "artworkExists", scope: .volume,
                     message: String(ui: "OneLibrary 앨범아트 자리에 다른 파일이 있어 옮기지 않았습니다. rekordbox에서 USB를 다시 내보내세요"))
        }

        static func filesMismatch(detail: String) -> UsbBlock {
            UsbBlock(code: "libraryFilesMismatch", scope: .volume,
                     message: String(ui: "USB 파일이 Device Library와 맞지 않아 옮기지 않았습니다(\(detail)). rekordbox에서 USB를 다시 내보내세요"))
        }
    }
}

extension UsbMigrationResult {
    /// 쓰기 뒤 검증기: 목표 지문(원래 pdb 그대로 포함) · 새 OneLibrary = 변환 모델 · 두 형식 불변식
    public func verifiers(preexistingAppleDoubles: Set<String> = []) -> [any UsbWriteVerifier] {
        var result: [any UsbWriteVerifier] = [UsbFingerprintVerifier()]
        if let library { result.append(OneLibraryVerifier(expected: library)) }
        result.append(UsbInvariantVerifier(preexistingAppleDoubles: preexistingAppleDoubles, preexistingProblems: preexistingProblems))
        return result
    }
}

/// 옮기기의 쓰기 전 확인(A 단계)을 한 번 더: 계획 뒤 쓰기 전까지 USB가 옮길 수 있는 모양 그대로인지 본다.
/// 계획 base(pdb 지문)가 같은지는 쓰기 절차가 본다(`usbChanged`). 여기서는 ① OneLibrary DB 하나만 새로 만들고(그 파일·사이드카가 없음)
/// ② 덮어쓰기·지우기·음원 복사가 없고 ③ 두 pdb 머리 0x10 = 5인지 본다.
public struct UsbMigrationInspector: UsbWriteInspector {
    public init() {}

    public func blocks(root: UsbRoot, changes: UsbChangeSet) throws -> [UsbBlock] {
        var blocks: [UsbBlock] = []
        let onlyOneLibrary = changes.databases.count == 1 && changes.databases[0].format == .oneLibrary
            && changes.databases[0].destination == UsbLayout.oneLibrary
        let present = try ([UsbLayout.oneLibrary] + UsbLayout.oneLibrarySidecarSuffixes.map { UsbLayout.oneLibrary + $0 })
            .contains { try UsbEditInspector.fileSize(root, $0) != nil }
        if !onlyOneLibrary || present { blocks.append(UsbMigration.Blocks.oneLibraryExists) }
        if !changes.copies.isEmpty || !changes.removals.isEmpty || changes.writes.contains(where: { $0.disposition == .overwrite }) {
            blocks.append(UsbBlock(code: "migrateChangesFiles", scope: .volume,
                                   message: String(ui: "OneLibrary로 옮기기는 있던 파일을 바꾸지 않습니다. USB를 다시 읽은 뒤 옮기세요")))
        }
        for path in [UsbLayout.exportPdb, UsbLayout.exportExtPdb] {
            guard let flag = try UsbEditInspector.headerFlag(root, path), flag != PdbVerifier.closedFlag else { continue }
            blocks.append(UsbBlock(code: "pdbNotClosed", scope: .format(.deviceLibrary),
                                   message: String(ui: "rekordbox에 이 USB를 연결했다가 정상적으로 꺼낸 뒤 다시 시도하세요")))
            break
        }
        return blocks
    }
}
