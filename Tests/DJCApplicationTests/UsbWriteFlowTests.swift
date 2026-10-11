import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// USB 쓰기 흐름 시험의 쓰기 창구 가짜: 미리 보기·쓰기·저널·회복·되돌리기에 정해 둔 답을 주고 부른 차례를 적는다(USB·Mac 파일 없음)
final class FlowFakeService: UsbWriting, Sendable {
    struct State {
        var calls: [String] = []
        var running = false
        var journal: UsbJournalInfo = .none
        var summary = UsbExportSummary(trackCount: 3, playlistCount: 1, blocks: [], ruleCounts: [:], requiredRules: [],
                                       requiredBytes: 1, availableBytes: 100, hasChanges: true, isTestVolume: true, unverifiedTrackCount: 0)
        var writeResult: Result<UsbWriteReport, UsbError> = .success(UsbWriteReport(outcome: .written, session: "s1"))
        var recoverResult: Result<UsbWriteReport, UsbError> = .success(UsbWriteReport(outcome: .recovered, session: "s1"))
        var latestBackup: URL?
    }
    let state = Mutex(State())
    var calls: [String] { state.withLock { $0.calls } }
    private func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func isRekordboxRunning() -> Bool { record("running"); return state.withLock { $0.running } }
    func journal(volumeKey: String) -> UsbJournalInfo { record("journal"); return state.withLock { $0.journal } }
    func preview(_ input: UsbExportInput) throws -> UsbExportSummary { record("preview"); return state.withLock { $0.summary } }
    func write(_ input: UsbExportInput, progress: @escaping @Sendable (UsbProgress) -> Void,
               isCancelled: @escaping @Sendable () -> Bool) throws -> UsbWriteReport {
        record("write")
        return try state.withLock { $0.writeResult }.get()
    }
    func recover(_ volume: UsbVolumeInfo) throws -> UsbWriteReport { record("recover"); return try state.withLock { $0.recoverResult }.get() }
    func restore(_ volume: UsbVolumeInfo, backup: URL?, discardDeviceChanges: Bool) throws -> UsbWriteReport {
        record("restore")
        return UsbWriteReport(outcome: .restored, session: "s1")
    }
    func latestBackup(volumeKey: String) -> URL? { record("latestBackup"); return state.withLock { $0.latestBackup } }
    func currentVolume(_ volume: UsbVolumeInfo) throws -> UsbVolumeInfo { record("currentVolume"); return volume }
    func syncSelectionBaseFiles(_ volume: UsbVolumeInfo, formats: Set<UsbFormat>) throws -> [UsbFormat: Data] {
        record("syncFiles")
        return [:]
    }
    func isScratchMount(_ mountPoint: String) -> Bool { true }
    var syncGate: UsbSyncSelectionGate { UsbSyncSelectionGate(gateBlock: { _, _ in nil }, productionBlock: { nil }, draftBlock: { _ in nil }) }

    // 이 시험이 쓰지 않는 것
    func previewMigration(_ volume: UsbVolumeInfo) throws -> UsbMigrationSummary { throw UsbError.cancelled }
    func writeMigration(_ volume: UsbVolumeInfo, progress: @escaping @Sendable (UsbProgress) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) throws -> UsbMigrationWritten { throw UsbError.cancelled }
    func draftBase(_ volume: UsbVolumeInfo) throws -> UsbFingerprint { UsbFingerprint(files: [:]) }
    func previewEdit(_ input: UsbEditInput) throws -> UsbEditSummary { throw UsbError.cancelled }
    func writeEdit(_ input: UsbEditInput, progress: @escaping @Sendable (UsbProgress) -> Void,
                   isCancelled: @escaping @Sendable () -> Bool) throws -> UsbEditWritten { throw UsbError.cancelled }
    func planCueGridImport(volume: UsbVolumeInfo, snapshot: URL, share: URL, scratch: URL,
                           rows: [String: UsbCueGridImportTrack]) throws -> UsbCueGridImportPlan { throw UsbError.cancelled }
}

/// 쓰기 흐름이 보는 USB 화면·알림·확인 창의 가짜
@MainActor
final class UsbWriteWorld {
    let session = UsbWriteSession()
    let service = FlowFakeService()
    var volumes: [UsbVolumeInfo]
    var prompts: [ReflectionPrompt] = []
    var answers: [Bool] = []
    var choice: ReflectionChoice = .cancel
    var toasts: [UsbWriteToast] = []
    var dismissed: [String] = []
    var opened: [URL] = []
    var refreshes = 0
    var exportSheet: UsbExportSheetRequest?
    var sourceIsCurrent = true
    var ejectFailure: String?
    var ejected: [String] = []

    init(volumes: [UsbVolumeInfo] = [FakeUsbVolume.diskImageFAT32()]) {
        self.volumes = volumes
    }

    var flow: UsbWriteFlow {
        UsbWriteFlow(
            session: session,
            screen: UsbWriteScreen(
                volume: { key in self.volumes.first { $0.usbKey == key } }, isEjecting: { _ in false }, draftEdits: { _ in nil },
                libraryFormats: { _ in nil }, savedSyncDraft: { _ in nil }, rememberSyncDraft: { _, _, _ in }, invalidateSyncDraft: { _ in },
                beginWrite: { volume, title, cancellable in self.session.begin(volume, title: title, cancellable: cancellable) },
                refresh: { self.refreshes += 1 }, reloadDraft: { _ in },
                draftQueue: { _, body in await body() }, draftEditing: { nil }, setExportSheet: { self.exportSheet = $0 },
                eject: { key in self.ejected.append(key); return self.ejectFailure }),
            syncSourceIsCurrent: { _, _, _ in self.sourceIsCurrent },
            service: service,
            confirmation: UserConfirmation(confirm: { prompt in
                self.prompts.append(prompt)
                return self.answers.isEmpty ? true : self.answers.removeFirst()
            }, choose: { prompt in
                self.prompts.append(prompt)
                return self.choice
            }),
            results: UsbWriteResults(show: { self.toasts.append($0) }, dismissEject: { self.dismissed.append($0) },
                                     errorText: { _ in "일반 오류" }, log: { _ in }, openFolder: { self.opened.append($0) }),
            isRekordboxRunning: nil)
    }

    var volume: UsbVolumeInfo { volumes[0] }

    func job(native: Bool = false) -> UsbExportJob {
        UsbExportJob(database: URL(filePath: "/private/tmp/djc-flow/master-copy.db"), share: URL(filePath: "/private/tmp/djc-flow/share"),
                     volume: volume, selection: .playlists(["10"]), formats: UsbFormat.defaultSet, snapshotTime: nil,
                     syncSelection: native ? UsbSyncSelectionDraft(localDBID: 1, sourceNodes: [], selection: ITunesSyncSelection(), enabled: true,
                                                                   playlistRefs: [:], baseFiles: [:]) : nil)
    }
}

@MainActor
@Suite("USB 쓰기 흐름")
struct UsbWriteFlowTests {
    @Test func rekordbox가_켜져_있으면_잠그지도_미리_보지도_않고_알린다() async {
        let world = UsbWriteWorld()
        world.service.state.withLock { $0.running = true }
        #expect(await world.flow.export(world.job()) == false)
        #expect(world.service.calls == ["running"])
        #expect(world.toasts == [.notice(title: UsbWriteFlow.Text.rekordboxRunningTitle, text: UsbWriteFlow.Text.rekordboxRunningDetail)])
        #expect(world.session.busyVolumes.isEmpty && world.prompts.isEmpty)
    }

    @Test func 내보내기는_잠그고_미리_보고_묻고_저널을_다시_본_뒤_쓰고_알린다() async throws {
        let world = UsbWriteWorld()
        let job = world.job()
        #expect(await world.flow.export(job) == true)
        #expect(world.service.calls == ["running", "journal", "preview", "journal", "write"])
        let summary = world.service.state.withLock { $0.summary }
        #expect(world.prompts == [UsbWriteFlow.confirmation(summary, job: job)], "확인 창 하나(볼륨 줄을 보인 창이 쓰기 동의다)")
        guard case let .success(title, _, eject)? = world.toasts.last else { Issue.record("쓴 알림"); return }
        #expect(title == UsbWriteFlow.Text.writtenTitle(tracks: 3) && eject == job.volumeKey)
        #expect(world.session.busyVolumes.isEmpty && world.session.activeWrite == nil, "끝나면 잠금을 푼다")
        #expect(world.refreshes == 1)
        #expect(world.session.lastExports[job.volumeKey]?.snapshotLease == nil, "지난 쓰기에는 사본 소유권 없이 남긴다")
    }

    @Test func 시트가_동의하고_미리_본_결과를_주면_다시_묻지도_미리_보지도_않는다() async {
        let world = UsbWriteWorld()
        let summary = world.service.state.withLock { $0.summary }
        #expect(await world.flow.export(world.job(), reusing: summary, consented: true) == true)
        #expect(world.prompts.isEmpty && !world.service.calls.contains("preview") && world.service.calls.contains("write"))
    }

    @Test func 동의만_있고_미리_본_결과가_없으면_확인_창으로_묻는다() async {
        let world = UsbWriteWorld()
        world.answers = [false]
        #expect(await world.flow.export(world.job(), consented: true) == false)
        #expect(world.prompts.count == 1 && !world.service.calls.contains("write"))
        #expect(world.toasts.isEmpty && world.session.busyVolumes.isEmpty)
    }

    @Test func 쓸_수_없는_미리_보기는_이유를_보이고_쓰지_않는다() async {
        let world = UsbWriteWorld()
        world.service.state.withLock {
            $0.summary = UsbExportSummary(trackCount: 0, playlistCount: 0, blocks: [UsbBlock(code: "noTracks", scope: .volume, message: "곡이 없습니다")],
                                          ruleCounts: [:], requiredRules: [], requiredBytes: 0, availableBytes: 100, hasChanges: false,
                                          isTestVolume: true, unverifiedTrackCount: 0)
        }
        #expect(await world.flow.export(world.job()) == false)
        #expect(world.prompts.first?.title == UsbWriteFlow.Text.cannotWriteTitle && !world.service.calls.contains("write"))
    }

    @Test func 끝나지_않은_쓰기가_있으면_회복을_권하고_나중에면_손대지_않는다() async {
        let world = UsbWriteWorld()
        world.service.state.withLock { $0.journal = .state(.committing) }
        world.choice = .cancel
        #expect(await world.flow.export(world.job()) == false)
        #expect(world.prompts == [UsbWriteFlow.pendingPrompt(world.volume)])
        #expect(!world.service.calls.contains("preview") && !world.service.calls.contains("recover"))
    }

    @Test func 회복하기를_누르면_잠그고_회복한_뒤_알리고_다시_읽는다() async {
        let world = UsbWriteWorld()
        world.service.state.withLock { $0.journal = .state(.committing) }
        world.choice = .confirm
        await world.flow.offerRecovery(world.volume)
        #expect(world.service.calls.suffix(1) == ["recover"])
        #expect(world.toasts == [.success(title: UsbWriteFlow.Text.recoveredTitle, ejectVolumeKey: world.volume.usbKey)])
        #expect(world.refreshes == 1 && world.session.busyVolumes.isEmpty)
    }

    @Test func 이미_쓰는_볼륨이면_알리기만_한다() async {
        let world = UsbWriteWorld()
        _ = world.session.begin(world.volume, title: "다른 쓰기")
        #expect(await world.flow.export(world.job()) == false)
        #expect(world.toasts == [.notice(title: UsbWriteFlow.Text.busyTitle, text: UsbWriteFlow.Text.retryLaterDetail)])
        #expect(!world.service.calls.contains("preview"))
    }

    @Test func 되돌린_쓰기_실패는_백업_폴더를_열_수_있게_알린다() async throws {
        let world = UsbWriteWorld()
        let backup = URL(filePath: "/private/tmp/djc-flow/usb-backups/B/s1")
        world.service.state.withLock {
            $0.writeResult = .failure(.writeRolledBack(reason: "검증 실패"))
            $0.latestBackup = backup
        }
        world.answers = [true, true]
        #expect(await world.flow.export(world.job()) == false)
        let error = UsbError.writeRolledBack(reason: "검증 실패")
        let prompt = try #require(UsbWriteFlow.interruptedPrompt(error))
        #expect(world.prompts.last == UsbWriteFlow.withBackupButtons(prompt))
        #expect(world.opened == [backup] && world.service.calls.contains("latestBackup"))
    }

    @Test func 동기화_원본이_바뀐_native_내보내기는_잠그지_않고_알린다() async {
        let world = UsbWriteWorld()
        world.sourceIsCurrent = false
        #expect(await world.flow.export(world.job(native: true)) == false)
        #expect(world.service.calls.isEmpty && world.session.busyVolumes.isEmpty)
        #expect(world.toasts.first == .notice(title: UsbWriteFlow.Text.notWrittenTitle,
                                              text: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요"))
    }

    @Test func 꺼내기는_알림을_닫고_꺼내며_못_꺼내면_이유를_알린다() async {
        let world = UsbWriteWorld()
        let key = world.volume.usbKey
        world.ejectFailure = "사용 중인 앱을 닫으세요"
        await world.flow.eject(key)
        #expect(world.dismissed == [key] && world.ejected == [key])
        #expect(world.toasts == [.notice(title: UsbWriteFlow.Text.ejectFailedTitle, text: "사용 중인 앱을 닫으세요")])
    }
}
