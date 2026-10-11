import Foundation
import Testing

/// 시험이 시간이 아니라 상태로 판정하게 하는 기다리기 도우미(#154).
/// 이 시험도 걸린 시간으로 판정하지 않는다. 기다림이 언제 끝났는지는 조건을 몇 번 봤는지로 확인한다.
@MainActor
@Suite("상태 기다리기")
struct StateWaitingTests {
    @Test func 조건이_이미_참이면_바로_참을_돌려준다() async {
        var checks = 0
        #expect(await waitForState(until: { checks += 1; return true }))
        #expect(checks == 1)
    }

    @Test func 조건이_나중에_참이_되면_기다렸다가_참을_돌려준다() async {
        var checks = 0
        #expect(await waitForState(until: { checks += 1; return checks == 5 }))
        #expect(checks == 5)
    }

    /// 더 기다려도 참이 될 수 없다고 드러나면 안전망 시간을 다 쓰지 않고 거짓으로 돌아온다.
    /// 포기 조건을 무시하고 계속 기다리는 구현은 조건을 더 보게 되므로 `runaway`로 끊어 시험이 멈추지 않게 한다.
    @Test func 포기_조건이_참이면_안전망을_기다리지_않고_거짓을_돌려준다() async {
        var checks = 0
        var runaway = false
        let result = await waitForState(giveUp: { true }, until: {
            checks += 1
            if checks > 2 { runaway = true; return true }
            return false
        })
        #expect(!runaway)
        #expect(!result)
        #expect(checks == 2, "기다리기 전 한 번, 돌려주기 전 한 번")
    }

    @Test func 포기_조건이_기다리는_중에_참이_되면_그때_거짓을_돌려준다() async {
        var checks = 0
        var gaveUp = false
        var runaway = false
        let result = await waitForState(giveUp: { gaveUp }, until: {
            checks += 1
            if checks == 5 { gaveUp = true }
            if checks > 6 { runaway = true; return true }
            return false
        })
        #expect(!runaway)
        #expect(!result)
        #expect(checks == 6, "포기 조건이 참이 된 다음 한 번만 더 본다")
    }

    /// "일어나지 않음"을 보기 전에 메인 액터에 이미 쌓인 일(이어 띄운 일까지)을 돌린다.
    @Test func 메인_액터에_쌓인_일을_돌린_뒤_돌아온다() async {
        @MainActor final class Steps { var all: [Int] = [] }
        let steps = Steps()
        Task { @MainActor in
            steps.all.append(1)
            Task { @MainActor in steps.all.append(2) }
        }
        #expect(steps.all.isEmpty)
        await drainMainActor()
        #expect(steps.all == [1, 2])
    }

    /// 판정이 영영 오지 않는 잘못된 구현에서도 시험이 멈춰 있지 않게 안전망 시간이 지나면 거짓을 돌려준다.
    @Test func 안전망_시간이_지나면_거짓을_돌려준다() async {
        #expect(!(await waitForState(safetyNet: .milliseconds(100), until: { false })))
    }
}
