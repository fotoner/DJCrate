import DJCDomain
import Foundation

/// 앱·CLI의 USB 내보내기 한 번(유스케이스 입력): 로컬 스냅샷 사본의 목록·곡을 어느 볼륨에 어떤 형식으로
public struct UsbExportInput: Sendable, Equatable {
    /// 로컬 스냅샷 사본(라이브 master.db는 세션이 거부한다)
    public var database: URL
    /// 로컬 rekordbox share(읽기만)
    public var share: URL
    public var volume: UsbVolumeInfo
    public var selection: UsbSelection
    public var formats: Set<UsbFormat>
    /// ISO 8601 스냅샷 시각(nil이면 사본 이름 → mtime)
    public var snapshotTime: String?
    /// 부분 선택을 적용한 로컬·iTunes 목록. nil이면 DB 목록을 읽는다
    public var playlistLayout: PlaylistLayout?
    /// rekordbox가 다시 여는 USB 동기화 선택(일반 내보내기는 nil)
    public var syncSelection: UsbSyncSelectionDraft?

    public init(database: URL, share: URL, volume: UsbVolumeInfo, selection: UsbSelection, formats: Set<UsbFormat>, snapshotTime: String?,
                playlistLayout: PlaylistLayout? = nil, syncSelection: UsbSyncSelectionDraft? = nil) {
        self.database = database
        self.share = share
        self.volume = volume
        self.selection = selection
        self.formats = formats
        self.snapshotTime = snapshotTime
        self.playlistLayout = playlistLayout
        self.syncSelection = syncSelection
    }

    public var root: URL { URL(filePath: volume.mountPoint) }

    /// 앱은 쓰기 확인 창(볼륨 이름을 보인다)이 CLI의 --confirm을 대신하고, 확인한 볼륨의 UUID를 넘긴다
    public var options: UsbExportOptions {
        UsbExportOptions(formats: formats, confirmName: volume.name, expectedVolumeUUID: UsbWriteService.confirmedUUID(volume),
                         snapshotTime: snapshotTime, playlistLayout: playlistLayout, syncSelection: syncSelection)
    }
}

/// 앱의 USB 수정 한 번(유스케이스 입력): 이 볼륨에 쌓인 초안을 쓴다(`UsbEditSession.writeDraft`)
public struct UsbEditInput: Sendable, Equatable {
    /// 앱이 이미 연 로컬 스냅샷 사본(곡 더하기·갱신과 음원 지우기 확인에 쓴다. 새로 뜨지 않는다)
    public var database: URL?
    /// 로컬 rekordbox share(읽기만)
    public var share: URL?
    public var volume: UsbVolumeInfo
    /// ISO 8601 스냅샷 시각(nil이면 사본 이름 → mtime)
    public var snapshotTime: String?

    public init(database: URL?, share: URL?, volume: UsbVolumeInfo, snapshotTime: String?) {
        self.database = database
        self.share = share
        self.volume = volume
        self.snapshotTime = snapshotTime
    }

    public var root: URL { URL(filePath: volume.mountPoint) }
}

/// 볼륨 쓰기 저널 상태. 닫힌 상태(`UsbJournalState.closed`)가 아닌 저널만 끝나지 않은 쓰기로 본다
public enum UsbJournalInfo: Equatable, Sendable {
    case none
    case state(UsbJournalState)
    /// 저널 파일을 읽지 못함(쓰기·회복 모두 막힌다)
    case unreadable

    /// 끝나지 않은 쓰기. 드라이 런·다시 계획은 닫힌 상태라 알리지 않는다
    public var isPending: Bool {
        if case let .state(state) = self { !state.isClosed } else { false }
    }
}

/// USB 쓰기 유스케이스(주도 포트): 앱의 쓰기 흐름(`UsbWriteCoordinator`)·사이드바가 부른다. 모두 메인 액터 밖에서 부른다.
/// 실제 구현은 `UsbWriteService`(포트로 세션·쓰기 절차를 잇는다), 앱 시험은 가짜.
public protocol UsbWriting: Sendable {
    /// 목록 캐시와 별개로 그 마운트의 현재 정보를 다시 읽는다. 폴더를 만들거나 USB에 쓰지 않는다
    func currentVolume(_ volume: UsbVolumeInfo) throws -> UsbVolumeInfo
    /// 보관한 native 선택을 이어 쓰기 전에 원문도 다시 읽는다
    func syncSelectionBaseFiles(_ volume: UsbVolumeInfo, formats: Set<UsbFormat>) throws -> [UsbFormat: Data]
    func journal(volumeKey: String) -> UsbJournalInfo
    /// 계획·막힘·준비까지(USB에 쓰지 않는다)
    func preview(_ input: UsbExportInput) throws -> UsbExportSummary
    func write(_ input: UsbExportInput, progress: @escaping @Sendable (UsbProgress) -> Void,
               isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport
    func previewMigration(_ volume: UsbVolumeInfo) throws -> UsbMigrationSummary
    func writeMigration(_ volume: UsbVolumeInfo, progress: @escaping @Sendable (UsbProgress) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) throws -> UsbMigrationWritten
    func recover(_ volume: UsbVolumeInfo) throws -> UsbWriteReport
    /// backup: 되돌릴 쓰기의 백업 폴더(nil이면 이 볼륨의 가장 최근 백업)
    func restore(_ volume: UsbVolumeInfo, backup: URL?, discardDeviceChanges: Bool) throws -> UsbWriteReport
    /// 이 볼륨의 가장 최근 백업 폴더(실패 알림의 "백업 폴더 열기")
    func latestBackup(volumeKey: String) -> URL?
    /// 초안을 처음 만들 때의 base: 지금 USB DB 지문(DB 파일의 크기·해시만 읽는다)
    func draftBase(_ volume: UsbVolumeInfo) throws -> UsbFingerprint
    /// 이 볼륨 초안의 계획·막힘·준비까지(USB에 쓰지 않는다)
    func previewEdit(_ input: UsbEditInput) throws -> UsbEditSummary
    /// 초안을 쓴다. 쓴 뒤 초안에는 막힌 편집만 남는다(`UsbEditSession.writeDraft`)
    func writeEdit(_ input: UsbEditInput, progress: @escaping @Sendable (UsbProgress) -> Void,
                   isCancelled: @escaping @Sendable () -> Bool) throws -> UsbEditWritten
    /// 마운트 지점이 임시 폴더 뿌리 아래인지(쓰기 세션의 실물 관문과 같은 판정, 편집 막힘 미리 판정이 쓴다)
    func isScratchMount(_ mountPoint: String) -> Bool
    /// 동기화 선택 파일의 쓰기 관문 규칙(편집 막힘 미리 판정·동기화 창이 쓴다)
    var syncGate: UsbSyncSelectionGate { get }
    /// rekordbox·rekordboxAgent가 켜져 있는지(쓰기 절차의 가드와 같은 판정)
    func isRekordboxRunning() -> Bool
    /// USB 큐·그리드 가져오기의 읽기: 그 자리 볼륨을 다시 보고 사본을 떠서, 곡마다 만들 초안과 건너뛸 이유를 계획한다(초안 파일은 쓰지 않는다)
    func planCueGridImport(volume: UsbVolumeInfo, snapshot: URL, share: URL, scratch: URL,
                           rows: [String: UsbCueGridImportTrack]) throws -> UsbCueGridImportPlan
}

extension UsbWriting {
    /// 새 사전 확인을 구현하지 않은 창구는 native 경로를 허용하지 않는다. 일반 작업은 이 API를 부르지 않는다.
    public func currentVolume(_ volume: UsbVolumeInfo) throws -> UsbVolumeInfo {
        throw UsbError.writeRefused([UsbBlock(code: "volumeChanged", scope: .volume,
                                            message: String(ui: "USB가 바뀌었습니다. USB를 다시 읽은 뒤 동기화하세요"))])
    }

    public func syncSelectionBaseFiles(_ volume: UsbVolumeInfo, formats: Set<UsbFormat>) throws -> [UsbFormat: Data] {
        throw UsbError.writeRefused([UsbBlock(code: "syncSourceChanged", scope: .volume,
                                            message: String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요"))])
    }
}

extension UsbVolumeInfo {
    /// 여유 용량은 신원이 아니고 하위 Writer가 다시 검사한다. 나머지 장치·정책 정보는 계속 같아야 한다.
    public func matchesSyncWriteVolume(_ expected: UsbVolumeInfo) -> Bool {
        var actual = self, confirmed = expected
        actual.available = confirmed.available
        actual.volumeUUID = actual.volumeUUID?.uppercased()
        confirmed.volumeUUID = confirmed.volumeUUID?.uppercased()
        return actual == confirmed
    }
}

/// USB 쓰기 유스케이스의 실제 구현: 내보내기는 `UsbExportSession`, 수정(초안)은 `UsbEditSession`, 옮기기는 `UsbMigrateSession`,
/// 회복·되돌리기·저널·백업은 엔진의 쓰기 절차(`UsbWriter`). 앱(`UsbWriteCoordinator`)과 CLI(`UsbCommands`)가 함께 쓴다.
/// 가드·Mac 쪽 폴더·포트는 기본값 없이 조립 지점(앱 `AppComposition`, CLI `CLIComposition`)이 넘긴다.
public struct UsbWriteService: UsbWriting {
    public var paths: UsbWritePaths
    /// 세션 로컬 사본(`local-<세션>/`)·USB DB 사본(`usb-<세션>/`)을 둘 곳
    public var localCopies: URL
    /// 부를 때마다 새로 만든다(앱: 쓰기 확인 창을 거친 쓰기를 실물 동의로 본다, CLI: `--allow-physical`)
    public var writeGuard: @Sendable () -> UsbWriteGuard
    public var engine: UsbLibraryEngine
    public var device: UsbDevice
    /// USB 초안 파일
    public var drafts: UsbDraftFiles
    /// 지금 시각
    public var now: @Sendable () -> Date
    /// USB를 읽기 직전에 그 자리의 볼륨을 다시 본다(기본은 `UsbRead.currentVolume`, 시험은 바꿔 넣는다)
    public var recheck: @Sendable (UsbVolumeInfo) throws -> UsbVolumeInfo

    public init(paths: UsbWritePaths, localCopies: URL, writeGuard: @escaping @Sendable () -> UsbWriteGuard, engine: UsbLibraryEngine,
                device: UsbDevice, drafts: UsbDraftFiles, now: @escaping @Sendable () -> Date) {
        self.paths = paths
        self.localCopies = localCopies
        self.writeGuard = writeGuard
        self.engine = engine
        self.device = device
        self.drafts = drafts
        self.now = now
        let reader = UsbRead(engine: engine, device: device)
        recheck = { try reader.currentVolume(matching: $0) }
    }

    /// 같은 엔진·이 Mac의 일로 USB를 읽기만 하는 유스케이스
    public var reader: UsbRead { UsbRead(engine: engine, device: device) }

    // MARK: - 세션(앱·CLI 공용)

    public func exportSession(database: URL, share: URL, root: URL) -> UsbExportSession {
        UsbExportSession(database: database, share: share, root: root, guard: writeGuard(), paths: paths, engine: engine, device: device,
                         localCopies: localCopies, now: now)
    }

    /// 로컬 사본은 넘겨받은 스냅샷 사본이다. 세션이 곡 더하기·갱신 때만 `local-<세션>/`에 따로 뜨고 끝나면 지운다
    public func editSession(root: URL, database: URL?, share: URL?) -> UsbEditSession {
        UsbEditSession(root: root, database: database, share: share, guard: writeGuard(), paths: paths, engine: engine, device: device,
                       localCopies: localCopies, drafts: drafts, now: now)
    }

    public func migrateSession(root: URL) -> UsbMigrateSession {
        UsbMigrateSession(root: root, guard: writeGuard(), paths: paths, engine: engine, device: device, copies: localCopies)
    }

    /// 끝나지 않은 쓰기를 마치거나 되돌린다(쓰기와 같은 확인·실물 관문을 먼저 거친다)
    public func recover(root: URL, discardTemp: Bool = false, confirmName: String?, expectedVolumeUUID: String?) throws -> UsbWriteReport {
        try engine.writer.recover(UsbRecoverRequest(root: root, paths: paths, guard: writeGuard(), discardTemp: discardTemp,
                                                    confirmName: confirmName, expectedVolumeUUID: expectedVolumeUUID))
    }

    /// 끝난 쓰기를 그 쓰기의 백업으로 되돌린다(backup이 nil이면 이 볼륨의 가장 최근 백업)
    public func restore(root: URL, backup: URL?, discardDeviceChanges: Bool, confirmName: String?, dryRun: Bool = false,
                        expectedVolumeUUID: String?) throws -> UsbWriteReport {
        try engine.writer.restore(UsbRestoreRequest(root: root, paths: paths, guard: writeGuard(), backup: backup,
                                                    discardDeviceChanges: discardDeviceChanges, confirmName: confirmName, dryRun: dryRun,
                                                    expectedVolumeUUID: expectedVolumeUUID))
    }

    // MARK: - 앱의 쓰기 흐름

    public func currentVolume(_ volume: UsbVolumeInfo) throws -> UsbVolumeInfo { try recheck(volume) }

    public func syncSelectionBaseFiles(_ volume: UsbVolumeInfo, formats: Set<UsbFormat>) throws -> [UsbFormat: Data] {
        let current = try recheck(volume)
        guard current.matchesSyncWriteVolume(volume) else { throw UsbError.cancelled }
        return try engine.syncSelectionFiles(URL(filePath: current.mountPoint), formats)
    }

    public func journal(volumeKey: String) -> UsbJournalInfo {
        switch engine.writer.journalStatus(paths, volumeKey) {
        case .missing: .none
        case let .open(state), let .closed(state, _): .state(state)
        case .corrupt: .unreadable
        }
    }

    public func preview(_ input: UsbExportInput) throws -> UsbExportSummary {
        try makeFolders()
        let preview = try exportSession(database: input.database, share: input.share, root: input.root)
            .preview(selection: input.selection, options: input.options)
        return UsbExportSummary(preview: preview, volume: input.volume)
    }

    public func write(_ input: UsbExportInput, progress: @escaping @Sendable (UsbProgress) -> Void,
                      isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport {
        try makeFolders()
        return try exportSession(database: input.database, share: input.share, root: input.root)
            .write(selection: input.selection, options: input.options, progress: progress, isCancelled: isCancelled)
    }

    public func previewMigration(_ volume: UsbVolumeInfo) throws -> UsbMigrationSummary {
        try makeFolders()
        let result = try migrateSession(root: URL(filePath: volume.mountPoint)).preview(options: UsbWriteOptions(confirmName: volume.name))
        return UsbMigrationSummary(result: result, volume: volume)
    }

    public func writeMigration(_ volume: UsbVolumeInfo, progress: @escaping @Sendable (UsbProgress) -> Void,
                               isCancelled: @escaping @Sendable () -> Bool) throws -> UsbMigrationWritten {
        try makeFolders()
        let (result, report) = try migrateSession(root: URL(filePath: volume.mountPoint))
            .write(options: Self.writeOptions(volume), progress: progress, isCancelled: isCancelled)
        return UsbMigrationWritten(summary: UsbMigrationSummary(result: result, volume: volume), report: report)
    }

    public func recover(_ volume: UsbVolumeInfo) throws -> UsbWriteReport {
        try makeFolders()
        return try recover(root: URL(filePath: volume.mountPoint), confirmName: volume.name, expectedVolumeUUID: Self.confirmedUUID(volume))
    }

    public func restore(_ volume: UsbVolumeInfo, backup: URL?, discardDeviceChanges: Bool) throws -> UsbWriteReport {
        try makeFolders()
        return try restore(root: URL(filePath: volume.mountPoint), backup: backup, discardDeviceChanges: discardDeviceChanges,
                           confirmName: volume.name, expectedVolumeUUID: Self.confirmedUUID(volume))
    }

    public func latestBackup(volumeKey: String) -> URL? {
        engine.writer.backups(paths, volumeKey).first
    }

    /// 사이드바가 들고 있던 볼륨 정보는 앞선 훑기 때 것이라, 같은 자리에 다른 볼륨이 붙었으면 읽지 않는다(사이드바 읽기와 같은 다시 보기)
    public func draftBase(_ volume: UsbVolumeInfo) throws -> UsbFingerprint {
        let current = try recheck(volume)
        return try engine.writer.databaseFingerprint(URL(filePath: current.mountPoint))
    }

    public func previewEdit(_ input: UsbEditInput) throws -> UsbEditSummary {
        try makeFolders()
        guard let (result, edits) = try editSession(root: input.root, database: input.database, share: input.share).previewDraft(
            volume: input.volume, options: UsbWriteOptions(confirmName: input.volume.name), snapshotTime: input.snapshotTime,
            currentBase: { try draftBase(input.volume) }) else {
            return .noDraft(isTestVolume: input.volume.isDiskImage)
        }
        return UsbEditSummary(result: result, edits: edits, volume: input.volume)
    }

    public func writeEdit(_ input: UsbEditInput, progress: @escaping @Sendable (UsbProgress) -> Void,
                          isCancelled: @escaping @Sendable () -> Bool) throws -> UsbEditWritten {
        try makeFolders()
        _ = try UsbEditSession.volumeKey(input.volume)
        let session = editSession(root: input.root, database: input.database, share: input.share)
        let (result, report) = try session.writeDraft(options: Self.writeOptions(input.volume), snapshotTime: input.snapshotTime,
                                                      progress: progress, isCancelled: isCancelled)
        return UsbEditWritten(summary: UsbEditSummary(result: result, edits: session.lastEdits, volume: input.volume), report: report)
    }

    public func isScratchMount(_ mountPoint: String) -> Bool { device.isScratchMount(mountPoint) }

    public var syncGate: UsbSyncSelectionGate { engine.syncGate }

    public func isRekordboxRunning() -> Bool { writeGuard().isRekordboxRunning() }

    public func planCueGridImport(volume: UsbVolumeInfo, snapshot: URL, share: URL, scratch: URL,
                                  rows: [String: UsbCueGridImportTrack]) throws -> UsbCueGridImportPlan {
        try UsbCueGridImportPlan.read(volume: volume, snapshot: snapshot, share: share, scratch: scratch, rows: rows, engine: engine,
                                      device: device, currentVolume: recheck)
    }

    /// 사용자가 확인한 볼륨의 UUID. 쓰기 절차가 열 때 지금 그 자리의 볼륨과 비교한다(그 사이 다른 USB가 붙었으면 막는다).
    /// 볼륨 UUID가 없는 볼륨은 쓰기 절차가 `noVolumeUUID`로 막으므로 비교할 것이 없다
    public static func confirmedUUID(_ volume: UsbVolumeInfo) -> String? { volume.volumeUUID }

    /// 앱의 쓰기 선택: 쓰기 확인 창(볼륨 이름을 보인다)이 CLI의 --confirm을 대신하고, 확인한 볼륨의 UUID를 넘긴다
    public static func writeOptions(_ volume: UsbVolumeInfo) -> UsbWriteOptions {
        UsbWriteOptions(confirmName: volume.name, expectedVolumeUUID: confirmedUUID(volume))
    }

    /// 폴더는 USB에 쓸 때 만든다(저널을 보기만 할 때는 만들지 않는다)
    private func makeFolders() throws {
        try device.makeFolders(paths, [localCopies])
    }
}
