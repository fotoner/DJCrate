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
        /// 켜진 채 종료 시트(#326): 감지 값과 쓰기 대기 수는 시험이 정하고, 시트는 띄운 내용만 남긴다(답은 시험이 준다)
        var run: RekordboxRunState?
        var pendingCount = PendingWriteCount(items: 0, playlistEdits: 0)
        var presented: [QuitConfirmation] = []
        var answers: [@MainActor (Bool) -> Void] = []
        /// 종료를 다시 요청할 때 컨트롤러가 준 답(실제 앱은 `terminate:`가 `applicationShouldTerminate`를 바로 부른다)
        var reentrantReplies: [NSApplication.TerminateReply] = []
        var terminateReenters = false
        /// 답하는 순간 초안 저장이 먼저 비워졌는지 보려고 남기는 순서
        var order: [String] = []
        /// 자동 저장 엔진이 아직 디스크에 남기지 못한 기록 저장(사용자가 취소한 판). 시험이 끝낸다
        var pendingRecord: Task<Void, Never>?
        var finishRecord: (() -> Void)?
        /// 자동 저장 엔진(R17): 자동 저장하는 실행인지·자동 저장이 쓰는 중인지는 시험이 정하고, ⌘Q 저장은 부른 순서와 답을 남긴다
        var autoSaves = false
        var autoWriting = false
        var prepareCalls = 0
        var cancelledPrepares = 0
        var shutdowns: [Bool] = []
        /// 시험이 답할 때까지 끝나지 않는 엔진의 ⌘Q 저장
        var preparing: CheckedContinuation<QuitPreparation, Never>?
        /// 켜면 입력 확정을 시험이 풀 때까지 붙잡는다(`commitHold`)
        var holdsCommit = false
        var commitHold: CheckedContinuation<Void, Never>?
        let model = QuitWaitModel()

        lazy var link = QuitAutoSaveLink(
            autoSaves: { [unowned self] in autoSaves },
            autoWriting: { [unowned self] in autoWriting },
            commitInput: { [unowned self] in
                order.append("commit")
                if holdsCommit { await withCheckedContinuation { commitHold = $0 } }
            },
            prepare: { [unowned self] in
                prepareCalls += 1
                order.append("prepare")
                return await withCheckedContinuation { preparing = $0 }
            },
            cancel: { [unowned self] in
                cancelledPrepares += 1
                preparing?.resume(returning: .cancelled)
                preparing = nil
            },
            shutdown: { [unowned self] in shutdowns.append($0) })

        /// 엔진의 ⌘Q 저장이 시작될 때까지 기다린 뒤 답한다
        func answerPrepare(_ result: QuitPreparation) async {
            for _ in 0..<2000 where preparing == nil { await Task.yield() }
            preparing?.resume(returning: result)
            preparing = nil
        }

        /// 끝내 주기 전까지 끝나지 않는 기록 저장을 건다
        func holdRecordSave() {
            pendingRecord = Task { @MainActor [unowned self] in
                await withCheckedContinuation { continuation in
                    finishRecord = { [unowned self] in
                        pendingRecord = nil
                        continuation.resume()
                    }
                }
            }
        }

        lazy var controller: AppQuitController = AppQuitController(
            model: model, activity: { [unowned self] in activity },
            cancelPreparation: { [unowned self] in cancelled += 1; order.append("cancel") },
            flushDrafts: { [unowned self] in flushed += 1; order.append("flush") },
            reply: { [unowned self] in replies.append($0); order.append("reply \($0)") },
            terminate: { [unowned self] in
                terminated += 1
                order.append("terminate")
                if terminateReenters { reentrantReplies.append(controller.requestTermination()) }
            },
            inform: { [unowned self] in informed.append($0) },
            terminationCancelled: { [unowned self] in cancelledTerminations += 1 },
            bringForward: { [unowned self] in raised += 1 },
            runState: { [unowned self] in run }, pending: { [unowned self] in pendingCount },
            present: { [unowned self] confirmation, answer in presented.append(confirmation); answers.append(answer) },
            now: { [unowned self] in now }, pendingRecordSave: { [unowned self] in pendingRecord },
            autoSave: link)
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

    // MARK: - 자동 저장 엔진의 기록 저장(#404 5라운드, S15)

    @Test func 취소한_자동_저장의_기록을_저장하는_중이면_저장이_끝난_뒤_끈다() async {
        // 사용자가 자동 저장을 [취소]한 기록이 디스크에 닿기 전에 끄면, 다시 켠 뒤 같은 판을 자동으로 쓴다
        w.activity = AppWriteActivity(rekordbox: .cancellable, writingUsb: false)
        w.holdRecordSave()
        w.terminateReenters = true
        #expect(w.controller.requestTermination() == .terminateCancel, "기록 저장이 끝나기 전에는 끄지 않는다")
        #expect(w.terminated == 0 && w.cancelled == 1)
        await Task.yield()
        #expect(w.terminated == 0)
        w.finishRecord?()
        #expect(await waitForState(safetyNet: .seconds(90)) { w.terminated == 1 }, "저장이 끝난 뒤 종료를 다시 요청한다")
        w.activity = .idle
        #expect(w.reentrantReplies == [.terminateNow], "다시 요청한 종료는 바로 끈다")
    }

    @Test func 미루는_방식도_기록_저장이_끝난_뒤_종료한다() async {
        w.activity = AppWriteActivity(rekordbox: .idle, writingUsb: false)
        w.holdRecordSave()
        #expect(w.controller.requestTermination(nested: true) == .terminateLater)
        await Task.yield()
        #expect(w.replies.isEmpty, "저장이 끝나기 전에는 답하지 않는다")
        w.finishRecord?()
        #expect(await waitForState(safetyNet: .seconds(90)) { w.replies == [true] })
    }

    @Test func 저장_중인_기록이_없으면_기다리지_않고_바로_끈다() {
        w.activity = AppWriteActivity(rekordbox: .idle, writingUsb: false)
        #expect(w.pendingRecord == nil)
        #expect(w.controller.requestTermination() == .terminateNow)
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

    /// 종료를 기다리는 중 쓴 뒤 다시 읽기를 미룬 길(#305)은 다시 읽는 단계를 거치지 않는다. 쓰기가 끝났다는 알림이 올 때 잠금은 이미 풀려 단계가 `idle`이다.
    /// 그래도 기다린 것은 쓰기였으니 종료 전에 쓴 초안 정리가 걸린 저장 큐를 비워야 한다.
    @Test func 다시_읽기_단계를_거치지_않고_쓰기가_끝나도_초안_저장을_비운_뒤_종료로_답한다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true)
        w.activity = .idle
        w.controller.activityChanged()
        w.controller.activityChanged()
        #expect(w.replies == [true] && w.model.current == nil)
        #expect(w.order == ["flush", "reply true"], "초안 저장 큐를 비운 뒤에 답한다: \(w.order)")
    }

    @Test func 미루지_않은_종료도_다시_읽기_단계_없이_쓰기가_끝나면_초안_저장을_비운_뒤_다시_요청한다() {
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination()
        w.activity = .idle
        w.controller.activityChanged()
        #expect(w.replies.isEmpty && w.terminated == 1 && w.model.current == nil)
        #expect(w.order == ["flush", "terminate"], "초안 저장 큐를 비운 뒤 다시 요청한다: \(w.order)")
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

    // MARK: - ⌘Q 때 대기 중인 대상 편집을 저장하고 끈다(R17)

    @Test func 끄기_전에는_쓰기_여부와_상관없이_초안_저장_큐를_비운다() {
        // 편집 직후에는 초안 저장 큐에 쓰지 않은 편집이 있을 수 있다(쓰기를 하지 않았어도 비운다)
        #expect(w.controller.requestTermination(nested: true) == .terminateNow)
        #expect(w.flushed == 1)
        w.activity = AppWriteActivity(rekordbox: .cancellable, writingUsb: false)
        #expect(w.controller.requestTermination(nested: true) == .terminateNow)
        #expect(w.flushed == 2)
    }

    @Test func 사용자_종료는_입력_칸을_확정하고_초안_저장_큐를_비운_뒤_엔진의_종료_저장을_기다린다() async {
        w.autoSaves = true
        w.terminateReenters = true
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.model.isWaiting && w.model.allowsAutoSave && w.terminated == 0)
        await w.answerPrepare(.finished(run: .stopped))
        #expect(await waitForState(safetyNet: .seconds(90)) { w.terminated == 1 })
        #expect(Array(w.order.prefix(3)) == ["commit", "flush", "prepare"], "\(w.order)")
        #expect(w.reentrantReplies == [.terminateNow], "저장을 마친 뒤 다시 한 요청은 다시 저장하지 않고 끈다")
        #expect(w.prepareCalls == 1 && !w.model.isWaiting)
    }

    @Test func 엔진이_쓰지_못한_편집은_초안으로_남기고_끈다() async {
        w.autoSaves = true
        w.terminateReenters = true
        _ = w.controller.requestTermination()
        await w.answerPrepare(.unwritten(nil))
        #expect(await waitForState(safetyNet: .seconds(90)) { w.terminated == 1 })
        #expect(w.reentrantReplies == [.terminateNow] && w.presented.isEmpty)
    }

    /// 기다리는 동안 rekordboxAgent가 켜진 것을 엔진이 먼저 봤다: 감시 모델이 아직 꺼짐이어도 엔진이 본 상태로 시트를 띄운다(S6)
    @Test func 엔진이_켜짐을_보고_돌려주면_그_실행_상태로_종료_시트를_띄운다() async {
        w.autoSaves = true
        w.terminateReenters = true
        w.run = .stopped
        w.pendingCount = PendingWriteCount(items: 2, playlistEdits: 0)
        _ = w.controller.requestTermination()
        await w.answerPrepare(.unwritten(.agentRunning))
        #expect(await waitForState(safetyNet: .seconds(90)) { w.presented.count == 1 })
        #expect(w.presented.first?.running == .agentOnly && w.reentrantReplies == [.terminateCancel])
    }

    @Test func 자동_저장하지_않는_실행은_엔진을_기다리지_않고_바로_끈다() {
        #expect(w.controller.requestTermination() == .terminateNow)
        #expect(w.prepareCalls == 0 && w.flushed == 1 && !w.model.isWaiting)
    }

    @Test func 자동_저장의_미리_보기는_취소하지_않고_끝까지_기다린_뒤_종료_저장을_한다() async {
        w.autoSaves = true
        w.autoWriting = true
        w.activity = AppWriteActivity(rekordbox: .cancellable, writingUsb: false)
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.cancelled == 0 && w.prepareCalls == 0 && w.model.isWaiting)
        w.autoWriting = false
        w.activity = .idle
        w.controller.activityChanged()
        await w.answerPrepare(.finished(run: .stopped))
        #expect(await waitForState(safetyNet: .seconds(90)) { w.terminated == 1 })
        #expect(w.cancelled == 0 && w.prepareCalls == 1)
    }

    @Test func 수동_저장의_미리_보기는_취소하고_대기_중인_자동_저장을_한다() async {
        w.autoSaves = true
        w.activity = AppWriteActivity(rekordbox: .cancellable, writingUsb: false)
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.cancelled == 1)
        w.activity = .idle
        await w.answerPrepare(.finished(run: .stopped))
        #expect(await waitForState(safetyNet: .seconds(90)) { w.terminated == 1 })
        #expect(w.prepareCalls == 1)
    }

    @Test func 종료_취소는_엔진의_종료_대기를_풀고_다시_요청하지_않는다() async {
        w.autoSaves = true
        _ = w.controller.requestTermination()
        for _ in 0..<2000 where w.preparing == nil { await Task.yield() }
        w.model.cancel()
        #expect(w.cancelledPrepares == 1 && !w.model.isWaiting && w.cancelledTerminations == 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(w.terminated == 0)
        // 두 번째 ⌘Q도 같다
        _ = w.controller.requestTermination()
        for _ in 0..<2000 where w.preparing == nil { await Task.yield() }
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.cancelledPrepares == 2 && !w.model.isWaiting && w.terminated == 0)
    }

    // MARK: - 종료 저장 준비의 세대 표식(컨실 2라운드 D)

    /// 입력 확정을 기다리는 사이 [종료 취소]를 누르면 그 요청은 엔진에 넘기지 않는다(엔진이 T_edit를 건너뛴 종료 대기에 들지 않게)
    @Test func 입력_확정_중에_종료를_취소하면_엔진의_종료_저장을_부르지_않는다() async {
        w.autoSaves = true
        w.holdsCommit = true
        _ = w.controller.requestTermination()
        #expect(await waitForState(safetyNet: .seconds(90)) { w.commitHold != nil })
        w.model.cancel()
        w.commitHold?.resume()
        w.commitHold = nil
        for _ in 0..<50 { await Task.yield() }
        #expect(w.prepareCalls == 0 && w.terminated == 0 && !w.model.isWaiting)
    }

    /// 첫 대기를 취소한 직후(옛 저장 준비가 아직 돌아오기 전) 다시 ⌘Q를 누르면 새 요청이 저장한 뒤 끈다. 옛 결과(취소)로 끄지 않는다
    @Test func 대기를_취소하고_곧바로_다시_종료하면_새_요청이_저장한_뒤_끈다() async {
        w.autoSaves = true
        w.terminateReenters = true
        _ = w.controller.requestTermination()
        for _ in 0..<2000 where w.preparing == nil { await Task.yield() }
        w.model.cancel()
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.model.isWaiting)
        #expect(await waitForState(safetyNet: .seconds(90)) { w.prepareCalls == 2 || w.terminated > 0 })
        for _ in 0..<20 { await Task.yield() }
        #expect(w.prepareCalls == 2 && w.terminated == 0, "옛 결과로 끄지 않고 새 요청이 엔진의 종료 저장을 기다린다")
        await w.answerPrepare(.finished(run: .stopped))
        #expect(await waitForState(safetyNet: .seconds(90)) { w.terminated == 1 })
        #expect(w.reentrantReplies == [.terminateNow])
    }

    /// 확인할 경고창·USB 쓰기로 종료를 취소하면 엔진의 종료 대기도 푼다
    @Test(arguments: [false, true])
    func 경고창이나_USB_거절로_종료를_취소하면_엔진의_종료_대기를_푼다(_ usb: Bool) async {
        w.autoSaves = true
        _ = w.controller.requestTermination()
        for _ in 0..<2000 where w.preparing == nil { await Task.yield() }
        w.activity = usb ? AppWriteActivity(rekordbox: .idle, writingUsb: true) : AppWriteActivity(rekordbox: .acknowledging, writingUsb: false)
        w.controller.activityChanged()
        #expect(!w.model.isWaiting && w.cancelledPrepares == 1 && w.terminated == 0)
    }

    // MARK: - 저장 대기 중 바뀐 종료 사유(컨실 2라운드 G·H·G14·J)

    /// ⌘Q 저장을 기다리는 중 업데이트 다시 켜기가 오면 대기를 마치고 다시 한 요청은 시트 없이 끈다(업데이트를 시트가 막지 않는다)
    @Test func 저장_대기_중_업데이트_다시_켜기가_오면_다시_요청한_종료에서_시트를_띄우지_않는다() async {
        w.autoSaves = true
        w.terminateReenters = true
        w.pendingCount = PendingWriteCount(items: 2, playlistEdits: 0)
        w.run = .stopped
        _ = w.controller.requestTermination()
        for _ in 0..<2000 where w.preparing == nil { await Task.yield() }
        w.run = .running
        #expect(w.controller.requestTermination(cause: .updateRelaunch) == .terminateCancel)
        #expect(await waitForState(safetyNet: .seconds(90)) { w.terminated == 1 })
        #expect(w.presented.isEmpty && w.reentrantReplies == [.terminateNow], "\(w.reentrantReplies)")
    }

    /// 업데이트 다시 켜기로 새 자동 저장을 막았는데 그 종료가 취소돼 앱이 다시 활성화되면 다시 연다
    @Test func 막은_종료가_취소되고_앱이_다시_활성화되면_자동_저장을_다시_연다() {
        w.autoSaves = true
        #expect(w.controller.requestTermination(cause: .updateRelaunch) == .terminateNow)
        #expect(w.shutdowns == [true])
        w.controller.reopenAutoSaveAfterCancelledShutdown(poweringOffCancelled: false)
        #expect(w.shutdowns == [true, false])
        // 막은 것이 없으면 다시 열 것도 없다
        w.controller.reopenAutoSaveAfterCancelledShutdown(poweringOffCancelled: false)
        #expect(w.shutdowns == [true, false])
    }

    @Test func 종료를_기다리는_중에는_다시_활성화돼도_자동_저장을_다시_열지_않는다() {
        w.autoSaves = true
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination(nested: true, cause: .systemShutdown)
        #expect(w.model.isWaiting && w.shutdowns == [true])
        w.controller.reopenAutoSaveAfterCancelledShutdown(poweringOffCancelled: true)
        #expect(w.shutdowns == [true])
    }

    /// 알 수 없는 종료 사유는 사용자가 고른 종료가 아니다: 자동 저장을 기다리지 않는다(시트 판정과 같다)
    @Test func 알_수_없는_종료_사유는_자동_저장을_기다리지_않는다() {
        w.autoSaves = true
        #expect(w.controller.requestTermination(cause: .unknown) == .terminateNow)
        #expect(w.prepareCalls == 0 && !w.model.isWaiting && w.flushed == 1)
    }

    /// 대상 밖 편집만 남아 엔진이 다 썼다고 돌아와도 엔진이 본 실행 상태로 시트를 판정한다(감시 모델이 아직 꺼짐이어도)
    @Test func 엔진이_다_썼다고_돌아와도_엔진이_본_실행_상태로_종료_시트를_띄운다() async {
        w.autoSaves = true
        w.terminateReenters = true
        w.run = .stopped
        w.pendingCount = PendingWriteCount(items: 1, playlistEdits: 0)
        _ = w.controller.requestTermination()
        await w.answerPrepare(.finished(run: .agentOnly))
        #expect(await waitForState(safetyNet: .seconds(90)) { w.terminated == 1 })
        #expect(w.presented.first?.running == .agentOnly && w.reentrantReplies == [.terminateCancel])
    }

    /// 엔진이 꺼짐·모름을 봤으면 시트는 지금처럼 감시 모델로 판정한다: 엔진이 본 뒤 rekordbox가 켜졌으면 시트를 띄운다(컨실 3라운드 Q)
    @Test(arguments: [RekordboxRunState.stopped, .unknown])
    func 엔진이_꺼짐이나_모름을_봤으면_감시_모델로_시트를_판정한다(_ seen: RekordboxRunState) async {
        w.autoSaves = true
        w.terminateReenters = true
        w.run = .stopped
        w.pendingCount = PendingWriteCount(items: 1, playlistEdits: 0)
        _ = w.controller.requestTermination()
        for _ in 0..<2000 where w.preparing == nil { await Task.yield() }
        w.run = .running
        await w.answerPrepare(.finished(run: seen))
        #expect(await waitForState(safetyNet: .seconds(90)) { w.terminated == 1 })
        #expect(w.presented.first?.running == .rekordbox && w.reentrantReplies == [.terminateCancel])
    }

    /// 업데이트 다시 켜기·알 수 없는 사유로 처음 시작한 미루는 대기도 쓰기가 끝나 다시 한 요청은 시트 없이 끈다(컨실 3라운드 T)
    @Test(arguments: [AppQuitCause.updateRelaunch, .unknown])
    func 사용자가_고르지_않은_종료로_시작한_대기는_다시_요청할_때_시트를_띄우지_않는다(_ cause: AppQuitCause) async {
        w.autoSaves = true
        w.terminateReenters = true
        w.run = .running
        w.pendingCount = PendingWriteCount(items: 2, playlistEdits: 0)
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        #expect(w.controller.requestTermination(cause: cause) == .terminateCancel)
        #expect(w.model.isWaiting && w.presented.isEmpty)
        w.activity = .idle
        w.controller.activityChanged()
        #expect(await waitForState(safetyNet: .seconds(90)) { w.terminated == 1 })
        #expect(w.presented.isEmpty && w.reentrantReplies == [.terminateNow], "\(w.reentrantReplies)")
    }

    /// 로그아웃·재시작·전원 끔(알림 앞이든 뒤든)과 업데이트 다시 켜기는 새 자동 저장을 기다리지 않고 막는다
    @Test(arguments: [(true, AppQuitCause.systemShutdown), (false, .systemShutdown), (false, .updateRelaunch)])
    func 시스템_종료와_업데이트는_자동_저장을_기다리지_않고_새_쓰기를_막는다(_ nested: Bool, _ cause: AppQuitCause) {
        w.autoSaves = true
        #expect(w.controller.requestTermination(nested: nested, cause: cause) == .terminateNow)
        #expect(w.prepareCalls == 0 && w.shutdowns == [true] && w.flushed == 1)
    }

    @Test func 시스템_종료가_취소되면_자동_저장을_다시_연다() {
        w.autoSaves = true
        w.activity = AppWriteActivity(rekordbox: .idle, writingUsb: true)
        _ = w.controller.requestTermination(nested: true, cause: .systemShutdown)
        #expect(w.shutdowns == [true, false] && w.cancelledTerminations == 1)
    }

    /// ⌘Q 저장을 기다리는 중 로그아웃이 오면 엔진의 종료 저장을 풀고 새 쓰기를 막은 뒤 곧바로 다시 판정한다(미리 보기는 취소한다)
    @Test func 저장_대기_중_로그아웃이_오면_새_자동_저장을_막고_곧바로_다시_판정한다() async {
        w.autoSaves = true
        _ = w.controller.requestTermination()
        for _ in 0..<2000 where w.preparing == nil { await Task.yield() }
        // 엔진의 자동 저장이 미리 보기 중이다
        w.activity = AppWriteActivity(rekordbox: .cancellable, writingUsb: false)
        w.autoWriting = true
        #expect(w.controller.requestTermination(nested: true, cause: .systemShutdown) == .terminateLater)
        #expect(w.cancelledPrepares == 1 && w.shutdowns == [true] && !w.model.allowsAutoSave)
        #expect(await waitForState(safetyNet: .seconds(90)) { w.replies == [true] })
        #expect(w.cancelled == 1, "아직 아무것도 쓰지 않은 미리 보기는 취소하고 끈다")
    }

    /// 취소 기록 저장을 기다리는 동안 다시 누른 ⌘Q는 종료를 하나 더 만들지 않고 기다림을 취소한다(#404 S18)
    @Test func 기록_저장을_기다리는_중_두_번째_종료는_기다림을_취소하고_다시_요청하지_않는다() async {
        w.holdRecordSave()
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.model.isWaiting, "기록 저장 대기도 종료 대기 상태다")
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(!w.model.isWaiting && w.cancelledTerminations == 1)
        // 기록 저장 작업이 시작해 끝낼 손잡이를 건 뒤에 끝낸다
        #expect(await waitForState(safetyNet: .seconds(90)) { w.finishRecord != nil })
        let saving = w.pendingRecord
        w.finishRecord?()
        await saving?.value
        for _ in 0..<5 { await Task.yield() }
        #expect(w.terminated == 0, "취소한 종료를 기록 저장 뒤에 다시 요청하지 않는다")
    }

    /// 종료 대기 동안 수동 입구(⌘S·복원·곡 넣기)는 지금처럼 거절하고, 종료가 기다리는 엔진 쓰기만 세션 잠금에서 연다(C)
    @Test func 종료_저장을_기다리는_동안_수동_입구는_거절하고_세션_잠금만_연다() {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let session = AppComposition.reflection(store: store, gate: .restoringOnly).session
        store.quitWait.begin(at: Date(), onCancel: {})
        #expect(store.writeRefusal != nil && session.ports.lock.isLocked())
        store.quitWait.finish()
        store.quitWait.begin(at: Date(), allowsAutoSave: true, onCancel: {})
        #expect(store.writeRefusal != nil, "수동 입구는 종료 대기 중 거절한다")
        #expect(!session.ports.lock.isLocked(), "종료가 기다리는 자동 저장은 세션 잠금을 지난다")
        store.quitWait.finish()
    }

    // MARK: - 켜진 채 종료 시트(#326)

    /// 켜져 있고 쓰기 대기가 있는 상태. 시트 판정표는 DJCDomainTests `QuitConfirmationTests`가 보고, 여기서는 시트가 흐름에 붙는 모습을 본다.
    private func runningWithPending(_ run: RekordboxRunState = .running) {
        w.run = run
        w.pendingCount = PendingWriteCount(items: 3, playlistEdits: 0)
    }

    @Test func 켜진_채_쓰기_대기가_있으면_종료를_취소로_답하고_시트를_띄운다() {
        runningWithPending()
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.presented == [QuitConfirmation(running: .rekordbox, pending: PendingWriteCount(items: 3, playlistEdits: 0))])
        // 아직 끄지 않았고 기다림도 만들지 않았다. 확인할 창이 뒤에 있을 수 있어 앞으로 가져온다
        #expect(w.terminated == 0 && w.replies.isEmpty && w.model.current == nil && w.raised == 1)
    }

    @Test func rekordboxAgent만_켜져_있어도_시트를_띄운다() {
        runningWithPending(.agentOnly)
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.presented.map(\.running) == [.agentOnly])
    }

    @Test func 그냥_종료를_누르면_다시_종료를_요청하고_그_요청은_묻지_않고_끈다() {
        runningWithPending()
        w.terminateReenters = true
        _ = w.controller.requestTermination()
        w.answers[0](true)
        #expect(w.terminated == 1)
        #expect(w.reentrantReplies == [.terminateNow], "다시 한 요청은 묻지 않고 끈다: \(w.reentrantReplies)")
        #expect(w.presented.count == 1 && w.cancelledTerminations == 0)
    }

    /// [그냥 종료]는 다음 종료 요청 한 번만 건너뛴다. 종료가 이어지지 않았으면(그 사이 다시 켜졌다 등) 다음 종료는 다시 묻는다
    @Test func 그냥_종료는_다음_요청_한_번만_건너뛴다() {
        runningWithPending()
        _ = w.controller.requestTermination()
        w.answers[0](true)
        #expect(w.terminated == 1)
        // 종료가 실제로 이어지지 않았다면 다음 종료 요청은 다시 묻는다
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.presented.count == 2)
    }

    @Test func 취소를_누르면_종료하지_않고_다음_종료에서_다시_묻는다() {
        runningWithPending()
        _ = w.controller.requestTermination()
        w.answers[0](false)
        #expect(w.terminated == 0 && w.replies.isEmpty && w.cancelledTerminations == 1)
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.presented.count == 2)
    }

    @Test func 시트가_떠_있는_동안_다시_종료를_요청해도_시트를_더_띄우지_않는다() {
        runningWithPending()
        _ = w.controller.requestTermination()
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.presented.count == 1)
        // 하나를 닫은 뒤에는 다시 물을 수 있다
        w.answers[0](false)
        _ = w.controller.requestTermination()
        #expect(w.presented.count == 2)
    }

    /// 시트가 열린 채 사용자가 rekordbox를 끄러 갔다가 로그아웃하거나 업데이트가 다시 켜려 할 수 있다. 그 종료를 취소로 답하면 그 일이 통째로 멈춘다(리뷰 지적)
    @Test func 시트가_떠_있어도_시스템_종료와_업데이트_다시_켜기는_취소로_답하지_않는다() {
        runningWithPending()
        _ = w.controller.requestTermination()
        #expect(w.presented.count == 1)
        #expect(w.controller.requestTermination(nested: true, cause: .systemShutdown) == .terminateNow, "Mac을 끄는 중")
        #expect(w.controller.requestTermination(cause: .systemShutdown) == .terminateNow, "종료 이유가 로그아웃·재시작·전원 끔")
        #expect(w.controller.requestTermination(cause: .updateRelaunch) == .terminateNow, "업데이트 다시 켜기")
        #expect(w.controller.requestTermination(cause: .unknown) == .terminateNow, "이유를 알 수 없는 종료")
        #expect(w.presented.count == 1, "시트를 더 띄우지 않는다")
        // 사용자가 고른 종료는 시트가 떠 있는 동안 계속 취소로만 답한다
        #expect(w.controller.requestTermination() == .terminateCancel)
    }

    @Test func 쓰기_대기가_없거나_꺼져_있거나_모르면_묻지_않고_바로_끈다() {
        w.run = .running
        #expect(w.controller.requestTermination() == .terminateNow, "대기 없음")
        runningWithPending(.stopped)
        #expect(w.controller.requestTermination() == .terminateNow, "꺼짐")
        w.run = .unknown
        #expect(w.controller.requestTermination() == .terminateNow, "모름")
        w.run = nil
        #expect(w.controller.requestTermination() == .terminateNow, "읽기 전")
        #expect(w.presented.isEmpty)
    }

    @Test(arguments: [AppQuitCause.systemShutdown, .updateRelaunch, .unknown])
    func 로그아웃_재시작_업데이트_모르는_이유의_종료는_묻지_않고_끈다(_ cause: AppQuitCause) {
        runningWithPending()
        #expect(w.controller.requestTermination(cause: cause) == .terminateNow)
        #expect(w.presented.isEmpty)
    }

    /// 미루는 방식(`nested`)은 시스템이 Mac을 끄는 중일 때다. 이유를 잘못 알려 와도 이 방식으로 온 종료는 묻지 않는다
    @Test func Mac을_끄는_중인_종료는_이유와_상관없이_묻지_않는다() {
        runningWithPending()
        #expect(w.controller.requestTermination(nested: true, cause: .user) == .terminateNow)
        #expect(w.presented.isEmpty)
    }

    /// 쓰는 중이면 시트보다 종료 대기(#300)가 앞선다
    @Test func 쓰는_중이면_시트_없이_종료_대기를_따른다() {
        runningWithPending()
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.presented.isEmpty && w.model.isWaiting)
        // 쓰기가 끝나 대기가 없어지면 묻지 않고 다시 요청해 끈다
        w.pendingCount = PendingWriteCount(items: 0, playlistEdits: 0)
        w.activity = AppWriteActivity(rekordbox: .readingBack, writingUsb: false)
        w.controller.activityChanged()
        #expect(w.terminated == 1 && w.presented.isEmpty)
    }

    @Test func USB에_쓰는_중이면_시트_없이_기존_거절을_따른다() {
        runningWithPending()
        w.activity = AppWriteActivity(rekordbox: .idle, writingUsb: true)
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.presented.isEmpty && w.informed.count == 1)
    }

    @Test func 종료를_기다리는_중_다시_요청하면_시트가_아니라_종료_취소다() {
        runningWithPending()
        w.activity = AppWriteActivity(rekordbox: .writing, writingUsb: false)
        _ = w.controller.requestTermination()
        w.activity = .idle
        #expect(w.controller.requestTermination() == .terminateCancel)
        #expect(w.presented.isEmpty && !w.model.isWaiting)
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
        store.writeStage = WriteStage("rekordbox에 저장하는 중…")
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(store.quitWait.current != nil)
        // 중간 단계 변화로는 답하지 않는다
        store.writeStage = WriteStage("rekordbox에 저장하는 중…", completed: 1, total: 2)
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
        store.writeStage = WriteStage("rekordbox에 저장하는 중…")
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

    /// 업데이트 다시 켜기로 엔진을 멈췄는데 그 종료가 취소돼 앱이 다시 활성화되면 엔진의 자동 저장을 다시 연다(컨실 2라운드 H)
    @Test func 업데이트로_막은_자동_저장은_종료가_취소돼_다시_활성화되면_다시_연다() {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let delegate = AppDelegate()
        var shutdowns: [Bool] = []
        delegate.quitAutoSave = QuitAutoSaveLink(autoSaves: { true }, shutdown: { shutdowns.append($0) })
        delegate.consumeUpdateRelaunch = { true }
        let center = NotificationCenter()
        delegate.observePowerOff(center: center, activation: center)
        delegate.store = store
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(shutdowns == [true])
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(shutdowns == [true, false])
    }

    /// Mac을 끄는 중 알림으로 엔진을 멈춘 뒤 기다리던 종료를 취소하면 Mac을 끄는 중 표시와 함께 엔진의 자동 저장도 다시 연다(컨실 3라운드 U)
    @Test func 전원_끔_알림으로_멈춘_자동_저장은_종료를_취소하면_다시_연다() {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let delegate = AppDelegate()
        var shutdowns: [Bool] = []
        delegate.quitAutoSave = QuitAutoSaveLink(autoSaves: { true }, shutdown: { shutdowns.append($0) })
        let center = NotificationCenter()
        delegate.observePowerOff(center: center, activation: center)
        delegate.store = store
        // ⌘Q가 쓰기를 기다리는 중 Mac을 끄는 중 알림이 왔다
        store.setWriteLock(true)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        center.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        #expect(shutdowns == [true] && store.isPoweringOff)
        store.quitWait.cancel()
        #expect(!store.isPoweringOff && shutdowns == [true, false], "\(shutdowns)")
        store.setWriteLock(false)
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

    // MARK: - 켜진 채 종료 시트와 실제 저장소(#326)

    /// 켜진 채 종료 시트의 가짜 주변을 건 델리게이트와 쓰기 대기 곡 하나가 있는 저장소
    @MainActor private final class SheetWorld {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let delegate = AppDelegate()
        var presented: [QuitConfirmation] = []
        var answers: [@MainActor (Bool) -> Void] = []
        var terminations = 0
        var terminateReplies: [NSApplication.TerminateReply] = []

        init(run: RekordboxRunState? = .running, reason: UInt32? = nil, updateRelaunch: Bool = false, pending: Bool = true) {
            delegate.rekordboxRunState = { run }
            delegate.quitReason = { reason }
            delegate.consumeUpdateRelaunch = { updateRelaunch }
            delegate.presentQuitConfirmation = { [unowned self] confirmation, answer in
                presented.append(confirmation)
                answers.append(answer)
            }
            delegate.terminateApp = { [unowned self] in
                terminations += 1
                terminateReplies.append(delegate.applicationShouldTerminate(NSApplication.shared))
            }
            delegate.store = store
            if pending {
                store.rowsByUUID["a"] = PendingCountCacheTests.track("a")
                store.setDraftMark(.cue, trackUUID: "a", exists: true)
            }
        }

        func quit() -> NSApplication.TerminateReply { delegate.applicationShouldTerminate(NSApplication.shared) }
    }

    @Test func 저장소에_쓰기_대기가_있고_rekordbox가_켜져_있으면_사용자_종료에_시트를_띄운다() {
        let world = SheetWorld()
        #expect(world.quit() == .terminateCancel)
        #expect(world.presented == [QuitConfirmation(running: .rekordbox, pending: PendingWriteCount(items: 1, playlistEdits: 0))],
                "시트의 수는 상태 줄 칩과 같다(\(world.store.pendingWriteCount))")
    }

    @Test func 시트에서_그냥_종료를_누르면_델리게이트가_종료를_다시_요청하고_그_요청은_끈다() {
        let world = SheetWorld()
        _ = world.quit()
        world.answers[0](true)
        #expect(world.terminations == 1 && world.terminateReplies == [.terminateNow])
        #expect(world.presented.count == 1)
    }

    @Test func 시트에서_취소를_누르면_종료하지_않는다() {
        let world = SheetWorld()
        _ = world.quit()
        world.answers[0](false)
        #expect(world.terminations == 0)
    }

    @Test func 쓰기_대기가_없거나_rekordbox가_꺼져_있거나_모르면_묻지_않는다() {
        #expect(SheetWorld(pending: false).quit() == .terminateNow)
        #expect(SheetWorld(run: .stopped).quit() == .terminateNow)
        #expect(SheetWorld(run: .unknown).quit() == .terminateNow)
        #expect(SheetWorld(run: nil).quit() == .terminateNow)
    }

    /// 로그아웃·재시작·전원 끔은 Apple 이벤트의 종료 이유(「why?」)나 Mac을 끄는 중이라는 알림으로 알아본다. 업데이트 다시 켜기는 업데이트 도구가 표시한다
    @Test func 로그아웃_재시작_전원_끔_업데이트_다시_켜기에서는_묻지_않는다() {
        for code in ["rlgo", "logo", "rest", "shut", "rrst", "rsdn"] {
            let world = SheetWorld(reason: AppQuitCause.fourCC(code))
            #expect(world.quit() == .terminateNow, "종료 이유 \(code)")
            #expect(world.presented.isEmpty)
        }
        let power = SheetWorld()
        power.store.isPoweringOff = true
        #expect(power.quit() == .terminateNow && power.presented.isEmpty, "Mac을 끄는 중")
        let update = SheetWorld(updateRelaunch: true)
        #expect(update.quit() == .terminateNow && update.presented.isEmpty, "업데이트 다시 켜기")
    }

    @Test func 일반_종료_이유_quia는_사용자_종료로_본다() {
        let world = SheetWorld(reason: AppQuitCause.fourCC("quia"))
        #expect(world.quit() == .terminateCancel)
        #expect(world.presented.count == 1)
    }

    @Test func 모르는_종료_이유는_묻지_않는다() {
        let world = SheetWorld(reason: AppQuitCause.fourCC("zzzz"))
        #expect(world.quit() == .terminateNow && world.presented.isEmpty)
    }

    /// 감지 서비스를 이어 주지 않은 델리게이트(시험·화면 시험의 조립)는 늘 모름이라 시트를 띄우지 않는다
    @Test func 감지를_이어_주지_않으면_묻지_않는다() {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let delegate = AppDelegate()
        delegate.presentQuitConfirmation = { _, _ in Issue.record("시트를 띄우면 안 된다") }
        delegate.store = store
        store.rowsByUUID["a"] = PendingCountCacheTests.track("a")
        store.setDraftMark(.cue, trackUUID: "a", exists: true)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    // MARK: - 경고창

    @Test func 시트는_취소가_기본_단추이고_그냥_종료가_두_번째다() {
        let alert = QuitConfirmationAlert.makeAlert(QuitConfirmation(running: .rekordbox, pending: PendingWriteCount(items: 2, playlistEdits: 0)))
        #expect(alert.messageText == "저장 대기가 남아 있습니다")
        #expect(alert.informativeText.hasPrefix("rekordbox가 켜져 있어 저장 대기 2건을"))
        #expect(alert.buttons.map(\.title) == ["취소", "그냥 종료"])
        #expect(QuitConfirmationAlert.isQuitAnyway(.alertSecondButtonReturn))
        #expect(!QuitConfirmationAlert.isQuitAnyway(.alertFirstButtonReturn))
    }
}
