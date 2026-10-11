@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Observation
@testable import RekordboxKit
import Testing

/// 시험용 USB 쓰기 창구(유스케이스 `UsbWriting`의 가짜): 정해 둔 결과를 돌려주고 부른 것을 적는다(USB·Mac 파일을 건드리지 않는다).
/// 코디네이터가 메인 액터 밖에서 부르므로 모든 상태는 잠금 안에서만 바꾼다.
/// 막힘 미리 판정(임시 폴더 마운트·동기화 관문)은 실제 판정을 그대로 쓴다(옛 `UsbStore` 기본값과 같다)
final class FakeUsbWriteService: UsbWriting, @unchecked Sendable {
    struct State {
        /// 이벤트·사이드바 채택과 독립적인 실제 마운트 입력. 없으면 native 확인은 거부한다.
        var liveVolumeReader: (@Sendable (UsbVolumeInfo) throws -> UsbVolumeInfo)?
        var liveSyncFilesReader: (@Sendable (UsbVolumeInfo, Set<UsbFormat>) throws -> [UsbFormat: Data])?
        var journal: UsbJournalInfo = .none
        var journalCalls = 0
        var onJournal: (@Sendable (Int) -> Void)?
        var exportDatabases: [URL] = []
        var onWriteJob: (@Sendable (UsbExportInput) -> Void)?
        var summary = UsbTestData.summary()
        var onPreview: (@Sendable () -> Void)?
        var migrationSummary = UsbMigrationSummary(trackCount: 3, playlistCount: 1, artworkFiles: 6, blocks: [],
                                                   rules: [.deviceLibraryMigration], notes: [], hasChanges: true, isTestVolume: true)
        var migrationPreviewError: UsbError?
        var migrationWriteResult: Result<UsbWriteReport?, UsbError> = .success(UsbWriteReport(outcome: .written, session: "m1",
                                                                                          backup: "/tmp/djc-fixture/usb-backups/B/m1"))
        var migrationOnMain: [Bool] = []
        /// 미리 보기 뒤 저널(실제 절차는 드라이 런 저널을 닫힌 상태로 남길 수 있다)
        var journalAfterPreview: UsbJournalInfo?
        var writeResult: Result<UsbWriteReport, UsbError> = .success(UsbWriteReport(outcome: .written, session: "s1", filesCreated: 12))
        var journalAfterWrite: UsbJournalInfo?
        /// 쓰는 동안 차례로 보낼 진행
        var writeProgress: [UsbProgress] = []
        /// 진행을 보낸 뒤 부른다(메인 액터 밖, 잠금 밖). 시험이 풀어 줄 때까지 쓰기를 멈출 수 있다.
        var onWrite: (@Sendable () -> Void)?
        var recoverResult: Result<UsbWriteReport, UsbError> = .success(UsbWriteReport(outcome: .recovered, session: "s1",
                                                                                                 backup: "/tmp/djc-fixture/usb-backups/B/s1"))
        var journalAfterRecover: UsbJournalInfo?
        var restoreResult: Result<UsbWriteReport, UsbError> = .success(UsbWriteReport(outcome: .restored, session: "s1"))
        /// 참이면 기기 변경을 버린다고 하지 않은 되돌리기를 `deviceChanged`로 막는다
        var deviceChanged = false
        var backup: URL?
        /// 되돌리기에 넘긴 백업 폴더(nil = 가장 최근 백업)
        var restoredBackups: [URL?] = []
        /// 가장 최근 백업을 메인 스레드에서 찾았는지(파일 입출력은 메인 액터 밖에서 한다)
        var latestBackupOnMain: [Bool] = []
        var calls: [String] = []
        /// USB 파일 연산 수(가짜는 끝까지 간 쓰기·회복·되돌리기만 센다)
        var fileOperations = 0
        /// DB 교체까지 갔는지
        var committed = false
        /// 초안 base로 돌려줄 USB DB 지문
        var base = UsbFingerprint(files: [:])
        /// 지문을 뜨지 못함(그 자리에 다른 볼륨이 붙음 등)
        var baseError: UsbError?
        /// 지문을 뜰 때 부른다(메인 액터 밖, 잠금 밖)
        var onDraftBase: (@Sendable () -> Void)?
        /// 수정 미리 보기·쓰기가 돌려줄 요약
        var editSummary = UsbTestData.editSummary()
        var editWriteResult: Result<UsbWriteReport?, UsbError> = .success(UsbWriteReport(outcome: .written, session: "e1", filesCreated: 2))
        var editWriteProgress: [UsbProgress] = []
        /// 받은 수정 작업(미리 보기·쓰기)
        var editJobs: [UsbEditInput] = []
        /// rekordbox·rekordboxAgent가 켜져 있는지(쓰기 창구의 판정)
        var rekordboxRunning = false
        /// 수정 쓰기 때 부른다(실제 세션이 초안을 고치는 것을 흉내 낸다)
        var onWriteEdit: (@Sendable () -> Void)?
        /// 수정 미리 보기 때 부른다(메인 액터 밖, 잠금 밖)
        var onPreviewEdit: (@Sendable () -> Void)?
        /// 수정 미리 보기가 던질 오류(계획이 Mac 사본에서 실패)
        var editPreviewError: UsbError?
        /// 초안 폴더. 주면 실제 창구처럼 미리 보기가 그때 초안 편집을 읽어 요약(`edits`)에 담는다
        var drafts: URL?
    }

    private let lock = NSLock()
    private var state = State()

    func update(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }
    var current: State { lock.withLock { state } }

    func currentVolume(_ volume: UsbVolumeInfo) throws -> UsbVolumeInfo {
        guard let reader = lock.withLock({ state.liveVolumeReader }) else { throw UsbError.cancelled }
        return try reader(volume)
    }

    func syncSelectionBaseFiles(_ volume: UsbVolumeInfo, formats: Set<UsbFormat>) throws -> [UsbFormat: Data] {
        guard let reader = lock.withLock({ state.liveSyncFilesReader }) else { throw UsbError.cancelled }
        return try reader(volume, formats)
    }

    func journal(volumeKey: String) -> UsbJournalInfo {
        let (count, hook) = lock.withLock {
            state.journalCalls += 1
            return (state.journalCalls, state.onJournal)
        }
        hook?(count)
        return lock.withLock { state.journal }
    }

    func preview(_ job: UsbExportInput) throws -> UsbExportSummary {
        let hook = lock.withLock { () -> (@Sendable () -> Void)? in
            state.calls.append("preview")
            state.exportDatabases.append(job.database)
            if let next = state.journalAfterPreview { state.journal = next }
            return state.onPreview
        }
        hook?()
        return lock.withLock { state.summary }
    }

    func write(_ job: UsbExportInput, progress: @escaping @Sendable (UsbProgress) -> Void,
               isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport {
        let (steps, hook) = lock.withLock { () -> ([UsbProgress], (@Sendable () -> Void)?) in
            state.calls.append("write")
            state.exportDatabases.append(job.database)
            return (state.writeProgress, state.onWrite)
        }
        for step in steps { progress(step) }
        hook?()
        let jobHook = lock.withLock { state.onWriteJob }
        jobHook?(job)
        if isCancelled() { throw UsbError.cancelled }
        return try lock.withLock {
            if let next = state.journalAfterWrite { state.journal = next }
            if case .success = state.writeResult {
                state.committed = true
                state.fileOperations += 1
            }
            return try state.writeResult.get()
        }
    }

    func previewMigration(_ volume: UsbVolumeInfo) throws -> UsbMigrationSummary {
        let onMain = Thread.isMainThread
        return try lock.withLock {
            state.calls.append("previewMigration")
            state.migrationOnMain.append(onMain)
            if let next = state.journalAfterPreview { state.journal = next }
            if let error = state.migrationPreviewError { throw error }
            return state.migrationSummary
        }
    }

    func writeMigration(_ volume: UsbVolumeInfo, progress: @escaping @Sendable (UsbProgress) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) throws -> UsbMigrationWritten {
        let onMain = Thread.isMainThread
        let (steps, hook) = lock.withLock { () -> ([UsbProgress], (@Sendable () -> Void)?) in
            state.calls.append("writeMigration")
            state.migrationOnMain.append(onMain)
            return (state.writeProgress, state.onWrite)
        }
        for step in steps { progress(step) }
        hook?()
        if isCancelled() { throw UsbError.cancelled }
        return try lock.withLock {
            if let next = state.journalAfterWrite { state.journal = next }
            let report = try state.migrationWriteResult.get()
            if report != nil {
                state.fileOperations += 1
                state.committed = true
            }
            return UsbMigrationWritten(summary: state.migrationSummary, report: report)
        }
    }

    func recover(_ volume: UsbVolumeInfo) throws -> UsbWriteReport {
        try lock.withLock {
            state.calls.append("recover")
            let report = try state.recoverResult.get()
            state.fileOperations += 1
            if let next = state.journalAfterRecover { state.journal = next }
            return report
        }
    }

    func restore(_ volume: UsbVolumeInfo, backup: URL?, discardDeviceChanges: Bool) throws -> UsbWriteReport {
        try lock.withLock {
            state.calls.append(discardDeviceChanges ? "restore(discard)" : "restore")
            state.restoredBackups.append(backup)
            if state.deviceChanged, !discardDeviceChanges {
                throw UsbError.writeRefused([UsbBlock(code: "deviceChanged", scope: .volume, message: "기기 변경")])
            }
            let report = try state.restoreResult.get()
            state.fileOperations += 1
            return report
        }
    }

    func latestBackup(volumeKey: String) -> URL? {
        let onMain = Thread.isMainThread
        return lock.withLock {
            state.latestBackupOnMain.append(onMain)
            return state.backup
        }
    }

    func draftBase(_ volume: UsbVolumeInfo) throws -> UsbFingerprint {
        let hook = lock.withLock { () -> (@Sendable () -> Void)? in
            state.calls.append("draftBase")
            return state.onDraftBase
        }
        hook?()
        return try lock.withLock {
            if let error = state.baseError { throw error }
            return state.base
        }
    }

    func previewEdit(_ job: UsbEditInput) throws -> UsbEditSummary {
        let (drafts, hook) = lock.withLock { () -> (URL?, (@Sendable () -> Void)?) in
            state.calls.append("previewEdit")
            state.editJobs.append(job)
            return (state.drafts, state.onPreviewEdit)
        }
        // 실제 창구처럼 초안을 먼저 읽고 계획한다(계획하는 동안 더한 편집은 이 요약에 없다)
        let edits = try drafts.map { try UsbDraftStore(directory: $0).load(volumeKey: UsbEditSession.volumeKey(job.volume))?.edits ?? [] }
        hook?()
        if let error = lock.withLock({ state.editPreviewError }) { throw error }
        var summary = lock.withLock { state.editSummary }
        if let edits { summary.edits = edits }
        return summary
    }

    func writeEdit(_ job: UsbEditInput, progress: @escaping @Sendable (UsbProgress) -> Void,
                   isCancelled: @escaping @Sendable () -> Bool) throws -> UsbEditWritten {
        let (steps, hook) = lock.withLock { () -> ([UsbProgress], (@Sendable () -> Void)?) in
            state.calls.append("writeEdit")
            state.editJobs.append(job)
            return (state.editWriteProgress, state.onWriteEdit)
        }
        for step in steps { progress(step) }
        hook?()
        return try lock.withLock {
            let report = try state.editWriteResult.get()
            if report != nil { state.fileOperations += 1 }
            return UsbEditWritten(summary: state.editSummary, report: report)
        }
    }

    func isScratchMount(_ mountPoint: String) -> Bool { UsbDevice.live().isScratchMount(mountPoint) }

    var syncGate: UsbSyncSelectionGate { .live }

    func isRekordboxRunning() -> Bool { lock.withLock { state.rekordboxRunning } }

    func planCueGridImport(volume: UsbVolumeInfo, snapshot: URL, share: URL, scratch: URL,
                           rows: [String: UsbCueGridImportTrack]) throws -> UsbCueGridImportPlan {
        lock.withLock { state.calls.append("planCueGridImport") }
        throw UsbCueGridReadFailure(message: "가짜 창구는 큐·그리드를 읽지 않는다")
    }
}

extension FakeUsbWriteService.State {
    /// USB에 쓰는 호출(내보내기·옮기기·수정 쓰기)을 했는지
    var wrote: Bool { calls.contains { ["write", "writeMigration", "writeEdit"].contains($0) } }
    var previewed: Bool { calls.contains { ["preview", "previewMigration", "previewEdit"].contains($0) } }
    /// 첫 쓰기 전에 미리 보기가 있었는지
    var previewedBeforeWrite: Bool {
        guard let write = calls.firstIndex(where: { ["write", "writeMigration", "writeEdit"].contains($0) }) else { return false }
        return calls[..<write].contains { ["preview", "previewMigration", "previewEdit"].contains($0) }
    }
    var recovered: Bool { calls.contains("recover") }
    /// 되돌리기(기기 변경을 버리는 되돌리기 포함)를 했는지
    var restored: Bool { calls.contains { $0.hasPrefix("restore") } }
    /// `first`가 `then`보다 먼저 불렸는지
    func called(_ first: String, before then: String) -> Bool {
        guard let a = calls.firstIndex(of: first), let b = calls.lastIndex(of: then) else { return false }
        return a < b
    }
}

/// 토스트를 받는 가짜 앱
@MainActor
final class FakeUsbWriteHost: UsbWriteHost {
    var toast: AppToast?
}

extension UsbTestData {
    /// 미리 보기 요약(곡 3·목록 1, 막힘 없음)
    static func summary(tracks: Int = 3, playlists: Int = 1, blocks: [UsbBlock] = [], rules: [UsbProvisionalRule: Int] = [:],
                        required: Int64 = 2 << 20, available: Int64 = 100 << 20, hasChanges: Bool = true,
                        testVolume: Bool = true, unverifiedTracks: Int = 0) -> UsbExportSummary {
        UsbExportSummary(trackCount: tracks, playlistCount: playlists, blocks: blocks, ruleCounts: rules, requiredRules: Set(rules.keys),
                         requiredBytes: required, availableBytes: available, hasChanges: hasChanges, isTestVolume: testVolume,
                         unverifiedTrackCount: unverifiedTracks)
    }

    static var physicalBlock: UsbBlock {
        UsbBlock(code: "physicalDisabled", scope: .volume,
                 message: "실물 USB에 쓰려면 앱은 볼륨 이름을 확인하고 ‘USB에 쓰기’를 누르고, djc는 --allow-physical --confirm <볼륨 이름>을 주세요",
                 rule: .physicalVolume)
    }
}

@MainActor
@Suite("USB 내보내기 흐름(UsbWriteCoordinator)")
struct UsbWriteCoordinatorTests {
    let image = FakeUsbVolume.diskImageFAT32(name: "B12T")
    let prompter = ScriptedPrompter()
    let service = FakeUsbWriteService()
    let host = FakeUsbWriteHost()

    func store(_ volumes: [UsbVolumeInfo]? = nil, journal: @escaping @Sendable (String) -> UsbJournalInfo = { _ in .none })
        -> (UsbStore, FakeUsbHost) {
        let usbHost = FakeUsbHost(volumes ?? [image])
        for volume in volumes ?? [image] { usbHost.serveEmpty(volume) }
        let usb = UsbStore(host: usbHost, readPolicy: .all, writeService: service, localLibrary: { nil }, journal: journal)
        return (usb, usbHost)
    }

    func coordinator(_ usb: UsbStore, running: Bool = false, opened: (@MainActor (URL) -> Void)? = nil) -> UsbWriteCoordinator {
        UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { running },
                            openFolder: opened ?? { _ in })
    }

    func job(_ volume: UsbVolumeInfo? = nil) -> UsbExportJob {
        UsbExportJob(database: URL(filePath: "/tmp/djc-fixture/m.db"), share: URL(filePath: "/tmp/djc-fixture/share"),
                     volume: volume ?? image, selection: .playlists(["10"]), formats: UsbFormat.defaultSet, snapshotTime: nil)
    }

    // MARK: - 확인·취소·실패 문구

    @Test("확인 창은 곡·목록 수·공간·막힘·CDJ에서 확인하지 않은 항목을 보이고, 취소하면 쓰지 않는다. 실패는 되돌린 결과를 알린다")
    func confirmCancelFailRestoreMessages() async throws {
        let (usb, _) = store()
        let blocks = [UsbBlock(code: "audioSizeMismatch", scope: .track("7"), message: "rekordbox에서 다시 분석한 뒤 내보내세요"),
                      UsbBlock(code: "audioSizeMismatch", scope: .track("8"), message: "rekordbox에서 다시 분석한 뒤 내보내세요")]
        service.update {
            $0.summary = UsbTestData.summary(blocks: blocks, rules: [.analysisFolderNaming: 3, .cueVariant: 2], unverifiedTracks: 2)
        }
        prompter.answer = false
        await coordinator(usb).export(job())

        // 미리 본 요약으로 만든 확인 창(문구 모양은 `UsbWriteFlow.confirmation`이 정한다)
        let summary = service.current.summary
        #expect(prompter.shown.last == UsbWriteFlow.confirmation(summary, job: job()))
        #expect(prompter.shown.last?.details.contains(UsbWriteFlow.volumeLines(image, isTestVolume: true)[0]) == true)
        // 빼고 쓰는 곡은 이유별 수로, 흐름 규칙(분석 파일 폴더 이름)은 알리지 않고 곡 내용 규칙만 곡 수와 함께 알린다
        #expect(summary.blockedTrackCount == 2)
        #expect(summary.rules.map(\.rule) == [.cueVariant] && summary.unverifiedTrackCount == 2)
        #expect(service.current.previewed && !service.current.wrote)
        #expect(host.toast == nil)
        #expect(usb.busyVolumes.isEmpty)
        #expect(usb.activeWrite == nil)

        // 쓰다가 되돌림: 결과와 백업 폴더 열기
        var opened: [URL] = []
        let backup = URL(filePath: "/tmp/djc-fixture/usb-backups/B/1")
        service.update {
            $0.writeResult = .failure(.writeRolledBack(reason: "verify"))
            $0.backup = backup
        }
        prompter.answer = true
        prompter.shown = []
        await coordinator(usb, opened: { opened.append($0) }).export(job())
        #expect(prompter.shown.last == UsbWriteFlow.interruptedPrompt(.writeRolledBack(reason: "verify"))
            .map(UsbWriteFlow.withBackupButtons))
        #expect(opened == [backup])
        // 백업 폴더 찾기(폴더 열거·manifest 읽기)는 메인 액터 밖에서 한다
        #expect(service.current.latestBackupOnMain == [false])

        // 되돌리지도 못함: 기기에 꽂지 말라는 경고
        service.update { $0.writeResult = .failure(.restoreFailed(reason: "verify", restoreError: "rename", backup: backup.path)) }
        prompter.answers = [true, false]
        prompter.shown = []
        await coordinator(usb).export(job())
        let failed = UsbWriteFlow.interruptedPrompt(.restoreFailed(reason: "verify", restoreError: "rename", backup: backup.path))
        #expect(prompter.shown.contains(UsbWriteFlow.withBackupButtons(try #require(failed))))
        #expect(failed?.critical == true)
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("DB 교체 전에 취소하면 USB는 그대로이고, 취소하지 않고 풀어 주면 쓰고 알린다", arguments: [true, false])
    func cancelBeforeCommitLeavesVolume(cancel: Bool) async {
        let (usb, _) = store()
        let release = DispatchSemaphore(value: 0)
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        service.update {
            $0.writeProgress = [UsbProgress(phase: .backup, cancellable: true),
                                UsbProgress(phase: .files, completedItems: 1, totalItems: 9, completedBytes: 10, totalBytes: 90, cancellable: true)]
            $0.onWrite = { release.waitOffPool() }
        }
        let coordinator = coordinator(usb)
        let task = Task {
            await coordinator.export(job())
            continuation.finish()
        }
        // 메인 액터가 파일 단계 진행을 실제로 받을 때까지 변경 알림으로 기다린다.
        var iterator = changes.makeAsyncIterator()
        while true {
            let progress = withObservationTracking { usb.activeWrite?.progress } onChange: { continuation.yield(()) }
            if progress?.phase == .files { break }
            guard await iterator.next() != nil else { break }
        }
        #expect(usb.activeWrite?.progress?.phase == .files)
        #expect(usb.activeWrite?.progress?.completedItems == 1)
        #expect(usb.activeWrite?.progress?.cancellable == true)
        #expect(usb.busyVolumes == [image.usbKey])
        #expect(service.current.previewedBeforeWrite)
        #expect(!service.current.committed)
        #expect(service.current.fileOperations == 0)
        if cancel { usb.cancelWrite() }
        // 가짜는 메인 액터 밖에서만 기다린다. 취소·계속 쓰기 모두 작업을 회수하기 전에 풀어 준다.
        release.signal()
        await task.value
        #expect(service.current.committed == !cancel)
        #expect(service.current.fileOperations == (cancel ? 0 : 1))
        #expect(host.toast?.kind == .success)
        #expect(host.toast?.title == (cancel ? UsbWriteFlow.Text.cancelledTitle : UsbWriteFlow.Text.writtenTitle(tracks: 3)))
        #expect(host.toast?.detail == (cancel ? UsbWriteFlow.Text.unchangedDetail : "B12T · 재생 목록 1개"))
        #expect(host.toast?.action == (cancel ? nil : .ejectUsb(volumeKey: image.usbKey)))
        #expect(usb.activeWrite == nil)
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("실물 볼륨은 관문 막힘을 그대로 보이고 쓰지 않는다")
    func physicalVolumeWriteDisabled() async {
        let physical = FakeUsbVolume.physicalFAT32()
        let (usb, _) = store([physical])
        service.update { $0.summary = UsbTestData.summary(blocks: [UsbTestData.physicalBlock], testVolume: false) }
        await coordinator(usb).export(job(physical))
        #expect(service.current.previewed && !service.current.wrote)
        let shown = prompter.shown.last
        #expect(shown?.confirm == nil)
        #expect(shown?.title == UsbWriteFlow.Text.cannotWriteTitle)
        #expect(shown?.text == UsbTestData.physicalBlock.message)
        let summary = service.current.summary
        #expect(summary.isPhysicalDisabled)
        #expect(!summary.canWrite)
    }

    @Test("실물 USB 확인 창은 볼륨 이름·용량·형식과 '실물 USB입니다'를 보이고, exFAT·GPT는 한 줄로 알린다. 확인이 곧 쓰기 동의다")
    func physicalConfirmationShowsVolume() async {
        var physical = FakeUsbVolume.exfat()
        physical.partitionScheme = .gpt
        let (usb, _) = store([physical])
        service.update { $0.summary = UsbTestData.summary(testVolume: false) }
        prompter.answer = false
        await coordinator(usb).export(job(physical))
        let details = prompter.shown.last?.details ?? []
        let capacity = physical.capacity.formatted(ByteCountFormatStyle(style: .file))
        #expect(details.first == "실물 USB입니다: DJCPHYS · \(capacity) · exFAT · GPT")
        // exFAT·GPT는 볼륨 정책의 경고를 한 줄씩
        #expect(UsbVolumePolicy.warnings(physical).count == 2)
        #expect(UsbVolumePolicy.warnings(physical).allSatisfy { details.contains($0.message) })
        #expect(!details.contains(UsbWriteFlow.volumeLines(physical, isTestVolume: true)[0]))
        #expect(service.current.previewed && !service.current.wrote)
        let fat32 = UsbWriteFlow.volumeLines(FakeUsbVolume.physicalFAT32(), isTestVolume: false)
        #expect(fat32.count == 2 && fat32[0].hasSuffix("FAT32 · MBR"))
    }

    @Test("앱의 쓰기 창구는 확인 창을 거친 쓰기라 실물 동의로 보고, 시험 실행(디스크 이미지만)은 동의하지 않는다")
    func appServiceConsent() {
        #expect(UsbReadPolicy.all.physicalWriteConsent)
        #expect(!UsbReadPolicy.diskImagesOnly.physicalWriteConsent)
    }

    @Test("rekordbox가 켜져 있으면 미리 보기도 하지 않는다")
    func rekordboxRunningBlocks() async {
        let (usb, _) = store()
        await coordinator(usb, running: true).export(job())
        #expect(await coordinator(usb, running: true).preview(job()) == nil)
        #expect(service.current.calls.isEmpty)
        // 창을 띄우지 않고 닫을 때까지 남는 경고 토스트로 알린다(#230)
        #expect(prompter.shown.isEmpty)
        #expect(host.toast?.title == UsbWriteFlow.Text.rekordboxRunningTitle && host.toast?.kind == .warning)
        #expect(host.toast?.detail == UsbWriteFlow.Text.rekordboxRunningDetail)
        #expect(host.toast?.isUsb == true && host.toast?.showsResult == false && host.toast?.duration == .infinity)
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("같은 볼륨에 쓰는 중이면 두 번째 쓰기는 막는다")
    func busyVolumeBlocksSecondWrite() async {
        let (usb, _) = store()
        await usb.refresh()
        let flag = usb.beginWrite(image, title: "시험")
        #expect(flag != nil)
        #expect(usb.beginWrite(image, title: "두 번째") == nil)
        await coordinator(usb).export(job())
        #expect(service.current.calls.isEmpty)
        #expect(prompter.shown.isEmpty && host.toast?.title == UsbWriteFlow.Text.busyTitle && host.toast?.kind == .warning)
        let refusal = await usb.eject(image.usbKey)
        #expect(refusal != nil)
        // 토스트의 꺼내기가 실패해도 창 대신 토스트로 알린다
        await coordinator(usb).perform(.ejectUsb(volumeKey: image.usbKey))
        #expect(prompter.shown.isEmpty && host.toast?.title == UsbWriteFlow.Text.ejectFailedTitle)
        #expect(host.toast?.detail == refusal && host.toast?.kind == .warning)
        usb.endWrite(image.usbKey)
        #expect(usb.busyVolumes.isEmpty)
    }

    // MARK: - 끝나지 않은 쓰기

    @Test("끝나지 않은 쓰기 알림: 회복·되돌리기·나중에")
    func pendingJournalPrompt() async {
        let (usb, _) = store()
        service.update { $0.journal = .state(.filesWritten) }
        prompter.choices = [.confirm]
        await coordinator(usb).offerRecovery(image)
        let prompt = prompter.shown.last
        #expect(prompt == UsbWriteFlow.pendingPrompt(image))
        // 누르면 바로 되돌린다(기기 변경이 있을 때만 한 번 더 묻는다): 말줄임표를 붙이지 않는다
        #expect(prompt?.alternate?.hasSuffix("…") == false)
        #expect(service.current.recovered && !service.current.restored)
        #expect(host.toast?.title == UsbWriteFlow.Text.recoveredTitle)

        // 되돌리기: 저널을 먼저 닫고(회복) 그 쓰기의 백업으로 되돌린다
        service.update { $0.calls = [] }
        prompter.choices = [.alternate]
        await coordinator(usb).offerRecovery(image)
        #expect(service.current.called("recover", before: "restore"))
        #expect(service.current.restoredBackups == [URL(filePath: "/tmp/djc-fixture/usb-backups/B/s1")])
        #expect(host.toast?.title == UsbWriteFlow.Text.restoredTitle)

        // 나중에: 아무것도 하지 않는다
        service.update { $0.calls = [] }
        host.toast = nil
        prompter.choices = [.cancel]
        await coordinator(usb).offerRecovery(image)
        #expect(service.current.calls.isEmpty)
        #expect(host.toast == nil)
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("내보내기 시트에서 미리 본 뒤 누른 USB에 쓰기가 동의라 확인 창을 다시 띄우지 않는다(#212)")
    func sheetConsentSkipsSecondConfirmation() async throws {
        let (usb, _) = store()
        let summary = try #require(await coordinator(usb).preview(job()))
        service.update { $0.calls = [] }
        await coordinator(usb).export(job(), reusing: summary, consented: true)
        #expect(prompter.shown.isEmpty)
        // 시트가 미리 본 결과를 다시 쓰고 미리 보기를 되풀이하지 않는다
        #expect(service.current.wrote && !service.current.previewed)
        #expect(host.toast?.title == UsbWriteFlow.Text.writtenTitle(tracks: 3))
        // 시트를 거치지 않은 쓰기(미리 본 결과 없음)는 지금처럼 확인 창으로 묻는다
        prompter.answer = false
        await coordinator(usb).export(job(), consented: true)
        #expect(prompter.shown.first == UsbWriteFlow.confirmation(service.current.summary, job: job()))
    }

    @Test("미리 보기가 드라이 런 저널을 남겨도 쓰기로 가고, 끝나지 않은 쓰기로 알리지 않는다")
    func previewThenWriteNotBlocked() async {
        var appeared: [String] = []
        let journal = service
        let (usb, usbHost) = store(journal: { journal.journal(volumeKey: $0) })
        usb.onPendingJournal = { appeared.append($0.usbKey) }
        service.update { $0.journalAfterPreview = .state(.dryRun) }
        await coordinator(usb).export(job())
        #expect(service.current.previewedBeforeWrite)
        // 끝나지 않은 쓰기 알림 없이 확인 창 하나로 쓴다
        #expect(prompter.shown == [UsbWriteFlow.confirmation(service.current.summary, job: job())])
        #expect(host.toast?.title == UsbWriteFlow.Text.writtenTitle(tracks: 3))
        // 미리 보기를 두 번 해도 같다. 볼륨이 다시 나타나도 알리지 않는다
        service.update { $0.calls = [] }
        #expect(await coordinator(usb).preview(job()) != nil)
        #expect(service.current.previewed && !service.current.wrote)
        usbHost.mounted = []
        await usb.refresh()
        usbHost.mounted = [image]
        await usb.refresh()
        #expect(appeared.isEmpty)
        #expect(UsbJournalInfo.state(.dryRun).isPending == false)
        #expect(UsbJournalInfo.state(.needsReplan).isPending == false)
        #expect(UsbJournalInfo.state(.committing).isPending)
    }

    @Test("회복이 다시 계획하라고 하면 다시 미리 보기를 권하고, 그 볼륨을 다시 알리지 않는다")
    func needsReplanOffersNewPreview() async {
        var appeared: [String] = []
        let journal = service
        let (usb, usbHost) = store(journal: { journal.journal(volumeKey: $0) })
        usb.onPendingJournal = { appeared.append($0.usbKey) }
        // 쓰다가 USB가 빠짐: 저널이 열린 채 남는다
        service.update {
            $0.writeResult = .failure(.volumeLost(volumeName: "B12T"))
            $0.journalAfterWrite = .state(.filesWritten)
        }
        await coordinator(usb).export(job())
        #expect(prompter.shown.last == UsbWriteFlow.interruptedPrompt(.volumeLost(volumeName: "B12T")))
        // 다시 나타나면 알린다(자동으로 회복하지 않는다)
        usbHost.mounted = []
        await usb.refresh()
        usbHost.mounted = [image]
        await usb.refresh()
        #expect(appeared == [image.usbKey])
        #expect(!service.current.recovered)

        service.update {
            $0.calls = []
            $0.recoverResult = .success(UsbWriteReport(outcome: .needsReplan, session: "s1"))
            $0.journalAfterRecover = .state(.needsReplan)
        }
        prompter.choices = [.confirm]
        prompter.answers = [true, false]
        await coordinator(usb).offerRecovery(image)
        #expect(prompter.shown.contains(UsbWriteFlow.replanPrompt))
        // 회복 뒤 다시 미리 보기만 하고 쓰지 않는다
        #expect(service.current.called("recover", before: "preview") && !service.current.wrote)
        #expect(usb.exportSheet?.volumeKey == image.usbKey)
        #expect(usb.exportSheet?.summary != nil)

        // 닫힌 저널(다시 계획)은 볼륨이 다시 나타나도 알리지 않는다
        usbHost.mounted = []
        await usb.refresh()
        usbHost.mounted = [image]
        await usb.refresh()
        #expect(appeared == [image.usbKey])
    }

    @Test("실물 볼륨의 끝나지 않은 쓰기: 회복을 눌러도 관문 막힘 문구만 보이고 파일은 건드리지 않는다")
    func pendingJournalOnPhysicalShowsBlocked() async {
        let physical = FakeUsbVolume.physicalFAT32()
        let (usb, _) = store([physical])
        service.update {
            $0.journal = .state(.committing)
            $0.recoverResult = .failure(.writeRefused([UsbTestData.physicalBlock]))
        }
        prompter.choices = [.confirm]
        await coordinator(usb).offerRecovery(physical)
        #expect(service.current.recovered && !service.current.restored)
        #expect(service.current.fileOperations == 0)
        let shown = prompter.shown.last
        #expect(shown?.title == UsbWriteFlow.Text.notRecoveredTitle)
        #expect(shown?.text == UsbTestData.physicalBlock.message)
        // 되돌리기도 같은 막힘에서 멈춘다(되돌리기까지 가지 않는다)
        prompter.choices = [.alternate]
        await coordinator(usb).offerRecovery(physical)
        #expect(!service.current.restored)
        #expect(service.current.fileOperations == 0)
    }

    @Test("볼륨이 나타나도 사용자가 누르기 전에는 회복하지 않는다")
    func recoverNeverAutomatic() async {
        var appeared: [UsbVolumeInfo] = []
        let journal = service
        service.update { $0.journal = .state(.committing) }
        let (usb, _) = store(journal: { journal.journal(volumeKey: $0) })
        usb.onPendingJournal = { appeared.append($0) }
        await usb.refresh()
        #expect(appeared.map(\.usbKey) == [image.usbKey])
        // 붙어 있는 동안 다시 읽어도 또 알리지 않는다
        await usb.refresh()
        #expect(appeared.count == 1)
        #expect(service.current.calls.isEmpty)
        prompter.choices = [.cancel]
        await coordinator(usb).offerRecovery(image)
        #expect(service.current.calls.isEmpty)
        #expect(service.current.fileOperations == 0)
        // 끝난 저널이면 알리지 않는다
        service.update { $0.journal = .none }
        prompter.shown = []
        await coordinator(usb).offerRecovery(image)
        #expect(prompter.shown.isEmpty)
    }

    @Test("기기가 그 뒤에 쓴 것이 있으면 되돌리기 전에 한 번 더 묻는다")
    func discardDeviceChangesConfirm() async {
        let (usb, _) = store()
        service.update {
            $0.journal = .state(.committed)
            $0.deviceChanged = true
        }
        prompter.choices = [.alternate]
        prompter.answers = [false]
        await coordinator(usb).offerRecovery(image)
        let confirm = prompter.shown.last
        #expect(confirm == UsbWriteFlow.discardDeviceChangesPrompt(image))
        #expect(confirm?.destructive == true)
        // 묻는 창에서 그만두면 기기 변경을 버리는 되돌리기는 하지 않는다
        #expect(service.current.called("recover", before: "restore") && !service.current.calls.contains("restore(discard)"))

        service.update { $0.calls = [] }
        prompter.choices = [.alternate]
        prompter.answers = [true]
        await coordinator(usb).offerRecovery(image)
        #expect(service.current.called("restore", before: "restore(discard)"))
        #expect(host.toast?.title == UsbWriteFlow.Text.restoredTitle)
    }

    @Test("회복·되돌리기가 실패하면 기기에 꽂지 말라고 알리고, 그 밖의 USB 오류는 그 설명을 보인다")
    func recoverAndRevertFailureWarnings() async {
        let (usb, _) = store()
        let backup = URL(filePath: "/tmp/djc-fixture/usb-backups/B/9")
        var opened: [URL] = []
        service.update {
            $0.journal = .state(.committing)
            $0.recoverResult = .failure(.restoreFailed(reason: "회복", restoreError: "rename", backup: backup.path))
        }
        // 회복 → 되돌리지 못함: 경고와 백업 폴더 열기
        prompter.choices = [.confirm]
        prompter.answers = [true]
        await coordinator(usb, opened: { opened.append($0) }).offerRecovery(image)
        let failed = prompter.shown.last
        #expect(failed == UsbWriteFlow.interruptedPrompt(.restoreFailed(reason: "회복", restoreError: "rename", backup: backup.path))
            .map(UsbWriteFlow.withBackupButtons))
        #expect(failed?.critical == true)
        #expect(opened == [backup])

        // 회복 중 USB가 빠짐
        service.update { $0.recoverResult = .failure(.volumeLost(volumeName: "B12T")) }
        prompter.choices = [.confirm]
        await coordinator(usb).offerRecovery(image)
        #expect(prompter.shown.last == UsbWriteFlow.interruptedPrompt(.volumeLost(volumeName: "B12T")))

        // 되돌리기의 복원이 rekordbox 때문에 미뤄짐·USB가 빠짐
        service.update {
            $0.recoverResult = .success(UsbWriteReport(outcome: .recovered, session: "s1", backup: backup.path))
            $0.restoreResult = .failure(.restorePending(reason: "rekordbox"))
        }
        prompter.choices = [.alternate]
        await coordinator(usb).offerRecovery(image)
        #expect(prompter.shown.last == UsbWriteFlow.interruptedPrompt(.restorePending(reason: "rekordbox")))
        service.update { $0.restoreResult = .failure(.volumeLost(volumeName: "B12T")) }
        prompter.choices = [.alternate]
        await coordinator(usb).offerRecovery(image)
        #expect(prompter.shown.last == UsbWriteFlow.interruptedPrompt(.volumeLost(volumeName: "B12T")))

        // 그 밖의 USB 오류는 일반 문구 대신 그 설명을 보인다
        service.update { $0.recoverResult = .failure(.formatUnsupported(detail: "x")) }
        prompter.choices = [.confirm]
        await coordinator(usb).offerRecovery(image)
        #expect(prompter.shown.last?.title == UsbWriteFlow.Text.notRecoveredTitle)
        #expect(prompter.shown.last?.text == UsbError.formatUnsupported(detail: "x").errorDescription)
        #expect(usb.busyVolumes.isEmpty)
        #expect(usb.activeWrite == nil)
    }

    @Test("회복 결과: 끊긴 되돌리기를 마치면 되돌렸다고, 저널이 없었으면 회복할 쓰기가 없다고 알린다")
    func recoverOutcomeToasts() async {
        let (usb, _) = store()
        service.update {
            $0.journal = .state(.restorePending)
            $0.recoverResult = .success(UsbWriteReport(outcome: .restored, session: "s1", backup: "/tmp/djc-fixture/usb-backups/B/s1"))
        }
        prompter.choices = [.confirm]
        await coordinator(usb).offerRecovery(image)
        #expect(host.toast?.title == UsbWriteFlow.Text.restoredTitle)
        #expect(host.toast?.action == nil)

        service.update { $0.recoverResult = .success(UsbWriteReport(outcome: .recovered, session: "")) }
        prompter.choices = [.confirm]
        await coordinator(usb).offerRecovery(image)
        #expect(host.toast?.title == UsbWriteFlow.Text.nothingToRecoverTitle)
        #expect(host.toast?.action == nil)
        #expect(!service.current.restored)
    }

    @Test("되돌리기는 끝나지 않은 그 쓰기의 백업으로만 되돌린다")
    func revertUsesPendingWriteBackup() async {
        let (usb, _) = store()
        let backup = URL(filePath: "/tmp/djc-fixture/usb-backups/B/7")
        service.update {
            $0.journal = .state(.committed)
            $0.recoverResult = .success(UsbWriteReport(outcome: .recovered, session: "s7", backup: backup.path))
        }
        prompter.choices = [.alternate]
        await coordinator(usb).offerRecovery(image)
        #expect(service.current.called("recover", before: "restore"))
        #expect(service.current.restoredBackups == [backup])

        // 회복이 끊긴 되돌리기를 마쳤으면 다시 되돌리지 않는다
        service.update {
            $0.calls = []
            $0.recoverResult = .success(UsbWriteReport(outcome: .restored, session: "s7", backup: backup.path))
        }
        prompter.choices = [.alternate]
        await coordinator(usb).offerRecovery(image)
        #expect(service.current.recovered && !service.current.restored)
        #expect(host.toast?.title == UsbWriteFlow.Text.restoredTitle)

        // 저널이 없었거나(다른 곳에서 닫음) 백업 폴더가 없으면 다른 쓰기의 백업을 고르지 않는다
        for report in [UsbWriteReport(outcome: .recovered, session: ""), UsbWriteReport(outcome: .recovered, session: "s7", backup: nil)] {
            service.update {
                $0.calls = []
                $0.recoverResult = .success(report)
            }
            prompter.choices = [.alternate]
            await coordinator(usb).offerRecovery(image)
            #expect(service.current.recovered && !service.current.restored)
            #expect(prompter.shown.last?.title == UsbWriteFlow.Text.notRestoredTitle)
            #expect(prompter.shown.last?.text == UsbWriteFlow.Text.backupMissingText)
        }
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("쓰기 직전에 다른 곳이 저널을 열면(쓰기 절차의 recoveryNeeded 막힘) 회복 알림으로 간다")
    func writeRefusedRecoveryNeededOffersRecovery() async {
        let (usb, _) = store()
        service.update {
            $0.writeResult = .failure(.writeRefused([UsbBlock(code: "recoveryNeeded", scope: .volume, message: "회복 먼저")]))
            $0.journalAfterWrite = .state(.filesWritten)
        }
        prompter.choices = [.cancel]
        await coordinator(usb).export(job())
        #expect(service.current.previewedBeforeWrite)
        #expect(prompter.shown.last == UsbWriteFlow.pendingPrompt(image))
        #expect(!prompter.shown.contains { $0.title == UsbWriteFlow.Text.notWrittenTitle })
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("내보내기 시트는 연 볼륨을 들고 있고, 그 볼륨이 빠지면 닫힌다")
    func exportSheetClosesWhenVolumeLeaves() async {
        let (usb, usbHost) = store()
        await usb.refresh()
        usb.exportSheet = UsbExportSheetRequest(volume: image)
        #expect(usb.exportSheet?.volume == image)
        #expect(usb.exportSheet?.volumeKey == image.usbKey)
        await usb.refresh()
        #expect(usb.exportSheet != nil)
        usbHost.mounted = []
        await usb.refresh()
        #expect(usb.exportSheet == nil)

        // 꺼내도 닫힌다
        usbHost.mounted = [image]
        await usb.refresh()
        usb.exportSheet = UsbExportSheetRequest(volume: image)
        #expect(await usb.eject(image.usbKey) == nil)
        #expect(usb.exportSheet == nil)
    }

    // MARK: - 토스트·진행

    @Test("다 쓰면 곡 수와 꺼내기를 알리고, 꺼내기를 누르면 그 볼륨을 꺼낸다")
    func toastEjectAction() async {
        let (usb, usbHost) = store()
        await usb.refresh()
        let coordinator = coordinator(usb)
        await coordinator.export(job())
        #expect(host.toast?.kind == .success)
        #expect(host.toast?.title == UsbWriteFlow.Text.writtenTitle(tracks: 3))
        #expect(host.toast?.action == .ejectUsb(volumeKey: image.usbKey))
        #expect(usb.lastExports[image.usbKey] == job())
        if let action = host.toast?.action { await coordinator.perform(action) }
        #expect(usbHost.ejectCalls == [image.usbKey])
        #expect(usb.volume(image.usbKey) == nil)
    }

    @Test("DB 교체가 시작되면 취소 단추를 숨기고 취소를 받지 않는다")
    func progressHidesCancelAfterCommit() {
        let (usb, _) = store()
        let flag = usb.beginWrite(image, title: "시험")
        usb.report(UsbProgress(phase: .files, completedItems: 2, totalItems: 8, completedBytes: 1 << 20, totalBytes: 4 << 20,
                               cancellable: true), for: image.usbKey)
        let files = UsbWriteProgressModel(usb.activeWrite!)
        #expect(files.showsCancel)
        #expect(files.items == "2/8")
        #expect(files.phase == "파일 쓰기")
        usb.report(UsbProgress(phase: .commit, completedItems: 1, totalItems: 3, cancellable: false), for: image.usbKey)
        let commit = UsbWriteProgressModel(usb.activeWrite!)
        #expect(!commit.showsCancel)
        #expect(commit.phase == "DB 교체")
        usb.cancelWrite()
        #expect(flag?.isSet == false)
        // 다른 볼륨의 진행은 받지 않는다
        usb.report(UsbProgress(phase: .files, cancellable: true), for: "other")
        #expect(usb.activeWrite?.progress?.phase == .commit)
        usb.endWrite(image.usbKey)
        #expect(usb.activeWrite == nil)
    }

    // MARK: - 자가 테스트

    @Test("USB 자가 테스트는 임시 DJC_HOME과 명시한 사본(--db·DJC_DB)이 있어야 띄운다")
    func usbSelfTestRequiresExplicitDatabase() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-usbselftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let args = ["DJCrate", "--usb-selftest"]
        #expect(UsbSelfTest.launchRefusal(arguments: args + ["--db", "/tmp/x/m.db"], environment: ["DJC_HOME": home.path]) == nil)
        #expect(UsbSelfTest.launchRefusal(arguments: args, environment: ["DJC_HOME": home.path])
            == "USB 시험 실패: --db <스냅샷 사본>으로 띄우세요")
        #expect(UsbSelfTest.launchRefusal(arguments: args + ["--db"], environment: ["DJC_HOME": home.path]) != nil)
        #expect(UsbSelfTest.launchRefusal(arguments: args, environment: ["DJC_HOME": home.path, "DJC_DB": "/tmp/x/m.db"]) == nil)
        // 격리 실행의 HOME은 임시 폴더일 수 있다. 항상 있는 비임시 경로로 경로 제한 자체를 확인한다.
        #expect(UsbSelfTest.launchRefusal(arguments: args + ["--db", "/tmp/x/m.db"], environment: ["DJC_HOME": "/"])?.contains("outsideScratch") == true)
        #expect(UsbSelfTest.launchRefusal(arguments: args + ["--db", "/tmp/x/m.db"], environment: [:]) != nil)
        // 앱 시작 때(라이브러리를 읽기 전) 보는 판정: 자가 테스트 인자가 있을 때만 거부한다
        #expect(UsbSelfTest.startupRefusal(arguments: ["DJCrate"], environment: [:]) == nil)
        #expect(UsbSelfTest.startupRefusal(arguments: args, environment: ["DJC_HOME": home.path])
            == "USB 시험 실패: --db <스냅샷 사본>으로 띄우세요")
        #expect(UsbSelfTest.startupRefusal(arguments: args + ["--db", "/tmp/x/m.db"], environment: ["DJC_HOME": home.path]) == nil)
    }

    @Test("provenance: 앱이 쓴 파일 가운데 옆에 ._가 생겨 지운 파일만 센다(임시 이름·폴더의 ._는 빼고)")
    func provenanceCountsFinalFilesOnly() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-provenance-\(UUID().uuidString)")
        let folder = root.appending(path: "PIONEER/USBANLZ")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["._ANLZ0000.DAT", "._\(UsbLayout.tempPrefix)s-1", "._ANLZ0000.EXT"]
        for name in names { try Data([0]).write(to: folder.appending(path: name)) }
        try Data([0]).write(to: root.appending(path: "PIONEER/._USBANLZ"))
        let recorder = UsbAppleDoubleRecorder()
        for name in names { try recorder.remove(folder.appending(path: name)) }
        try recorder.remove(root.appending(path: "PIONEER/._USBANLZ"))
        #expect(recorder.removedAppleDoubles.count == 4)
        let written = ["PIONEER/USBANLZ/ANLZ0000.DAT", "PIONEER/USBANLZ/ANLZ0000.2EX", "PIONEER/rekordbox/export.pdb"]
        #expect(UsbSelfTestScenario.appleDoubleCount(appFiles: written, root: root, removed: recorder.removedAppleDoubles) == 1)
        // 한글 이름도 NFC·NFD 차이 없이 맞춘다
        let nfd = "Contents/\("가".decomposedStringWithCanonicalMapping)/a.mp3"
        let removed = [root.appending(path: "Contents/가/._a.mp3").path]
        #expect(UsbSelfTestScenario.appleDoubleCount(appFiles: [nfd], root: root, removed: removed) == 1)
    }
}
