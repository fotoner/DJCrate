@testable import DJCrate
import AppKit
import DJCDomain
import SwiftUI
import Testing

/// 태그 시트의 열은 화면 위치가 아니라 이름(identifier)으로 찾는다. 표는 열 배치를 저장해 되살리고(`autosaveTableColumns`) 새 열은 맨 끝으로
/// 밀려 오므로, 위치로 찾으면 "코멘트" 칸을 고치는데 키 초안이 생기고 "파일" 칸 붙여넣기가 코멘트 초안을 만든다.
@Suite("태그 시트 — 열은 이름으로 찾는다", .serialized)
@MainActor
struct SheetColumnLookupTests {
    /// 저장된 배치처럼 열을 옮긴 시트: 코멘트·파일·키가 앞으로 와서 `SheetColumn.all` 순서와 화면 순서가 다르다.
    @MainActor
    final class Harness {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let coordinator: SheetCoordinator
        let table = SheetTableView()
        let window: NSWindow

        init(rows: [TrackRow], moved: Bool = true) {
            _ = NSApplication.shared
            coordinator = SheetCoordinator(store: store)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
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
            window.contentView = scroll
            coordinator.update(rows: rows, revision: 0)
            if moved {
                // comment → 1번째, file → 2번째, key → 3번째 자리로
                for (target, id) in ["comment", "file", "key"].enumerated() { move(id, to: target + 1) }
            }
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func column(_ id: String) -> Int { table.column(withIdentifier: .init(id)) }

        func move(_ id: String, to index: Int) {
            table.moveColumn(column(id), toColumn: index)
        }
    }

    static func rows() -> [TrackRow] {
        [TrackListTagEditTests.row("1", title: "곡 하나", comment: "코멘트 하나"),
         TrackListTagEditTests.row("2", title: "곡 둘", comment: "코멘트 둘"),
         MusicalKeyEditingTests.row("3", staged: true)]
    }

    @Test func 열을_옮겨도_화면_열마다_그_열의_칸으로_읽고_편집_가능을_가른다() throws {
        let h = Harness(rows: Self.rows())
        defer { h.window.close() }
        // 화면 순서가 정말 달라졌다
        #expect(h.table.tableColumns.map(\.identifier.rawValue).prefix(4) == ["index", "comment", "file", "key"])
        for (c, tableColumn) in h.table.tableColumns.enumerated() {
            let spec = try #require(SheetColumn.all.first { $0.id == tableColumn.identifier.rawValue })
            for row in 0..<2 {
                #expect(h.coordinator.editableKey(row: row, column: c) == spec.key, "\(spec.id) 줄 \(row)")
                let expected: String = switch spec.id {
                case "index": "\(row + 1)"
                case "file": (h.coordinator.rows[row].track.folderPath as NSString).lastPathComponent
                default: spec.key.map { h.store.tagCell(h.coordinator.rows[row], $0) } ?? ""
                }
                #expect(h.coordinator.text(row: row, column: c) == expected, "\(spec.id) 줄 \(row)")
                let cell = try #require(h.coordinator.tableView(h.table, viewFor: tableColumn, row: row) as? SheetCell)
                #expect(cell.label.stringValue == expected && cell.label.accessibilityLabel() == spec.title, "\(spec.id) 줄 \(row)")
            }
        }
        // 추가한 곡도 옮긴 자리의 키 칸·코멘트 칸을 고친다(키는 넣을 때 함께 쓴다, #5). 읽기 전용 파일 칸은 옮겨도 편집 불가다.
        #expect(h.coordinator.editableKey(row: 2, column: h.column("key")) == .musicalKey)
        #expect(h.coordinator.editableKey(row: 2, column: h.column("comment")) == .comment)
        #expect(h.coordinator.editableKey(row: 2, column: h.column("file")) == nil)
    }

    @Test func 옮긴_열에_붙여넣으면_그_열의_칸에만_초안이_생긴다() throws {
        let h = Harness(rows: Self.rows())
        defer { h.window.close() }
        let first = h.coordinator.rows[0]
        // 코멘트 열(화면 1번째)
        h.coordinator.select(.init(row: 0, column: h.column("comment")), extend: false)
        h.coordinator.paste(string: "새 코멘트")
        var draft = try #require(h.store.tagDrafts[first.track.uuid])
        #expect(draft.changedKeys == [.comment] && draft.fields.comment == "새 코멘트")
        // 파일 열은 읽기 전용이라 아무 칸도 바뀌지 않는다
        h.coordinator.select(.init(row: 0, column: h.column("file")), extend: false)
        h.coordinator.paste(string: "엉뚱한 값")
        draft = try #require(h.store.tagDrafts[first.track.uuid])
        #expect(draft.changedKeys == [.comment] && draft.fields.comment == "새 코멘트")
        // 키 열(화면 3번째): Camelot 이름만 키 초안이 된다
        h.coordinator.select(.init(row: 0, column: h.column("key")), extend: false)
        h.coordinator.paste(string: "8a")
        draft = try #require(h.store.tagDrafts[first.track.uuid])
        #expect(draft.changedKeys == [.comment, .musicalKey] && draft.fields.musicalKey == "8A" && draft.fields.comment == "새 코멘트")
        // 여러 칸 붙여넣기는 시작 칸에서 화면 순서대로 칸을 찾는다: 코멘트·파일·키
        let second = h.coordinator.rows[1]
        h.coordinator.select(.init(row: 1, column: h.column("comment")), extend: false)
        h.coordinator.paste(string: "코멘트 둘 고침\t읽기 전용 무시\t6A")
        let other = try #require(h.store.tagDrafts[second.track.uuid])
        #expect(other.fields.comment == "코멘트 둘 고침" && other.fields.musicalKey == "6A" && other.fields.title == "곡 둘")
    }

    @Test func 옮긴_열에서_아래로_채우면_그_열의_칸만_채운다() throws {
        let h = Harness(rows: Self.rows())
        defer { h.window.close() }
        h.coordinator.select(.init(row: 0, column: h.column("comment")), extend: false)
        h.coordinator.select(.init(row: 1, column: h.column("key")), extend: true)
        h.coordinator.fillDown()
        let second = h.coordinator.rows[1]
        #expect(h.store.tagCell(second, .comment) == "코멘트 하나", "코멘트 열이 채워졌다")
        #expect(h.store.tagCell(second, .title) == "곡 둘" && h.store.tagCell(second, .musicalKey) == "", "제목·키는 그대로(키는 빈칸을 그대로 채워 바뀌지 않는다)")
        #expect(h.store.tagDrafts[second.track.uuid]?.changedKeys == [.comment])
    }

    @Test func 옮긴_열에서_지우기는_고른_열의_칸을_비운다() throws {
        let h = Harness(rows: Self.rows())
        defer { h.window.close() }
        let first = h.coordinator.rows[0]
        h.coordinator.select(.init(row: 0, column: h.column("comment")), extend: false)
        h.coordinator.clearSelection()
        #expect(h.store.tagCell(first, .comment) == "" && h.store.tagCell(first, .title) == "곡 하나")
        #expect(h.store.tagDrafts[first.track.uuid]?.changedKeys == [.comment])
    }

    @Test func 툴팁도_옮긴_열의_이름으로_이유를_고른다() throws {
        let h = Harness(rows: Self.rows())
        defer { h.window.close() }
        func tip(row: Int, id: String) -> String {
            let rect = h.table.frameOfCell(atColumn: h.column(id), row: row)
            return h.table.view(h.table, stringForToolTip: 0, point: NSPoint(x: rect.midX, y: rect.midY), userData: nil)
        }
        // 옮긴 파일 열(읽기 전용)에만 이유가 붙고, 같은 줄의 옮긴 코멘트 칸에는 없다. 추가한 곡(줄 2)의 키 칸도 이제 고를 수 있어 이유가 없다(#5).
        #expect(tip(row: 0, id: "file").contains("읽기 전용"))
        #expect(tip(row: 0, id: "comment") == "코멘트 하나")
        #expect(!tip(row: 2, id: "key").contains("읽기 전용") && !tip(row: 2, id: "key").contains("rekordbox에 넣은 뒤"))
    }

    @Test func 키_고르기_메뉴는_옮긴_키_열에서도_열린다() throws {
        let h = Harness(rows: Self.rows())
        defer { h.window.close() }
        #expect(h.coordinator.keyMenu(row: 0) != nil && h.coordinator.keyMenu(row: 2) != nil, "추가한 곡도 키를 고른다(넣을 때 함께 쓴다)")
        // 편집 시작: 옮긴 키 열은 메뉴, 옮긴 코멘트 열은 글자 편집기
        h.coordinator.select(.init(row: 0, column: h.column("comment")), extend: false)
        h.coordinator.beginEditing()
        #expect(h.coordinator.isEditing)
        h.coordinator.cancelEditing()
    }

    @Test func 표_열_배치를_저장하는_이름을_올려_옛_배치를_되살리지_않는다() throws {
        // 키 열을 더하기 전에 저장한 배치("v1")는 열 순서가 달라 새 열이 맨 끝으로 밀린다. 새 이름으로 시작한다.
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let controller = NSHostingController(rootView: TagSheetView(store: store))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 400))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> SheetTableView? {
            (view as? SheetTableView) ?? view.subviews.lazy.compactMap { find($0) }.first
        }
        let table = try #require(find(controller.view))
        // 평점·곡 색 열(#65)을 더하며 "v3"로 올렸다
        #expect(table.autosaveName == "djc.tagSheet.v3")
        #expect(table.tableColumns.map(\.identifier.rawValue) == SheetColumn.all.map(\.id))
    }
}
