@testable import DJCrate
import AppKit
import DJCDomain
import RekordboxFixtures
import SwiftUI
import Testing

@Suite("태그 시트 편집 배치", .serialized)
@MainActor
struct SheetEditingTests {
    // 실제 오류처럼 SwiftUI에 붙인 표를 편집하고 AppKit 배치를 끝까지 수행한다. 창은 표시하지 않는다.
    @Test func 제목_편집_중에도_호스팅_뷰의_배치가_안정된다() async throws {
        _ = NSApplication.shared
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        try fixture.add(TrackSpec(id: "2"))
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let revisionBeforeLoad = store.tagRevision
        await store.load(snapshot: fixture.database)
        #expect(store.tagRevision > revisionBeforeLoad)
        let revisionAfterLoad = store.tagRevision
        let draftsAfterLoad = store.tagDrafts
        let controller = NSHostingController(rootView: TagSheetView(store: store))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 400))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        let table = try #require(findTable(in: controller.view))
        let coordinator = try #require(table.coordinator)
        let tagsAfterLoad = coordinator.rows.map { store.tagDraft(for: $0).fields }
        coordinator.select(.init(row: 1, column: 1), extend: false)
        window.makeFirstResponder(table)
        coordinator.beginEditing()
        #expect(coordinator.isEditing)
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("취소할 제목", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        coordinator.cancelEditing()
        #expect(!coordinator.isEditing)
        #expect(store.tagRevision == revisionAfterLoad)
        #expect(store.tagDrafts == draftsAfterLoad)
        #expect(coordinator.rows.map { store.tagDraft(for: $0).fields } == tagsAfterLoad)
    }

    @Test(arguments: ["더블클릭", "Return", "타이핑"])
    func 편집을_시작해도_덱은_유지하고_Esc는_취소한다(_ entry: String) throws {
        let h = SheetEditingHarness()
        defer { h.window.close() }
        let revisionBeforeEditing = h.store.tagRevision
        let draftsBeforeEditing = h.store.tagDrafts
        var loads: [String?] = []
        h.store.onLoadToDeck = { loads.append($0?.id) }
        h.store.loadToDeck(h.coordinator.rows[0])
        h.coordinator.select(.init(row: 1, column: 1), extend: false)
        switch entry {
        case "더블클릭":
            let rect = h.table.frameOfCell(atColumn: 1, row: 1)
            let point = h.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                      timestamp: 0, windowNumber: h.window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
            h.table.mouseDown(with: event)
        case "Return": h.table.keyDown(with: try h.key("\r", code: 36))
        default: h.table.keyDown(with: try h.key("x", code: 7))
        }
        h.window.contentView?.layoutSubtreeIfNeeded()
        #expect(h.coordinator.isEditing)
        let field = try h.field()
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(field.accessibilityLabel() == "제목")
        #expect(!editor.string.isEmpty)
        editor.insertText("취소할 제목", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        #expect(h.coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        h.window.contentView?.layoutSubtreeIfNeeded()
        #expect(!h.coordinator.isEditing)
        #expect(h.store.tagCell(h.coordinator.rows[1], .title) == "합성 곡 2")
        #expect(h.store.tagRevision == revisionBeforeEditing)
        #expect(h.store.tagDrafts == draftsBeforeEditing)
        #expect(h.store.selection == ["2"])
        #expect(loads == ["1"] && h.store.deckTrackID == "1")
        #expect(h.window.firstResponder === h.table)
    }

    @Test func 일본어_코멘트를_입력해_확정하고_다시_편집을_취소하면_초안을_보존한다() throws {
        let h = SheetEditingHarness()
        defer { h.window.close() }
        let column = try #require(SheetColumn.all.firstIndex { $0.key == .comment })
        let row = h.coordinator.rows[1]
        let title = h.store.tagCell(row, .title)
        let revisionBeforeEditing = h.store.tagRevision
        h.coordinator.select(.init(row: 1, column: column), extend: false)
        h.table.keyDown(with: try h.key("\r", code: 36))
        #expect(h.coordinator.isEditing)
        let field = try h.field()
        let editor = try #require(field.currentEditor() as? NSTextView)
        let comment = "合成コメント 日本語の入力 🎵"
        editor.insertText(comment, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        #expect(editor.string == comment)
        #expect(h.coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        h.coordinator.update(rows: h.coordinator.rows, revision: h.store.tagRevision)
        #expect(!h.coordinator.isEditing)
        #expect(h.store.tagCell(row, .comment) == comment)
        #expect(h.store.tagCell(row, .title) == title)
        let draft = try #require(h.store.tagDrafts[row.track.uuid])
        #expect(draft.changedKeys == [.comment] && draft.fields.comment == comment)
        #expect(h.store.tagRevision > revisionBeforeEditing)

        let revisionAfterCommit = h.store.tagRevision
        let draftsAfterCommit = h.store.tagDrafts
        h.coordinator.select(.init(row: 1, column: column), extend: false)
        h.table.keyDown(with: try h.key("\r", code: 36))
        let reopened = try h.field()
        let reopenedEditor = try #require(reopened.currentEditor() as? NSTextView)
        #expect(reopenedEditor.string == comment)
        reopenedEditor.insertText("取り消す合成コメント", replacementRange: NSRange(location: 0, length: (reopenedEditor.string as NSString).length))
        #expect(h.coordinator.control(reopened, textView: reopenedEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!h.coordinator.isEditing && h.window.firstResponder === h.table)
        #expect(h.store.tagCell(row, .comment) == comment)
        #expect(h.store.tagCell(row, .title) == title)
        #expect(h.store.tagRevision == revisionAfterCommit)
        #expect(h.store.tagDrafts == draftsAfterCommit)
    }

    @Test(arguments: ["Return", "Tab", "Shift+Tab"])
    func 제목을_확정하고_다음_칸으로_이동한_뒤_실행_취소한다(_ command: String) throws {
        let h = SheetEditingHarness()
        defer { h.window.close() }
        let undo = UndoManager()
        h.store.undoManager = undo
        h.coordinator.select(.init(row: 0, column: 1), extend: false)
        h.coordinator.select(.init(row: 1, column: 1), extend: true)
        #expect(h.table.selectedRowIndexes == IndexSet(integersIn: 0...1))
        #expect(h.store.canFillDownTags)
        h.coordinator.beginEditing()
        h.window.contentView?.layoutSubtreeIfNeeded()
        #expect(h.coordinator.anchor == h.coordinator.cursor)
        #expect(!h.store.canFillDownTags)
        let field = try h.field()
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("확정한 제목", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        let selector = command == "Return" ? #selector(NSResponder.insertNewline(_:))
            : command == "Tab" ? #selector(NSResponder.insertTab(_:)) : #selector(NSResponder.insertBacktab(_:))
        #expect(h.coordinator.control(field, textView: editor, doCommandBy: selector))
        h.coordinator.update(rows: h.coordinator.rows, revision: h.store.tagRevision)
        h.window.contentView?.layoutSubtreeIfNeeded()
        #expect(h.store.tagCell(h.coordinator.rows[1], .title) == "확정한 제목")
        #expect(h.store.tagCell(h.coordinator.rows[0], .title) == "합성 곡 1")
        let expected = command == "Return" ? CellPosition(row: 2, column: 1)
            : CellPosition(row: 1, column: command == "Tab" ? 2 : 0)
        #expect(h.coordinator.cursor == expected)
        #expect(!h.coordinator.isEditing && h.window.firstResponder === h.table)
        #expect(undo.canUndo)
        undo.undo()
        #expect(h.store.tagCell(h.coordinator.rows[1], .title) == "합성 곡 2")
        undo.redo()
        #expect(h.store.tagCell(h.coordinator.rows[1], .title) == "확정한 제목")
    }

    @Test func 포커스를_옮기면_긴_제목을_확정하고_입력_칸을_남기지_않는다() throws {
        let h = SheetEditingHarness()
        defer { h.window.close() }
        h.coordinator.select(.init(row: 1, column: 1), extend: false)
        h.coordinator.beginEditing()
        let field = try h.field()
        let editor = try #require(field.currentEditor() as? NSTextView)
        let title = String(repeating: "긴 제목 가로 스크롤 검증 ", count: 8)
        editor.insertText(title, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        h.window.contentView?.layoutSubtreeIfNeeded()
        #expect(field.cell?.isScrollable == true)
        #expect(editor.string == title)
        h.window.makeFirstResponder(h.table)
        #expect(!h.coordinator.isEditing)
        #expect(h.store.tagCell(h.coordinator.rows[1], .title) == title)
        #expect(field.superview == nil)
        h.coordinator.update(rows: h.coordinator.rows, revision: h.store.tagRevision)
        h.coordinator.select(.init(row: 2, column: 1), extend: false)
        h.window.contentView?.layoutSubtreeIfNeeded()
        h.coordinator.beginEditing()
        #expect(try h.field().stringValue == "합성 곡 3")
        h.coordinator.cancelEditing()
        let cell = try #require(h.table.view(atColumn: 1, row: 2, makeIfNecessary: false) as? SheetCell)
        #expect(cell.editingField == nil && !cell.label.isHidden)
    }

    private func findTable(in view: NSView) -> SheetTableView? {
        if let table = view as? SheetTableView { return table }
        return view.subviews.lazy.compactMap { findTable(in: $0) }.first
    }
}

@MainActor
private final class SheetEditingHarness {
    let store = LibraryStore.test(saveTagDrafts: { _ in })
    let coordinator: SheetCoordinator
    let table = SheetTableView()
    let window: NSWindow

    init() {
        _ = NSApplication.shared
        coordinator = SheetCoordinator(store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        table.coordinator = coordinator
        coordinator.table = table
        table.delegate = coordinator
        table.dataSource = coordinator
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for spec in SheetColumn.all {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.width = spec.width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        window.contentView = scroll
        coordinator.update(rows: (1...3).map { TrackListTagEditTests.row(String($0), title: "합성 곡 \($0)") }, revision: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(table)
    }

    func field() throws -> NSTextField {
        let position = coordinator.cursor
        let cell = try #require(table.view(atColumn: position.column, row: position.row, makeIfNecessary: false) as? SheetCell)
        return try #require(cell.editingField)
    }

    func key(_ characters: String, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
