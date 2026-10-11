import AppKit
import DJCDomain

/// 확대 파형을 끄는 동안 핫큐 키를 덱에 보낸다(#133).
/// 마우스를 쥔 SwiftUI 제스처(끌기·확대)가 도는 동안 AppKit은 이벤트 추적 모드로 이벤트를 받고, 그 사이 키 이벤트는
/// `sendEvent`에 가지 않고 버려진다(KeyRouter의 로컬 모니터까지 오지 않는다). 그래서 끄는 동안에만 키보드 상태를 직접 읽는다.
/// 새로 누른 키만 누른 것으로 본다(`HotCueKeyWatch`). Shift를 함께 누르면 지우기(단축키와 같다).
@MainActor
final class DragHotCueKeys {
    struct Input {
        var isKeyDown: (UInt16) -> Bool
        var isShiftDown: () -> Bool
        var isMouseDown: () -> Bool

        static var hardware: Input {
            Input(isKeyDown: { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) },
                  isShiftDown: { NSEvent.modifierFlags.contains(.shift) },
                  isMouseDown: { NSEvent.pressedMouseButtons & 1 != 0 })
        }
    }

    var input = Input.hardware
#if DEBUG
    /// 자가 시험(`--scrub-hotcue-selftest`)이 합성 키·마우스 상태를 넣는 자리
    static var selfTestInput: Input?
#endif
    private weak var deck: DeckModel?
    private var watch: HotCueKeyWatch?
    private var task: Task<Void, Never>?

    var isWatching: Bool { watch != nil }

    /// 끌기 시작. `polling`을 끄면 부른 쪽이 `poll()`을 직접 부른다(시험).
    func begin(deck: DeckModel, polling: Bool = true) {
        end()
#if DEBUG
        if let input = Self.selfTestInput { self.input = input }
#endif
        self.deck = deck
        let keys = HotCueKeyWatch(shortcuts: deck.shortcuts, pressed: []).keys
        watch = HotCueKeyWatch(shortcuts: deck.shortcuts, pressed: Set(keys.filter(input.isKeyDown)))
        guard polling else { return }
        // 키를 짧게 톡 쳐도 놓치지 않게 자주 읽는다(끄는 동안에만).
        task = Task { [weak self] in
            while !Task.isCancelled, let self, self.isWatching {
                self.poll()
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    func poll() {
        guard var watch, let deck else { return }
        // 제스처가 끝을 알리지 못하고 끝나도(창을 떠남 등) 마우스를 뗐으면 멈춘다. 뗀 뒤 키는 KeyRouter가 받는다.
        guard input.isMouseDown() else { end(); return }
        let slots = watch.slots(pressed: Set(watch.keys.filter(input.isKeyDown)))
        self.watch = watch
        guard !slots.isEmpty, !deck.isWriteLocked else { return }
        let shift = input.isShiftDown()
        for slot in slots {
            if shift { deck.deleteHotCue(slot: slot) } else { deck.pressHotCue(slot: slot) }
        }
    }

    func end() {
        task?.cancel()
        task = nil
        watch = nil
    }
}
