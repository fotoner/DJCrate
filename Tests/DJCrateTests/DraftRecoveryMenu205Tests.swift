@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import Foundation
import Testing

@MainActor
@Suite("현재값 가져오기 문맥 메뉴", .serialized)
struct DraftRecoveryMenu205Tests {
    private final class MenuTable: NSTableView {
        var menuClickedRow = -1
        override var clickedRow: Int { menuClickedRow }
    }

    private func list(_ rows: [TrackRow], selected: IndexSet, clicked: Int = -1) -> (LibraryStore, TrackListCoordinator, MenuTable) {
        _ = NSApplication.shared
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        store.rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.track.id, $0) })
        store.rowsByUUID = Dictionary(uniqueKeysWithValues: rows.map { ($0.track.uuid, $0) })
        let coordinator = TrackListCoordinator(store: store, actions: .live(store: store)), table = MenuTable()
        table.allowsMultipleSelection = true
        table.dataSource = coordinator; table.delegate = coordinator
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        coordinator.table = table
        coordinator.update(rows: rows, edited: [], selection: Set(selected.map { rows[$0].id }), sortOrder: [], snapshotURL: nil, previewRevision: 0)
        table.menuClickedRow = clicked
        return (store, coordinator, table)
    }

    private func draft(_ row: TrackRow, in store: LibraryStore) {
        var draft = TagDraft(track: row.track); draft.fields.comment = "내 편집"
        store.tagDrafts[row.track.uuid] = draft
    }

    @Test func 한_곡은_종류별_항목이고_초안_없는_곡에는_없다() throws {
        let rows = [MusicalKeyEditingTests.row("1"), MusicalKeyEditingTests.row("2")]
        let (store, coordinator, table) = list(rows, selected: [0])
        draft(rows[0], in: store)
        store.draftChanged(trackUUID: rows[0].track.uuid, kind: .cue, exists: true)
        store.draftChanged(trackUUID: rows[0].track.uuid, kind: .grid, exists: true)
        let menu = coordinator.makeMenu(); coordinator.menuNeedsUpdate(menu)
        #expect(DraftRecoveryKind.allCases.allSatisfy { kind in menu.items.contains { $0.title == kind.recoveryButtonTitle && $0.action != nil } })
        table.selectRowIndexes([1], byExtendingSelection: false)
        coordinator.menuNeedsUpdate(menu)
        #expect(!menu.items.contains { $0.title.contains("현재값 가져오기") })
        withExtendedLifetime(table) {}
    }

    @Test func 여러_곡은_곡과_종류_메뉴이고_선택_밖_오른쪽_클릭은_그_곡만_쓴다() throws {
        let rows = [MusicalKeyEditingTests.row("1"), MusicalKeyEditingTests.row("2"), MusicalKeyEditingTests.row("3")]
        let (store, coordinator, table) = list(rows, selected: [0, 1])
        rows.forEach { draft($0, in: store) }
        let menu = coordinator.makeMenu(); coordinator.menuNeedsUpdate(menu)
        let selected = try #require(menu.items.first { $0.title == "선택한 곡 현재값 가져오기…" }?.submenu)
        #expect(selected.items.map(\.title) == rows.prefix(2).map(\.title))
        #expect(selected.items.allSatisfy { $0.submenu?.items.map(\.title) == [DraftRecoveryKind.tags.recoveryButtonTitle] })
        table.menuClickedRow = 2
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.contains { $0.title == DraftRecoveryKind.tags.recoveryButtonTitle })
        #expect(!menu.items.contains { $0.title == "선택한 곡 현재값 가져오기…" })
        withExtendedLifetime(table) {}
    }

    @Test func 선택_밖_덱_곡은_별도_메뉴이고_선택과_같으면_중복하지_않는다() throws {
        let rows = [MusicalKeyEditingTests.row("1"), MusicalKeyEditingTests.row("2")]
        let (store, coordinator, table) = list(rows, selected: [1])
        draft(rows[0], in: store)
        store.loadToDeck(rows[0])
        let menu = coordinator.makeMenu(); coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.first { $0.title == "덱 곡 현재값 가져오기…" }?.submenu?.items.map(\.title) == [DraftRecoveryKind.tags.recoveryButtonTitle])
        table.selectRowIndexes([0], byExtendingSelection: false)
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.contains { $0.title == DraftRecoveryKind.tags.recoveryButtonTitle })
        #expect(!menu.items.contains { $0.title == "덱 곡 현재값 가져오기…" })
        withExtendedLifetime(table) {}
    }

    @Test(arguments: 0..<4)
    func 메뉴는_명시한_곡과_종류만_열고_복구와_쓰기_중에는_열지_않는다(state: Int) throws {
        let row = MusicalKeyEditingTests.row("1")
        let (store, _, table) = list([row], selected: [0])
        draft(row, in: store)
        store.isRecoveringDraft = state == 1
        store.isWritingRekordbox = state == 2
        store.allowsLibrarySync = { state != 3 }
        var opened: [(String, DraftRecoveryKind)] = []
        let recovery = DraftRecoveryMenu(store: store) { row, kind in opened.append((row.track.uuid, kind)) }, menu = NSMenu()
        recovery.append(to: menu, rows: [row])
        let item = try #require(menu.items.first { $0.title == DraftRecoveryKind.tags.recoveryButtonTitle })
        let target = try #require(item.representedObject as? DraftRecoveryMenu.Target)
        #expect(target.row.track.uuid == row.track.uuid && target.kind == .tags)
        #expect(item.isEnabled == (state == 0))
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        #expect(opened.count == (state == 0 ? 1 : 0))
        #expect(opened.first?.0 == (state == 0 ? row.track.uuid : nil))
        #expect(store.tagDrafts[row.track.uuid]?.hasChanges == true)
        withExtendedLifetime(table) {}
    }

    @Test func 태그_시트도_선택_범위와_선택_밖_곡의_복구_메뉴를_보존한다() throws {
        let rows = [MusicalKeyEditingTests.row("1"), MusicalKeyEditingTests.row("2"), MusicalKeyEditingTests.row("3")]
        let (store, _, table) = list(rows, selected: [0, 1])
        rows.forEach { draft($0, in: store) }
        let sheet = SheetCoordinator(store: store)
        sheet.update(rows: rows, revision: 0)
        sheet.anchor = CellPosition(row: 0, column: 1)
        sheet.cursor = CellPosition(row: 1, column: 1)
        let multiple = sheet.contextMenu(forRow: 0)
        #expect(multiple.items.first { $0.title == "선택한 곡 현재값 가져오기…" }?.submenu?.items.count == 2)
        let outside = sheet.contextMenu(forRow: 2)
        let target = try #require(outside.items.first { $0.title == DraftRecoveryKind.tags.recoveryButtonTitle }?.representedObject as? DraftRecoveryMenu.Target)
        #expect(target.row.track.uuid == rows[2].track.uuid)
        withExtendedLifetime(table) {}
    }
}
