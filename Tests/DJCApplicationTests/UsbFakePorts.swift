import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation

/// 가짜 USB 포트(엔진·이 Mac의 일·가드): 부른 것을 차례로 적고 정해 둔 값을 돌려준다. USB·DB·Mac 파일을 건드리지 않는다.
/// 세션은 메인 액터 밖에서도 부르므로 상태는 잠금 안에서만 바꾼다. 실제 구현이 지키는 약속(없는 폴더 지우기는 넘어감 등)은
/// DJCAdaptersTests `UsbPortAssumptionTests`가 실제 구현에서 확인한다.
final class FakeUsbPorts: @unchecked Sendable {
    static let snapshotDate = Date(timeIntervalSince1970: 1_800_000_000)
    static let root = URL(filePath: "/Volumes/DJCTEST")
    static let database = URL(filePath: "/private/tmp/djc-fixture/master-copy.db")
    static let share = URL(filePath: "/private/tmp/djc-fixture/share")
    static let paths = UsbWritePaths(backups: URL(filePath: "/private/tmp/djc-fixture/usb-backups"),
                                     sessions: URL(filePath: "/private/tmp/djc-fixture/usb-sessions"),
                                     staging: URL(filePath: "/private/tmp/djc-fixture/usb-staging"))
    static let copies = URL(filePath: "/private/tmp/djc-fixture/usb-snapshots")

    /// 가짜가 연 로컬 사본(닫았는지 센다)
    final class Opened: UsbOpenedLibrary, @unchecked Sendable {
        let ports: FakeUsbPorts
        init(_ ports: FakeUsbPorts) { self.ports = ports }
        func close() { ports.record("close") }
    }

    struct State {
        /// 부른 순서(이름만, 인자는 따로 적는다)
        var calls: [String] = []
        // 이 Mac
        var appVersion: String? = "7.2.18"
        var verifiedVersions: Set<String> = ["7.2.18"]
        var liveDatabases: Set<URL> = []
        var snapshotTime: Result<Date, UsbError> = .success(FakeUsbPorts.snapshotDate)
        /// realpath 결과가 임시 폴더 아래인지(디스크 이미지 판정)
        var underScratch = true
        /// realpath → 마운트 지점(없으면 nil)
        var mountedOn: [String: String] = [:]
        /// 볼륨 정보 읽기 결과(목록 다시 보기·폴더 대상 판정)
        var volumeInfo: Result<UsbVolumeInfo, UsbError> = .success(FakeUsbVolume.diskImageFAT32())
        var existing: Set<URL> = []
        var folderNames: [URL: [String]] = [:]
        var stamps: [URL: UsbLocalFileStamp] = [:]
        var removed: [URL] = []
        var copied: [(database: URL, into: URL)] = []
        var madeFolders = 0
        // 가드
        var volume = FakeUsbVolume.diskImageFAT32()
        var gate = FakeUsbVolume.gate()
        var protectedRoots: [URL] = []
        var rekordboxRunning = false
        // 내보내기
        var hasLibrary = false
        var leftover: UsbBlock?
        var tree: Result<[UsbPlaylistInput], UsbError> = .success([])
        var candidates: [UsbExportCandidate] = []
        /// nil이면 요청을 계획기(`UsbExportPlanner`)로 계획한다
        var buildBlocks: [UsbBlock] = []
        var assembled: Result<UsbExportAssembled, UsbError>?
        // 수정
        var editSourceBlocks: [UsbBlock] = []
        var editResult = UsbEditResult()
        var editPlans: [UsbEditPlanInputRecord] = []
        // 옮기기
        var migration = UsbMigrationResult()
        // 쓰기·저널
        var journal: UsbJournalStatus = .missing
        /// 차례로 돌려주는 USB DB 지문(마지막 것을 계속 쓴다)
        var fingerprints: [UsbFingerprint] = [UsbFingerprint(files: [:])]
        var preexisting: Set<String> = []
        var writeResult: Result<UsbWriteReport, UsbError> = .success(UsbWriteReport(outcome: .written, session: "s1"))
        var writes: [UsbWriteRequestRecord] = []
        var recoverResult: Result<UsbWriteReport, UsbError> = .success(UsbWriteReport(outcome: .recovered, session: "s1"))
        var recovers: [UsbRecoverRequest] = []
        var restoreResult: Result<UsbWriteReport, UsbError> = .success(UsbWriteReport(outcome: .restored, session: "s1"))
        var restores: [UsbRestoreRequest] = []
        var backups: [URL] = []
        var syncFiles: [UsbFormat: Data] = [:]
        // 동기화 관문
        var syncGateBlock: UsbBlock?
        // 읽기(`UsbRead`·큐 그리드 가져오기)
        var rekordboxFileNames: Set<String> = []
        var databaseCopy: Result<UsbDatabaseCopy, UsbError> = .success(FakeUsbPorts.copy())
        var oneLibrary: Result<UsbLibrary, UsbError> = .success(UsbLibrary(formats: [.oneLibrary], property: UsbProperty(dbVersion: "1000")))
        var deviceLibrary: Result<UsbDeviceLibraryRead, UsbError>?
        var pdbCopy: (export: URL, ext: URL?)?
        var regularFiles: Set<String> = []
        var analysisTrackPaths: [String: String] = [:]
        // 큐·그리드
        var localKeys: LocalLibraryKeys = LocalLibraryKeys(localDBID: 1, tracks: [], counters: [:])
        var deviceCueContentIDs: Set<Int> = []
        var trackReads: [Int: Result<UsbCueGridRead, UsbCueGridReadFailure>] = [:]
        var localGrid = BeatGrid(beats: [])
        var databasesUnchanged = true
    }

    /// 세션이 엔진 쓰기에 넘긴 것(요청에는 닫힘이 있어 고를 칸만 적는다)
    struct UsbWriteRequestRecord {
        var verification: String
        var root: URL
        var options: UsbWriteOptions
        var preexisting: Set<String>
        var guardGate: UsbPhysicalWriteGate
    }

    struct UsbEditPlanInputRecord {
        var edits: [UsbLibraryEdit]
        var hasLocal: Bool
        var highWater: [String: Int]
        var snapshotTakenAt: Date?
        var staging: URL
    }

    private let lock = NSLock()
    private var state = State()

    init(_ configure: (inout State) -> Void = { _ in }) { configure(&state) }

    func update(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }
    var current: State { lock.withLock { state } }
    var calls: [String] { current.calls }

    func record(_ call: String) { lock.withLock { state.calls.append(call) } }
    private func read<T>(_ call: String, _ body: (inout State) -> T) -> T {
        lock.withLock {
            state.calls.append(call)
            return body(&state)
        }
    }

    static func copy(oneLibrary: Bool = true, pdb: Bool = true, fingerprint: UsbFingerprint = UsbFingerprint(files: [:])) -> UsbDatabaseCopy {
        UsbDatabaseCopy(oneLibrary: oneLibrary ? URL(filePath: "/private/tmp/djc-fixture/copy/exportLibrary.db") : nil,
                        exportPdb: pdb ? URL(filePath: "/private/tmp/djc-fixture/copy/export.pdb") : nil,
                        exportExtPdb: pdb ? URL(filePath: "/private/tmp/djc-fixture/copy/exportExt.pdb") : nil,
                        fingerprint: fingerprint, rollbackHeader: false, walPresent: false, journalPresent: false)
    }

    // MARK: - 포트

    var writeGuard: UsbWriteGuard {
        let state = current
        return UsbWriteGuard(volume: { [self] _ in read("volume") { $0.volume } }, isRekordboxRunning: { state.rekordboxRunning },
                             protectedRoots: state.protectedRoots, gate: state.gate)
    }

    var device: UsbDevice {
        UsbDevice(
            appVersion: { [self] in current.appVersion },
            isVerifiedVersion: { [self] in current.verifiedVersions.contains($0) },
            isLiveDatabase: { [self] url in read("isLive") { $0.liveDatabases.contains(url) } },
            copyLocalDatabase: { [self] database, into in
                read("copyLocal") { $0.copied.append((database, into)) }
                return into.appending(path: database.lastPathComponent)
            },
            snapshotTime: { [self] explicit, _ in
                let result = read("snapshotTime") { $0.snapshotTime }
                return (try result.get(), explicit == nil ? .fileName : .explicit)
            },
            realPath: { $0 },
            isUnderScratch: { [self] _ in current.underScratch },
            mountedOn: { [self] path in current.mountedOn[path] },
            volumeInfo: { [self] _ in try read("volumeInfo") { $0.volumeInfo }.get() },
            exists: { [self] url in current.existing.contains(url) },
            names: { [self] url in current.folderNames[url] },
            remove: { [self] url in read("remove") { $0.removed.append(url) } },
            stat: { [self] url in current.stamps[url] },
            makeFolders: { [self] _, _ in read("makeFolders") { $0.madeFolders += 1 } })
    }

    var engine: UsbLibraryEngine {
        UsbLibraryEngine(
            openLocal: { [self] _ in
                record("openLocal")
                return Opened(self)
            },
            read: .init(
                rekordboxFileNames: { [self] _ in read("rekordboxFileNames") { $0.rekordboxFileNames } },
                exists: { [self] _, relative in current.regularFiles.contains(relative) },
                isRegularFile: { [self] _, relative in current.regularFiles.contains(relative) },
                copyDatabases: { [self] _, _ in try read("copyDatabases") { $0.databaseCopy }.get() },
                copyPdb: { [self] _, _ in read("copyPdb") { $0.pdbCopy } },
                oneLibrary: { [self] _ in try read("oneLibrary") { $0.oneLibrary }.get() },
                deviceLibrary: { [self] _, _ in
                    let result = read("deviceLibrary") { $0.deviceLibrary }
                    guard let result else { throw UsbError.readFailed(detail: "no pdb") }
                    return try result.get()
                },
                roundTrip: { [self] _, _ in read("roundTrip") { _ in [] } },
                analysisTrackPath: { [self] _, relative in current.analysisTrackPaths[relative] },
                settings: { _ in [] }),
            export: .init(
                hasLibrary: { [self] _ in read("hasLibrary") { $0.hasLibrary } },
                leftoverBlock: { [self] _ in read("leftover") { $0.leftover } },
                existingContents: { [self] _ in read("existingContents") { _ in nil } },
                layoutTree: { [self] _, _ in try read("layoutTree") { $0.tree }.get() },
                playlistTree: { [self] _, _ in try read("playlistTree") { $0.tree }.get() },
                candidates: { [self] _, _, ids in
                    read("candidates") { state in state.candidates.filter { ids.contains($0.localContentID) } }
                },
                sameContent: { _, _ in false },
                build: { [self] request, _, _, _ in
                    let blocks = read("build") { $0.buildBlocks }
                    let plan = UsbExportPlanner.plan(request)
                    return UsbExportBuilt(plan: plan, blocks: plan.blocked + blocks, model: "가짜 모델")
                },
                assemble: { [self] input in
                    let result = read("assemble") { $0.assembled }
                    return try (result ?? .success(Self.assembled(staging: input.staging))).get()
                }),
            edit: .init(
                load: { [self] _, _ in UsbEditSourceRead(blocks: read("editLoad") { $0.editSourceBlocks }, source: "가짜 원본") },
                plan: { [self] input in
                    read("editPlan") { state in
                        state.editPlans.append(UsbEditPlanInputRecord(edits: input.edits, hasLocal: input.local != nil, highWater: input.highWater,
                                                                      snapshotTakenAt: input.snapshotTakenAt, staging: input.staging))
                        return state.editResult
                    }
                }),
            migration: .init(
                oneLibraryExistsBlock: UsbBlock(code: "oneLibraryExists", scope: .format(.oneLibrary), message: "이미 OneLibrary가 있음"),
                plan: { [self] _, _, _, _ in read("migrationPlan") { $0.migration } }),
            cueGrid: .init(
                localKeys: { [self] _ in read("localKeys") { $0.localKeys } },
                deviceCueContentIDs: { [self] _ in read("deviceCueContentIDs") { $0.deviceCueContentIDs } },
                readTrack: { [self] _, track in
                    let result = read("readTrack \(track.id)") { $0.trackReads[track.id] }
                    guard let result else { throw UsbCueGridReadFailure(message: "가짜: 읽을 곡이 아님") }
                    return try result.get()
                },
                analysisURL: { path, share in path.map { share.appending(path: String($0.drop { $0 == "/" })) } },
                localGrid: { [self] _ in read("localGrid") { $0.localGrid } },
                databasesUnchanged: { [self] _, _ in read("databasesUnchanged") { $0.databasesUnchanged } },
                newCueID: { UUID() }),
            writer: .init(
                preexistingAppleDoubles: { [self] _ in read("appleDoubles") { $0.preexisting } },
                write: { [self] request in
                    try read("write") { state in
                        let kind: String
                        switch request.verification {
                        case .export: kind = "export"
                        case .edit: kind = "edit"
                        case .migration: kind = "migration"
                        }
                        state.writes.append(UsbWriteRequestRecord(verification: kind, root: request.root, options: request.options,
                                                                  preexisting: request.preexistingAppleDoubles, guardGate: request.writeGuard.gate))
                        return state.writeResult
                    }.get()
                },
                recover: { [self] request in try read("recover") { $0.recovers.append(request); return $0.recoverResult }.get() },
                restore: { [self] request in try read("restore") { $0.restores.append(request); return $0.restoreResult }.get() },
                journalStatus: { [self] _, _ in read("journal") { $0.journal } },
                backups: { [self] _, _ in read("backups") { $0.backups } },
                databaseFingerprint: { [self] _ in
                    read("fingerprint") { state in
                        let next = state.fingerprints.first ?? UsbFingerprint(files: [:])
                        if state.fingerprints.count > 1 { state.fingerprints.removeFirst() }
                        return next
                    }
                }),
            syncGate: UsbSyncSelectionGate(gateBlock: { [self] _, _ in current.syncGateBlock }, productionBlock: { nil }, draftBlock: { _ in nil }),
            syncSelectionFiles: { [self] _, _ in read("syncFiles") { $0.syncFiles } })
    }

    // MARK: - 세션

    func exportSession(database: URL = FakeUsbPorts.database) -> UsbExportSession {
        UsbExportSession(database: database, share: Self.share, root: Self.root, guard: writeGuard, paths: Self.paths, engine: engine,
                         device: device, localCopies: Self.copies, now: { FakeUsbPorts.snapshotDate })
    }

    func editSession(database: URL? = FakeUsbPorts.database, drafts: UsbDraftFiles = .memory(now: { FakeUsbPorts.snapshotDate })) -> UsbEditSession {
        UsbEditSession(root: Self.root, database: database, share: Self.share, guard: writeGuard, paths: Self.paths, engine: engine, device: device,
                       localCopies: Self.copies, drafts: drafts, now: { FakeUsbPorts.snapshotDate })
    }

    func migrateSession() -> UsbMigrateSession {
        UsbMigrateSession(root: Self.root, guard: writeGuard, paths: Self.paths, engine: engine, device: device, copies: Self.copies)
    }

    // MARK: - 재료

    /// 막는 것이 없는 조립 결과(DB 하나만 바꾼다, 필요 공간은 작다)
    static func assembled(staging: URL, rules: Set<UsbProvisionalRule> = [], databaseSize: Int64 = 1_000) -> UsbExportAssembled {
        UsbExportAssembled(changes: changes(staging: staging, rules: rules, databaseSize: databaseSize), warnings: [],
                           library: UsbLibrary(formats: UsbFormat.defaultSet, property: UsbProperty(dbVersion: "1000")), pdbWritten: nil,
                           ruleCounts: [:])
    }

    static func changes(staging: URL, rules: Set<UsbProvisionalRule> = [], databaseSize: Int64 = 1_000) -> UsbChangeSet {
        UsbChangeSet(session: "s1", label: "가짜", purpose: .export, formats: UsbFormat.defaultSet, requiredRules: rules,
                     databases: [UsbDatabaseReplacement(format: .oneLibrary, destination: UsbLayout.oneLibrary, staged: "db", sha256: "0", size: databaseSize)],
                     copies: [], writes: [], removals: [], base: nil, target: UsbTargetFingerprint(mustExist: [:], mustNotExist: []),
                     stagingDirectory: staging.path, idHighWater: [:])
    }

    /// 읽은 pdb의 보고(머리 0x10 = 5, 표 수만)
    static func pdbReport(issues: [String] = []) -> PdbReadReport {
        let header = PdbFileHeader(pageSize: 4096, numTables: 20, nextUnusedPage: 1, flag10: 5, sequence: 1, gap: 0, tables: [])
        return PdbReadReport(exportHeader: header, extHeader: nil, tableCounts: [:], unknownRows: [], issues: issues, stringKinds: [:],
                             issueDetails: [], pageCounts: [:], longestShortASCII: 0, misalignedUTF16: 0, farShapeRows: [:])
    }

    static func deviceLibrary(_ library: UsbLibrary = UsbLibrary(formats: [.deviceLibrary], property: UsbProperty(dbVersion: "1000")),
                              issues: [String] = []) -> UsbDeviceLibraryRead {
        UsbDeviceLibraryRead(library: library, report: pdbReport(issues: issues))
    }

    /// 계획기를 지나는 곡 후보(분석 끝남·그림 있음, 경로·ID는 지어낸 값)
    static func candidate(_ id: String) -> UsbExportCandidate {
        UsbExportCandidate(
            localContentID: id, masterSongID: id, masterDBID: "424242", artistName: "Artist", albumName: "Album",
            fileNameL: "track \(id).mp3", sourcePath: "/music/\(id)/track \(id).mp3", isStreaming: false, fileType: 1,
            fileSize: 1_000, actualFileSize: 1_000, analysis: .complete, analysisModifiedAt: snapshotDate.addingTimeInterval(-3_600),
            artwork: UsbArtworkSource(smallPath: "/share/\(id)_s.jpg", mediumPath: "/share/\(id)_m.jpg", smallBytes: 3_000, mediumBytes: 20_000),
            artworkPathSetButMissing: false, cues: [], metadata: UsbTrackMetadataFlags())
    }

    /// 세션 사본 폴더(`local-…`)·USB DB 사본(`usb-…`)·준비 폴더를 지웠는지
    func removedCopies(prefix: String) -> [URL] {
        current.removed.filter { Self.isChild($0, of: Self.copies) && $0.lastPathComponent.hasPrefix(prefix) }
    }

    func removedStaging() -> [URL] {
        current.removed.filter { Self.isChild($0, of: Self.paths.staging) }
    }

    /// 바로 아래 항목인지(폴더 URL 끝의 "/"는 보지 않는다)
    static func isChild(_ url: URL, of folder: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
    }
}

extension UsbSyncSelectionGate {
    /// 막지 않는 관문(확인한 계약, 선택 파일 문제 없음). 실제 규칙은 RekordboxKitTests `UsbSyncSelectionXMLTests`
    static let open = UsbSyncSelectionGate(gateBlock: { _, _ in nil }, productionBlock: { nil }, draftBlock: { _ in nil })
}

/// 던진 USB 오류(던지지 않았거나 다른 오류면 nil). `UsbError`는 같음 비교가 없어 사례 이름으로 본다
func thrownUsbError(_ body: () throws -> Void) -> UsbError? {
    do { try body() } catch let error as UsbError { return error } catch { return nil }
    return nil
}

extension UsbError {
    /// 사례 이름과 막힘 code·읽기 실패 detail(비교용)
    var shape: String {
        switch self {
        case let .writeRefused(blocks): "writeRefused " + blocks.map(\.code).joined(separator: ",")
        case let .readFailed(detail): "readFailed " + detail
        case .volumeLost: "volumeLost"
        case .volumeChanged: "volumeChanged"
        case .recoveryNeeded: "recoveryNeeded"
        case .cancelled: "cancelled"
        default: "\(self)"
        }
    }
}
