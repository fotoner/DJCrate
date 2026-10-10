@testable import DJCrate
import Foundation
import Testing

/// 알림이 저절로 닫히는 시각(#244에서 뷰의 `.task`에서 옮겼다). 시간은 기다리지 않고 틱 수로 본다.
@MainActor
@Suite("알림 자동 닫기")
struct AppToastTimerTests {
    /// 틱(0.25초)마다 부르는 잠: 기다리지 않고 센다
    final class Ticks {
        var count = 0
        var onTick: (Int) -> Void = { _ in }
    }

    func timer(_ ticks: Ticks, voiceOver: Bool = false) -> AppToastTimer {
        AppToastTimer(voiceOver: { voiceOver }, sleep: { _ in
            ticks.count += 1
            ticks.onTick(ticks.count)
        })
    }

    @Test func 성공_알림은_정한_시간이_지나면_닫는다() async {
        let ticks = Ticks(), timer = timer(ticks)
        var closed = 0
        await timer.run(AppToast(title: "썼습니다"), close: { closed += 1 })
        // 3.5초 = 0.25초 × 14
        #expect(closed == 1 && ticks.count == 14)
    }

    @Test func 마우스를_올려_둔_동안은_시간을_세지_않는다() async {
        let ticks = Ticks(), timer = timer(ticks)
        timer.hovering = true
        ticks.onTick = { if $0 == 5 { timer.hovering = false } }
        var closed = false
        await timer.run(AppToast(title: "썼습니다"), close: { closed = true })
        #expect(closed && ticks.count == 4 + 14)
    }

    @Test func 경고와_VoiceOver에서는_저절로_닫지_않는다() async {
        let ticks = Ticks()
        var closed = false
        await timer(ticks).run(AppToast(kind: .warning, title: "확인하세요"), close: { closed = true })
        await timer(ticks, voiceOver: true).run(AppToast(title: "썼습니다"), close: { closed = true })
        #expect(!closed && ticks.count == 0)
    }

    @Test func 알림이_사라지거나_바뀌어_취소되면_닫지_않는다() async {
        let ticks = Ticks(), timer = timer(ticks)
        var closed = false
        let running = Task { await timer.run(AppToast(title: "썼습니다"), close: { closed = true }) }
        running.cancel()
        await running.value
        #expect(!closed && ticks.count == 1)
    }
}
