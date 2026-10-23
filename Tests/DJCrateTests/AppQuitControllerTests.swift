@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 쓰는 중 앱 종료(#300): 종료 요청을 받으면 쓰기 단계에 따라 바로 끄거나, 취소하고 끄거나, 끝날 때까지 기다렸다 끄거나, 끄지 않는다.
/// 판정표는 DJCDomainTests `AppQuitPolicyTests`가 본다. 여기서는 기다림의 흐름(한 번만 답하기·취소·시계·관찰)을 가짜로 본다.
/// 기다리는 방식은 둘이다: 종료를 미루고 `reply`로 답하는 방식(`nested`, 로그아웃·전원 끔)과 취소로 답하고 쓰기가 끝나면 다시 요청하는 기본 방식.
@MainActor
@Suite("앱 종료 컨트롤러")
struct AppQuitControllerTests {
    /// 컨트롤러가 부른 것을 남기는 가짜 주변
    @MainActor final class World {
        var activity = AppWriteActivity.idle
        var now = Date(timeIntervalSince1970: 1_000)
        var replies: [Bool] = []
        var informed: [String] = []
        var cancelled = 0
        var flushed = 0
        var raised = 0
        var terminated = 0
        var cancelledTerminations = 0
        /// 답하는 순간 초안 저장이 먼저 비워졌는지 보려고 남기는 순서
        var order: [String] = []
        let model = QuitWaitModel()

        lazy var controller = AppQuitController(
            model: model, activity: { [unowned self] in activity },
            cancelPreparation: { [unowned self] in cancelled += 1; order.append("cancel") },
            flushDrafts: { [unowned self] in flushed += 1; order.append("flush") },
            reply: { [unowned self] in replies.append($0); order.append("reply \($0)") },
            terminate: { [unowned self] in terminated += 1; order.append("terminate") },
            inform: { [unowned self] in informed.append($0) },
            terminationCancelled: { [unowned self] in cancelledTerminations += 1 },
            bringForward: { [unowned self] in raised += 1 },
            now: { [unowned self] in now })
    }

    let w = World()

    // MARK: - 바로 답하는 경우

    @Test func 쓰지_않으면_바로_끄고_기다림을_만들지_않는다() {
        #expect(w.controller.requestTermination(nested: true) == .terminateNow)
        #expect(w.model.current == nil && w.replies.isEmpty && w.informed.isEmpty && w.cancelled == 0)
    }

    @Test func 취소할_수_있는_단계면_취소를_부르고_바로_끈다() {
        w.activity = AppWriteActivity(rekordbox: .cancellable, writingUsb: false)
        #expect(w.controller.requestTermination(nested: true) == .terminateNow)
        #expect(w.cancelled == 1 && w.model.current == nil && w.replies.isEmpty)
        // 쓰지 않았으니 알림창도 없다
        #expect(w.informed.isEmpty)
    }

    @Test func 확인_창이_떠_있으면_취소를_부르지_않고_바로_끈다() {
        w.activity = AppWriteActivity(rekordbox: .confirming, writingUsb: false)
        #expect(w.controller.requestTermination(nested: true) == .terminateNow)
        #expect(w.cancelled == 0 && w.model.current == nil)
    }

    @Test func 쓴_뒤_다시_읽는_중이면_바로_끈다() {
        w.activity = AppWriteActivity(rekordbox: .readingBack, writingUsb: false)
        #expect(w.controller.requestTermination(nested: true) == .terminateNow)
        #expect(w.model.current == nil)
    }

    @Test func 바로_끄기_전에_초안_저장_큐를_비운다() {
        // 쓴 초안의 정리가 큐에 걸린 채 프로세스가 끝나면 쓴 초안이 디스크에 남는다
        w.activity = AppWriteActivity(rekordbox: .readingBack, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        #expect(w.flushed == 1)
    }

    @Test func 복원까지_실패해_확인이_필요하면_끄지_않고_앞으로_가져온다() {
        w.activity = AppWriteActivity(rekordbox: .acknowledging, writingUsb: false)
        #expect(w.controller.requestTermination(nested: true) == .terminateCancel)
        #expect(w.raised == 1 && w.informed.isEmpty && w.model.current == nil && w.replies.isEmpty)
    }

    @Test func USB에_쓰는_중이면_끄지_않고_이유와_할_일을_알린다() {
        w.activity = AppWriteActivity(rekordbox: .idle, writingUsb: true)
        #expect(w.controller.requestTermination(nested: true) == .terminateCancel)
        #expect(w.informed == ["USB에 쓰는 중이라 지금은 종료하지 않았습니다. 쓰기가 끝나면 다시 종료하세요"])
        #expect(w.model.current == nil && w.cancelled == 0)
    }

    // MARK: - 기다리는 경우(종료를 미루고 `reply`로 답한다)

    @Test func 쓰는_중이면_미루고_기다림을_시작한_시각과_함께_보인다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        #expect(w.controller.requestTermination(nested: true) == .terminateLater)
        #expect(w.model.current == QuitWait(startedAt: w.now) && w.replies.isEmpty && w.informed.isEmpty)
    }

    @Test func 지난_시간은_가짜_시계를_따라간다() throws {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        let wait = try #require(w.model.current)
        #expect(wait.elapsedSeconds(at: w.now) == 0)
        w.now.addTimeInterval(37.9)
        #expect(wait.elapsedSeconds(at: w.now) == 37)
    }

    @Test func 쓰기가_끝나면_초안_저장을_비운_뒤_한_번만_종료로_답한다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        // 다시 읽기 단계가 오면 끝난 것이다(DB·분석 파일·초안 정리가 끝났다)
        w.activity = AppWriteActivity(rekordbox: .readingBack, writingUsb: false)
        w.controller.activityChanged()
        w.controller.activityChanged()
        #expect(w.replies == [true] && w.model.current == nil)
        #expect(w.order == ["flush", "reply true"], "초안 저장 큐를 비운 뒤에 답한다: \(w.order)")
    }

    @Test func 쓰기가_모두_끝나_잠금이_풀려도_종료로_답한다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        w.activity = .idle
        w.controller.activityChanged()
        #expect(w.replies == [true])
    }

    @Test func 아직_쓰는_중이면_계속_기다린다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        w.now.addTimeInterval(120)
        w.controller.activityChanged()
        #expect(w.replies.isEmpty && w.model.current?.startedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test func 종료_취소를_누르면_종료만_취소하고_쓰기는_건드리지_않는다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        w.model.cancel()
        #expect(w.replies == [false] && w.model.current == nil)
        // 쓰기를 끊는 길은 없다: 취소 호출이 없고 쓰기 상태도 그대로다
        #expect(w.cancelled == 0 && w.activity.rekordbox == .writing)
        // 그 뒤 쓰기가 끝나도 이미 답했으니 다시 답하지 않는다
        w.activity = .idle
        w.controller.activityChanged()
        #expect(w.replies == [false])
        // 다시 눌러도 한 번만 답했다
        w.model.cancel()
        #expect(w.replies == [false])
    }

    @Test func 기다리는_중_종료를_다시_요청하면_종료만_취소한다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        #expect(w.controller.requestTermination(nested: true) == .terminateCancel)
        #expect(w.replies == [false] && w.model.current == nil && w.cancelled == 0)
        // 취소한 뒤 다시 종료를 요청하면 처음부터 기다린다
        #expect(w.controller.requestTermination(nested: true) == .terminateLater)
        #expect(w.model.current != nil)
    }

    @Test func 기다리는_중_복원까지_실패해_확인이_필요해지면_종료를_취소하고_앞으로_가져온다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        w.activity = AppWriteActivity(rekordbox: .acknowledging, writingUsb: false)
        w.controller.activityChanged()
        #expect(w.replies == [false] && w.model.current == nil && w.raised == 1)
        #expect(w.informed.isEmpty, "안내는 이미 떠 있는 경고창이다")
    }

    @Test func 기다리는_동안은_새_쓰기를_거절한다() {
        #expect(!w.model.isWaiting)
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        #expect(w.model.isWaiting)
        w.model.cancel()
        #expect(!w.model.isWaiting)
    }

    // MARK: - 종료를 취소로 끝냈을 때(Mac을 끄는 중이었다면 그 일도 멈췄다)

    @Test func 종료를_취소로_끝내면_알린다() {
        // USB에 쓰는 중이라 끄지 않았다
        w.activity = AppWriteActivity(rekordbox: .idle, writingUsb: true)
        _ = w.controller.requestTermination(nested: true)
        // 확인할 경고창이 떠 있어 끄지 않았다
        w.activity = AppWriteActivity(rekordbox: .acknowledging, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        #expect(w.cancelledTerminations == 2)
        // [종료 취소]
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        w.model.cancel()
        #expect(w.cancelledTerminations == 3)
        // 바로 끄는 요청과 기다림이 끝나 끄는 요청은 취소가 아니다
        w.activity = .idle
        _ = w.controller.requestTermination(nested: true)
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        w.activity = AppWriteActivity(rekordbox: .readingBack, writingUsb: false)
        w.controller.activityChanged()
        #expect(w.cancelledTerminations == 3)
    }

    /// ⌘Q로 기다리는 중(미루지 않는 방식)에 Mac을 끄는 요청이 오면 그 일을 취소하지 않고 같이 기다린다.
    @Test func 기다리는_중_Mac을_끄는_요청이_오면_취소하지_않고_미루는_방식으로_바꾼다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.controller.requestTermination(nested: true) == .terminateLater)
        #expect(w.model.isWaiting && w.replies.isEmpty && w.terminated == 0 && w.cancelledTerminations == 0)
        // 쓰기가 끝나면 다시 요청하지 않고 미룬 종료에 답한다
        w.activity = AppWriteActivity(rekordbox: .readingBack, writingUsb: false)
        w.controller.activityChanged()
        #expect(w.replies == [true] && w.terminated == 0)
    }

    @Test func 미룬_종료를_취소하면_Mac을_끄는_일도_멈춘다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        w.model.cancel()
        #expect(w.replies == [false] && w.cancelledTerminations == 1)
    }

    // MARK: - 미루지 않는 기본 방식(취소로 답하고 쓰기가 끝나면 다시 요청한다)

    /// `terminate:`가 메인 큐 블록 안에서 불리면 `terminateLater`로 미룬 AppKit의 안쪽 이벤트 순환이 메인 큐를 처리하지 못한다(자가 테스트에서 확인).
    /// 메인 액터의 쓰기가 끝나지 못해 영영 답하지 못하므로 기본은 미루지 않는다: 취소로 답하고 쓰기가 끝나면 앱이 다시 종료를 요청한다.
    @Test func 기본은_종료를_미루지_않고_취소로_답하면서_기다림을_보인다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.model.current == QuitWait(startedAt: w.now), "기다림 카드는 똑같이 보인다")
        #expect(w.replies.isEmpty && w.informed.isEmpty)
    }

    @Test func 미루지_않은_종료는_쓰기가_끝나면_답하지_않고_다시_종료를_요청한다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination()
        w.activity = AppWriteActivity(rekordbox: .readingBack, writingUsb: false)
        w.controller.activityChanged()
        w.controller.activityChanged()
        #expect(w.replies.isEmpty && w.terminated == 1 && w.model.current == nil)
        #expect(w.order == ["flush", "terminate"], "초안 저장 큐를 비운 뒤 다시 요청한다: \(w.order)")
    }

    @Test func 미루지_않은_종료도_종료_취소를_누르면_다시_요청하지_않는다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination()
        w.model.cancel()
        #expect(w.replies.isEmpty && w.terminated == 0 && w.model.current == nil && w.cancelled == 0)
        w.activity = .idle
        w.controller.activityChanged()
        #expect(w.terminated == 0)
    }

    @Test func 미루지_않은_종료를_한_번_더_요청하면_종료만_취소한다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination()
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.model.current == nil && w.replies.isEmpty && w.terminated == 0)
    }

    @Test func 미루지_않은_종료도_복원까지_실패해_확인이_필요해지면_다시_요청하지_않는다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination()
        w.activity = AppWriteActivity(rekordbox: .acknowledging, writingUsb: false)
        w.controller.activityChanged()
        #expect(w.terminated == 0 && w.replies.isEmpty && w.raised == 1 && w.model.current == nil)
    }

    // MARK: - 실제 저장소와 관찰

    /// 실제 저장소의 쓰기 상태를 관찰해 기다림이 끝나는지(관찰을 다시 걸어 가며 한 번만 답한다). 미루는 방식은 Mac을 끄는 중일 때다.
    @Test func 저장소의_쓰기_상태가_바뀌면_스스로_알아채고_종료한다() async {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.replyToTermination = { replies.append($0) }
        delegate.store = store
        store.isPoweringOff = true
        store.setWriteLock(true)
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(store.quitWait.current != nil)
        // 중간 단계 변화로는 답하지 않는다
        store.writeStage = WriteStage("rekordbox에 쓰는 중…", completed: 1, total: 2)
        await drainMainActor()
        #expect(replies.isEmpty)
        // 쓴 뒤 다시 읽기에 들어서면 종료한다
        store.writeStage = .reloadingLibrary
        #expect(await waitForState { replies == [true] })
        #expect(store.quitWait.current == nil)
    }

    @Test func 저장소의_쓰기_잠금이_풀려도_종료한다() async {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.replyToTermination = { replies.append($0) }
        delegate.store = store
        store.isPoweringOff = true
        store.setWriteLock(true)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        store.setWriteLock(false)
        #expect(await waitForState { replies == [true] })
    }

    /// 기본 방식에서는 저장소를 지켜보다 쓰기가 끝나면 앱이 스스로 다시 종료를 요청한다.
    @Test func 저장소의_쓰기가_끝나면_미루지_않은_종료를_다시_요청한다() async {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let delegate = AppDelegate()
        var replies: [Bool] = []
        var terminations = 0
        delegate.replyToTermination = { replies.append($0) }
        delegate.terminateApp = { terminations += 1 }
                delegate.store = store
        store.setWriteLock(true)
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(store.quitWait.isWaiting)
        store.setWriteLock(false)
        store.writeStage = nil
        // 쓰기가 끝나면 카드를 거두고 종료를 다시 요청한다. 이미 취소로 답했으니 미룬 종료에 답하지는 않는다
        #expect(await waitForState { terminations == 1 })
        #expect(!store.quitWait.isWaiting && replies.isEmpty)
    }

    /// 로그아웃이 시작된 뒤 앱이 종료를 취소로 끝내면(USB에 쓰는 중) 그 일이 멈췄으니 쓰기를 다시 연다. 취소된 로그아웃은 알림이 없다.
    @Test func 종료를_취소로_끝내면_Mac을_끄는_중_표시를_푼다() throws {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let volume = FakeUsbVolume.diskImageFAT32(name: "B1", uuid: "00000000-0000-0000-0000-0000000000B1")
        let usb = UsbTestData.store(FakeUsbHost([volume]))
        store.usb = usb
        let delegate = AppDelegate()
        delegate.inform = { _ in }
        delegate.store = store
        store.isPoweringOff = true
        _ = try #require(usb.beginWrite(volume, title: "합성 쓰기"))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(!store.isPoweringOff)
    }

    /// 창을 닫았다 열면 같은 저장소를 다시 알려 온다. 기다리는 중인 컨트롤러가 바뀌면 [종료 취소]가 끊긴다.
    @Test func 같은_저장소를_다시_알려도_기다리는_중인_종료를_이어_간다() {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.replyToTermination = { replies.append($0) }
        delegate.store = store
        store.isPoweringOff = true
        store.setWriteLock(true)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        delegate.store = store
        store.quitWait.cancel()
        #expect(replies == [false] && !store.quitWait.isWaiting)
    }
}
