/// 키 이벤트 없이 키보드 상태만 읽을 때 새로 누른 핫큐 키를 골라낸다(#133, 파형을 마우스로 끄는 동안).
/// 끌기 전부터 누르고 있던 키는 뗐다가 다시 눌러야 한다(누른 채 끌기를 시작해도 한 번 더 먹지 않게).
/// 키가 어느 동작인지는 키 이벤트와 같이 단축키 표(`DeckShortcuts.action(for:)`)를 따른다.
public struct HotCueKeyWatch: Sendable {
    public let shortcuts: DeckShortcuts
    /// 읽을 키: 단축키 표가 핫큐 A~H로 보내는 키(작은 칸부터)
    public let keys: [UInt16]
    private var held: Set<UInt16>

    public init(shortcuts: DeckShortcuts, pressed: Set<UInt16>) {
        self.shortcuts = shortcuts
        var keys: [UInt16] = []
        for action in DeckAction.allCases where action.hotCueSlot != nil {
            for key in shortcuts.keys(for: action) where !keys.contains(key) && shortcuts.action(for: key)?.hotCueSlot != nil {
                keys.append(key)
            }
        }
        self.keys = keys
        held = pressed.intersection(keys)
    }

    /// 지금 눌린 키 → 이번에 새로 눌린 핫큐 칸(칸 순서, 같은 칸은 한 번)
    public mutating func slots(pressed: Set<UInt16>) -> [Int] {
        let fresh = keys.filter { pressed.contains($0) && !held.contains($0) }
        held = pressed.intersection(keys)
        var slots: [Int] = []
        for key in fresh {
            if let slot = shortcuts.action(for: key)?.hotCueSlot, !slots.contains(slot) { slots.append(slot) }
        }
        return slots.sorted()
    }
}
