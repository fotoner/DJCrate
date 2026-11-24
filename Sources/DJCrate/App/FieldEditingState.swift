import AppKit
import Observation

/// 입력 중인 칸(Return 전)이 있는지와 그 칸을 확정하는 입구(R19, #375). ⌘S가 읽는다.
/// 칸에 글자를 치기 시작하면(`NSControl`의 편집 시작 알림) 입력 중이고, 칸을 벗어나거나 확정·취소하면 끝난다.
/// 태그 시트·곡 목록 칸·인스펙터의 칸이 모두 같은 알림을 낸다. 검색칸은 저장할 편집이 아니라 센다.
/// 확정은 창의 포커스를 거둬(`makeFirstResponder(nil)`) 각 칸이 스스로 확정하게 한다: 칸마다 다른 확정 규칙을 여기서 따로 알지 않는다.
/// 조립 지점이 `live`를 하나 만들어 주 창 화면 모델에 넣는다. 화면 시험은 값을 직접 바꾼다.
@MainActor
@Observable
final class FieldEditingState {
    /// 입력 중인 칸이 있다
    var isEditing = false
    /// 입력 중인 칸을 확정한다. 시험이 바꿔 끼운다
    @ObservationIgnored var commit: @MainActor () -> Void = {}
    /// 칸이 포커스를 잃은 뒤 값을 넣는 확정이 아직 끝나지 않았다(SwiftUI 입력 칸). 조립 지점이 인스펙터에 잇는다
    @ObservationIgnored var hasPendingCommit: @MainActor () -> Bool = { false }
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// 지금 입력 중인 칸(끝났다는 알림이 같은 칸의 것일 때만 끝낸다)
    @ObservationIgnored private weak var editing: AnyObject?

    /// 이 Mac의 입력 알림을 지켜보고, 확정은 `window`의 포커스를 거두는 것으로 한다
    /// - Parameter window: 확정할 창(기본은 키 창)
    static func live(window: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow }) -> FieldEditingState {
        let state = FieldEditingState()
        state.commit = { [weak state] in
            // 칸이 확정을 거절하면(검증 실패) 입력은 이어진다
            if let window = window(), window.makeFirstResponder(nil) { state?.finish(nil) }
        }
        let center = NotificationCenter.default
        let began = center.addObserver(forName: NSControl.textDidBeginEditingNotification, object: nil, queue: .main) { [weak state] note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated { state?.begin(object as AnyObject?) }
        }
        let ended = center.addObserver(forName: NSControl.textDidEndEditingNotification, object: nil, queue: .main) { [weak state] note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated { state?.finish(object as AnyObject?) }
        }
        state.observers = [began, ended]
        return state
    }

    /// 지켜보기를 멈춘다(시험·앱 끝)
    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func begin(_ object: AnyObject?) {
        // 검색칸은 저장할 편집이 아니다
        guard !(object is NSSearchField) else { return }
        editing = object
        if !isEditing { isEditing = true }
    }

    /// - Parameter object: 끝난 칸. nil이면 어느 칸이든 끝낸다
    private func finish(_ object: AnyObject?) {
        guard object == nil || object === editing || editing == nil else { return }
        editing = nil
        if isEditing { isEditing = false }
    }
}
