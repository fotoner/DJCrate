import AppKit
@testable import DJCrate
import DJCApplication
import Testing

/// 입력 중인 칸(R19, #405): 고칠 수 있는 글 칸에서 글자를 바꾼 뒤 확정(Return·포커스 이동)하기 전이면 편집 중이다.
/// 자동 저장은 입력을 확정하지 않고 그동안 미룬다(엔진의 `EditActivity.fieldEditing`). 검색칸은 편집이 아니다.
@MainActor
@Suite("입력 중인 칸 감지")
struct FieldEditingMonitorTests {
    let center = NotificationCenter()

    @Test func 글자를_바꾸면_확정할_때까지_입력_중이다() {
        var signals: [Bool] = []
        let monitor = FieldEditingMonitor(center: center) { signals.append($0) }
        let field = NSTextField(string: "원래 제목")
        center.post(name: NSControl.textDidBeginEditingNotification, object: field)
        // 포커스만 들어온 칸은 미확정 값이 없다
        #expect(!monitor.isEditing && signals.isEmpty)
        center.post(name: NSControl.textDidChangeNotification, object: field)
        center.post(name: NSControl.textDidChangeNotification, object: field)
        #expect(monitor.isEditing && signals == [true])
        center.post(name: NSControl.textDidEndEditingNotification, object: field)
        #expect(!monitor.isEditing && signals == [true, false])
    }

    @Test func 두_칸_가운데_하나라도_미확정이면_입력_중이다() {
        var signals: [Bool] = []
        let monitor = FieldEditingMonitor(center: center) { signals.append($0) }
        let title = NSTextField(string: ""), comment = NSTextField(string: "")
        center.post(name: NSControl.textDidChangeNotification, object: title)
        center.post(name: NSControl.textDidChangeNotification, object: comment)
        center.post(name: NSControl.textDidEndEditingNotification, object: title)
        #expect(monitor.isEditing)
        center.post(name: NSControl.textDidEndEditingNotification, object: comment)
        #expect(!monitor.isEditing && signals == [true, false])
    }

    @Test func 검색칸과_고칠_수_없는_칸은_편집이_아니다() {
        var signals: [Bool] = []
        let monitor = FieldEditingMonitor(center: center) { signals.append($0) }
        let search = NSSearchField(string: "")
        let label = NSTextField(labelWithString: "표시만")
        center.post(name: NSControl.textDidChangeNotification, object: search)
        center.post(name: NSControl.textDidChangeNotification, object: label)
        #expect(!monitor.isEditing && signals.isEmpty)
    }

    @Test func 확정하지_않은_칸이_사라지면_입력_중이_아니다() {
        var signals: [Bool] = []
        let monitor = FieldEditingMonitor(center: center) { signals.append($0) }
        autoreleasepool {
            let field = NSTextField(string: "")
            center.post(name: NSControl.textDidChangeNotification, object: field)
        }
        #expect(monitor.isEditing)
        // 창이 닫혀 칸이 확정 알림 없이 사라졌다: 다음 알림 때 사라진 칸을 솎는다
        let other = NSTextField(string: "")
        center.post(name: NSControl.textDidEndEditingNotification, object: other)
        #expect(!monitor.isEditing && signals == [true, false])
    }

    @Test func 끝_알림_없이_편집을_마친_칸은_판정_때_솎는다() {
        var signals: [Bool] = []
        let monitor = FieldEditingMonitor(center: center) { signals.append($0) }
        // 창이 닫혀 칸의 편집기가 없어졌다(끝 알림 없음)
        let field = NSTextField(string: "")
        center.post(name: NSControl.textDidChangeNotification, object: field)
        #expect(monitor.isEditing)
        monitor.revalidate()
        #expect(!monitor.isEditing && signals == [true, false])
    }

    @Test func 입력_중_신호를_엔진_활동으로_옮긴다() {
        #expect(FieldEditingMonitor.activity(editing: true) == [.fieldEditing])
        #expect(FieldEditingMonitor.activity(editing: false).isEmpty)
    }
}
