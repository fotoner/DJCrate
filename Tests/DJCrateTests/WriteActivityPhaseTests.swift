@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
@testable import RekordboxKit
import Testing

/// 쓰는 중 앱 종료(#300): 저장소의 쓰기 상태(잠금·진행 안내·창이 떠 있는지)가 종료 판정의 단계(`RekordboxWritePhase`)로 맞게 옮겨지는지,
/// 새 쓰기를 거절해야 할 때(종료 기다림·전원 끔) 거절하는지 본다.
@MainActor
@Suite("쓰기 단계와 종료 판정 연결")
struct WriteActivityPhaseTests {
    let store = LibraryStore.test(activityLog: ActivityLog(url: nil))

    /// 창이 뜬 순간의 단계를 남기는 프롬프터
    @MainActor final class ProbePrompter: HeadlessReflectionPrompter {
        var phases: [RekordboxWritePhase] = []
        var phase: () -> RekordboxWritePhase = { .idle }
        func show(_ prompt: ReflectionPrompt) -> Bool {
            phases.append(phase())
            return true
        }
    }

    // MARK: - 단계

    @Test func 저장소의_쓰기_상태가_단계로_옮겨진다() {
        #expect(store.rekordboxWritePhase == .idle)
        store.setWriteLock(true)
        // 진행 안내가 없는 쓰기(iTunes 동기화 등)는 끊지 않는다
        #expect(store.rekordboxWritePhase == .writing)
        store.writeStage = WriteStage("미리 보기 1/2단계 · 사본을 만드는 중…", completed: 0, total: 2, cancellable: true)
        #expect(store.rekordboxWritePhase == .cancellable)
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        #expect(store.rekordboxWritePhase == .writing)
        store.writeStage = .reloadingLibrary
        #expect(store.rekordboxWritePhase == .readingBack)
        store.setWriteLock(false)
        #expect(store.rekordboxWritePhase == .idle)
    }

    @Test func 확인_창과_경고창이_떠_있는_동안은_진행_안내보다_앞선다() {
        store.setWriteLock(true)
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        store.isAwaitingConfirmation = true
        #expect(store.rekordboxWritePhase == .confirming)
        store.isAwaitingAcknowledgement = true
        #expect(store.rekordboxWritePhase == .acknowledging)
        store.isAwaitingAcknowledgement = false
        store.isAwaitingConfirmation = false
        #expect(store.rekordboxWritePhase == .writing)
        // 잠금이 없으면 확인 창 표시가 남아 있어도 쓰는 중이 아니다
        store.setWriteLock(false)
        store.isAwaitingConfirmation = true
        #expect(store.rekordboxWritePhase == .idle)
        store.isAwaitingConfirmation = false
        // 확인할 경고창은 잠금이 풀린 뒤(시점 복원 실패)에도 뜬다
        store.isAwaitingAcknowledgement = true
        #expect(store.rekordboxWritePhase == .acknowledging)
    }

    @Test func 쓰기_활동은_rekordbox_단계와_USB를_함께_든다() throws {
        #expect(store.writeActivity == .idle)
        store.setWriteLock(true)
        store.writeStage = .reloadingLibrary
        #expect(store.writeActivity == AppWriteActivity(rekordbox: .readingBack, writingUsb: false))
        store.setWriteLock(false)
        let volume = FakeUsbVolume.diskImageFAT32(name: "B1", uuid: "00000000-0000-0000-0000-0000000000B1")
        let usb = UsbTestData.store(FakeUsbHost([volume]))
        store.usb = usb
        _ = try #require(usb.beginWrite(volume, title: "합성 쓰기"))
        #expect(store.writeActivity == AppWriteActivity(rekordbox: .idle, writingUsb: true))
    }

    // MARK: - 창이 뜬 동안

    @Test func 쓰기_확인_창이_뜬_동안만_확인_중이다() {
        let prompter = ProbePrompter()
        let coordinator = ReflectionCoordinator.test(store: store, prompter: prompter)
        prompter.phase = { [store] in store.rekordboxWritePhase }
        store.setWriteLock(true)
        _ = coordinator.session.ports.confirmation.confirm(ReflectionPrompt(title: "쓸까요?", text: "확인"))
        _ = coordinator.session.ports.confirmation.choose(ReflectionPrompt(title: "복원할까요?", text: "확인"))
        #expect(prompter.phases == [.confirming, .confirming])
        #expect(store.rekordboxWritePhase == .writing, "답한 뒤에는 풀린다")
    }

    @Test func 자동_복원까지_실패한_경고창이_뜬_동안만_확인이_필요하다() {
        let prompter = ProbePrompter()
        let presenter = ReflectionPresenter(store: store, prompter: prompter)
        prompter.phase = { [store] in store.rekordboxWritePhase }
        store.setWriteLock(true)
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/test-backup"), createdAt: .now, isWrite: true, report: nil)
        presenter.publish(.restoreFailed(backup, error: FixtureFailure()))
        presenter.publish(.failed(title: "rekordbox에 쓰지 않았습니다",
                                  error: DJCError.restoreFailed(reason: "검증 실패", restoreError: "복원 실패", backup: "/tmp/b", database: nil),
                                  exclusions: []))
        #expect(prompter.phases == [.acknowledging, .acknowledging])
        #expect(store.rekordboxWritePhase == .writing)
        // 복원이 일어나지 않은 평범한 실패는 토스트로 알리니 확인이 필요하지 않다
        presenter.publish(.failed(title: "rekordbox에 쓰지 않았습니다", error: FixtureFailure(), exclusions: []))
        #expect(prompter.phases.count == 2)
    }

    // MARK: - 새 쓰기 거절

    @Test func 종료를_기다리거나_Mac을_끄는_중에는_새_쓰기를_거절한다() {
        #expect(store.writeRefusal == nil)
        store.isPoweringOff = true
        #expect(store.writeRefusal == "Mac을 끄는 중이라 rekordbox에 쓰지 않았습니다. 다시 켠 뒤 쓰세요")
        store.isPoweringOff = false
        store.quitWait.begin(at: Date(timeIntervalSince1970: 0), onCancel: {})
        #expect(store.writeRefusal == "종료하는 중이라 rekordbox에 쓰지 않았습니다. 종료를 취소한 뒤 다시 쓰세요")
        store.quitWait.finish()
        #expect(store.writeRefusal == nil)
    }

    @Test func 전원을_끄는_중에_쓰기를_시작하면_쓰지_않고_이유를_알린다() {
        store.isPoweringOff = true
        let coordinator = ReflectionCoordinator.test(store: store)
        coordinator.startWrite(rows: [])
        coordinator.startAddTracks(rows: [])
        coordinator.startDeleteTracks(rows: [])
        #expect(store.writeTask == nil && !store.isWritingRekordbox)
        #expect(store.toast?.title == "Mac을 끄는 중이라 rekordbox에 쓰지 않았습니다. 다시 켠 뒤 쓰세요")
        #expect(store.toast?.isNotice == true)
        // 복원은 백업이 없으면 그 안내가 먼저다. 어느 쪽이든 쓰기를 시작하지 않는다
        coordinator.startRestoreLatest()
        #expect(store.writeTask == nil && !store.isWritingRekordbox)
    }

    @Test func 세션도_거절_중에는_바쁘다고_답한다() async {
        store.isPoweringOff = true
        let coordinator = ReflectionCoordinator.test(store: store)
        #expect(coordinator.session.ports.lock.isLocked())
        #expect(await coordinator.session.write(rows: []).isBusy)
        #expect(await coordinator.session.addTracks(rows: []).isBusy)
        #expect(await coordinator.session.deleteTracks(rows: []).isBusy)
        // 복원도 같다(백업이 있어도 시작하지 않는다)
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/test-backup"), createdAt: .now, isWrite: true, report: nil)
        #expect(await coordinator.session.restore(backup).isBusy)
        #expect(!store.isWritingRekordbox)
    }

    @Test func 전원_끔_알림을_받으면_저장소에_알리고_앱이_다시_활성화되면_푼다() {
        let center = NotificationCenter()
        let delegate = AppDelegate()
        delegate.store = store
        delegate.observePowerOff(center: center, activation: center)
        center.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        #expect(store.isPoweringOff)
        // 취소된 로그아웃은 알림이 없다: 앱이 다시 활성화되면 쓰기를 다시 연다
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(!store.isPoweringOff)
    }

    @Test func 전원을_끄는_중에_쓰는_중이면_같이_기다린다() async {
        let delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.replyToTermination = { replies.append($0) }
        delegate.store = store
        store.isPoweringOff = true
        store.setWriteLock(true)
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        store.writeStage = .reloadingLibrary
        #expect(await waitForState { replies == [true] })
    }
}

private extension ReflectionOutcome {
    var isBusy: Bool { if case .busy = self { true } else { false } }
}
