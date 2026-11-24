import AppKit
import DJCApplication
import Observation
import SwiftUI

/// 입력 중인 칸(Return 전)이 있는지와 그 칸을 확정하는 입구(R19, #375·#405). ⌘S가 확정하고(#404), 자동 저장은 그동안 미룬다(엔진의 `EditActivity.fieldEditing`).
/// 칸에 글자를 쳐서 편집을 시작할 때의 값을 원래 값으로 잡고, 지금 값이 원래 값과 다를 때만 입력 중이다(원래 값으로 되돌리면 입력 중이 아니다, 컨실 S11).
/// 칸을 벗어나거나 확정·취소하면 끝난다. 태그 시트·곡 목록 칸·인스펙터의 칸(`NSControl` 알림)과 여러 줄 글 상자(필드 편집기가 아닌 `NSTextView`, G6)를 본다.
/// 검색칸과 목록을 거르는 칸(`filterField()`, O5)은 저장할 편집이 아니라 세지 않는다.
/// 확정은 창의 포커스를 거둬(`makeFirstResponder(nil)`) 각 칸이 스스로 확정하게 한다: 칸마다 다른 확정 규칙을 여기서 따로 알지 않는다.
/// 조립 지점이 `live`를 하나 만들어 주 창 화면 모델에 넣고 엔진에 잇는다. 화면 시험은 값을 직접 바꾼다.
@MainActor
@Observable
final class FieldEditingState {
    /// 입력 중인 칸이 있다
    var isEditing = false {
        didSet { if isEditing != oldValue { onChange?(isEditing) } }
    }
    /// 입력 중인 칸을 확정한다. 칸이 확정을 거절하면(검증이 포커스를 놓지 못하게 함) false. 시험이 바꿔 끼운다
    @ObservationIgnored var commit: @MainActor () -> Bool = { true }
    /// 확정이 끝나기를 기다리는 한도. 넘으면 저장하지 않고 이유를 알린다(칸의 값이 빠진 채 저장하지 않게)
    @ObservationIgnored var settleLimit: Duration = .milliseconds(1500)
    /// 칸이 포커스를 잃은 뒤 값을 넣는 확정이 아직 끝나지 않았다(SwiftUI 입력 칸). 조립 지점이 인스펙터에 잇는다
    @ObservationIgnored var hasPendingCommit: @MainActor () -> Bool = { false }
    /// 입력 중 여부가 바뀔 때마다(같은 값은 다시 부르지 않는다). 조립 지점이 자동 저장 엔진의 편집 활동으로 옮긴다
    @ObservationIgnored var onChange: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var center: NotificationCenter = .default
    /// 편집을 시작한 칸과 그때의 값. 창이 닫혀 끝 알림 없이 사라진 칸은 다음 알림·판정 때 솎는다
    @ObservationIgnored private var fields: [ObjectIdentifier: Field] = [:]

    private struct Field {
        weak var object: AnyObject?
        /// 편집을 시작할 때의 값(읽지 못하면 nil: 바꿈 알림이 오면 입력 중으로 본다)
        var original: String?
        /// 원래 값과 다른 미확정 값이 있다
        var changed = false
    }

    /// 목록을 거르는 칸의 표시(`filterField()`가 칸의 내용 종류 `contentType`에 단다). 이 표시가 있는 칸은 입력 중으로 보지 않는다(컨실 O5).
    /// SwiftUI의 접근성 식별자는 AppKit 칸까지 내려오지 않아 쓰지 않는다(내용 종류는 `NSTextField.contentType`으로 내려온다)
    nonisolated static let filterIdentifier = "djc.filter-field"

    /// 입력 중 여부 → 엔진의 편집 활동
    nonisolated static func activity(editing: Bool) -> EditActivity { editing ? [.fieldEditing] : [] }

    /// 이 Mac의 입력 알림을 지켜보고, 확정은 `window`의 포커스를 거두는 것으로 한다
    /// - Parameters:
    ///   - window: 확정할 창(기본은 키 창)
    ///   - center: 알림을 받을 곳(시험이 따로 준다)
    static func live(window: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
                     center: NotificationCenter = .default) -> FieldEditingState {
        let state = FieldEditingState()
        state.commit = { [weak state] in
            guard let window = window() else { return true }
            // 칸이 확정을 거절하면(검증 실패) 입력은 이어진다
            guard window.makeFirstResponder(nil) else { return false }
            state?.finishAll()
            return true
        }
        state.observe(center)
        return state
    }

    /// 지켜보기를 멈춘다(시험·앱 끝)
    func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    /// 끝 알림 없이 편집을 마친 칸(창이 닫힘 등)을 솎는다. 엔진이 판정할 때마다 부른다(`AppComposition.autoReflectionHolds`)
    func revalidate() {
        fields = fields.filter { _, field in
            if let control = field.object as? NSTextField { return control.currentEditor() != nil }
            if let text = field.object as? NSTextView { return text.window?.firstResponder === text }
            return false
        }
        publish()
    }

    // MARK: - 알림

    private func observe(_ center: NotificationCenter) {
        self.center = center
        // AppKit은 글 칸 알림을 메인 스레드에서 보낸다(받는 즉시 같은 차례에서 센다)
        func watch(_ name: Notification.Name, _ handle: @escaping @MainActor (FieldEditingState, AnyObject?, NSText?) -> Void) -> any NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                nonisolated(unsafe) let object = note.object as AnyObject?
                nonisolated(unsafe) let editor = note.userInfo?["NSFieldEditor"] as? NSText
                MainActor.assumeIsolated { if let self { handle(self, object, editor) } }
            }
        }
        observers = [
            watch(NSControl.textDidBeginEditingNotification) { $0.began($1, editor: $2) },
            watch(NSControl.textDidChangeNotification) { $0.changed($1, editor: $2) },
            watch(NSControl.textDidEndEditingNotification) { state, object, _ in state.ended(object) },
            // 여러 줄 글 상자(G6). 필드 편집기도 같은 알림을 내지만 그 칸은 위 `NSControl` 알림으로 센다
            watch(NSText.didBeginEditingNotification) { state, object, _ in state.began(object, editor: nil) },
            watch(NSText.didChangeNotification) { state, object, _ in state.changed(object, editor: nil) },
            watch(NSText.didEndEditingNotification) { state, object, _ in state.ended(object) },
        ]
    }

    /// 세는 칸인지: 고칠 수 있는 글 칸·여러 줄 글 상자. 검색칸·거르기 칸·필드 편집기는 세지 않는다
    private func counts(_ object: AnyObject?) -> Bool {
        if let field = object as? NSTextField {
            return field.isEditable && !(field is NSSearchField) && field.contentType?.rawValue != Self.filterIdentifier
        }
        if let text = object as? NSTextView {
            return text.isEditable && !text.isFieldEditor && text.contentType?.rawValue != Self.filterIdentifier
        }
        return false
    }

    /// 칸의 지금 값: 필드 편집기의 글(칸의 `stringValue`는 편집을 확정하므로 읽지 않는다), 여러 줄 글 상자는 그 글
    private func text(_ object: AnyObject?, editor: NSText?) -> String? {
        if let editor { return editor.string }
        if let field = object as? NSTextField { return (field.currentEditor() as? NSText)?.string }
        return (object as? NSTextView)?.string
    }

    private func began(_ object: AnyObject?, editor: NSText?) {
        guard counts(object), let object else { return }
        fields[ObjectIdentifier(object)] = Field(object: object, original: text(object, editor: editor))
    }

    private func changed(_ object: AnyObject?, editor: NSText?) {
        guard counts(object), let object else { return }
        let key = ObjectIdentifier(object)
        var field = fields[key] ?? Field(object: object, original: nil)
        let now = text(object, editor: editor)
        field.changed = field.original == nil || now == nil || now != field.original
        fields[key] = field
        publish()
    }

    private func ended(_ object: AnyObject?) {
        if let object { fields[ObjectIdentifier(object)] = nil }
        publish()
    }

    /// 확정했다(창의 포커스를 거뒀다): 모든 칸을 끝낸다
    private func finishAll() {
        fields = [:]
        publish()
    }

    private func publish() {
        fields = fields.filter { $0.value.object != nil }
        let editing = fields.values.contains(where: \.changed)
        if editing != isEditing { isEditing = editing }
    }
}

extension View {
    /// 목록을 거르는 칸(찾기·속성 필터): 저장할 편집이 아니라 입력 감지기가 입력 중으로 보지 않는다(R19, 컨실 O5)
    func filterField() -> some View { textContentType(NSTextContentType(rawValue: FieldEditingState.filterIdentifier)) }
}
