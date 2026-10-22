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

    /// 0.25초 틱으로 센 수
    static func ticks(_ seconds: Double) -> Int { Int((seconds / 0.25).rounded(.up)) }

    // MARK: - 수명(#296)

    @Test func 성공과_경고는_4초에_글자마다_0점06초를_더한_시간_뒤_닫는다() {
        // 제목 5자
        #expect(AppToast(kind: .warning, title: "확인하세요").duration == 4 + 0.06 * 5)
        // 제목 4자 + 설명 6자
        #expect(AppToast(title: "썼습니다", detail: "곡 3개 씀").duration == 4 + 0.06 * 10)
        // 긴 경고는 길이만큼 오래 남는다(상한 없음)
        let long = AppToast(kind: .warning, title: String(repeating: "가", count: 20), detail: String(repeating: "나", count: 180))
        #expect(long.duration == 4 + 0.06 * 200)
    }

    @Test func 되돌리기나_동작_단추가_있으면_적어도_7초_남는다() {
        let backup = URL(filePath: "/tmp/djc-synthetic-backup")
        #expect(AppToast(title: "썼습니다", undoBackup: backup).duration == 7)
        #expect(AppToast(title: "USB에 썼습니다", action: .ejectUsb(volumeKey: "k")).duration == 7)
        #expect(AppToast(kind: .warning, title: "일부만 썼습니다", undoBackup: backup).duration == 7)
        // 글이 길면 7초보다 길게 남는다
        let long = AppToast(title: "썼습니다", detail: String(repeating: "가", count: 96), undoBackup: backup)
        #expect(long.duration == 4 + 0.06 * 100)
    }

    @Test func 실패는_닫을_때까지_남는다() {
        #expect(AppToast(kind: .failure, title: "실패").duration == .infinity)
        #expect(!AppToast(kind: .failure, title: "실패").automaticallyDismisses(voiceOverEnabled: false))
        #expect(AppToast(kind: .warning, title: "경고").automaticallyDismisses(voiceOverEnabled: false))
    }

    // MARK: - 타이머

    @Test func 성공_알림은_정한_시간이_지나면_닫는다() async {
        let ticks = Ticks(), timer = timer(ticks)
        var closed = 0
        let toast = AppToast(title: "썼습니다")
        await timer.run(toast, close: { closed += 1 })
        #expect(closed == 1 && ticks.count == Self.ticks(toast.duration))
    }

    @Test func 경고_알림도_정한_시간이_지나면_닫는다() async {
        let ticks = Ticks(), timer = timer(ticks)
        var closed = 0
        let toast = AppToast(kind: .warning, title: "확인하세요", detail: "rekordbox를 종료한 뒤 다시 누르세요")
        await timer.run(toast, close: { closed += 1 })
        #expect(closed == 1 && ticks.count == Self.ticks(toast.duration))
    }

    @Test func 마우스를_올려_둔_동안은_시간을_세지_않는다() async {
        let ticks = Ticks(), timer = timer(ticks)
        timer.hovering = true
        ticks.onTick = { if $0 == 5 { timer.hovering = false } }
        var closed = false
        let toast = AppToast(title: "썼습니다")
        await timer.run(toast, close: { closed = true })
        #expect(closed && ticks.count == 4 + Self.ticks(toast.duration))
    }

    @Test func 단추에_키보드_포커스가_있는_동안은_시간을_세지_않는다() async {
        let ticks = Ticks(), timer = timer(ticks)
        timer.focused = true
        ticks.onTick = { if $0 == 5 { timer.focused = false } }
        var closed = false
        let toast = AppToast(kind: .warning, title: "확인하세요")
        await timer.run(toast, close: { closed = true })
        #expect(closed && ticks.count == 4 + Self.ticks(toast.duration))
    }

    @Test func 실패와_VoiceOver에서는_저절로_닫지_않는다() async {
        let ticks = Ticks()
        var closed = false
        await timer(ticks).run(AppToast(kind: .failure, title: "실패했습니다"), close: { closed = true })
        await timer(ticks, voiceOver: true).run(AppToast(title: "썼습니다"), close: { closed = true })
        await timer(ticks, voiceOver: true).run(AppToast(kind: .warning, title: "확인하세요"), close: { closed = true })
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
