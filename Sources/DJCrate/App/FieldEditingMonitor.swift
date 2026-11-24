import AppKit
import DJCApplication

/// 입력 중인 칸(R19): 고칠 수 있는 글 칸에서 글자를 바꾼 뒤 아직 확정하지 않았다(Return·포커스 이동 전).
/// 자동 저장은 입력을 확정하지 않고 그동안 미룬다(엔진의 `EditActivity.fieldEditing`). 검색칸은 목록을 거르는 칸이라 편집이 아니다.
/// AppKit 글 칸(SwiftUI `TextField` 포함)이 보내는 편집 알림만 본다: 바꿈 알림부터 끝 알림까지가 미확정이다.
@MainActor
final class FieldEditingMonitor {
    /// 미확정 값이 있는 칸이 있다
    private(set) var isEditing = false
    private let onChange: @MainActor (Bool) -> Void
    /// 미확정 값이 있는 칸(창이 닫혀 끝 알림 없이 사라진 칸은 다음 알림 때 솎는다)
    private var fields: [ObjectIdentifier: WeakField] = [:]
    private var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter

    private struct WeakField {
        weak var field: NSTextField?
    }

    /// - Parameter onChange: 입력 중 여부가 바뀔 때마다(같은 값은 다시 부르지 않는다)
    init(center: NotificationCenter = .default, onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        self.center = center
        // AppKit은 글 칸 알림을 메인 스레드에서 보낸다(받는 즉시 같은 차례에서 센다)
        let changed = center.addObserver(forName: NSControl.textDidChangeNotification, object: nil, queue: nil) { [weak self] note in
            let field = note.object as? NSTextField
            MainActor.assumeIsolated { self?.changed(field) }
        }
        let ended = center.addObserver(forName: NSControl.textDidEndEditingNotification, object: nil, queue: nil) { [weak self] note in
            let field = note.object as? NSTextField
            MainActor.assumeIsolated { self?.ended(field) }
        }
        observers = [changed, ended]
    }

    isolated deinit {
        observers.forEach(center.removeObserver)
    }

    /// 입력 중 여부 → 엔진의 편집 활동
    nonisolated static func activity(editing: Bool) -> EditActivity { editing ? [.fieldEditing] : [] }

    private func changed(_ field: NSTextField?) {
        guard let field, field.isEditable, !(field is NSSearchField) else { return }
        fields[ObjectIdentifier(field)] = WeakField(field: field)
        publish()
    }

    private func ended(_ field: NSTextField?) {
        if let field { fields[ObjectIdentifier(field)] = nil }
        publish()
    }

    /// 끝 알림 없이 편집을 마친 칸(창이 닫힘 등)을 솎는다. 엔진이 판정할 때마다 부른다(`AppComposition.autoReflectionHolds`)
    func revalidate() {
        fields = fields.filter { $0.value.field?.currentEditor() != nil }
        publish()
    }

    private func publish() {
        fields = fields.filter { $0.value.field != nil }
        let editing = !fields.isEmpty
        guard editing != isEditing else { return }
        isEditing = editing
        onChange(editing)
    }
}
