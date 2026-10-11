import DJCDomain
import Foundation

/// USB 쓰기 흐름이 보는 USB 화면(사이드바)의 상태와 일. 앱은 `UsbStore`가 답한다(부를 때마다 지금 값).
@MainActor
public struct UsbWriteScreen {
    public var volume: @MainActor (String) -> UsbVolumeInfo?
    public var isEjecting: @MainActor (String) -> Bool
    /// 이 볼륨의 쓰기 대기 초안(없으면 nil)
    public var draftEdits: @MainActor (String) -> [UsbLibraryEdit]?
    /// 읽은 라이브러리의 형식(읽지 않았으면 nil)
    public var libraryFormats: @MainActor (String) -> Set<UsbFormat>?
    /// 이 실행이 만든 동기화 초안의 작업·편집·사본 소유권(없으면 nil)
    public var savedSyncDraft: @MainActor (String) -> UsbSavedSyncDraft?
    /// 동기화 초안을 그 작업·출처 확인과 함께 기억한다(확인 취소·실패 뒤에도 같은 초안은 사본을 이어 소유한다)
    public var rememberSyncDraft: @MainActor (UsbEditJob, [UsbLibraryEdit], _ sourceIsCurrent: @escaping @MainActor @Sendable () -> Bool) -> Void
    /// 초안 파일·원래 스냅샷은 남기고 이 실행이 만든 사본의 소유권만 놓는다
    public var invalidateSyncDraft: @MainActor (String) -> Void
    /// 볼륨을 잠그고 덮개를 띄운다(이미 잠겼거나 다른 볼륨에 쓰는 중이면 nil)
    public var beginWrite: @MainActor (UsbVolumeInfo, _ title: String, _ cancellable: Bool) -> UsbCancelFlag?
    /// USB를 모두 다시 읽는다
    public var refresh: @MainActor () async -> Void
    /// 그 볼륨의 초안을 다시 읽는다
    public var reloadDraft: @MainActor (String) async -> Void
    /// 그 볼륨의 초안 고치기 줄에 서서 body를 돌린다(쓰기와 편집 더하기가 겹쳐 편집을 잃지 않게)
    public var draftQueue: @MainActor (String, @escaping @MainActor () async -> Result<UsbEditWritten, any Error>?) async
        -> Result<UsbEditWritten, any Error>?
    /// 초안 고치기(초안을 다루지 않으면 nil)
    public var draftEditing: @MainActor () -> UsbDraftEditing?
    /// 내보내기 시트를 연다(nil이면 닫는다)
    public var setExportSheet: @MainActor (UsbExportSheetRequest?) -> Void
    /// 볼륨을 꺼낸다. 실패하면 이유와 할 일
    public var eject: @MainActor (String) async -> String?

    public init(volume: @escaping @MainActor (String) -> UsbVolumeInfo?, isEjecting: @escaping @MainActor (String) -> Bool,
                draftEdits: @escaping @MainActor (String) -> [UsbLibraryEdit]?, libraryFormats: @escaping @MainActor (String) -> Set<UsbFormat>?,
                savedSyncDraft: @escaping @MainActor (String) -> UsbSavedSyncDraft?,
                rememberSyncDraft: @escaping @MainActor (UsbEditJob, [UsbLibraryEdit], @escaping @MainActor @Sendable () -> Bool) -> Void,
                invalidateSyncDraft: @escaping @MainActor (String) -> Void,
                beginWrite: @escaping @MainActor (UsbVolumeInfo, String, Bool) -> UsbCancelFlag?,
                refresh: @escaping @MainActor () async -> Void, reloadDraft: @escaping @MainActor (String) async -> Void,
                draftQueue: @escaping @MainActor (String, @escaping @MainActor () async -> Result<UsbEditWritten, any Error>?) async
                    -> Result<UsbEditWritten, any Error>?,
                draftEditing: @escaping @MainActor () -> UsbDraftEditing?, setExportSheet: @escaping @MainActor (UsbExportSheetRequest?) -> Void,
                eject: @escaping @MainActor (String) async -> String?) {
        self.volume = volume
        self.isEjecting = isEjecting
        self.draftEdits = draftEdits
        self.libraryFormats = libraryFormats
        self.savedSyncDraft = savedSyncDraft
        self.rememberSyncDraft = rememberSyncDraft
        self.invalidateSyncDraft = invalidateSyncDraft
        self.beginWrite = beginWrite
        self.refresh = refresh
        self.reloadDraft = reloadDraft
        self.draftQueue = draftQueue
        self.draftEditing = draftEditing
        self.setExportSheet = setExportSheet
        self.eject = eject
    }
}

/// 이 실행이 만든 동기화 초안: 만든 때의 작업(출처 문맥 포함)·편집과 그 사본의 소유권
public struct UsbSavedSyncDraft: Sendable {
    public var job: UsbEditJob
    public var edits: [UsbLibraryEdit]
    public let snapshotLease: UsbSyncSnapshotLease

    public init(job: UsbEditJob, edits: [UsbLibraryEdit], snapshotLease: UsbSyncSnapshotLease) {
        self.job = job
        self.edits = edits
        self.snapshotLease = snapshotLease
    }
}

/// USB 쓰기 결과 알림(앱: 창 아래 토스트). 결과는 늘 USB 쓰기 알림이다
public enum UsbWriteToast: Equatable, Sendable {
    /// 끝난 일. 쓴 볼륨이면 꺼내기 단추를 단다
    case success(title: String, detail: String? = nil, ejectVolumeKey: String? = nil)
    /// USB에 손대지 않은 안내(지금은 못 함·할 것 없음): 창 대신 닫을 때까지 남는 경고(#230)
    case notice(title: String, text: String)
}

/// 결과 알리기·오류 문구·폴더 열기(앱: 토스트·`AppErrorMessage`·Finder)
@MainActor
public struct UsbWriteResults {
    public var show: @MainActor (UsbWriteToast) -> Void
    /// 그 볼륨의 꺼내기 단추가 달린 알림이 떠 있으면 닫는다
    public var dismissEject: @MainActor (_ volumeKey: String) -> Void
    /// 막힘이 아닌 오류의 사용자 문구(이유와 할 일)
    public var errorText: @MainActor (any Error) -> String
    /// 알리지 않는 오류 기록
    public var log: @MainActor (any Error) -> Void
    public var openFolder: @MainActor (URL) -> Void

    public init(show: @escaping @MainActor (UsbWriteToast) -> Void, dismissEject: @escaping @MainActor (String) -> Void,
                errorText: @escaping @MainActor (any Error) -> String, log: @escaping @MainActor (any Error) -> Void,
                openFolder: @escaping @MainActor (URL) -> Void) {
        self.show = show
        self.dismissEject = dismissEject
        self.errorText = errorText
        self.log = log
        self.openFolder = openFolder
    }
}

/// USB 내보내기·수정·옮기기·회복·되돌리기 흐름(유스케이스, `ReflectionSession` 본보기):
/// rekordbox·Agent 꺼짐 확인 → 볼륨 잠금 → 미리 보기(준비까지) → 확인 창 → 쓰기(진행·DB 교체 전 취소) → 알림([꺼내기]).
/// 끝나지 않은 쓰기는 알림만 띄우고, 회복·되돌리기는 사용자가 누를 때만 한다. 파일 입출력은 모두 메인 액터 밖에서 한다.
/// 물을지는 이 흐름이 정하고 확인 창(`UserConfirmation`)은 답만 한다. 실물 USB 동의는 확인 창·시트의 쓰기 버튼이고
/// (볼륨 줄 `volumeLines`), 쓰기 창구가 그 동의로 실물 관문을 연다. 앱 화면 쪽(`UsbWriteCoordinator`)은 포트를 붙여 부르기만 한다.
@MainActor
public struct UsbWriteFlow {
    /// 쓰기 세션 상태(잠금·진행·지난 쓰기)
    public let session: UsbWriteSession
    public let screen: UsbWriteScreen
    /// 동기화 원본(선택 당시 원본·revision·스냅샷)이 지금도 같은지. 원본을 모르는 곳은 거짓(native 쓰기를 허용하지 않는다)
    public let syncSourceIsCurrent: @MainActor (UsbExportSyncSourceContext, _ database: URL?, _ share: URL?) -> Bool
    /// USB 쓰기 유스케이스(앱은 조립 지점이 만든 `UsbWriteService`, 시험은 가짜)
    public let service: any UsbWriting
    public let confirmation: UserConfirmation
    public let results: UsbWriteResults
    /// rekordbox·rekordboxAgent가 켜져 있는지(메인 액터 밖에서 부른다). nil이면 쓰기 창구의 가드가 보는 것과 같은 판정
    public let isRekordboxRunning: (@Sendable () -> Bool)?

    public init(session: UsbWriteSession, screen: UsbWriteScreen,
                syncSourceIsCurrent: @escaping @MainActor (UsbExportSyncSourceContext, URL?, URL?) -> Bool, service: any UsbWriting,
                confirmation: UserConfirmation, results: UsbWriteResults, isRekordboxRunning: (@Sendable () -> Bool)?) {
        self.session = session
        self.screen = screen
        self.syncSourceIsCurrent = syncSourceIsCurrent
        self.service = service
        self.confirmation = confirmation
        self.results = results
        self.isRekordboxRunning = isRekordboxRunning
    }

    // MARK: - 내보내기

    /// 시트의 미리 보기. 막히면(rekordbox·잠금·끝나지 않은 쓰기·오류) 알리고 nil
    public func preview(_ job: UsbExportJob) async -> UsbExportSummary? {
        let lease = job.snapshotLease ?? job.syncSourceContext?.snapshot?.lease
        defer { withExtendedLifetime(lease) {} }
        guard exportSourceIsCurrent(job), await ready(job.volume, sourceIsCurrent: { await exportInputsAreCurrent(job) }), exportSourceIsCurrent(job) else { return nil }
        guard let flag = begin(job.volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return nil }
        let service = service
        let result = await BlockingWork.run { Result { try service.preview(job.input) } }
        session.end(job.volumeKey)
        guard await exportInputsAreCurrent(job) else { return nil }
        switch result {
        case let .success(summary):
            return flag.isSet ? nil : summary
        case let .failure(error):
            fail(Text.previewFailedTitle, error)
            return nil
        }
    }

    /// 미리 보기 → 확인 창 → 쓰기 → 토스트. `reusing`이 있으면(시트에서 방금 본 미리 보기) 다시 미리 보지 않는다.
    /// `consented`면 시트가 볼륨 줄(이름·용량·형식·"실물 USB입니다")과 미리 보기를 보인 뒤 누른 [USB에 쓰기]가 쓰기 동의라
    /// 확인 창을 다시 띄우지 않는다(#212). 미리 본 결과가 없으면 지금처럼 확인 창으로 묻는다
    @discardableResult
    public func export(_ job: UsbExportJob, reusing reused: UsbExportSummary? = nil, consented: Bool = false) async -> Bool {
        let lease = job.snapshotLease ?? job.syncSourceContext?.snapshot?.lease
        defer { withExtendedLifetime(lease) {} }
        guard exportSourceIsCurrent(job), await ready(job.volume, sourceIsCurrent: { await exportInputsAreCurrent(job) }), exportSourceIsCurrent(job) else { return false }
        let key = job.volumeKey
        guard let flag = begin(job.volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return false }
        var cached = job
        cached.snapshotLease = nil
        session.lastExports[key] = cached
        session.lastMigrations.remove(key)
        let outcome = await run(job, reused: reused, consented: consented && reused != nil, flag: flag)
        session.end(key)
        switch outcome {
        case .stopped:
            break
        case let .written(summary):
            session.migrationBackups[key] = nil
            let skipped = summary.blockedTrackCount
            results.show(.success(title: Text.writtenTitle(tracks: summary.trackCount),
                                  detail: String(ui: "\(job.volume.name) · 재생 목록 \(summary.playlistCount)개")
                                      + (skipped > 0 ? " · " + String(ui: "USB에 넣지 못한 곡 \(skipped)개") : ""),
                                  ejectVolumeKey: key))
            await screen.refresh()
            return true
        case .cancelled:
            results.show(.success(title: Text.cancelledTitle, detail: Text.unchangedDetail))
        case .recoveryNeeded:
            await offerRecovery(job.volume)
        case let .failed(error):
            await failWrite(error, volumeKey: key, otherwise: Text.notWrittenTitle)
        }
        return false
    }

    /// 잠근 채 한 쓰기의 결과(내보내기·수정 요약)
    private enum Outcome<Summary> {
        case stopped, cancelled, recoveryNeeded
        case written(Summary)
        case failed(any Error)
    }

    /// 잠근 채로 미리 보기·확인·쓰기. 잠금은 부르는 쪽이 푼다
    private func run(_ job: UsbExportJob, reused: UsbExportSummary?, consented: Bool, flag: UsbCancelFlag) async -> Outcome<UsbExportSummary> {
        let service = service, key = job.volumeKey
        let summary: UsbExportSummary
        if let reused {
            summary = reused
        } else {
            switch await BlockingWork.run({ Result { try service.preview(job.input) } }) {
            case let .success(value): summary = value
            case let .failure(error): return previewFailed(error)
            }
        }
        if flag.isSet { return .cancelled }
        guard await exportInputsAreCurrent(job) else { return .stopped }
        guard summary.canWrite else {
            inform(Text.cannotWriteTitle, Self.stoppingText(summary), details: Self.blockLines(summary))
            return .stopped
        }
        let confirmed = consented || confirmation.confirm(Self.confirmation(summary, job: job))
        guard await exportInputsAreCurrent(job), confirmed else { return .stopped }
        // 미리 보기가 남긴 저널(드라이 런)은 닫힌 상태라 막지 않는다. 그 사이 끝나지 않은 쓰기가 생겼으면 회복부터
        if let stop: Outcome<UsbExportSummary> = await journalStop(key, sourceIsCurrent: { await exportInputsAreCurrent(job) }) { return stop }
        guard await exportInputsAreCurrent(job) else { return .stopped }
        let result = await perform(key, actualCheck: { await exportInputsAreCurrent(job) }, sourceIsCurrent: { exportSourceIsCurrent(job) }) { progress in
            try service.write(job.input, progress: progress, isCancelled: { flag.isSet })
        }
        switch result {
        case .success: return .written(summary)
        case let .failure(error): return Self.outcome(of: error)
        }
    }

    /// 쓰기 절차를 메인 액터 밖에서 돌린다. 진행은 순서대로 받아 메인 액터에서 덮개에 보인다
    private func perform<T: Sendable>(_ key: String, actualCheck: @MainActor () async -> Bool = { true }, sourceIsCurrent: @MainActor () -> Bool = { true },
                                      _ body: @escaping @Sendable (_ progress: @escaping @Sendable (UsbProgress) -> Void) throws -> T)
        async -> Result<T, any Error> {
        guard await actualCheck() else { return .failure(UsbError.writeRefused([Self.syncSourceChangedBlock])) }
        session.setTitle(String(ui: "USB에 쓰는 중…"), for: key)
        // actual 확인 await 뒤의 원본·캐시 판정부터 제출까지 양보하지 않는다.
        // 확인 이후의 새 분리는 원자적으로 막을 수 없으므로 하위 Writer의 UUID 검사가 계속 필요하다.
        guard sourceIsCurrent() else { return .failure(UsbError.writeRefused([Self.syncSourceChangedBlock])) }
        let (stream, continuation) = AsyncStream.makeStream(of: UsbProgress.self)
        let session = session
        let consumer = Task { @MainActor in
            for await progress in stream { session.report(progress, for: key) }
        }
        let result = await BlockingWork.run {
            Result { try body { continuation.yield($0) } }
        }
        continuation.finish()
        await consumer.value
        return result
    }

    /// 미리 보기(Mac 사본에서 계획) 실패. USB에는 쓰지 않았으니 쓰기 실패(되돌림)로 알리지 않고 미리 보기 실패로 알린다.
    /// 볼륨이 빠지거나 바뀐 것은 쓰기 실패처럼 알린다(동기화 초안 사본을 놓는다)
    private func previewFailed<Summary>(_ error: any Error) -> Outcome<Summary> {
        switch UsbWriteDecision.afterPreview(error) {
        case .volumeGone: return .failed(error)
        case .cancelled: return .cancelled
        case .previewFailed:
            fail(Text.previewFailedTitle, error)
            return .stopped
        }
    }

    /// 쓰기 실패 → 결과(취소·회복 필요·실패, `UsbWriteDecision.afterWrite`)
    private static func outcome<Summary>(of error: any Error) -> Outcome<Summary> {
        switch UsbWriteDecision.afterWrite(error) {
        case .cancelled: .cancelled
        case .recoveryNeeded: .recoveryNeeded
        case .failed: .failed(error)
        }
    }

    /// 확인 창 뒤: 그 사이 끝나지 않은 쓰기가 생겼으면 회복부터, 저널을 읽지 못하면 멈춘다. 쓰러 가도 되면 nil
    private func journalStop<Summary>(_ key: String, sourceIsCurrent: @MainActor () async -> Bool = { true }) async -> Outcome<Summary>? {
        let service = service
        let journal = await BlockingWork.run { service.journal(volumeKey: key) }
        guard await sourceIsCurrent() else { return .stopped }
        switch UsbWriteDecision.journalCheck(journal) {
        case .proceed: return nil
        case .recoveryNeeded: return .recoveryNeeded
        case .unreadable:
            inform(Text.notWrittenTitle, Self.journalUnreadableText)
            return .stopped
        }
    }

    // MARK: - Device Library → OneLibrary

    public func previewMigration(_ volume: UsbVolumeInfo) async -> UsbMigrationSummary? {
        guard await ready(volume), let flag = begin(volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return nil }
        let service = service
        let result = await BlockingWork.run { Result { try service.previewMigration(volume) } }
        session.end(volume.usbKey)
        switch result {
        case let .success(summary):
            session.migrationBlockReasons[volume.usbKey] = summary.stopping.isEmpty ? nil : summary.stopping
            return flag.isSet ? nil : summary
        case let .failure(error):
            fail(Text.previewFailedTitle, error)
            return nil
        }
    }

    /// CLI와 같은 옮기기 세션: 미리 보기 → 확인 → 쓰기 → 다시 읽기. 원래 파일은 세션의 검증기가 확인한다.
    public func migrate(_ volume: UsbVolumeInfo) async {
        guard await ready(volume), let flag = begin(volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return }
        let key = volume.usbKey
        session.lastMigrations.insert(key)
        session.lastExports[key] = nil
        let outcome = await runMigration(volume, flag: flag)
        session.end(key)
        switch outcome {
        case .stopped: break
        case let .written(written):
            if let backup = written.report?.backup { session.migrationBackups[key] = URL(filePath: backup) }
            results.show(.success(title: Text.migratedTitle,
                                  detail: String(ui: "\(volume.name) · 곡 \(written.summary.trackCount)개 · 재생 목록 \(written.summary.playlistCount)개"),
                                  ejectVolumeKey: key))
            await screen.refresh()
        case .cancelled:
            results.show(.success(title: Text.cancelledTitle, detail: Text.unchangedDetail))
        case .recoveryNeeded: await offerRecovery(volume)
        case let .failed(error):
            if case let UsbError.writeRefused(blocks) = error {
                var seen: Set<String> = []
                session.migrationBlockReasons[key] = blocks.map(\.message).filter { seen.insert($0).inserted }.joined(separator: "\n")
            }
            await failWrite(error, volumeKey: key, otherwise: Text.notWrittenTitle)
        }
    }

    private func runMigration(_ volume: UsbVolumeInfo, flag: UsbCancelFlag) async -> Outcome<UsbMigrationWritten> {
        let service = service, key = volume.usbKey
        let result = await BlockingWork.run { Result { try service.previewMigration(volume) } }
        let summary: UsbMigrationSummary
        switch result {
        case let .success(value): summary = value
        case let .failure(error): return .failed(error)
        }
        if flag.isSet { return .cancelled }
        session.migrationBlockReasons[key] = summary.stopping.isEmpty ? nil : summary.stopping
        guard summary.canWrite else {
            inform(Text.cannotMigrateTitle, summary.stopping.isEmpty
                   ? String(ui: "옮길 곡이 없습니다. USB를 다시 읽은 뒤 확인하세요") : summary.stopping)
            return .stopped
        }
        guard confirmation.confirm(Self.migrationConfirmation(summary, volume: volume)) else { return .stopped }
        if let stop: Outcome<UsbMigrationWritten> = await journalStop(key) { return stop }
        switch await perform(key, { progress in try service.writeMigration(volume, progress: progress, isCancelled: { flag.isSet }) }) {
        case let .success(written):
            guard written.report?.outcome == .written else { return .stopped }
            return .written(written)
        case let .failure(error): return Self.outcome(of: error)
        }
    }

    /// 이 실행에서 옮긴 쓰기의 백업으로만 되돌린다. 다른 쓰기 뒤에는 메뉴를 숨긴다.
    public func restoreMigration(_ volume: UsbVolumeInfo) async {
        guard let backup = session.migrationBackups[volume.usbKey], await ready(volume) else { return }
        guard confirmation.confirm(ReflectionPrompt(title: String(ui: "USB를 쓰기 전으로 되돌릴까요?"),
                                            text: String(ui: "\(volume.name)에 OneLibrary를 더하기 전의 백업으로 되돌립니다. 끝날 때까지 USB를 뽑지 마세요."),
                                            confirm: String(ui: "되돌리기"), destructive: true)) else { return }
        guard begin(volume, title: String(ui: "USB를 되돌리는 중…"), cancellable: false) != nil else { return }
        await restore(volume, backup: backup)
    }

    public static func migrationConfirmation(_ summary: UsbMigrationSummary, volume: UsbVolumeInfo) -> ReflectionPrompt {
        var details = [String(ui: "곡 \(summary.trackCount)개 · 재생 목록 \(summary.playlistCount)개 · 새 앨범아트 파일 \(summary.artworkFiles)개")]
        details += volumeLines(volume, isTestVolume: summary.isTestVolume)
        details += summary.notes
        details += deviceCheckLines(summary.rules.map { ($0, 0) }, trackCount: 0)
        return ReflectionPrompt(title: String(ui: "OneLibrary를 더할까요?"),
                                text: String(ui: "\(volume.name)의 Device Library를 읽어 OneLibrary를 더합니다. 쓰기 전에 Mac에 백업하고 쓴 뒤 USB에서 다시 읽어 확인합니다. 끝날 때까지 USB를 뽑지 마세요."),
                                confirm: String(ui: "OneLibrary 더하기"), details: details)
    }

    // MARK: - 수정(초안)

    /// native 초안은 선택 때 보관한 작업을 쓴다. 새 스냅샷이나 현재 원본으로 옛 초안의 출처를 다시 만들지 않는다.
    private func editJob(_ volumeKey: String, database: URL?, share: URL?, snapshotTime: String?) -> UsbEditJob? {
        guard let volume = screen.volume(volumeKey) else {
            screen.invalidateSyncDraft(volumeKey)
            notify(Text.notWrittenTitle, Text.connectFirstDetail)
            return nil
        }
        let edits = screen.draftEdits(volumeKey) ?? []
        if Self.hasSyncSelection(edits) {
            guard let saved = screen.savedSyncDraft(volumeKey), saved.edits == edits,
                  saved.job.syncSourceContext?.snapshot?.provenance.sourceURL == database,
                  saved.job.share == share, volume.matchesSyncWriteVolume(saved.job.volume),
                  snapshotTime == nil || snapshotTime == (saved.job.snapshotTime ?? saved.job.syncSourceContext?.snapshot?.provenance.snapshotTime) else {
                screen.invalidateSyncDraft(volumeKey)
                notify(Text.notWrittenTitle, Self.syncDraftUnavailableText)
                return nil
            }
            return saved.job
        }
        return UsbEditJob(database: database, share: share, volume: volume, snapshotTime: snapshotTime)
    }

    private static func hasSyncSelection(_ edits: [UsbLibraryEdit]) -> Bool {
        edits.contains { if case .syncSelection = $0 { true } else { false } }
    }

    private static var syncDraftUnavailableText: String {
        String(ui: "동기화 초안의 원본을 다시 준비해야 하므로 쓰기 대기 목록에서 초안을 버린 뒤 USB 동기화 창을 새로고침하세요")
    }

    private static var syncSourceChangedBlock: UsbBlock {
        UsbBlock(code: "syncSourceChanged", scope: .volume,
                 message: String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요"))
    }

    private func sourceIsCurrent(_ context: UsbExportSyncSourceContext?, database: URL?, share: URL?, required: Bool) -> Bool {
        guard required || context != nil else { return true }
        guard !Task.isCancelled, let context, let snapshot = context.snapshot, snapshot.lease != nil, database == snapshot.database,
              syncSourceIsCurrent(context, database, share) else {
            notify(Text.notWrittenTitle, Self.syncSourceChangedBlock.message)
            return false
        }
        return true
    }

    private func nativeVolumeIsCurrent(_ volume: UsbVolumeInfo) -> Bool {
        guard screen.volume(volume.usbKey)?.matchesSyncWriteVolume(volume) == true, !screen.isEjecting(volume.usbKey) else {
            screen.invalidateSyncDraft(volume.usbKey)
            notify(Text.notWrittenTitle, String(ui: "USB가 바뀌었습니다. USB를 다시 읽은 뒤 동기화하세요"))
            return false
        }
        return true
    }

    private func exportSourceIsCurrent(_ job: UsbExportJob) -> Bool {
        let native = job.syncSelection != nil || job.syncSourceContext != nil
        guard !native || nativeVolumeIsCurrent(job.volume) else { return false }
        return sourceIsCurrent(job.syncSourceContext, database: job.database, share: job.share, required: job.syncSelection != nil)
    }

    private func editSourceIsCurrent(_ job: UsbEditJob, edits: [UsbLibraryEdit]) -> Bool {
        let native = Self.hasSyncSelection(edits) || job.syncSourceContext != nil
        guard !native || nativeVolumeIsCurrent(job.volume) else { return false }
        if job.syncSourceContext != nil {
            guard let saved = screen.savedSyncDraft(job.volumeKey), saved.job == job, saved.edits == edits,
                  screen.draftEdits(job.volumeKey) == edits else {
                screen.invalidateSyncDraft(job.volumeKey)
                notify(Text.notWrittenTitle, Self.syncDraftUnavailableText)
                return false
            }
        }
        let current = sourceIsCurrent(job.syncSourceContext, database: job.database, share: job.share, required: Self.hasSyncSelection(edits))
        if !current, !Task.isCancelled {
            screen.invalidateSyncDraft(job.volumeKey)
            notify(Text.notWrittenTitle, Self.syncDraftUnavailableText)
        }
        return current
    }

    private func nativeInputsAreCurrent(_ volume: UsbVolumeInfo, baseFiles: [UsbFormat: Data]?, formats: Set<UsbFormat>,
                                        sourceIsCurrent: @MainActor () -> Bool) async -> Bool {
        guard sourceIsCurrent() else { return false }
        let service = service
        let result = await BlockingWork.run {
            Result {
                let actual = try service.currentVolume(volume)
                // 교체를 발견했으면 원문 파일도 읽지 않는다.
                guard actual.matchesSyncWriteVolume(volume) else { throw UsbError.cancelled }
                let files = try baseFiles.map { _ in try service.syncSelectionBaseFiles(actual, formats: formats) }
                return (actual, files)
            }
        }
        // actual 확인 중 원본·epoch·초안·캐시가 바뀌어도 옛 결과를 채택하지 않는다.
        guard sourceIsCurrent() else { return false }
        guard case let .success((actual, files)) = result, actual.matchesSyncWriteVolume(volume), files == baseFiles else {
            screen.invalidateSyncDraft(volume.usbKey)
            notify(Text.notWrittenTitle, String(ui: "USB가 바뀌었습니다. USB를 다시 읽은 뒤 동기화하세요"))
            return false
        }
        return true
    }

    private func exportInputsAreCurrent(_ job: UsbExportJob) async -> Bool {
        guard job.syncSelection != nil || job.syncSourceContext != nil else { return exportSourceIsCurrent(job) }
        return await nativeInputsAreCurrent(job.volume, baseFiles: job.syncSelection?.baseFiles, formats: job.formats,
                                            sourceIsCurrent: { exportSourceIsCurrent(job) })
    }

    private func editInputsAreCurrent(_ job: UsbEditJob, edits: [UsbLibraryEdit]) async -> Bool {
        guard Self.hasSyncSelection(edits) || job.syncSourceContext != nil else { return editSourceIsCurrent(job, edits: edits) }
        let bases = edits.compactMap { edit -> [UsbFormat: Data]? in
            if case let .syncSelection(draft) = edit { return draft.baseFiles }
            return nil
        }
        guard bases.dropFirst().allSatisfy({ $0 == bases.first }) else {
            screen.invalidateSyncDraft(job.volumeKey)
            return false
        }
        return await nativeInputsAreCurrent(job.volume, baseFiles: bases.first,
                                            formats: screen.libraryFormats(job.volumeKey) ?? UsbFormat.defaultSet,
                                            sourceIsCurrent: { editSourceIsCurrent(job, edits: edits) })
    }

    /// 동기화 모델이 저장한 초안의 인계. 확인 취소·실패 뒤에도 동일 초안은 UsbStore가 사본을 이어 소유한다.
    @discardableResult
    public func writeSyncDraft(_ job: UsbEditJob, edits: [UsbLibraryEdit]) async -> Bool {
        let lease = job.syncSourceContext?.snapshot?.lease
        defer { withExtendedLifetime(lease) {} }
        guard let context = job.syncSourceContext, Self.hasSyncSelection(edits) else { return false }
        let current = syncSourceIsCurrent
        screen.rememberSyncDraft(job, edits, { current(context, job.database, job.share) })
        return await writeDraft(volumeKey: job.volumeKey, database: context.snapshot?.provenance.sourceURL,
                                share: job.share, snapshotTime: job.snapshotTime)
    }

    /// 쓰기 대기 목록의 미리 보기. 볼륨이 빠졌거나 막히면(rekordbox·잠금·끝나지 않은 쓰기·오류) 알리고 nil
    /// - database: 앱이 연 로컬 스냅샷 사본(새로 뜨지 않는다)
    public func previewDraft(volumeKey: String, database: URL?, share: URL?, snapshotTime: String? = nil) async -> UsbEditSummary? {
        let lease = screen.savedSyncDraft(volumeKey)?.snapshotLease
        defer { withExtendedLifetime(lease) {} }
        guard let job = editJob(volumeKey, database: database, share: share, snapshotTime: snapshotTime),
              await ready(job.volume, sourceIsCurrent: { await editInputsAreCurrent(job, edits: screen.draftEdits(volumeKey) ?? []) }) else { return nil }
        guard await editInputsAreCurrent(job, edits: screen.draftEdits(volumeKey) ?? []) else { return nil }
        guard let flag = begin(job.volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return nil }
        let service = service
        let result = await BlockingWork.run { Result { try service.previewEdit(job.input) } }
        session.end(job.volumeKey)
        guard await editInputsAreCurrent(job, edits: screen.draftEdits(volumeKey) ?? []) else { return nil }
        switch result {
        case let .success(summary):
            guard await editInputsAreCurrent(job, edits: summary.edits) else { return nil }
            return flag.isSet ? nil : summary
        case let .failure(error):
            fail(Text.previewFailedTitle, error)
            return nil
        }
    }

    /// 초안 쓰기: 미리 보기 → 확인 창 → 쓰기(진행·DB 교체 전 취소) → 토스트([꺼내기]). 내보내기와 같은 잠금·회복 흐름을 탄다.
    /// `reusing`이 있으면(대기 목록에서 방금 본 미리 보기) 다시 미리 보지 않는다. 쓴 뒤에는 초안 수를 다시 읽는다(막힌 편집만 남는다)
    @discardableResult
    public func writeDraft(volumeKey: String, database: URL?, share: URL?, snapshotTime: String? = nil, reusing reused: UsbEditSummary? = nil) async -> Bool {
        let lease = screen.savedSyncDraft(volumeKey)?.snapshotLease
        defer { withExtendedLifetime(lease) {} }
        guard let job = editJob(volumeKey, database: database, share: share, snapshotTime: snapshotTime),
              await ready(job.volume, sourceIsCurrent: { await editInputsAreCurrent(job, edits: screen.draftEdits(volumeKey) ?? []) }) else { return false }
        guard await editInputsAreCurrent(job, edits: screen.draftEdits(volumeKey) ?? []) else { return false }
        guard let flag = begin(job.volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return false }
        session.lastMigrations.remove(volumeKey)
        let outcome = await runEdit(job, reused: reused, flag: flag)
        session.end(volumeKey)
        switch outcome {
        case .stopped:
            break
        case let .written(summary):
            screen.invalidateSyncDraft(volumeKey)
            session.migrationBackups[volumeKey] = nil
            let blocked = summary.blockedCount, skipped = summary.skippedTrackCount
            // rekordbox의 내보내기 기록처럼 넣지 못한 곡 수를 결과에 남긴다(이유는 확인 창에 이유별로 보였다)
            let detail = (blocked > 0 ? String(ui: "\(job.volume.name) · 막힌 편집 \(blocked)건은 초안에 남겼습니다") : job.volume.name)
                + (skipped > 0 ? " · " + String(ui: "USB에 넣지 못한 곡 \(skipped)개") : "")
            results.show(.success(title: Text.editWrittenTitle(count: summary.writtenCount), detail: detail, ejectVolumeKey: volumeKey))
            await screen.refresh()
        case .cancelled:
            results.show(.success(title: Text.cancelledTitle, detail: Text.unchangedDetail))
        case .recoveryNeeded:
            await offerRecovery(job.volume)
        case let .failed(error):
            switch error as? UsbError {
            case .volumeLost?, .volumeChanged?: screen.invalidateSyncDraft(volumeKey)
            default: break
            }
            await failWrite(error, volumeKey: volumeKey, otherwise: Text.notWrittenTitle)
        }
        await screen.reloadDraft(volumeKey)
        if case .written = outcome { return true }
        return false
    }

    /// 잠근 채로 미리 보기·확인·쓰기. 잠금은 부르는 쪽이 푼다.
    /// 미리 보기는 초안 줄 밖이라 확인하는 동안 초안이 바뀔 수 있다. 쓰기 줄에서 초안이 확인한 편집과 다르면 쓰지 않고 지금 초안으로 다시 미리 보고 묻는다
    private func runEdit(_ job: UsbEditJob, reused: UsbEditSummary?, flag: UsbCancelFlag) async -> Outcome<UsbEditSummary> {
        let service = service, key = job.volumeKey
        var summary: UsbEditSummary
        if let reused {
            summary = reused
        } else {
            let preview = await editPreview(job)
            guard await editInputsAreCurrent(job, edits: screen.draftEdits(key) ?? []) else { return .stopped }
            switch preview {
            case let .success(value): summary = value
            case let .failure(error): return previewFailed(error)
            }
        }
        guard await editInputsAreCurrent(job, edits: summary.edits) else { return .stopped }
        var draftChanged = false
        while true {
            if flag.isSet { return .cancelled }
            guard await editInputsAreCurrent(job, edits: summary.edits) else { return .stopped }
            guard summary.stopping.isEmpty else {
                inform(Text.cannotWriteTitle, summary.stopping.joined(separator: "\n"), details: Self.editLines(summary))
                return .stopped
            }
            guard summary.hasChanges else {
                notify(Text.nothingToWriteTitle, String(ui: "바꿀 것이 없거나 모든 편집이 막혔습니다. 쓰기 대기 목록에서 이유를 확인하세요"))
                return .stopped
            }
            let confirmedByUser = confirmation.confirm(Self.editConfirmation(summary, volume: job.volume, draftChanged: draftChanged))
            guard await editInputsAreCurrent(job, edits: summary.edits), confirmedByUser else { return .stopped }
            if let stop: Outcome<UsbEditSummary> = await journalStop(key, sourceIsCurrent: { await editInputsAreCurrent(job, edits: summary.edits) }) { return stop }
            guard await editInputsAreCurrent(job, edits: summary.edits) else { return .stopped }
            // 세션이 초안을 읽고 막힌 편집만 남겨 다시 저장하는 동안 더한 편집을 잃지 않게, 초안 고치기와 한 줄로 선다(그 편집은 쓰기 뒤에 더한다).
            // 세션은 줄 안에서 초안을 다시 읽어 쓰므로, 확인한 것과 다르면(미리 보기 뒤 더하거나 뺌) 확인 창에 없던 편집을 쓰지 않게 멈춘다
            let confirmed = summary.edits
            let result = await screen.draftQueue(key) { () -> Result<UsbEditWritten, any Error>? in
                guard (await draftEdits(key) ?? confirmed) == confirmed else {
                    if job.syncSourceContext != nil { screen.invalidateSyncDraft(key) }
                    return nil
                }
                guard editSourceIsCurrent(job, edits: confirmed) else {
                    return .failure(UsbError.writeRefused([Self.syncSourceChangedBlock]))
                }
                return await perform(key, actualCheck: { await editInputsAreCurrent(job, edits: confirmed) }, sourceIsCurrent: { editSourceIsCurrent(job, edits: confirmed) }) { progress in
                    try service.writeEdit(job.input, progress: progress, isCancelled: { flag.isSet })
                }
            }
            guard let result else {
                switch await editPreview(job) {
                case let .success(value): summary = value
                case let .failure(error): return previewFailed(error)
                }
                draftChanged = true
                continue
            }
            switch result {
            case let .success(written):
                guard written.report != nil else {
                    // 확인 뒤 USB가 바뀌어 다시 계획하니 쓸 것이 없었다
                    notify(Text.nothingToWriteTitle, String(ui: "바꿀 것이 없거나 모든 편집이 막혔습니다. 쓰기 대기 목록에서 이유를 확인하세요"))
                    return .stopped
                }
                if job.syncSourceContext != nil, written.report?.outcome != .written { return .stopped }
                return .written(written.summary)
            case let .failure(error): return Self.outcome(of: error)
            }
        }
    }

    /// 지금 초안으로 미리 보기(메인 액터 밖)
    private func editPreview(_ job: UsbEditJob) async -> Result<UsbEditSummary, any Error> {
        let service = service
        return await BlockingWork.run { Result { try service.previewEdit(job.input) } }
    }

    /// 지금 초안 파일의 편집(메인 액터 밖에서 읽는다). 읽지 못하면 빈 목록 — 확인한 것과 달라 다시 미리 보며 오류를 알린다.
    /// 초안 폴더가 없으면(초안을 다루지 않는 시험·캡처) nil
    private func draftEdits(_ key: String) async -> [UsbLibraryEdit]? {
        guard let editing = screen.draftEditing() else { return nil }
        return await BlockingWork.run { editing.edits(key) }
    }

    /// 시작 전 확인: rekordbox·Agent, 볼륨 잠금, 끝나지 않은 쓰기(회복 알림), 읽지 못한 저널
    private func ready(_ volume: UsbVolumeInfo, sourceIsCurrent: @MainActor () async -> Bool = { true }) async -> Bool {
        guard await sourceIsCurrent() else { return false }
        let service = service
        let running = isRekordboxRunning ?? { service.isRekordboxRunning() }
        let isRunning = await BlockingWork.run { running() }
        guard await sourceIsCurrent() else { return false }
        if isRunning {
            notify(Text.rekordboxRunningTitle, Text.rekordboxRunningDetail)
            return false
        }
        guard !isBusy(volume) else { return false }
        let key = volume.usbKey
        let journal = await BlockingWork.run { service.journal(volumeKey: key) }
        guard await sourceIsCurrent() else { return false }
        switch UsbWriteDecision.journalCheck(journal) {
        case .proceed: return true
        case .recoveryNeeded:
            await offerRecovery(volume)
            return false
        case .unreadable:
            inform(Text.notWrittenTitle, Self.journalUnreadableText)
            return false
        }
    }

    /// 잠겨 있으면 알리고 true. 쓰기 단추는 쓰는 동안 막혀 있어, 그 사이 다른 입구로 누른 것만 토스트로 알린다(#230)
    private func isBusy(_ volume: UsbVolumeInfo) -> Bool {
        if session.busyVolumes.contains(volume.usbKey) {
            notify(Text.busyTitle, Text.retryLaterDetail)
            return true
        }
        if session.activeWrite != nil {
            notify(Text.otherBusyTitle, Text.retryLaterDetail)
            return true
        }
        return false
    }

    private func begin(_ volume: UsbVolumeInfo, title: String, cancellable: Bool = true) -> UsbCancelFlag? {
        guard !isBusy(volume) else { return nil }
        return screen.beginWrite(volume, title, cancellable)
    }

    // MARK: - 끝나지 않은 쓰기

    /// 끝나지 않은 쓰기 알림: [회복하기] [되돌리기] [나중에]. 누를 때만 USB에 손댄다
    public func offerRecovery(_ volume: UsbVolumeInfo) async {
        guard !session.busyVolumes.contains(volume.usbKey), session.activeWrite == nil else { return }
        let service = service, key = volume.usbKey
        guard await BlockingWork.run({ service.journal(volumeKey: key) }).isPending else { return }
        switch confirmation.choose(Self.pendingPrompt(volume)) {
        case .confirm: await recover(volume)
        case .alternate: await revert(volume)
        case .cancel: return
        }
    }

    /// 회복: USB의 DB를 보고 마저 쓰거나 되돌린다(쓰기와 같은 확인·실물 관문을 먼저 거친다)
    private func recover(_ volume: UsbVolumeInfo) async {
        guard begin(volume, title: String(ui: "USB를 회복하는 중…"), cancellable: false) != nil else { return }
        let service = service
        let result = await BlockingWork.run { Result { try service.recover(volume) } }
        session.end(volume.usbKey)
        switch result {
        case let .success(report):
            switch UsbWriteDecision.recovery(report) {
            case .needsReplan:
                await offerReplan(volume)
                return
            case .rolledBack:
                results.show(.success(title: Text.rolledBackInterruptedTitle, detail: Text.unchangedDetail))
            case .restored:
                results.show(.success(title: Text.restoredTitle))
            case .recovered:
                results.show(.success(title: Text.recoveredTitle, ejectVolumeKey: volume.usbKey))
            case .nothingToRecover:
                results.show(.success(title: Text.nothingToRecoverTitle))
            }
        case let .failure(error):
            await failWrite(error, volumeKey: volume.usbKey, otherwise: Text.notRecoveredTitle)
        }
        await screen.refresh()
    }

    /// 되돌리기: 끝나지 않은 저널을 먼저 닫고(회복) 그 쓰기의 백업으로 되돌린다(되돌리기는 열린 저널을 받지 않는다).
    /// 기기가 그 뒤에 USB를 바꿨으면 한 번 더 묻는다
    private func revert(_ volume: UsbVolumeInfo) async {
        let key = volume.usbKey, service = service
        guard begin(volume, title: String(ui: "USB를 되돌리는 중…"), cancellable: false) != nil else { return }
        let recovered = await BlockingWork.run { Result { try service.recover(volume) } }
        let report: UsbWriteReport
        switch recovered {
        case let .failure(error):
            session.end(key)
            await failWrite(error, volumeKey: key, otherwise: Text.notRestoredTitle)
            return
        case let .success(value): report = value
        }
        switch UsbWriteDecision.revertStep(afterRecover: report) {
        case .alreadyRestored:
            session.end(key)
            results.show(.success(title: Text.restoredTitle))
            await screen.refresh()
        case .backupMissing:
            session.end(key)
            inform(Text.notRestoredTitle, Text.backupMissingText)
            await screen.refresh()
        case let .restore(backup):
            await restore(volume, backup: backup)
        }
    }

    private func restore(_ volume: UsbVolumeInfo, backup: URL) async {
        let key = volume.usbKey, service = service
        var discard = false
        while true {
            let flagged = discard
            let result = await BlockingWork.run {
                Result { try service.restore(volume, backup: backup, discardDeviceChanges: flagged) }
            }
            switch result {
            case .success:
                session.end(key)
                results.show(.success(title: Text.restoredTitle))
                session.migrationBackups[key] = nil
                await screen.refresh()
                return
            case let .failure(error) where UsbWriteDecision.asksToDiscardDeviceChanges(error, discarding: discard):
                session.end(key)
                guard confirmation.confirm(Self.discardDeviceChangesPrompt(volume)) else { return }
                guard begin(volume, title: String(ui: "USB를 되돌리는 중…"), cancellable: false) != nil else { return }
                discard = true
            case let .failure(error):
                session.end(key)
                await failWrite(error, volumeKey: key, otherwise: Text.notRestoredTitle)
                return
            }
        }
    }

    /// 회복이 다시 계획하라고 했을 때: 누르면 USB를 다시 읽고 새로 미리 본 뒤 내보내기 시트를 연다
    private func offerReplan(_ volume: UsbVolumeInfo) async {
        guard confirmation.confirm(Self.replanPrompt) else { return }
        await screen.refresh()
        let key = volume.usbKey
        if session.lastMigrations.contains(key), let current = screen.volume(key) {
            await migrate(current)
            return
        }
        guard var job = session.lastExports[key] else {
            screen.setExportSheet(screen.volume(key).map { UsbExportSheetRequest(volume: $0) })
            return
        }
        if job.syncSelection != nil || job.syncSourceContext != nil {
            // native 재시도는 대상·출처를 바꾸지 않고 시트에 사본 소유권만 넘긴다.
            job.snapshotLease = job.syncSourceContext?.snapshot?.lease
            guard exportSourceIsCurrent(job) else { return }
        } else {
            job.volume = screen.volume(key) ?? job.volume
        }
        let summary = await preview(job)
        screen.setExportSheet(UsbExportSheetRequest(volume: job.volume, job: job, summary: summary))
    }

    // MARK: - 알림 동작

    /// 쓴 뒤 알림의 [꺼내기]: 그 알림을 닫고 볼륨을 꺼낸다(못 꺼내면 이유를 알린다)
    public func eject(_ volumeKey: String) async {
        results.dismissEject(volumeKey)
        if let message = await screen.eject(volumeKey) { notify(Text.ejectFailedTitle, message) }
    }

    // MARK: - 알림

    private func inform(_ title: String, _ text: String, details: [String] = []) {
        _ = confirmation.confirm(ReflectionPrompt(title: title, text: text, details: details))
    }

    /// USB에 손대지 않은 안내(지금은 못 함·할 것 없음): 창 대신 닫을 때까지 남는 경고 토스트(#230)
    private func notify(_ title: String, _ text: String) {
        results.show(.notice(title: title, text: text))
    }

    /// 막힘·오류 알림. 막힘(`writeRefused`)은 그 문구(이유와 할 일)를 그대로, 그 밖의 USB 오류는 그 설명을 보인다
    private func fail(_ title: String, _ error: any Error) {
        let text: String
        if case let UsbError.writeRefused(blocks)? = error as? UsbError, !blocks.isEmpty {
            var seen: Set<String> = []
            text = blocks.map(\.message).filter { seen.insert($0).inserted }.joined(separator: "\n")
        } else if let usbError = error as? UsbError, let description = usbError.errorDescription {
            // UsbError는 DJCError가 아니라 앱의 일반 오류 문구(`errorText`)가 일반 문구로 바꾼다
            results.log(error)
            text = description
        } else {
            text = results.errorText(error)
        }
        _ = confirmation.confirm(ReflectionPrompt(title: title, text: text, critical: true))
    }

    /// USB에 손댄 뒤(쓰기·회복·되돌리기)의 실패: 되돌린 결과와 할 일. 백업 폴더가 있으면 열 수 있다.
    /// 반쯤 쓰였을 수 있는 경우가 아니면 `otherwise` 제목으로 알린다
    private func failWrite(_ error: any Error, volumeKey: String, otherwise title: String) async {
        let backup: URL?
        guard let usbError = error as? UsbError, let prompt = Self.interruptedPrompt(usbError) else {
            fail(title, error)
            return
        }
        switch usbError {
        case .writeRolledBack:
            // 백업 폴더 찾기는 폴더를 열거하고 manifest를 읽는다: 메인 액터 밖에서
            let service = service
            backup = await BlockingWork.run { service.latestBackup(volumeKey: volumeKey) }
        case let .restoreFailed(_, _, folder):
            backup = folder.isEmpty ? nil : URL(filePath: folder)
        default:
            backup = nil
        }
        results.log(error)
        if confirmation.confirm(backup == nil ? prompt : Self.withBackupButtons(prompt)), let backup { results.openFolder(backup) }
    }
}
