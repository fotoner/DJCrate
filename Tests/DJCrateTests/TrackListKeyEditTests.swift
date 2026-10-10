@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 곡 목록의 키 칸(#204): 키 초안을 다른 태그 칸처럼 보이고, 태그 시트처럼 없음·Camelot 24개 메뉴로만 고친다.
@Suite("곡 목록 키 초안·고르기")
@MainActor
struct TrackListKeyEditTests {
    @Test func 키_초안은_목록에_값과_표식으로_보이고_되돌리면_원래_값이다() throws {
        let row = MusicalKeyEditingTests.row("1", key: "5A")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        let cell = try #require(h.cell(row: 0, column: "key"))
        #expect(cell.text == "5A" && !cell.showsDraftMark)
        h.store.tags.setTag(.musicalKey, "8A", rows: [row])
        h.coordinator.updateTagRevision(h.store.tagRevision)
        #expect(cell.text == "8A" && cell.showsDraftMark)
        #expect(cell.label.accessibilityValue() == "8A, 초안")
        h.undo.undo()
        h.coordinator.updateTagRevision(h.store.tagRevision)
        #expect(cell.text == "5A" && !cell.showsDraftMark)
        h.store.tags.setTag(.musicalKey, "", rows: [row])
        h.coordinator.updateTagRevision(h.store.tagRevision)
        #expect(cell.text.isEmpty && cell.showsDraftMark)
    }

    @Test func 추가한_곡은_키를_고르기_전까지_다른_초안이_있어도_추정_표시를_유지한다() throws {
        var row = MusicalKeyEditingTests.row("1", key: "8A", staged: true)
        row.keyEstimated = true
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        h.store.tags.setTag(.title, "새 제목", rows: [row])
        h.coordinator.updateTagRevision(h.store.tagRevision)
        let cell = try #require(h.cell(row: 0, column: "key"))
        #expect(cell.text == "8A" && !cell.showsDraftMark)
        #expect(cell.label.accessibilityValue() == "8A, 추정")
        // 추가한 곡의 기준 키는 빈칸이라 메뉴는 "없음"에 체크한다(제안은 고른 값이 아니다, #5)
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        #expect(menu.items.first { $0.state == .on }?.title == "없음")
        try choose("8A", menu: menu)
        #expect(h.store.tags.confirmedStagedKey(uuid: row.track.uuid) == "8A")
        #expect(cell.text == "8A" && cell.showsDraftMark)
        #expect(cell.label.accessibilityValue() == "8A, 초안")
    }

    /// 덱 제안 줄의 [적용]으로 생긴 키 초안도 목록 칸에 초안으로 보인다.
    @Test func 덱_제안_적용으로_생긴_키_초안도_목록에_보인다() throws {
        let suite = TestDefaults.suiteName("list-key-suggestion")
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.open(suite), persist: false), saveTagDrafts: { _ in })
        let row = MusicalKeyEditingTests.row("1")
        let h = ListHarness(rows: [row], selection: [row.id], store: store, showKey: true)
        defer { h.close() }
        let cell = try #require(h.cell(row: 0, column: "key"))
        #expect(cell.text.isEmpty && !cell.showsDraftMark)
        store.tags.applyKeySuggestion(estimate: "8B", rows: [row])
        h.coordinator.updateTagRevision(store.tagRevision)
        #expect(cell.text == "8B" && cell.showsDraftMark)
    }

    // MARK: - 여는 길

    @Test func Return은_키_칸을_누른_뒤에만_키_메뉴를_열고_취소는_초안을_만들지_않는다() throws {
        let row = MusicalKeyEditingTests.row("1", key: "Em")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        var opened: NSMenu?
        h.coordinator.presentKeyMenu = { menu, _, _ in opened = menu }
        // 키 칸을 누르지 않았으면 Return은 지금처럼 보이는 첫 글자 칸(제목)을 고친다(#88)
        h.pressReturn()
        #expect(opened == nil && h.coordinator.editingColumn == "title")
        h.command(#selector(NSResponder.cancelOperation(_:)))
        h.click(row: 0, column: "key")
        h.pressReturn()
        let menu = try #require(opened)
        #expect(h.editor == nil && !h.coordinator.isEditing)
        #expect(h.store.tagDrafts.isEmpty && !h.undo.canUndo)
        #expect(menu.items.filter(\.isEnabled).map(\.title) == ["없음"] + KeyNotation.camelotNames)
        // 옛 표기는 지금 값으로 보이기만 하고 고를 수 없다(태그 시트와 같다)
        #expect(menu.items.first?.title == "Em" && menu.items.first?.isEnabled == false && menu.items.first?.state == .on)
        h.coordinator.cancelEditing()
        #expect(h.store.tagDrafts.isEmpty && h.window.firstResponder === h.table)
        try choose("8A", menu: menu)
        #expect(h.store.tags.tagCell(row, .musicalKey) == "8A")
        // 다른 칸을 누르면 Return은 다시 제목부터다
        opened = nil
        h.click(row: 0, column: "artist")
        h.pressReturn()
        #expect(opened == nil && h.coordinator.editingColumn == "title")
        h.command(#selector(NSResponder.cancelOperation(_:)))
    }

    /// 키 칸을 누른 기억은 그 줄에서만 쓴다. ↓로 다른 줄에 간 Return은 #88대로 제목을 고친다.
    @Test func 키_칸을_누른_뒤_다른_줄로_옮기면_Return은_제목을_고친다() throws {
        let rows = (1...3).map { MusicalKeyEditingTests.row("\($0)", key: "5A") }
        let h = ListHarness(rows: rows, selection: [rows[0].id], showKey: true)
        defer { h.close() }
        var opened: NSMenu?
        h.coordinator.presentKeyMenu = { menu, _, _ in opened = menu }
        h.click(row: 0, column: "key")
        #expect(h.coordinator.clickedCell == .init(rowID: rows[0].id, column: "key"))
        h.pressDown()
        #expect(h.table.selectedRowIndexes == IndexSet(integer: 1))
        h.pressReturn()
        #expect(opened == nil && h.coordinator.editingColumn == "title")
        h.command(#selector(NSResponder.cancelOperation(_:)))
        // 눌렀던 줄로 되돌아와도 키보드로 옮긴 뒤라 기억은 지워졌다
        h.pressUp()
        #expect(h.table.selectedRowIndexes == IndexSet(integer: 0) && h.coordinator.clickedCell == nil)
        h.pressReturn()
        #expect(opened == nil && h.coordinator.editingColumn == "title")
        h.command(#selector(NSResponder.cancelOperation(_:)))
    }

    // MARK: - 고른 줄 안에서 누른 줄이 Return 대상이다

    /// 여러 줄을 고른 채 아래쪽 줄의 키 칸을 ⌘-클릭하면(그 줄이 선택에 더해진다) Return은 첫 줄이 아니라 그 줄에서 키 메뉴를 연다.
    @Test func 여러_줄을_고른_채_아래쪽_줄의_키_칸을_누르면_Return이_그_줄에서_키_메뉴를_열고_고른_곡_모두에_넣는다() throws {
        let rows = (1...4).map { MusicalKeyEditingTests.row("\($0)", key: "5A") }
        let h = ListHarness(rows: rows, selection: [rows[0].id, rows[1].id], showKey: true)
        defer { h.close() }
        var opened: (menu: NSMenu, point: NSPoint)?
        h.coordinator.presentKeyMenu = { menu, point, _ in opened = (menu, point) }
        commandClick(h, row: 3, column: "key")
        #expect(h.table.selectedRowIndexes == IndexSet([0, 1, 3]))
        h.pressReturn()
        let shown = try #require(opened)
        let keyColumn = try #require(h.table.tableColumns.firstIndex { $0.identifier.rawValue == "key" })
        let rect = h.table.frameOfCell(atColumn: keyColumn, row: 3)
        #expect(shown.point == NSPoint(x: rect.minX, y: rect.maxY))
        #expect(h.coordinator.editingColumn == nil && h.editor == nil)
        try choose("8A", menu: shown.menu)
        #expect([0, 1, 3].allSatisfy { h.store.tags.tagCell(rows[$0], .musicalKey) == "8A" })
        #expect(h.store.tags.tagCell(rows[2], .musicalKey) == "5A")
    }

    /// 누른 줄이 선택에서 빠지면 기억도 지워져 Return은 고른 줄 중 첫 곡의 보이는 첫 글자 칸이다.
    @Test func 누른_줄을_선택에서_빼면_Return은_첫_줄의_첫_글자_칸을_고친다() throws {
        let rows = (1...4).map { MusicalKeyEditingTests.row("\($0)", key: "5A") }
        let h = ListHarness(rows: rows, selection: [rows[0].id, rows[1].id], showKey: true)
        defer { h.close() }
        var opened = 0
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        commandClick(h, row: 3, column: "key")
        h.table.deselectRow(3)
        #expect(h.table.selectedRowIndexes == IndexSet([0, 1]) && h.coordinator.clickedCell == nil)
        h.pressReturn()
        #expect(opened == 0 && h.coordinator.editingColumn == "title")
        #expect(h.field?.isDescendant(of: try #require(h.cell(row: 0, column: "title"))) == true)
        h.command(#selector(NSResponder.cancelOperation(_:)))
    }

    /// 아래쪽 줄의 글자 칸을 누르고 Return하면 키 메뉴가 아니라 그 줄의 보이는 첫 글자 칸이다(칸 규칙은 `firstColumn`).
    @Test func 여러_줄을_고른_채_아래쪽_줄의_글자_칸을_누르면_Return이_그_줄의_첫_글자_칸을_고친다() throws {
        let rows = (1...4).map { MusicalKeyEditingTests.row("\($0)", key: "5A") }
        let h = ListHarness(rows: rows, selection: [rows[0].id, rows[1].id], showKey: true)
        defer { h.close() }
        var opened = 0
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        commandClick(h, row: 3, column: "artist")
        h.pressReturn()
        #expect(opened == 0 && h.coordinator.editingColumn == "title")
        #expect(h.field?.isDescendant(of: try #require(h.cell(row: 3, column: "title"))) == true)
        // 고른 곡 모두가 대상이다(인스펙터 여러 곡 편집과 같다)
        h.type("새 제목")
        h.command(#selector(NSResponder.insertNewline(_:)))
        #expect([0, 1, 3].allSatisfy { h.store.tags.tagCell(rows[$0], .title) == "새 제목" })
        #expect(h.store.tags.tagCell(rows[2], .title) == rows[2].track.title)
    }

    /// 누른 줄이 스트리밍·USB 곡이면 고칠 수 없으니 지금처럼 고른 줄 중 첫 곡의 보이는 첫 글자 칸이다.
    @Test func 누른_줄이_스트리밍이나_USB_곡이면_Return은_고칠_수_있는_첫_줄의_글자_칸을_고친다() throws {
        let a = MusicalKeyEditingTests.row("1", key: "5A")
        let streaming = MusicalKeyEditingTests.row("s", streaming: true)
        let usb = MusicalKeyEditingTests.row(UsbLibraryRows.idPrefix + "u", key: "6A")
        let rows = [a, streaming, usb]
        let h = ListHarness(rows: rows, selection: [a.id], showKey: true)
        defer { h.close() }
        var opened = 0
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        for index in [1, 2] {
            commandClick(h, row: index, column: "key")
            #expect(h.coordinator.clickedCell == .init(rowID: rows[index].id, column: "key"), "\(index)")
            h.pressReturn()
            #expect(opened == 0 && h.coordinator.editingColumn == "title", "\(index)")
            #expect(h.field?.isDescendant(of: try #require(h.cell(row: 0, column: "title"))) == true, "\(index)")
            h.command(#selector(NSResponder.cancelOperation(_:)))
            h.table.deselectRow(index)
        }
    }

    /// ⌘-클릭처럼 누른 줄을 기존 선택에 더한다(`ListHarness.click`은 그 줄 하나만 고른다).
    private func commandClick(_ h: ListHarness, row: Int, column: String) {
        guard let index = h.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column }) else { return }
        let rect = h.table.frameOfCell(atColumn: index, row: row)
        h.table.noteClick(at: NSPoint(x: rect.midX, y: rect.midY))
        h.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
    }

    @Test func 같은_줄을_다시_누르면_키_메뉴를_열고_글자_칸을_누르면_다시_제목부터다() throws {
        let rows = (1...2).map { MusicalKeyEditingTests.row("\($0)", key: "5A") }
        let h = ListHarness(rows: rows, selection: [rows[1].id], showKey: true)
        defer { h.close() }
        var opened = 0
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        h.click(row: 1, column: "key")
        h.pressReturn()
        #expect(opened == 1 && !h.coordinator.isEditing)
        // 다른 줄의 키 칸을 누르면 기억도 그 줄로 옮겨 간다
        h.click(row: 0, column: "key")
        h.pressReturn()
        #expect(opened == 2)
        h.click(row: 0, column: "artist")
        h.pressReturn()
        #expect(opened == 2 && h.coordinator.editingColumn == "title")
        h.command(#selector(NSResponder.cancelOperation(_:)))
    }

    @Test func 같은_줄로_다시_그려도_기억은_남고_줄이_바뀌면_지워진다() throws {
        let rows = (1...2).map { MusicalKeyEditingTests.row("\($0)", key: "5A") }
        let h = ListHarness(rows: rows, selection: [rows[0].id], showKey: true)
        defer { h.close() }
        var opened = 0
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        h.click(row: 0, column: "key")
        // 클릭이 바꾼 선택으로 SwiftUI가 다시 그려도(같은 줄·같은 선택) 기억은 그대로다
        h.coordinator.update(rows: rows, edited: [], selection: [rows[0].id], sortOrder: [], snapshotURL: nil, previewRevision: 0)
        #expect(h.coordinator.clickedCell == .init(rowID: rows[0].id, column: "key"))
        h.pressReturn()
        #expect(opened == 1)
        // 줄이 바뀌면(필터·검색·정렬·소스 전환·새 스냅샷) 같은 줄이 남아 있어도 지운다
        h.coordinator.update(rows: rows.reversed(), edited: [], selection: [rows[0].id], sortOrder: [], snapshotURL: nil, previewRevision: 0)
        #expect(h.coordinator.clickedCell == nil)
        h.pressReturn()
        #expect(opened == 1 && h.coordinator.editingColumn == "title")
        h.command(#selector(NSResponder.cancelOperation(_:)))
    }

    @Test func 스토어가_선택을_옮기거나_USB_목록을_오가면_기억을_지운다() throws {
        let rows = (1...2).map { MusicalKeyEditingTests.row("\($0)", key: "5A") }
        let h = ListHarness(rows: rows, selection: [rows[0].id], showKey: true)
        defer { h.close() }
        h.click(row: 0, column: "key")
        // 검색 창에서 돌아오듯 스토어가 다른 줄을 고르게 하면 지운다
        h.coordinator.update(rows: rows, edited: [], selection: [rows[1].id], sortOrder: [], snapshotURL: nil, previewRevision: 0)
        #expect(h.table.selectedRowIndexes == IndexSet(integer: 1) && h.coordinator.clickedCell == nil)
        h.click(row: 1, column: "key")
        h.coordinator.updateUsbMode(true)
        #expect(h.coordinator.clickedCell == nil)
        h.coordinator.updateUsbMode(false)
        h.click(row: 1, column: "key")
        #expect(h.coordinator.clickedCell != nil)
        h.coordinator.tableView(h.table, sortDescriptorsDidChange: [])
        #expect(h.coordinator.clickedCell == nil)
    }

    /// 글자 칸이 하나도 보이지 않아도 키 칸을 누르지 않았으면 Return은 키 메뉴를 열지 않는다.
    @Test func 글자_칸이_모두_숨겨져도_키_칸을_누르기_전에는_Return이_메뉴를_열지_않는다() throws {
        let row = MusicalKeyEditingTests.row("1", key: "5A")
        let h = ListHarness(rows: [row], selection: [row.id], hidden: ["title", "album", "artist", "comment"], showKey: true)
        defer { h.close() }
        var opened = 0
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        #expect(!h.coordinator.beginEditingSelection())
        h.pressReturn()
        #expect(opened == 0 && !h.coordinator.isEditing)
        h.click(row: 0, column: "key")
        h.pressReturn()
        #expect(opened == 1)
    }

    /// mouseDown이 쓰는 점 → 칸 이름 변환: 숨긴 칸과 옮긴 칸이 있어도 칸 번호가 아니라 이름으로 잇는다.
    /// (진짜 mouseDown은 mouseUp까지 기다리는 추적 루프라 부르지 않는다. 이벤트 좌표 변환·추적 루프는 이 시험 밖이다.)
    @Test func 누른_점은_숨긴_칸과_옮긴_칸이_있어도_칸_이름으로_기억한다() throws {
        let rows = (1...2).map { MusicalKeyEditingTests.row("\($0)", key: "5A") }
        let h = ListHarness(rows: rows, selection: [], hidden: ["album"], showKey: true)
        defer { h.close() }
        let ids = h.table.tableColumns.map(\.identifier.rawValue)
        h.table.moveColumn(try #require(ids.firstIndex(of: "key")), toColumn: try #require(ids.firstIndex(of: "title")))
        func center(row: Int, column: String) throws -> NSPoint {
            let index = try #require(h.table.tableColumns.firstIndex { $0.identifier.rawValue == column })
            let rect = h.table.frameOfCell(atColumn: index, row: row)
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        for column in ["key", "title", "artist", "comment"] {
            h.table.noteClick(at: try center(row: 1, column: column))
            #expect(h.coordinator.clickedCell == .init(rowID: rows[1].id, column: column), "\(column)")
        }
        // 칸이나 줄 밖을 누르면 잊는다
        h.table.noteClick(at: NSPoint(x: -5, y: 10))
        #expect(h.coordinator.clickedCell == nil)
        h.table.noteClick(at: try center(row: 1, column: "key"))
        h.table.noteClick(at: NSPoint(x: 10, y: 5000))
        #expect(h.coordinator.clickedCell == nil)
    }

    @Test func Tab은_키_칸에서_메뉴를_열지_않고_다음_글자_칸으로_간다() {
        let row = MusicalKeyEditingTests.row("1", key: "5A")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        var opened = 0
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        #expect(h.coordinator.beginEditing(row: 0, column: "artist"))
        h.command(#selector(NSResponder.insertTab(_:)))
        #expect(opened == 0 && h.coordinator.editingColumn == "comment")
        h.command(#selector(NSResponder.insertBacktab(_:)))
        #expect(opened == 0 && h.coordinator.editingColumn == "artist")
        h.command(#selector(NSResponder.cancelOperation(_:)))
        #expect(h.store.tagDrafts.isEmpty)
    }

    /// 고른 줄을 다시 눌러 고치기(#88)는 글자 칸만이다. 키 칸은 메뉴라 클릭 한 번에 저절로 열지 않는다.
    @Test func 다시_누르기는_키_칸에서_메뉴를_예약하지_않는다() {
        let row = MusicalKeyEditingTests.row("1")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        h.coordinator.scheduleEdit(row: 0, column: "key", after: .milliseconds(20))
        #expect(!h.coordinator.hasPendingEdit)
        h.coordinator.scheduleEdit(row: 0, column: "title", after: .seconds(60))
        #expect(h.coordinator.hasPendingEdit)
        h.coordinator.cancelPendingEdit()
    }

    @Test func 키_더블클릭은_메뉴를_열고_다른_칸과_고칠_수_없는_곡은_덱에_올린다() {
        let row = MusicalKeyEditingTests.row("1")
        let s = MusicalKeyEditingTests.row("s", streaming: true)
        let h = ListHarness(rows: [row, s], selection: [row.id], showKey: true)
        defer { h.close() }
        var opened = 0
        var loaded: [String?] = []
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        h.store.onLoadToDeck = { loaded.append($0?.track.id) }
        h.coordinator.doubleClicked(row: 0, column: "key")
        #expect(opened == 1 && loaded.isEmpty && h.store.tagDrafts.isEmpty)
        h.coordinator.doubleClicked(row: 0, column: "title")
        #expect(opened == 1 && loaded == [row.track.id])
        // 키를 고칠 수 없는 곡(스트리밍·USB)은 경고 대신 다른 칸처럼 덱에 올린다
        h.coordinator.doubleClicked(row: 1, column: "key")
        #expect(opened == 1 && loaded == [row.track.id, s.track.id] && h.store.staging.stagingMessage == nil)
    }

    // MARK: - 고르기 규칙

    @Test func 여러_곡의_키는_선택할_때만_한번에_바꾸고_실행_취소와_복귀를_지원한다() throws {
        let a = MusicalKeyEditingTests.row("1", key: "5A")
        let b = MusicalKeyEditingTests.row("2", key: "8A")
        let s = MusicalKeyEditingTests.row("s", streaming: true)
        let usb = MusicalKeyEditingTests.row(UsbLibraryRows.idPrefix + "u", key: "6A")
        let h = ListHarness(rows: [a, b, s, usb], selection: [a.id, b.id, s.id, usb.id], showKey: true)
        defer { h.close() }
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        // 값이 서로 다르면 어느 항목에도 체크하지 않는다
        #expect(menu.items.allSatisfy { $0.state == .off })
        #expect(h.store.tagDrafts.isEmpty)
        try choose("없음", menu: menu)
        #expect(h.store.tags.tagCell(a, .musicalKey).isEmpty && h.store.tags.tagCell(b, .musicalKey).isEmpty)
        #expect(h.store.tagDrafts.count == 2)
        #expect(h.store.tagDrafts[s.track.uuid] == nil && h.store.tagDrafts[usb.track.uuid] == nil)
        h.undo.undo()
        #expect(h.store.tagDrafts.isEmpty && !h.undo.canUndo)
        h.undo.redo()
        #expect(h.store.tagDrafts.count == 2)
        let single = try #require(h.coordinator.keyMenu(row: 1))
        try choose("12B", menu: single)
        #expect(h.store.tags.tagCell(a, .musicalKey) == "12B" && h.store.tags.tagCell(b, .musicalKey) == "12B")
        // 고른 줄 밖을 누르면 그 곡 하나만
        h.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let outside = try #require(h.coordinator.keyMenu(row: 1))
        try choose("3A", menu: outside)
        #expect(h.store.tags.tagCell(a, .musicalKey) == "12B" && h.store.tags.tagCell(b, .musicalKey) == "3A")
    }

    /// 메뉴를 연 사이 줄이 바뀌어도(빠짐·순서 바뀜) 줄 ID로 다시 찾아 지금 있는 대상에만 넣는다.
    @Test func 메뉴를_연_사이_줄이_바뀌어도_줄_ID로_다시_찾아_있는_곡에만_넣는다() throws {
        let rows = (1...4).map { MusicalKeyEditingTests.row("\($0)", key: "5A") }
        let h = ListHarness(rows: rows, selection: [rows[0].id, rows[1].id, rows[3].id], showKey: true)
        defer { h.close() }
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        // 1번 줄이 빠지고 순서가 뒤집힌 새 목록
        h.coordinator.update(rows: [rows[3], rows[2], rows[1]], edited: [], selection: [], sortOrder: [], snapshotURL: nil, previewRevision: 0)
        try choose("9B", menu: menu)
        #expect(h.store.tagDrafts.keys.sorted() == [rows[1].track.uuid, rows[3].track.uuid].sorted())
        #expect(h.store.tags.tagCell(rows[1], .musicalKey) == "9B" && h.store.tags.tagCell(rows[3], .musicalKey) == "9B")
        #expect(h.store.tags.tagCell(rows[0], .musicalKey) == "5A" && h.store.tags.tagCell(rows[2], .musicalKey) == "5A")
    }

    @Test func 읽기_전용_곡과_쓰기_중에는_메뉴와_선택을_막는다() throws {
        let a = MusicalKeyEditingTests.row("1")
        let s = MusicalKeyEditingTests.row("s", streaming: true)
        let usb = MusicalKeyEditingTests.row(UsbLibraryRows.idPrefix + "u")
        let h = ListHarness(rows: [a, s, usb], selection: [a.id], showKey: true)
        defer { h.close() }
        var opened = 0
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        let rows = [a, s, usb]
        for index in [1, 2] {
            #expect(h.coordinator.keyMenu(row: index) == nil)
            h.store.staging.stagingMessage = nil
            #expect(!h.coordinator.beginEditing(row: index, column: "key"))
            #expect(h.store.staging.stagingMessage?.text == KeyPicker.unavailableReason(rows[index]))
        }
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        h.store.isWritingRekordbox = true
        #expect(h.coordinator.keyMenu(row: 0) == nil)
        #expect(!h.coordinator.beginEditing(row: 0, column: "key"))
        try choose("8A", menu: menu)
        #expect(h.store.tagDrafts.isEmpty && opened == 0)
    }

    @Test func 메뉴는_Camelot만_고를_수_있고_같은_값은_초안을_만들지_않는다() throws {
        let row = MusicalKeyEditingTests.row("1", key: "5A")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        #expect(menu.items.filter(\.isEnabled).count == 25)
        for item in menu.items where item.isEnabled {
            #expect(item.title == "없음" || KeyNotation.camelotNames.contains(item.title))
        }
        #expect(menu.items.first { $0.state == .on }?.title == "5A")
        try choose("5A", menu: menu)
        #expect(h.store.tagDrafts.isEmpty && !h.undo.canUndo)
        // 목록에는 글자 입력 칸이 열리지 않는다
        h.coordinator.presentKeyMenu = { _, _, _ in }
        #expect(h.coordinator.beginEditing(row: 0, column: "key"))
        #expect(h.editor == nil && h.coordinator.editingColumn == nil)
    }

    // MARK: - 다른 입력

    /// 메뉴 추적은 AppKit의 별도 루프라 덱 단축키 모니터에 키가 오지 않는다. 그래서 키 전달 규칙은 바꾸지 않는다:
    /// 메뉴를 여는 동안·닫은 뒤 모두 목록이 첫 응답자이고 포커스는 곡 목록 그대로다.
    @Test func 키_메뉴는_키_전달_규칙을_바꾸지_않고_닫으면_목록이_포커스를_가진다() throws {
        let row = MusicalKeyEditingTests.row("1")
        let h = ListHarness(rows: [row], selection: [row.id], showKey: true)
        defer { h.close() }
        var during: (KeyRoutingPolicy.Focus, Bool)?
        h.coordinator.presentKeyMenu = { [unowned h] _, _, _ in
            during = (KeyRouter.focus(in: h.window), h.coordinator.isEditing)
        }
        #expect(h.coordinator.beginEditing(row: 0, column: "key"))
        #expect(during?.0 == .trackList && during?.1 == true)
        #expect(!h.coordinator.isEditing && h.window.firstResponder === h.table)
        #expect(KeyRouter.focus(in: h.window) == .trackList)
        for key in KeyRoutingTests.deckKeys {
            #expect(KeyRoutingPolicy.accepts(key, in: .init(focus: .trackList)))
        }
        // 고른 뒤에도 같다
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        try choose("1B", menu: menu)
        #expect(h.window.firstResponder === h.table && KeyRouter.focus(in: h.window) == .trackList)
    }

    @Test func 키_정렬은_다른_태그_칸처럼_초안_전_값을_쓴다() throws {
        let a = MusicalKeyEditingTests.row("1", key: "1A"), b = MusicalKeyEditingTests.row("2", key: "8A")
        let h = ListHarness(rows: [a, b], selection: [a.id], showKey: true)
        defer { h.close() }
        h.store.tags.setTag(.musicalKey, "12B", rows: [a])
        let sort = try #require(TrackColumn.comparator(key: "key", ascending: true))
        #expect([b, a].sorted(using: sort).map(\.id) == [a.id, b.id])
        #expect(TrackColumn.sortKey(of: sort.keyPath) == "key")
        // 제목도 초안 전 값으로 정렬한다(같은 규칙)
        h.store.tags.setTag(.title, "가", rows: [b])
        let title = try #require(TrackColumn.comparator(key: "title", ascending: true))
        #expect([b, a].sorted(using: title).map(\.id) == [a.id, b.id])
    }

    private func choose(_ title: String, menu: NSMenu) throws {
        let item = try #require(menu.items.first { $0.title == title && $0.isEnabled })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }
}
