import AppKit
@testable import DJCrate
import DJCApplication
import SwiftUI
import Testing

/// 입력 중인 칸(R19): ⌘S의 입력 확정(#404)과 자동 저장 미룸(#405)이 함께 쓰는 감지기 하나(`FieldEditingState`).
/// 실제 AppKit 창의 칸에 글자를 넣어 본다(필드 편집기·여러 줄 글 상자·SwiftUI 칸)
@MainActor
@Suite("입력 중인 칸 감지(실제 칸)", .serialized)
struct FieldEditingStateTests {
    func window(_ content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// 편집을 끝내고 닫는다: 감지기는 이 프로세스의 모든 칸 알림을 받으므로, 끝 알림 없이 닫으면 함께 도는 다른 시험의 감지기가 그 칸을 입력 중으로 붙든다
    func close(_ windows: NSWindow...) {
        for window in windows {
            window.makeFirstResponder(nil)
            window.close()
        }
    }

    func replace(_ editor: NSTextView, with text: String) {
        editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    }

    func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }

    /// 칸을 원래 값으로 되돌리면 확정하지 않아도 입력 중이 아니다(자동 저장을 포커스를 옮길 때까지 미루지 않는다, 컨실 S11)
    @Test func 칸을_원래_값으로_되돌리면_입력_중이_아니다() throws {
        let field = NSTextField(string: "원래 제목")
        let window = window(field)
        defer { close(window) }
        let state = FieldEditingState.live(window: { window })
        defer { state.stop() }
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        replace(editor, with: "고친 제목")
        #expect(state.isEditing)
        replace(editor, with: "원래 제목")
        #expect(!state.isEditing, "원래 값으로 되돌린 칸은 미확정 변경이 없다")
        replace(editor, with: "다시 고친 제목")
        #expect(state.isEditing)
        window.makeFirstResponder(nil)
        #expect(!state.isEditing)
    }

    /// 여러 줄 글 상자(인스펙터 코멘트처럼 필드 편집기가 아닌 NSTextView)도 입력 중으로 본다(컨실 G6)
    @Test func 여러_줄_글_상자도_입력_중으로_본다() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        text.string = "원래 코멘트"
        let window = window(text)
        defer { close(window) }
        let state = FieldEditingState.live(window: { window })
        defer { state.stop() }
        #expect(window.makeFirstResponder(text))
        replace(text, with: "고친 코멘트")
        #expect(state.isEditing)
        window.makeFirstResponder(nil)
        #expect(!state.isEditing)
    }

    struct Filter: View {
        @State var text = ""
        let marked: Bool
        var body: some View {
            if marked { TextField("찾기", text: $text).filterField() } else { TextField("이름", text: $text) }
        }
    }

    /// 목록을 거르는 SwiftUI 칸(찾기·속성 필터)은 저장할 편집이 아니다: 표시한 칸은 입력 중으로 보지 않는다(컨실 O5). 표시 없는 SwiftUI 칸은 본다
    @Test(arguments: [true, false])
    func 거르기_칸은_입력_중이_아니다(_ marked: Bool) throws {
        let host = NSHostingView(rootView: Filter(marked: marked))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        let window = window(host)
        defer { close(window) }
        let state = FieldEditingState.live(window: { window })
        defer { state.stop() }
        let field = try #require(textField(in: host))
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        replace(editor, with: "고른 말")
        #expect(state.isEditing == !marked)
    }

    /// 초안을 편집하지 않는 보조 창의 칸은 세지 않는다: 그 칸을 확정하지 않은 채 주 창으로 와도 입력 중이 아니다(컨실 3라운드 G18)
    @Test func 보조_창의_칸은_입력_중으로_세지_않는다() throws {
        let auxField = NSTextField(string: "복원 시점 이름"), mainField = NSTextField(string: "원래 제목")
        let aux = window(auxField), main = window(mainField)
        defer { close(aux, main) }
        let state = FieldEditingState.live(window: { main })
        defer { state.stop() }
        state.countsWindow = { $0 !== aux }
        #expect(aux.makeFirstResponder(auxField))
        replace(try #require(auxField.currentEditor() as? NSTextView), with: "새 이름")
        #expect(!state.isEditing, "보조 창의 칸")
        #expect(main.makeFirstResponder(mainField))
        replace(try #require(mainField.currentEditor() as? NSTextView), with: "고친 제목")
        #expect(state.isEditing, "주 창의 칸")
    }

    // MARK: - 알림만으로(필드 편집기 없이): 바꿈부터 끝까지 미확정, 검색칸·고칠 수 없는 칸 제외, 사라진 칸 솎기(#405 1라운드에서 옮김)

    let center = NotificationCenter()

    /// 따로 둔 알림 센터를 지켜보는 감지기(입력 중 여부가 바뀔 때마다 `onChange`)
    func watching(_ onChange: @escaping @MainActor (Bool) -> Void) -> FieldEditingState {
        let state = FieldEditingState.live(window: { nil }, center: center)
        state.onChange = onChange
        return state
    }

    @Test func 글자를_바꾸면_확정할_때까지_입력_중이다() {
        var signals: [Bool] = []
        let monitor = watching { signals.append($0) }
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
        let monitor = watching { signals.append($0) }
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
        let monitor = watching { signals.append($0) }
        let search = NSSearchField(string: "")
        let label = NSTextField(labelWithString: "표시만")
        center.post(name: NSControl.textDidChangeNotification, object: search)
        center.post(name: NSControl.textDidChangeNotification, object: label)
        #expect(!monitor.isEditing && signals.isEmpty)
    }

    @Test func 확정하지_않은_칸이_사라지면_입력_중이_아니다() {
        var signals: [Bool] = []
        let monitor = watching { signals.append($0) }
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
        let monitor = watching { signals.append($0) }
        // 창이 닫혀 칸의 편집기가 없어졌다(끝 알림 없음)
        let field = NSTextField(string: "")
        center.post(name: NSControl.textDidChangeNotification, object: field)
        #expect(monitor.isEditing)
        monitor.revalidate()
        #expect(!monitor.isEditing && signals == [true, false])
    }

    @Test func 입력_중_신호를_엔진_활동으로_옮긴다() {
        #expect(FieldEditingState.activity(editing: true) == [.fieldEditing])
        #expect(FieldEditingState.activity(editing: false).isEmpty)
    }
}
