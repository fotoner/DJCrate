import CryptoKit
import DJCDomain
import Darwin
import Foundation

/// 계획과 빌더 결과. 행 크기 막힘으로 뺀 곡은 계획에 없고 `blocks`에만 있다
public struct UsbExportBuild: Sendable {
    public var plan: UsbExportPlan
    public var model: UsbExportModel
    /// 계획의 막힘 + 행 크기 막힘(곡·목록·볼륨)
    public var blocks: [UsbBlock]

    public init(plan: UsbExportPlan, model: UsbExportModel, blocks: [UsbBlock]) {
        self.plan = plan
        self.model = model
        self.blocks = blocks
    }

    /// 볼륨 범위 막힘. 하나라도 있으면 쓰지 않는다(곡을 빼서 풀 수 없다)
    public var volumeBlocks: [UsbBlock] { blocks.filter { $0.scope == .volume } }
}

/// 빈 USB 내보내기의 조립: 계획·빌더 결과 → 준비 폴더(`<staging>/` 아래 USB와 같은 자리)에 DB 셋·분석 파일·아트워크를 만들고
/// 변경 묶음(`UsbChangeSet`)을 돌려준다. USB에는 쓰지 않는다(쓰기는 `UsbWriter.write` 한 곳).
public enum UsbExportAssembly {
    // MARK: - 계획 → 빌더(행 크기 막힘)

    /// 계획 → 빌더. Device Library에 들어가지 않는 곡(행 크기)은 빼고 다시 계획해 ID가 빈틈없게 한다.
    /// 볼륨 막힘(My Tag 이름 등)이 나오면 거기서 멈춘다(돌려준 모델로 조립하지 않는다)
    public static func planAndBuild(_ request: UsbExportRequest, local: UsbLocalSource, share: URL, myTagMasterDBID: Int64,
                                    createdDate: String) throws -> UsbExportBuild {
        var request = request
        var rowBlocks: [UsbBlock] = []
        while true {
            let plan = UsbExportPlanner.plan(request)
            let model = try UsbLibraryBuilder.build(plan: plan, formats: request.formats, local: local, share: share,
                                                    myTagMasterDBID: myTagMasterDBID, createdDate: createdDate)
            let found = rowSizeBlocks(model: model, plan: plan, formats: request.formats)
            rowBlocks += found
            let removed = Set(found.compactMap { block -> String? in if case let .track(id) = block.scope { id } else { nil } })
            let stop = plan.blocked.contains { $0.scope == .volume } || found.contains { $0.scope == .volume }
            if stop || removed.isEmpty {
                return UsbExportBuild(plan: plan, model: model, blocks: plan.blocked + rowBlocks)
            }
            request.candidates.removeAll { removed.contains($0.localContentID) }
        }
    }

    /// Device Library 곡 막힘(쓰기 전에, 할 일이 적힌 문구로). OneLibrary만 쓰면 없다.
    /// 작성기(`PdbWriter.files`)가 곡 하나 때문에 내보내기 전체를 거부하지 않게, 그 곡만 로컬 ID로 막아 빼고 다시 계획한다.
    /// - 트랙 행이 빈 쪽에도 안 들어가면 그 곡
    /// - 파일 확장자가 file_type과 다르면 그 곡
    /// - ISRC가 ASCII가 아니거나 칸 크기를 넘는 값(디스크 번호·연도 등)이 있으면 그 곡
    /// - 아티스트·앨범 행이 빈 쪽에도 안 들어가면 그 이름을 쓰는 곡(긴 이름은 먼 모양으로 쓴다)
    /// - My Tag 행이 안 들어가면 볼륨(My Tag 정의는 곡과 무관하게 모두 들어간다)
    public static func rowSizeBlocks(model: UsbExportModel, plan: UsbExportPlan, formats: Set<UsbFormat>) -> [UsbBlock] {
        guard formats.contains(.deviceLibrary) else { return [] }
        // 작성기와 같은 입력(Device Library 투영)으로 본다
        let library = model.library.projected(to: .deviceLibrary)
        let localIDs = Dictionary(plan.tracks.map { ($0.contentID, $0.localContentID) }) { first, _ in first }
        var blocks: [UsbBlock] = []
        var blocked: Set<Int> = []
        func block(_ track: UsbTrack, _ code: String, _ message: String, rule: UsbProvisionalRule? = nil) {
            guard blocked.insert(track.id).inserted else { return }
            blocks.append(UsbBlock(code: code, scope: .track(localIDs[track.id] ?? "usb:\(track.id)"), message: message, rule: rule))
        }
        let longArtists = Set(library.artists.filter { !PdbRowSize.fitsEmptyPage(rowSize: PdbRowSize.artist(name: $0.name)) }.map(\.id))
        let longAlbums = Set(library.albums.filter { !PdbRowSize.fitsEmptyPage(rowSize: PdbRowSize.album(name: $0.name)) }.map(\.id))
        let albumArtists = Dictionary(library.albums.map { ($0.id, $0.artistID) }) { first, _ in first }
        for track in library.tracks {
            if !PdbRowSize.fitsEmptyPage(rowSize: PdbRowSize.track(track, library: library)) {
                block(track, "trackRowTooLarge", String(ui: "곡 정보가 너무 길어 Device Library에 쓸 수 없습니다. rekordbox에서 주석 등 곡 정보를 줄인 뒤 다시 시도하세요"))
                continue
            }
            if !PdbWriter.fileTypeMatchesExtension(track) {
                block(track, "fileTypeMismatchForDeviceLibrary",
                      String(ui: "파일 확장자가 음원 형식과 달라 Device Library에 쓸 수 없습니다. rekordbox에서 트랙 정보를 다시 읽은 뒤 다시 시도하세요"))
                continue
            }
            if let refusal = trackRowRefusal(track) {
                block(track, refusal.code, refusal.message)
                continue
            }
            let artists = [track.artistID, track.remixerID, track.originalArtistID, track.composerID, track.albumID.flatMap { albumArtists[$0] ?? nil }]
                .compactMap { $0 }
            if artists.contains(where: longArtists.contains) || track.albumID.map(longAlbums.contains) == true {
                block(track, "nameTooLongForDeviceLibrary",
                      String(ui: "아티스트·앨범 이름이 너무 길어 아직 내보낼 수 없습니다. rekordbox에서 이름을 줄인 뒤 다시 시도하세요"))
            }
        }
        if library.myTags.contains(where: { PdbRowSize.tag(name: $0.name) > PdbRowSize.nearShapeLimit }) {
            blocks.append(UsbBlock(code: "myTagNameTooLongForDeviceLibrary", scope: .volume,
                                   message: String(ui: "My Tag 이름이 너무 길어 Device Library에 쓸 수 없습니다. rekordbox에서 My Tag 이름을 줄인 뒤 다시 시도하세요"),
                                   rule: .pdbFarOffsetRows))
        }
        return blocks
    }

    /// 트랙 행을 작성기와 같은 인코더로 만들어 본다. 만들 수 없으면 (code, 할 일이 적힌 문구)
    static func trackRowRefusal(_ track: UsbTrack) -> (code: String, message: String)? {
        do {
            _ = try PdbRowEncoder.track(track)
            return nil
        } catch PdbRowError.isrcNotASCII {
            return ("isrcNotASCIIForDeviceLibrary",
                    String(ui: "ISRC에 전각·한글처럼 ASCII가 아닌 글자가 있어 Device Library에 쓸 수 없습니다. rekordbox에서 ISRC를 반각 영문·숫자로 고친 뒤 다시 시도하세요"))
        } catch let PdbRowError.valueOutOfRange(field) {
            return ("valueOutOfRangeForDeviceLibrary",
                    String(ui: "곡 정보(\(field)) 값이 Device Library 칸 범위를 벗어납니다. rekordbox에서 곡 정보를 고친 뒤 다시 시도하세요"))
        } catch {
            // 트랙 행 인코더가 던지는 그 밖의 오류(행 크기)는 행 크기 막힘과 같다
            return ("trackRowTooLarge",
                    String(ui: "곡 정보가 너무 길어 Device Library에 쓸 수 없습니다. rekordbox에서 주석 등 곡 정보를 줄인 뒤 다시 시도하세요"))
        }
    }

    // MARK: - 조립

    public static func assemble(model: UsbExportModel, plan: UsbExportPlan, localDatabase: CipherDatabase, share: URL,
                                staging: URL, formats: Set<UsbFormat>, session: String) throws -> (UsbChangeSet, [UsbBlock]) {
        let result = try assembled(model: model, plan: plan, localDatabase: localDatabase, share: share, staging: staging, formats: formats,
                                   session: session)
        return (result.changes, result.warnings)
    }

    /// 준비 폴더(없거나 빈 폴더)에 파일을 만들고 변경 묶음을 돌려준다.
    /// - settingsFolder: 기기 설정 파일을 옮길 때 로컬 설정 폴더(세 이름만 연다, `settingFiles` 규칙). nil이면 만들지 않는다
    /// - progress: (끝낸 곡, 곡 수). isCancelled가 참이면 `UsbError.cancelled`
    public static func assembled(model: UsbExportModel, plan: UsbExportPlan, localDatabase: CipherDatabase, share: URL, staging: URL,
                                 formats: Set<UsbFormat>, session: String, settingsFolder: URL? = nil,
                                 syncSelection: UsbSyncSelectionDraft? = nil,
                                 progress: (Int, Int) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }) throws -> UsbExportAssembled {
        if let syncSelection, let block = UsbSyncSelectionStage.gateBlock(baseFiles: syncSelection.baseFiles, formats: formats) {
            throw UsbError.writeRefused([block])
        }
        guard !formats.isEmpty, !model.library.tracks.isEmpty else {
            throw UsbError.writeRefused([UsbBlock(code: "noTracks", scope: .volume,
                                                  message: String(ui: "내보낼 곡이 없습니다. 막힌 곡의 이유를 확인한 뒤 다시 시도하세요"))])
        }
        let sizeBlocks = rowSizeBlocks(model: model, plan: plan, formats: formats)
        if !sizeBlocks.isEmpty { throw UsbError.writeRefused(sizeBlocks) }
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.path), (try? fm.contentsOfDirectory(atPath: staging.path))?.isEmpty != true {
            throw UsbError.readFailed(detail: "staging not empty")
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var context = Context(staging: staging)
        let staged = try stageTracks(model: model, plan: plan, localDatabase: localDatabase, into: &context, progress: progress,
                                     isCancelled: isCancelled)
        let warnings = plan.warnings + staged.warnings
        let anlzRules = staged.rules

        var requiredRules = plan.requiredRules.union(anlzRules)
        if let settingsFolder {
            try stageSettings(from: settingsFolder, into: &context)
            requiredRules.insert(.settingFiles)
        }

        var pdbWritten: UsbLibrary?
        var pdbRulesByTrack: [Int: Set<UsbProvisionalRule>] = [:]
        if formats.contains(.oneLibrary) {
            let url = try context.prepare(UsbLayout.oneLibrary)
            try OneLibraryWriter.create(model.library, at: url)
            let problems = try OneLibraryWriter.verify(url, expected: model.library)
            guard problems.isEmpty else { throw UsbError.readFailed(detail: "OneLibrary verify: " + problems.prefix(5).joined(separator: "; ")) }
            try context.database(.oneLibrary, UsbLayout.oneLibrary, data: Data(contentsOf: url))
        }
        if formats.contains(.deviceLibrary) {
            let pdb = try PdbWriter.files(model.library, mode: .fresh)
            let problems = try PdbRoundTrip.check(export: pdb.export, exportExt: pdb.exportExt)
            guard problems.isEmpty else {
                throw UsbError.writeRefused([UsbBlock(code: "pdbRoundTripFailed", scope: .format(.deviceLibrary),
                                                      message: String(ui: "Device Library를 만들었지만 다시 읽은 결과가 달라 쓰지 않았습니다. 곡을 줄여 다시 시도하세요"))])
            }
            try context.database(.deviceLibrary, UsbLayout.exportPdb, data: pdb.export, write: true)
            try context.database(.deviceLibrary, UsbLayout.exportExtPdb, data: pdb.exportExt, write: true)
            // 인코더가 실제로 쓴 긴 ASCII(장르·레이블·키·My Tag·메뉴 이름 포함)를 버리지 않는다
            requiredRules.formUnion(pdb.rules)
            pdbRulesByTrack = pdb.rulesByTrack
            pdbWritten = pdb.written
        }

        var ruleCounts: [UsbProvisionalRule: Int] = [:]
        for trackPlan in plan.tracks {
            for rule in trackPlan.rules.union(pdbRulesByTrack[trackPlan.contentID] ?? []) { ruleCounts[rule, default: 0] += 1 }
        }
        let highWater = ["content": plan.tracks.map(\.contentID).max() ?? 0, "image": plan.tracks.compactMap(\.imageID).max() ?? 0,
                         "playlist": plan.playlists.map(\.playlistID).max() ?? 0].filter { $0.value > 0 }
        var syncVerification: UsbSyncSelectionVerification?
        if let syncSelection {
            guard let contract = UsbSyncXMLWriteContract.production,
                  try UsbLocalSource(database: localDatabase).localDBID() == syncSelection.localDBID,
                  syncSelection.baseFiles.isEmpty, plan.blocked.allSatisfy(\.isSkippableInSync) else {
                throw UsbError.writeRefused([UsbSyncSelectionStage.incompleteBlock])
            }
            let ids = Dictionary(plan.playlists.map { ($0.localID, $0.playlistID) }, uniquingKeysWith: { first, _ in first })
            syncVerification = try UsbSyncSelectionStage.stage(syncSelection, formats: formats, model: model.library, createdIDs: [:],
                                                              allocatedIDs: ids, root: nil, fileSystem: PosixUsbFileSystem(),
                                                              into: &context, contract: contract)
        }
        let changes = UsbChangeSet(session: session, label: "export", purpose: .export, formats: formats, requiredRules: requiredRules,
                                   databases: context.databases, copies: context.copies, writes: context.writes, removals: [], base: nil,
                                   target: UsbTargetFingerprint(mustExist: context.target, mustNotExist: []),
                                   stagingDirectory: staging.path, idHighWater: highWater, syncSelection: syncVerification)
        return UsbExportAssembled(changes: changes, warnings: unique(warnings), library: model.library, pdbWritten: pdbWritten,
                                  ruleCounts: ruleCounts, audioSizeFromDatabase: audioSizeFromDatabase(plan))
    }

    /// 곡마다 음원 복사 목록·아트워크·분석 파일을 준비 폴더에 만든다(내보내기·USB에 곡 더하기가 같이 쓴다).
    /// 이미 USB에 있는 같은 음원(재사용)도 목록에 넣는다. 돌려주는 것은 분석 파일 변환 경고·규칙
    static func stageTracks(model: UsbExportModel, plan: UsbExportPlan, localDatabase: CipherDatabase, into context: inout Context,
                            progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws -> (warnings: [UsbBlock], rules: Set<UsbProvisionalRule>) {
        let tracks = Dictionary(model.library.tracks.map { ($0.id, $0) }) { first, _ in first }
        let files = Dictionary(grouping: model.files, by: \.contentID)
        let cues = UsbCueSource(database: localDatabase)
        var warnings: [UsbBlock] = []
        var anlzRules: Set<UsbProvisionalRule> = []
        for (index, trackPlan) in plan.tracks.enumerated() {
            if isCancelled() { throw UsbError.cancelled }
            guard let track = tracks[trackPlan.contentID] else { throw UsbError.readFailed(detail: "track missing: \(trackPlan.contentID)") }
            let id = trackPlan.localContentID
            for file in files[trackPlan.contentID] ?? [] {
                switch file.kind {
                case let .audio(source):
                    // 복사 크기는 계획 때 본 실제 파일 크기다. DB 칸(`fileSize`)은 로컬 FileSize라 분석 뒤 바뀐 곡은 다르다(rekordbox와 같게)
                    let copy = UsbFileCopy(source: source, destination: UsbLayout.nfc(file.destination), size: trackPlan.audioSize ?? track.fileSize,
                                           sourceSHA1: nil,
                                           modificationDate: try modificationDate(source, "audio", content: id), disposition: .create)
                    context.copies.append(copy)
                    context.target[copy.destination] = UsbTreeStamp(size: copy.size, sha256: nil)
                case let .artwork(source):
                    try context.stage(readLocal(source, "artwork", content: id), at: file.destination,
                                      modified: modificationDate(source, "artwork", content: id))
                case let .analysis(localDAT, localEXT, local2EX, localContentID):
                    let result = try UsbAnlzTransform.transform(
                        localDAT: readLocal(localDAT, "analysis", content: id), localEXT: readLocal(localEXT, "analysis", content: id),
                        local2EX: try local2EX.map { try readLocal($0, "analysis", content: id) }, contentsPath: track.path,
                        cues: cues.cues(contentID: localContentID), fileType: track.fileType)
                    let base = String(file.destination.dropLast(4))
                    try context.stage(result.dat, at: base + ".DAT", modified: nil)
                    try context.stage(result.ext, at: base + ".EXT", modified: nil)
                    if let twoEx = result.twoEx { try context.stage(twoEx, at: base + ".2EX", modified: nil) }
                    anlzRules.formUnion(result.rules)
                    warnings += result.warnings.compactMap { analysisWarning($0, track: trackPlan.localContentID) }
                }
            }
            progress(index + 1, plan.tracks.count)
        }
        try addReusedAudio(plan: plan, localDatabase: localDatabase, into: &context)
        return (warnings, anlzRules)
    }

    /// 쓰기 뒤 검증기: 목표 지문 · (형식별) OneLibrary · Device Library · 불변식.
    /// preexistingAppleDoubles: 쓰기 직전 USB의 `._*`(`UsbInvariantVerifier.appleDoubles(on:)`) — 이 쓰기가 남긴 것만 센다
    public static func verifiers(for assembled: UsbExportAssembled, preexistingAppleDoubles: Set<String> = []) -> [any UsbWriteVerifier] {
        var result: [any UsbWriteVerifier] = [UsbFingerprintVerifier()]
        if assembled.changes.formats.contains(.oneLibrary) { result.append(OneLibraryVerifier(expected: assembled.library)) }
        if let written = assembled.pdbWritten { result.append(PdbVerifier(expected: written)) }
        result.append(UsbInvariantVerifier(preexistingAppleDoubles: preexistingAppleDoubles,
                                           audioSizeFromDatabase: assembled.audioSizeFromDatabase))
        return result
    }

    /// 두 DB의 파일 크기 칸(로컬 FileSize)이 복사한 음원과 다른 곡(USB content id)
    static func audioSizeFromDatabase(_ plan: UsbExportPlan) -> Set<Int> {
        Set(plan.tracks.filter { $0.rules.contains(.audioChangedSinceAnalysis) }.map(\.contentID))
    }

    /// 분석 파일 바이트에서 PPTH 경로(쓰기 절차의 덮어쓰기·지우기 확인용). 읽지 못하면 nil
    public static let ppthReader: @Sendable (Data) -> String? = { data in
        (try? AnlzFile(data: data))?.tag("PPTH").flatMap { try? AnlzPathTag.decode($0.bytes) }
    }

    // MARK: - 이미 Contents/가 있는 USB

    /// 루트 바로 아래 `Contents/`(철자 무관)를 이름만 훑어 계획기가 볼 기존 상태를 만든다. 없으면 nil.
    /// 폴더·파일의 실제 철자와 폴더마다 이름의 충돌 키를 넣는다(파일은 열지 않는다. 열지 않는 경로로는 내려가지 않는다)
    public static func existingContents(root: UsbRoot) throws -> UsbExistingState? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.url.path)) ?? []
        guard let name = names.first(where: { UsbLayout.collisionKey($0) == UsbLayout.collisionKey(UsbLayout.contents) }) else { return nil }
        var info = Darwin.stat()
        guard lstat(root.url.appending(path: name).path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let top = UsbLayout.nfc(name)
        var used: [String: Set<String>] = ["": [UsbLayout.collisionKey(top)]]
        var spelling: [String: String] = [UsbExistingState.key(forPath: top): top]
        for entry in try UsbTree.walk(root, under: name) {
            let path = entry.relativePath
            let parent = (path as NSString).deletingLastPathComponent, last = (path as NSString).lastPathComponent
            used[UsbExistingState.key(forPath: parent), default: []].insert(UsbLayout.collisionKey(last))
            spelling[UsbExistingState.key(forPath: path)] = path
        }
        return .contentsOnly(usedCollisionKeys: used, folderSpelling: spelling)
    }

    // MARK: - 도우미

    /// 준비 폴더에 만든 파일 목록
    struct Context {
        let staging: URL
        var copies: [UsbFileCopy] = []
        var writes: [UsbFileWrite] = []
        var databases: [UsbDatabaseReplacement] = []
        var target: [String: UsbTreeStamp] = [:]

        init(staging: URL) {
            self.staging = staging
        }

        /// 준비 폴더 안 자리(부모 폴더를 만든다). USB 상대 경로 모양이 아니면(`..`·절대 경로 등) 준비 폴더 밖을 가리킬 수 있어 거부한다
        func prepare(_ relative: String) throws -> URL {
            guard UsbWriter.isSafeRelativePath(relative) else { throw UsbError.readFailed(detail: "unsafe staging path") }
            let url = staging.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return url
        }

        /// replacing: USB에 있던 파일을 바꿀 때 그 파일의 계획 때 해시와(분석 파일이면) 있어야 할 PPTH
        mutating func stage(_ data: Data, at destination: String, modified: Date?,
                            replacing existing: (sha256: String, ppth: String?)? = nil) throws {
            let destination = UsbLayout.nfc(destination)
            let url = try prepare(destination)
            try data.write(to: url, options: .withoutOverwriting)
            let hash = UsbExportAssembly.sha256(data)
            writes.append(UsbFileWrite(staged: url.path, destination: destination, sha256: hash, size: Int64(data.count),
                                       modificationDate: modified, disposition: existing == nil ? .create : .overwrite,
                                       expectedExistingPPTH: existing?.ppth, expectedExistingSHA256: existing?.sha256))
            target[destination] = UsbTreeStamp(size: Int64(data.count), sha256: hash)
        }

        mutating func database(_ format: UsbFormat, _ destination: String, data: Data, write: Bool = false) throws {
            let url = try prepare(destination)
            if write { try data.write(to: url, options: .withoutOverwriting) }
            let hash = UsbExportAssembly.sha256(data)
            databases.append(UsbDatabaseReplacement(format: format, destination: destination, staged: url.path, sha256: hash,
                                                    size: Int64(data.count)))
            target[destination] = UsbTreeStamp(size: Int64(data.count), sha256: hash)
        }
    }

    /// USB에 이미 있는 같은 내용의 음원(계획이 재사용으로 정한 것). 이 묶음이 만드는 파일을 함께 쓰는 곡은 빼고,
    /// 로컬 원본의 SHA-1·SHA-256으로 USB 파일이 그대로인지 보게 한다
    static func addReusedAudio(plan: UsbExportPlan, localDatabase: CipherDatabase, into context: inout Context) throws {
        var listed = Set(context.copies.map { UsbLayout.collisionKey($0.destination) })
        let local = UsbLocalSource(database: localDatabase)
        for trackPlan in plan.tracks where trackPlan.audioDisposition == .reuse {
            let destination = UsbLayout.nfc(String(trackPlan.contentsPath.drop { $0 == "/" }))
            guard listed.insert(UsbLayout.collisionKey(destination)).inserted else { continue }
            let row = try local.track(trackPlan.localContentID)
            guard let source = row.folderPath else { continue }
            let hashes = try fileHashes(source, content: trackPlan.localContentID)
            context.copies.append(UsbFileCopy(source: source, destination: destination, size: hashes.size, sourceSHA1: hashes.sha1,
                                              modificationDate: try modificationDate(source, "audio", content: trackPlan.localContentID),
                                              disposition: .reuse))
            context.target[destination] = UsbTreeStamp(size: hashes.size, sha256: hashes.sha256)
        }
    }

    /// 파일을 한 번 읽으며 크기·SHA-1·SHA-256(음원은 커서 통째로 올리지 않는다).
    /// 오류에는 로컬 ID만 적는다(음원 파일 이름은 보통 곡 제목이고, CLI는 오류를 그대로 찍는다)
    static func fileHashes(_ path: String, content: String) throws -> (size: Int64, sha1: String, sha256: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw UsbError.readFailed(detail: "open audio content \(content)")
        }
        defer { try? handle.close() }
        var one = Insecure.SHA1(), two = SHA256()
        var size: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                one.update(data: chunk)
                two.update(data: chunk)
                size += Int64(chunk.count)
            }
        } catch {
            throw UsbError.readFailed(detail: "read audio content \(content)")
        }
        func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }
        return (size, hex(one.finalize()), hex(two.finalize()))
    }

    /// 로컬 설정 폴더의 세 파일(MYSETTING·MYSETTING2·DJMMYSETTING)을 내보내기 모양으로 옮긴다. 하나라도 만들지 못하면 막는다
    static func stageSettings(from folder: URL, into context: inout Context) throws {
        for kind in DeviceSettingFile.Kind.exported.sorted(by: { $0.fileName < $1.fileName }) {
            let output: DeviceSettingFile
            do {
                output = try DeviceSettingPatch.readForExport(localFile: folder.appending(path: kind.fileName)).output
            } catch {
                throw UsbError.writeRefused([UsbBlock(code: "settingFileUnavailable", scope: .file("PIONEER/" + kind.fileName),
                                                      message: String(ui: "기기 설정 파일(\(kind.fileName))을 옮길 수 없습니다. 설정 옮기기를 끄고 다시 시도하세요"),
                                                      rule: .settingFiles)])
            }
            try context.stage(output.bytes, at: "PIONEER/" + kind.fileName, modified: nil)
        }
    }

    /// 분석 파일 변환 경고 → 보고용 막힘 모양(막지 않음). 계획이 이미 낸 Kind 4 경고와 같은 code로 맞춘다
    static func analysisWarning(_ raw: String, track: String) -> UsbBlock? {
        guard let warning = UsbAnlzWarning(rawValue: raw) else { return nil }
        let (code, message): (String, String) = switch warning {
        case .cueKindDropped: ("kind4CueDropped", String(ui: "USB에 쓸 수 없는 종류의 큐가 있어 빼고 내보냅니다"))
        case .maskedLocalPSSIDropped:
            ("analysisPSSIMasked", String(ui: "로컬 분석 파일의 프레이즈 정보를 읽을 수 없어 빼고 내보냅니다. rekordbox에서 다시 분석하면 들어갑니다"))
        case .cueCreatedAtUnparsed: (raw, String(ui: "큐 만든 시각을 읽지 못해 이름 순서로 큐를 놓았습니다"))
        case .cueTagMissing: (raw, String(ui: "로컬 분석 파일에 큐 자리가 없어 일부 큐를 쓰지 못했습니다. rekordbox에서 다시 분석하세요"))
        case .maskedLocalPVDIKept: (raw, String(ui: "로컬 분석 파일의 보컬 정보를 그대로 옮겼습니다"))
        case .unknownLocalPVDIDropped: (raw, String(ui: "로컬 분석 파일의 보컬 정보를 읽을 수 없어 빼고 내보냅니다"))
        }
        return UsbBlock(code: code, scope: .track(track), message: message)
    }

    static func unique(_ blocks: [UsbBlock]) -> [UsbBlock] {
        var seen: Set<String> = []
        return blocks.filter { seen.insert("\($0.code)\u{0}\($0.scope)").inserted }
    }

    /// 로컬 파일의 수정 시각. 오류에는 파일 이름·경로 없이 종류와 로컬 ID만 적는다
    static func modificationDate(_ path: String, _ kind: String, content: String) throws -> Date {
        if let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date { return date }
        throw UsbError.readFailed(detail: "mtime \(kind) content \(content)")
    }

    /// 로컬 파일(아트워크·분석 파일)을 읽는다. 오류에는 파일 이름·경로 없이 종류와 로컬 ID만 적는다
    static func readLocal(_ path: String, _ kind: String, content: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(filePath: path))
        } catch {
            throw UsbError.readFailed(detail: "read \(kind) content \(content)")
        }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
