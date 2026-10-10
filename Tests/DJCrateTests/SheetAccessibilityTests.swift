@testable import DJCrate
import AppKit
import DJCDomain
import Testing

@Suite("태그 시트 접근성")
@MainActor
struct SheetAccessibilityTests {
    @Test func 일괄_편집은_실제로_바뀐_칸만_알리고_같은_값과_쓰기_잠금은_알리지_않는다() {
        let h = SheetAccessibilityHarness()
        var announcements: [String] = []
        h.coordinator.announce = { announcements.append($0) }
        h.coordinator.select(.init(row: 0, column: 1), extend: false)
        h.coordinator.select(.init(row: 2, column: 1), extend: true)
        h.coordinator.fillDown()
        #expect(announcements == ["1칸 바뀜"])
        #expect(h.store.tags.tagCell(h.coordinator.rows[1], .title) == "A")
        #expect(h.store.tags.tagCell(h.coordinator.rows[2], .title) == "C")
        h.coordinator.fillDown()
        #expect(announcements.count == 1)
        h.store.isWritingRekordbox = true
        h.coordinator.clearSelection()
        #expect(announcements.count == 1)
        h.store.isWritingRekordbox = false
        h.coordinator.clearSelection()
        #expect(announcements == ["1칸 바뀜", "2칸 바뀜"])
    }

    @Test func 셀_범위가_AppKit의_선택_줄과_선택_칸에_반영된다() throws {
        let h = SheetAccessibilityHarness()
        h.coordinator.select(.init(row: 0, column: 1), extend: false)
        h.coordinator.select(.init(row: 1, column: 2), extend: true)
        #expect(h.table.selectedRowIndexes == IndexSet(integersIn: 0...1))
        let cells = try #require(h.table.accessibilitySelectedCells())
        #expect(cells.count == 4)
        h.coordinator.selectAll()
        #expect(h.table.selectedRowIndexes == IndexSet(integersIn: 0...2))
        #expect(h.table.accessibilitySelectedCells()?.count == 3 * SheetColumn.all.count)
        h.coordinator.update(rows: [], revision: 1)
        #expect(h.table.selectedRowIndexes.isEmpty)
        #expect(h.table.accessibilitySelectedCells()?.isEmpty == true)
    }

    @Test func 선택한_칸은_머리글과_초안_값을_함께_읽는다() throws {
        let h = SheetAccessibilityHarness()
        let row = h.coordinator.rows[0]
        h.store.tags.applyTagEdits([(row, .title, "새 제목")])
        h.coordinator.update(rows: h.coordinator.rows, revision: h.store.tagRevision)
        let cell = try #require(h.coordinator.tableView(h.table, viewFor: h.table.tableColumns[1], row: 0) as? SheetCell)
        #expect(cell.label.accessibilityLabel() == "제목")
        let value = cell.label.accessibilityValue()
        #expect(value == "새 제목, 초안")
    }

    @Test func Control_Tab은_셀을_움직이지_않고_표_밖으로_나간다() throws {
        _ = NSApplication.shared
        let h = SheetAccessibilityHarness()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let before = NSTextField(string: "이전"), after = NSTextField(string: "다음")
        window.contentView?.addSubview(before)
        window.contentView?.addSubview(h.table)
        window.contentView?.addSubview(after)
        window.autorecalculatesKeyViewLoop = false
        before.nextKeyView = h.table
        h.table.nextKeyView = after
        after.nextKeyView = before
        let cursor = h.coordinator.cursor
        for backward in [false, true] {
            window.makeFirstResponder(h.table)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                    modifierFlags: backward ? [.control, .shift] : [.control],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    characters: backward ? "\u{19}" : "\t", charactersIgnoringModifiers: "\t",
                                                    isARepeat: false, keyCode: 48))
            h.table.keyDown(with: event)
            let expected = backward ? before : after
            #expect((window.firstResponder as? NSTextView)?.delegate === expected)
            #expect(h.coordinator.cursor == cursor)
        }
    }
}

@MainActor
private final class SheetAccessibilityHarness {
    let store = LibraryStore.test(saveTagDrafts: { _ in })
    let coordinator: SheetCoordinator
    let table = SheetTableView(frame: .init(x: 0, y: 40, width: 660, height: 300))

    init() {
        coordinator = SheetCoordinator(store: store)
        table.coordinator = coordinator
        table.delegate = coordinator
        table.dataSource = coordinator
        table.allowsMultipleSelection = true
        for spec in SheetColumn.all {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.title = spec.title
            table.addTableColumn(column)
        }
        coordinator.table = table
        coordinator.update(rows: [TrackListTagEditTests.row("1", title: "A"),
                                  TrackListTagEditTests.row("2", title: "B"),
                                  TrackListTagEditTests.row("3", title: "C", streaming: true)], revision: 0)
    }
}
