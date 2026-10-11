import AppKit

/// 파형 위 스크롤 휠·트랙패드 이벤트를 어떻게 처리할지 정한다(세로: 확대·축소, 가로: 위치 이동).
///
/// 트랙패드 제스처는 시작할 때(`mayBegin`·`began`) 커서가 파형 위였는지로 한 번만 정하고, 관성이 끝날 때까지
/// 그 제스처의 이벤트를 모두 같은 쪽으로 보낸다. 관성 이벤트의 위치는 커서를 따라 바뀌어서, 이벤트마다 위치로 정하면
/// 손을 떼고 커서를 핫큐 버튼으로 옮기는 순간 남은 관성이 덱을 감싼 스크롤 뷰로 샌다.
/// 제스처 일부만 전달되어 감속 중 클릭 처리에 영향을 주지 않게 막는다(#92). 물리 트랙패드의 클릭 억제는 별도 확인이 필요하다.
/// 손을 뗀 뒤의 관성으로는 확대도 이동도 하지 않는다(재생이 멈춘 채 밀려가지 않게, CDJ 조그처럼 손을 떼면 멈춘다).
struct WaveformScrollPolicy {
    struct Event {
        enum Phase { case none, mayBegin, began, changed, stationary, ended, cancelled }
        enum Momentum { case none, began, changed, ended }

        var phase: Phase = .none
        var momentum: Momentum = .none
        /// 커서가 파형 위인지
        var over: Bool
        var dx: Double = 0
        var dy: Double = 0
        /// 트랙패드처럼 픽셀 단위로 오는지(아니면 줄 단위 휠)
        var precise = false
    }

    enum Action: Equatable {
        /// 창에 넘긴다
        case pass
        /// 삼킨다(아무것도 하지 않음)
        case swallow
        case zoom(Double)
        /// 재생 위치를 이만큼(초) 옮긴다
        case scrub(Double)
    }

    /// 지금 제스처(관성 포함)를 파형이 받는지. nil이면 진행 중인 제스처가 없다.
    private var owns: Bool?

    mutating func handle(_ event: Event, zoomSeconds: Double, width: Double) -> Action {
        let owned: Bool
        if event.phase == .mayBegin || event.phase == .began {
            // 새 제스처(손가락을 올림): 앞 제스처와 그 관성의 결정을 버리고 지금 커서 위치로 정한다.
            owns = event.over
            owned = event.over
        } else if event.phase == .none, event.momentum == .none {
            // 제스처 단계가 없는 마우스 휠: 이벤트마다 커서 위치로
            owns = nil
            owned = event.over
        } else {
            owned = owns ?? event.over
            if event.momentum == .ended || (event.momentum == .none && event.phase == .cancelled) { owns = nil }
        }
        guard owned else { return .pass }
        guard event.momentum == .none else { return .swallow }
        if abs(event.dy) >= abs(event.dx) {
            guard event.dy != 0 else { return .swallow }
            return .zoom(event.precise ? exp(-event.dy * 0.01) : (event.dy > 0 ? 0.85 : 1.18))
        }
        return .scrub(-event.dx / max(width, 1) * zoomSeconds * (event.precise ? 1 : 6))
    }
}

extension WaveformScrollPolicy.Event {
    init(_ event: NSEvent, over: Bool) {
        let phase: Phase
        switch event.phase {
        case let p where p.contains(.mayBegin): phase = .mayBegin
        case let p where p.contains(.began): phase = .began
        case let p where p.contains(.changed): phase = .changed
        case let p where p.contains(.stationary): phase = .stationary
        case let p where p.contains(.ended): phase = .ended
        case let p where p.contains(.cancelled): phase = .cancelled
        default: phase = .none
        }
        let momentum: Momentum
        switch event.momentumPhase {
        case let p where p.contains(.began): momentum = .began
        case let p where p.contains(.ended) || p.contains(.cancelled): momentum = .ended
        case let p where p.isEmpty: momentum = .none
        default: momentum = .changed
        }
        self.init(phase: phase, momentum: momentum, over: over, dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                  precise: event.hasPreciseScrollingDeltas)
    }
}
