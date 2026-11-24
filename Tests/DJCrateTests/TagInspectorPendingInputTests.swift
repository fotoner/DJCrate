@testable import DJCrate
import AppKit
import DJCDomain
import SwiftUI
import Testing

/// 인스펙터 글자 칸의 입력 대기(`TagInspectorModel.hasPendingInput`)는 칸이 사라져도 남지 않는다(#404 sol 3라운드 S14).
/// 코멘트를 치다가 다른 곡을 고르면 칸이 새로 만들어지며 옛 칸의 포커스 확정이 불리지 않을 수 있다. 대기가 남으면 ⌘S가 매번 시간 초과로 저장하지 못한다.
@MainActor
@Suite("인스펙터 입력 대기", .serialized)
struct TagInspectorPendingInputTests {
    func fields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for child in view.subviews { found += fields(in: child) }
        return found
    }

    @Test func 입력_중인_칸이_사라지면_입력을_확정하고_대기를_푼다() async throws {
        _ = NSApplication.shared
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let a = TrackListTagEditTests.row("1", title: "합성 곡 1"), b = TrackListTagEditTests.row("2", title: "합성 곡 2")
        store.showRows([a, b])
        store.rowsByID = [a.id: a, b.id: b]
        store.rowsByUUID = [a.track.uuid: a, b.track.uuid: b]
        store.selection = [a.id]
        let model = TagInspectorModel(store: store)
        let controller = NSHostingController(rootView: TagInspector(model: model).frame(width: 420, height: 900))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 420, height: 900))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        // 제목 칸(첫 입력 칸)에 글자를 치기 시작한다
        let title = try #require(await waitForField(in: controller.view) { $0.stringValue == "합성 곡 1" })
        #expect(window.makeFirstResponder(title))
        let editor = try #require(title.currentEditor() as? NSTextView)
        editor.insertText("고친 제목", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        #expect(await waitForState(safetyNet: .seconds(90)) { model.hasPendingInput }, "글자를 치면 확정 대기가 생긴다")
        // 다른 곡을 고르면 칸이 새로 만들어진다
        store.selection = [b.id]
        #expect(await waitForField(in: controller.view) { $0.stringValue == "합성 곡 2" } != nil, "칸이 다른 곡의 값으로 바뀌었다")
        #expect(await waitForState(safetyNet: .seconds(90)) { !model.hasPendingInput }, "사라진 칸의 대기는 풀린다")
        #expect(store.tags.tagCell(a, .title) == "고친 제목", "입력한 값은 처음 고른 곡에 확정된다(대상은 시작할 때 고정했다)")
        #expect(store.tags.tagCell(b, .title) == "합성 곡 2")
    }

    /// 조건을 만족하는 입력 칸이 보일 때까지 기다린다(상태로 판정한다)
    func waitForField(in view: NSView, where condition: (NSTextField) -> Bool) async -> NSTextField? {
        var found: NSTextField?
        _ = await waitForState(safetyNet: .seconds(90)) {
            view.window?.contentView?.layoutSubtreeIfNeeded()
            found = fields(in: view).first(where: condition)
            return found != nil
        }
        return found
    }
}
