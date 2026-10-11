@testable import DJCrate
import AppKit
import Testing

/// 파형 위 스크롤(휠·트랙패드) 처리 규칙. #92: 트랙패드로 스크럽하고 손을 뗀 뒤 커서를 핫큐 버튼으로 옮기면
/// 남은 관성 이벤트가 덱을 감싼 스크롤 뷰로 새는 회귀를 확인한다.
/// OS 감속 중 클릭 억제 자체는 이 정책 테스트가 재현하지 않는다.
@Suite("파형 스크롤 규칙")
struct WaveformScrollPolicyTests {
    typealias Event = WaveformScrollPolicy.Event

    /// 창 폭 1000pt에 16초가 보이는 파형
    func handle(_ policy: inout WaveformScrollPolicy, _ event: Event) -> WaveformScrollPolicy.Action {
        policy.handle(event, zoomSeconds: 16, width: 1000)
    }

    func isScrub(_ action: WaveformScrollPolicy.Action, _ seconds: Double) -> Bool {
        if case let .scrub(value) = action { return abs(value - seconds) < 1e-9 }
        return false
    }

    @Test func 파형_위에서_시작한_제스처는_관성이_끝날_때까지_모두_삼킨다() {
        var policy = WaveformScrollPolicy()
        #expect(handle(&policy, Event(phase: .began, over: true)) == .swallow)
        #expect(isScrub(handle(&policy, Event(phase: .changed, over: true, dx: -100, precise: true)), 1.6))
        #expect(handle(&policy, Event(phase: .ended, over: true)) == .swallow)
        // 손을 뗀 뒤 커서를 핫큐 버튼(파형 밖)으로 옮겨도 관성 이벤트는 덱 스크롤 뷰로 보내지 않는다.
        #expect(handle(&policy, Event(momentum: .began, over: false, dx: -40, precise: true)) == .swallow)
        #expect(handle(&policy, Event(momentum: .changed, over: false, dx: -20, precise: true)) == .swallow)
        #expect(handle(&policy, Event(momentum: .ended, over: false)) == .swallow)
        // 관성이 끝나면 다음 스크롤은 그 자리에서 다시 정한다.
        #expect(handle(&policy, Event(phase: .mayBegin, over: false)) == .pass)
    }

    @Test func 손을_뗀_뒤_관성으로는_스크럽하지_않는다() {
        // 관성으로 계속 옮기면 재생이 멈춘 채 몇 초가 가고, 그사이 누른 핫큐 이동도 관성에 밀려났다.
        var policy = WaveformScrollPolicy()
        _ = handle(&policy, Event(phase: .began, over: true))
        _ = handle(&policy, Event(phase: .ended, over: true))
        #expect(handle(&policy, Event(momentum: .began, over: true, dx: -40, precise: true)) == .swallow)
        #expect(handle(&policy, Event(momentum: .changed, over: true, dx: -40, precise: true)) == .swallow)
    }

    @Test func 손가락을_올린_채_파형_밖으로_나가도_그_제스처는_스크럽이다() {
        var policy = WaveformScrollPolicy()
        _ = handle(&policy, Event(phase: .mayBegin, over: true))
        _ = handle(&policy, Event(phase: .began, over: true, dx: -10, precise: true))
        #expect(isScrub(handle(&policy, Event(phase: .changed, over: false, dx: -10, precise: true)), 0.16))
    }

    @Test func 파형_밖에서_시작한_제스처는_파형_위로_들어와도_건드리지_않는다() {
        // 곡 목록을 스크롤하다 관성으로 커서가 파형 위를 지나도 재생 위치가 움직이지 않게
        var policy = WaveformScrollPolicy()
        #expect(handle(&policy, Event(phase: .began, over: false, dx: 0, dy: -5, precise: true)) == .pass)
        #expect(handle(&policy, Event(phase: .changed, over: true, dx: -30, precise: true)) == .pass)
        #expect(handle(&policy, Event(momentum: .changed, over: true, dx: -30, precise: true)) == .pass)
        #expect(handle(&policy, Event(momentum: .ended, over: true)) == .pass)
    }

    @Test func 세로는_확대_가로는_스크럽이다() {
        var policy = WaveformScrollPolicy()
        _ = handle(&policy, Event(phase: .began, over: true))
        guard case let .zoom(factor) = handle(&policy, Event(phase: .changed, over: true, dy: 10, precise: true)) else {
            Issue.record("세로 스크롤은 확대·축소")
            return
        }
        #expect(factor < 1)
        #expect(isScrub(handle(&policy, Event(phase: .changed, over: true, dx: 50, precise: true)), -0.8))
    }

    @Test func 일반_휠은_이벤트마다_커서_위치로_정한다() {
        // 제스처 단계가 없는 마우스 휠: 파형 위면 받고, 밖이면 넘긴다. 줄 단위 휠은 6배로 옮긴다.
        var policy = WaveformScrollPolicy()
        #expect(handle(&policy, Event(over: true, dy: 1)) == .zoom(0.85))
        #expect(handle(&policy, Event(over: true, dy: -1)) == .zoom(1.18))
        #expect(isScrub(handle(&policy, Event(over: true, dx: -1)), 0.096))
        #expect(handle(&policy, Event(over: false, dx: -1)) == .pass)
    }

    /// 트랙패드 스크롤 이벤트(단계 필드를 채운 CGEvent → NSEvent)
    static func trackpad(phase: Int64, momentum: Int64, dx: Int32 = -12) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return NSEvent(cgEvent: cg)
    }

    @Test func 실제_NSEvent의_제스처_단계와_관성을_읽는다() throws {
        // CGScrollPhase: 1 시작 · 2 계속 · 4 끝 · 8 취소 · 128 손가락 올림 / CGMomentumScrollPhase: 1 시작 · 2 계속 · 3 끝
        let cases: [(Int64, Int64, Event.Phase, Event.Momentum)] = [
            (128, 0, .mayBegin, .none), (1, 0, .began, .none), (2, 0, .changed, .none), (4, 0, .ended, .none), (8, 0, .cancelled, .none),
            (0, 1, .none, .began), (0, 2, .none, .changed), (0, 3, .none, .ended), (0, 0, .none, .none),
        ]
        for (phase, momentum, expectedPhase, expectedMomentum) in cases {
            let event = try #require(Self.trackpad(phase: phase, momentum: momentum))
            let converted = Event(event, over: true)
            #expect(converted.phase == expectedPhase, "phase \(phase)")
            #expect(converted.momentum == expectedMomentum, "momentum \(momentum)")
        }
        let moving = Event(try #require(Self.trackpad(phase: 2, momentum: 0, dx: -12)), over: false)
        #expect(moving.dx < 0 && moving.precise && !moving.over)
    }

    @Test func 새_제스처가_시작하면_앞_제스처의_결정을_버린다() {
        var policy = WaveformScrollPolicy()
        _ = handle(&policy, Event(phase: .began, over: true))
        _ = handle(&policy, Event(phase: .ended, over: true))
        // 관성이 끝나기 전에 파형 밖에서 새로 스크롤(두 손가락을 다시 올림)
        #expect(handle(&policy, Event(phase: .mayBegin, over: false)) == .pass)
        #expect(handle(&policy, Event(phase: .changed, over: true, dy: -5, precise: true)) == .pass)
    }
}
