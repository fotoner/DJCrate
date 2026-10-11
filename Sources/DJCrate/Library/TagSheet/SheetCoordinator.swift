import DJCApplication
import DJCDomain
import AppKit
import SwiftUI

@MainActor
final class SheetCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let store: LibraryStore
    private lazy var recoveryMenu = DraftRecoveryMenu(store: store) { [weak self] row, kind in self?.recoverDraft?(row, kind) }
    /// 막힌 초안 복구 시트를 연다(시트 뷰가 환경의 반영 화면 쪽으로 붙인다)
    var recoverDraft: (@MainActor (TrackRow, DraftRecoveryKind) -> Void)?
    weak var table: SheetTableView?
    private(set) var rows: [TrackRow] = []
    private var rowIDs: [TrackRow.ID] = []
    private var revision = -1

    var anchor = CellPosition(row: 0, column: 1)
    var cursor = CellPosition(row: 0, column: 1)
    /// 고치는 칸과 고치기 전 글자(편집 확장이 쓴다)
    var editing: CellPosition?
    var editingOriginal = ""
    private var textScale = 1.0
    private var font = SheetCell.font(scale: 1)
    private var syncingSort = false
    var announce: (String) -> Void = { message in
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    init(store: LibraryStore) {
        self.store = store
    }

    // MARK: - 데이터

    /// 글자 배율(보기 › 글자 크게·작게)이 바뀌면 글자 크기와 줄 높이를 함께 바꾼다.
    func updateTextScale(_ scale: Double) {
        guard scale != textScale, let table else { return }
        textScale = scale
        font = SheetCell.font(scale: scale)
        table.rowHeight = TextScale.length(22, scale: scale)
        reloadVisible()
    }

    func update(rows: [TrackRow], revision: Int) {
        defer { table?.updateFillDownCommand() }
        applySortIndicator()
        let ids = rows.map(\.id)
        if ids != rowIDs {
            // 줄이 바뀌면(필터·정렬·검색) 편집 중인 셀을 먼저 취소한다. 편집 위치가 인덱스라
            // 그대로 확정하면 다른 곡에 들어갈 수 있다.
            if editing != nil { cancelEditing() }
            let anchorID = self.rows.indices.contains(anchor.row) ? self.rows[anchor.row].id : nil
            let cursorID = self.rows.indices.contains(cursor.row) ? self.rows[cursor.row].id : nil
            self.rows = rows
            rowIDs = ids
            self.revision = revision
            // 선택은 곡 ID로 다시 찾는다(없으면 범위 안으로).
            if let cursorID, let index = ids.firstIndex(of: cursorID) { cursor.row = index }
            if let anchorID, let index = ids.firstIndex(of: anchorID) { anchor.row = index } else { anchor = cursor }
            clampSelection()
            table?.reloadData()
            syncAccessibilitySelection(announceFocus: false)
        } else if revision != self.revision {
            self.rows = rows
            self.revision = revision
            reloadVisible()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// 화면 열(표의 열 순서) 수. 표가 열을 만들기 전(시험)에는 열 정의 수다.
    var columnCount: Int {
        let count = table?.tableColumns.count ?? 0
        return count > 0 ? count : SheetColumn.all.count
    }

    /// 화면 열 하나가 가리키는 열 정의. 열은 이름(identifier)으로 찾는다: 표가 열 배치를 저장해 되살리고 사용자가 열을 옮길 수 있어
    /// 화면 위치는 `SheetColumn.all` 순서와 다를 수 있다. 표가 열을 하나도 만들기 전(시험)에만 순서를 쓴다.
    func spec(atColumn column: Int) -> SheetColumn? {
        guard let table, !table.tableColumns.isEmpty else { return SheetColumn.all.indices.contains(column) ? SheetColumn.all[column] : nil }
        guard table.tableColumns.indices.contains(column) else { return nil }
        return SheetColumn.spec(id: table.tableColumns[column].identifier.rawValue)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !syncingSort, let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key, SheetColumn.all.contains(where: { $0.id == key && $0.key != nil }),
              let comparator = TrackColumn.comparator(key: key, ascending: descriptor.ascending) else { return }
        finishEditing(commit: true, then: nil)
        store.sortOrder = [comparator]
    }

    private func applySortIndicator() {
        guard let table else { return }
        let wanted: [NSSortDescriptor] = store.sortOrder.first.flatMap { comparator in
            guard let key = TrackColumn.sortKey(of: comparator.keyPath),
                  SheetColumn.all.contains(where: { $0.id == key && $0.key != nil }) else { return nil }
            return [NSSortDescriptor(key: key, ascending: comparator.order == .forward)]
        } ?? []
        guard table.sortDescriptors != wanted else { return }
        syncingSort = true
        table.sortDescriptors = wanted
        syncingSort = false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = tableView.tableColumns.firstIndex(of: tableColumn),
              let spec = SheetColumn.spec(id: tableColumn.identifier.rawValue) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SheetCell) ?? {
            let cell = SheetCell()
            cell.identifier = identifier
            return cell
        }()
        let position = CellPosition(row: row, column: column)
        cell.font = font
        // 평점은 별 다섯 칸이 칸 자리에 안 들어가면 "5★"로 줄여 보인다(잘린 "★★★…"은 3·4·5가 같아 보인다, #65). VoiceOver는 늘 "별 N개".
        let rating = spec.key == .rating ? store.tags.tagCell(rows[row], .rating) : nil
        cell.configure(text: text(row: row, column: column),
                       edited: spec.key.map { store.tags.isTagEdited(rows[row], $0) } ?? false,
                       readOnly: editableKey(row: row, column: column) == nil,
                       selected: isSelected(position),
                       active: position == cursor,
                       compact: rating.map(TrackRating.compact),
                       spoken: rating.map { TagChoice.spoken(.rating, $0, colors: store.trackColors) })
        cell.label.setAccessibilityLabel(spec.title)
        return cell
    }

    /// 편집 가능한 칸인가. 스트리밍 곡은 파일 태그가 없어 편집하지 않는다.
    func editableKey(row: Int, column: Int) -> TagFields.Key? {
        guard rows.indices.contains(row), !rows[row].track.isStreaming, let key = spec(atColumn: column)?.key else { return nil }
        // 그 칸을 고칠 수 없는 곡(키: USB·스트리밍, 평점·곡 색: 추가한 곡·확인 밖 곡, `TrackListTagEditing.unavailableReason`)은
        // 고르기 메뉴도 열지 않고 붙여넣기·채우기도 건너뛴다
        if TrackListTagEditing.unavailableReason(rows[row], key: key) != nil { return nil }
        return key
    }

    func text(row: Int, column: Int) -> String {
        guard rows.indices.contains(row), let spec = spec(atColumn: column) else { return "" }
        if spec.key == .title, rows[row].isEncrypted { return rows[row].title }
        if let key = spec.key { return TagChoice.display(key, store.tags.tagCell(rows[row], key), colors: store.trackColors) }
        switch spec.id {
        case "index": return "\(row + 1)"
        case "file": return (rows[row].track.folderPath as NSString).lastPathComponent
        default: return ""
        }
    }

    // MARK: - 선택

    var selectionRect: (rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        (min(anchor.row, cursor.row)...max(anchor.row, cursor.row),
         min(anchor.column, cursor.column)...max(anchor.column, cursor.column))
    }

    func isSelected(_ p: CellPosition) -> Bool {
        let rect = selectionRect
        return rect.rows.contains(p.row) && rect.columns.contains(p.column)
    }

    func select(_ position: CellPosition, extend: Bool) {
        defer { table?.updateFillDownCommand() }
        guard !rows.isEmpty else { return }
        let clamped = CellPosition(row: min(max(position.row, 0), rows.count - 1),
                                   column: min(max(position.column, 0), columnCount - 1))
        cursor = clamped
        if !extend { anchor = clamped }
        table?.scrollRowToVisible(clamped.row)
        table?.scrollColumnToVisible(clamped.column)
        reloadVisible()
        // 커서 줄을 고른 곡으로 둔다(태그 편집 창 등이 따라온다). 덱은 불러오기 명령으로만 바꾼다.
        store.selection = [rows[clamped.row].id]
        syncAccessibilitySelection()
    }

    // MARK: - 덱에 불러오기(#93)

    /// ⌘→: 커서 줄의 곡을 덱에 올린다.
    func loadCursorRow() {
        loadRow(cursor.row)
    }

    /// 오른쪽 클릭 메뉴: 누른 줄의 곡을 덱에 올린다.
    func contextMenu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()
        let load = LoadToDeckCommand.menuItem(action: rows.indices.contains(row) ? #selector(loadMenuRow(_:)) : nil, target: self)
        load.tag = row
        menu.addItem(load)
        if rows.indices.contains(row) {
            let targets = selectionRect.rows.contains(row) ? selectionRect.rows.map { rows[$0] } : [rows[row]]
            recoveryMenu.append(to: menu, rows: targets)
        }
        return menu
    }

    @objc private func loadMenuRow(_ sender: NSMenuItem) {
        loadRow(sender.tag)
    }

    private func loadRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        store.loadToDeck(rows[index])
    }

    func move(rows dRow: Int, columns dColumn: Int, extend: Bool) {
        select(CellPosition(row: cursor.row + dRow, column: cursor.column + dColumn), extend: extend)
    }

    func selectAll() {
        defer { table?.updateFillDownCommand() }
        guard !rows.isEmpty else { return }
        anchor = CellPosition(row: 0, column: 0)
        cursor = CellPosition(row: rows.count - 1, column: columnCount - 1)
        reloadVisible()
        syncAccessibilitySelection()
    }

    func syncAccessibilitySelection(announceFocus: Bool = true) {
        guard let table else { return }
        let indexes = rows.isEmpty ? IndexSet() : IndexSet(integersIn: selectionRect.rows)
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        NSAccessibility.post(element: table, notification: .selectedCellsChanged)
        if announceFocus, !rows.isEmpty,
           let cell = table.accessibilityCell(forColumn: cursor.column, row: cursor.row) {
            NSAccessibility.post(element: cell, notification: .focusedUIElementChanged)
        }
    }

    private func clampSelection() {
        let maxRow = max(rows.count - 1, 0)
        anchor.row = min(anchor.row, maxRow)
        cursor.row = min(cursor.row, maxRow)
    }

    func reloadVisible() {
        guard let table else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                         columnIndexes: IndexSet(integersIn: 0..<columnCount))
    }
}
