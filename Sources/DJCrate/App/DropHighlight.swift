/// 끌어다 놓을 자리의 강조(테두리) 상태(#127).
/// SwiftUI는 놓은 뒤(concludeDragOperation)에도 `dropUpdated`를 한 번 더 부르고 `dropExited`는 보내지 않는다.
/// 그래서 놓은 뒤에는 새 끌기가 들어올 때까지 강조를 다시 켜지 않는다.
struct DropHighlight: Equatable {
    private(set) var isTargeted = false
    private var hasDropped = false

    mutating func enter(accepted: Bool) {
        hasDropped = false
        isTargeted = accepted
    }

    mutating func update(accepted: Bool) { isTargeted = accepted && !hasDropped }
    mutating func exit() { isTargeted = false }

    mutating func drop() {
        hasDropped = true
        isTargeted = false
    }
}
