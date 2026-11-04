@testable import DJCrate
import AppKit
import DJCDomain
import SwiftUI
import Testing

/// 머리 줄 검색칸(`ListSearchField`, #338)의 입력·Esc·한글 조합·포커스 요청을 실제 창에 올린 `NSSearchField`로 본다.
/// 글자는 필드 에디터(`NSTextView`)에 직접 넣는다. 입력기(IME) 조합은 `setMarkedText`로 흉내 낸 것이라
/// 실제 키보드·입력기 체감은 사람이 본다(`--key-routing-selftest`는 이 Mac의 비활성 앱에서 키 창을 못 만든다).
@MainActor
@Suite("머리 줄 검색칸 — 입력·Esc·한글 조합·포커스")
struct ListSearchFieldTests {
    /// 앱처럼 쓰는 동안(`libraryBusy`)에는 칸을 잠그는 부모를 흉내 낸다(`ContentView`의 상세 열 `.disabled`)
    private struct Host: View {
        let store: LibraryStore
        let window: LibraryWindowModel

        var body: some View {
            ListSearchField(store: store, window: window).disabled(store.libraryBusy).padding()
        }
    }

    private func open(_ store: LibraryStore, _ model: LibraryWindowModel) async throws -> (window: NSWindow, field: NSSearchField, close: () -> Void) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Host(store: store, window: model))
        window.orderBack(nil)
        func search(in view: NSView?) -> NSSearchField? {
            guard let view else { return nil }
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap { search(in: $0) }.first
        }
        #expect(await waitForState { search(in: window.contentView) != nil })
        let field = try #require(search(in: window.contentView))
        return (window, field, { window.close() })
    }

    private func settle(_ window: NSWindow) async {
        await drainMainActor()
        try? await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func focusedEditor(of field: NSSearchField, in window: NSWindow) -> NSTextView? {
        guard let editor = window.firstResponder as? NSTextView, editor.delegate === field else { return nil }
        return editor
    }

    private let noRange = NSRange(location: NSNotFound, length: 0)

    @Test func 칸에_친_글자는_검색어가_되고_다른_곳에서_바뀐_검색어는_칸에_실린다() async throws {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let (window, field, close) = try await open(store, LibraryWindowModel(store: store))
        defer { close() }
        field.selectText(nil)
        let editor = try #require(focusedEditor(of: field, in: window))
        editor.insertText("합", replacementRange: noRange)
        editor.insertText("성", replacementRange: noRange)
        #expect(store.search == "합성")
        await settle(window)
        // 검색어가 같으면 칸을 다시 쓰지 않는다(커서·선택이 그대로다)
        #expect(field.stringValue == "합성")
        #expect(focusedEditor(of: field, in: window) === editor)
        store.search = "Beta"
        await settle(window)
        #expect(field.stringValue == "Beta")
        // 목록의 「검색 지우기」처럼 밖에서 비우면 칸도 빈다
        store.search = ""
        await settle(window)
        #expect(field.stringValue.isEmpty)
    }

    /// 입력기를 흉내 낸 조합(`setMarkedText`)이다. 조합 중 칸이 글자를 지키고, 확정하면 검색어가 된다.
    /// 조합 중에 검색어가 갱신되는지는 이 흉내 경로에서 알림이 오지 않아 판정하지 않는다(실제 입력기는 사람이 본다).
    @Test func 한글_조합_중에는_칸이_글자를_지키고_확정하면_검색어가_된다() async throws {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let (window, field, close) = try await open(store, LibraryWindowModel(store: store))
        defer { close() }
        field.selectText(nil)
        let editor = try #require(focusedEditor(of: field, in: window))
        // ㅎ → 하 → 한(조합 중)
        for composing in ["ㅎ", "하", "한"] {
            editor.setMarkedText(composing, selectedRange: NSRange(location: composing.count, length: 0), replacementRange: noRange)
            await settle(window)
            #expect(editor.hasMarkedText())
            #expect(field.stringValue == composing)
        }
        // 조합 중 밖에서 검색어가 바뀌어도(칸 값과 달라도) 칸을 덮어써 조합을 끊지 않는다
        store.search = "밖에서"
        await settle(window)
        #expect(editor.hasMarkedText())
        #expect(field.stringValue == "한")
        // 확정하면 칸의 글자가 검색어가 되고 조합 표시가 사라진다
        editor.insertText("한", replacementRange: noRange)
        await settle(window)
        #expect(!editor.hasMarkedText())
        #expect(store.search == "한")
        #expect(field.stringValue == "한")
    }

    @Test func Esc_명령은_검색어를_지우고_빈_칸에서는_처리하지_않는다() async throws {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let (window, field, close) = try await open(store, LibraryWindowModel(store: store))
        defer { close() }
        field.selectText(nil)
        let editor = try #require(focusedEditor(of: field, in: window))
        editor.insertText("합성", replacementRange: noRange)
        #expect(store.search == "합성")
        // 목록으로 포커스를 옮기는 일은 KeyRouter가 이어서 한다(키 전달 자가 테스트가 본다)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(store.search.isEmpty)
        #expect(field.stringValue.isEmpty)
        // 지운 뒤에도 필드 에디터가 첫 응답자로 남아야 KeyRouter가 이어서 목록으로 포커스를 옮긴다(`window.firstResponder === editor`일 때만 옮긴다)
        #expect(focusedEditor(of: field, in: window) === editor)
        let delegate = try #require(field.delegate)
        // 이미 빈 칸의 Esc는 칸이 처리하지 않아 AppKit의 기본 동작이 이어진다
        #expect(delegate.control?(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))) == false)
        // Return은 검색어를 두고 칸의 기본 동작(확정)을 따른다
        editor.insertText("Alpha", replacementRange: noRange)
        #expect(delegate.control?(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) == false)
        #expect(store.search == "Alpha")
        #expect(focusedEditor(of: field, in: window) === editor)
    }

    @Test func 찾기_요청은_칸에_포커스를_옮기고_전체를_고른다() async throws {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let model = LibraryWindowModel(store: store)
        store.search = "합성 곡"
        let (window, field, close) = try await open(store, model)
        defer { close() }
        #expect(focusedEditor(of: field, in: window) == nil)
        model.focusSearch()
        #expect(await waitForState { focusedEditor(of: field, in: window) != nil })
        let editor = try #require(focusedEditor(of: field, in: window))
        #expect(editor.selectedRange == NSRange(location: 0, length: "합성 곡".count))
        // 칸에 있을 때 다시 눌러도 칸에 남고 다시 전체를 고른다
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        model.focusSearch()
        #expect(await waitForState { focusedEditor(of: field, in: window)?.selectedRange.length == "합성 곡".count })
    }

    @Test func 칸이_생기기_전의_요청으로_포커스를_가져가지_않는다() async throws {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let model = LibraryWindowModel(store: store)
        // 검색이 걸리지 않는 화면에서 칸이 없을 때의 요청이 남아 있어도, 칸이 새로 생길 때 포커스를 가져가지 않는다
        model.focusSearch()
        model.focusSearch()
        let (window, field, close) = try await open(store, model)
        defer { close() }
        await settle(window)
        #expect(focusedEditor(of: field, in: window) == nil)
    }

    @Test func rekordbox에_쓰는_동안은_칸이_잠기고_찾기_요청도_받지_않는다() async throws {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        let model = LibraryWindowModel(store: store)
        let (window, field, close) = try await open(store, model)
        defer { close() }
        #expect(field.isEnabled)
        store.isWritingRekordbox = true
        #expect(await waitForState { !field.isEnabled })
        model.focusSearch()
        await settle(window)
        #expect(focusedEditor(of: field, in: window) == nil)
        store.isWritingRekordbox = false
        #expect(await waitForState { field.isEnabled })
    }
}
