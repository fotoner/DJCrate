import DJCDomain
import AppKit
import SwiftUI

extension TrackListCoordinator {
    // MARK: - 칸에서 바로 태그 고치기(#88)

    func refreshTagCells(_ table: NSTableView) {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        let columns = table.tableColumns.indices.filter {
            let id = table.tableColumns[$0].identifier.rawValue
            return TrackListTagEditing.key(forColumn: id) != nil || id == "class"
        }
        for index in visible.location..<NSMaxRange(visible) where rows.indices.contains(index) {
            for column in columns {
                guard let cell = table.view(atColumn: column, row: index, makeIfNecessary: false) as? TrackTextCell else { continue }
                configure(cell, column: table.tableColumns[column].identifier.rawValue, row: rows[index], index: index)
            }
        }
    }

    func visibleColumnIDs(_ table: NSTableView) -> [String] {
        table.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
    }

    // MARK: - 덱에 불러오기(#93)

    /// 더블클릭: 누른 곡을 덱에 올린다(rekordbox와 같다). 키 칸은 키 고르기 메뉴를 연다(#204). 한 번 클릭은 고르기만 한다.
    @objc func doubleClicked(_ sender: Any?) {
        guard let table else { return }
        let column = table.tableColumns.indices.contains(table.clickedColumn)
            ? table.tableColumns[table.clickedColumn].identifier.rawValue : nil
        doubleClicked(row: table.clickedRow, column: column)
    }

    /// 그 칸을 고칠 수 없는 곡(USB·스트리밍, 평점·곡 색은 추가한 곡·확인 밖 곡)이나 쓰는 중이면 메뉴 칸도 다른 칸처럼 덱에 올린다(경고로 막지 않는다).
    func doubleClicked(row index: Int, column: String?) {
        cancelPendingEdit()
        if let column, TrackListTagEditing.isMenuColumn(column), let key = TrackListTagEditing.key(forColumn: column), canPick(key, row: index) {
            beginEditing(row: index, column: column)
        } else {
            loadRow(at: index)
        }
    }

    /// 이 줄의 곡을 덱에 올린다. 다시 누른 칸을 고치려고 기다리던 것은 취소한다(더블클릭의 첫 클릭이었다).
    func loadRow(at index: Int) {
        cancelPendingEdit()
        guard rows.indices.contains(index) else { return }
        store.loadToDeck(rows[index])
    }

    /// ⌘→: 고른 줄 중 표에서 첫 곡을 덱에 올린다.
    func loadSelection() {
        guard let index = table?.selectedRowIndexes.first else { return }
        loadRow(at: index)
    }

    // MARK: - 다시 눌러 고치기(#88)

    /// 이미 고른 줄의 태그 칸을 다시 누르면, 더블클릭이 아닌 것을 확인한 뒤(더블클릭 간격) 그 칸을 고친다(Finder 이름 바꾸기처럼).
    func scheduleEdit(row index: Int, column: String, after delay: Duration = .seconds(NSEvent.doubleClickInterval)) {
        cancelPendingEdit()
        // 키 칸은 메뉴라 클릭 한 번에 저절로 열지 않는다(더블클릭·Return으로 연다)
        guard TrackListTagEditing.isTextColumn(column), rows.indices.contains(index), !rows[index].isUsb else { return }
        let id = rows[index].id
        pendingEdit = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let table = self.table else { return }
            self.pendingEdit = nil
            // 그 사이 줄·선택·포커스가 바뀌었거나 아직 누르고 있으면(끌기) 고치지 않는다.
            // 선택 알림은 늦게 올 때가 있어 알림으로 취소하지 않고 여기서 본다.
            guard self.rows.indices.contains(index), self.rows[index].id == id,
                  table.selectedRowIndexes == IndexSet(integer: index), table.window?.firstResponder === table,
                  !self.isMouseDown() else { return }
            self.beginEditing(row: index, column: column)
        }
    }

    /// 다시 누른 칸을 고치려고 기다리는 중인지(시험용)
    var hasPendingEdit: Bool { pendingEdit != nil }

    func cancelPendingEdit() {
        pendingEdit?.cancel()
        pendingEdit = nil
    }

    /// Return·Enter: 방금 누른 줄이 고른 줄 안에 있고 고칠 수 있으면(스트리밍·USB 제외) 그 줄에서, 아니면 고른 줄 중 표에서 첫 곡에서
    /// 보이는 첫 태그 칸부터 고친다(Finder 이름 바꾸기처럼). 방금 키 칸을 눌렀으면 그 줄에서 키 고르기 메뉴를 연다(#204).
    /// 누른 줄이 선택에서 빠졌거나 기억이 지워졌으면 보이는 첫 글자 칸이다. 어느 줄에서 시작하든 고칠 곡은 고른 곡 모두다.
    @discardableResult
    func beginEditingSelection() -> Bool {
        guard let table else { return false }
        let selected = table.selectedRowIndexes
        let isEditable = { (index: Int) in self.rows.indices.contains(index) && !self.rows[index].track.isStreaming && !self.rows[index].isUsb }
        let clicked = clickedCell.flatMap { cell in
            selected.first { isEditable($0) && rows[$0].id == cell.rowID }.map { (row: $0, column: cell.column) }
        }
        guard let row = clicked?.row ?? selected.first(where: isEditable),
              let column = TrackListTagEditing.firstColumn(in: visibleColumnIDs(table), clicked: clicked?.column)
        else { return false }
        return beginEditing(row: row, column: column)
    }

    /// 칸 자리에 입력 칸을 띄운다. 고른 줄 안이면 고른 곡 모두가 대상이다(인스펙터 여러 곡 편집과 같다).
    @discardableResult
    func beginEditing(row index: Int, column: String) -> Bool {
        if rows.indices.contains(index), let reason = TrackListTagEditing.unavailableReason(rows[index], key: TrackListTagEditing.key(forColumn: column)) {
            store.staging.stagingMessage = AppMessage(kind: .warning, text: reason)
            return false
        }
        guard !isEditing, store.writeLockPolicy.allowsLibraryInteraction, let table, rows.indices.contains(index), !rows[index].isUsb,
              let key = TrackListTagEditing.key(forColumn: column),
              let columnIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column && !$0.isHidden })
        else { return false }
        if TagChoice.keys.contains(key) {
            // 키·평점·곡 색은 글자 대신 메뉴로 고른다. 메뉴는 고를 때까지 돌아오지 않는다.
            guard let menu = choiceMenu(key, row: index) else { return false }
            table.scrollRowToVisible(index)
            table.scrollColumnToVisible(columnIndex)
            let rect = table.frameOfCell(atColumn: columnIndex, row: index)
            activeKeyMenu = menu
            defer { activeKeyMenu = nil }
            presentKeyMenu(menu, NSPoint(x: rect.minX, y: rect.maxY), table)
            return true
        }
        let selected = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        let targets = TrackListTagEditing.targets(anchor: rows[index], selection: selected)
        guard let session = TrackListTagEditing.Session(key: key, targets: targets, value: { store.tags.tagCell($0, key) }) else { return false }
        table.scrollRowToVisible(index)
        table.scrollColumnToVisible(columnIndex)
        guard let cell = table.view(atColumn: columnIndex, row: index, makeIfNecessary: true) as? TrackTextCell else { return false }
        let field = cell.beginEditing(text: session.original,
                                      placeholder: session.mixed ? String(ui: "(여러 값 — 입력하면 모두 바뀜)") : nil)
        field.delegate = self
        field.setAccessibilityLabel(key.label)
        if targets.count > 1 {
            let help = String(ui: "고른 \(targets.count)곡에 모두 적용합니다")
            field.toolTip = help
            field.setAccessibilityHelp(help)
        }
        inlineEdit = InlineEdit(row: index, column: column, session: session, cell: cell, field: field)
        table.window?.makeFirstResponder(field)
        return true
    }

    func cancelEditing() {
        activeKeyMenu?.cancelTracking()
        finishEditing(commit: false, restoreFocus: true)
    }

    /// 편집을 끝낸다. 키나 표 쪽 사정으로 끝낼 때만 표로 포커스를 되돌린다(다른 곳을 눌러 끝나면 그곳에 둔다).
    /// - Parameter forward: Tab(true)·⇧Tab(false)이면 확정 뒤 보이는 옆 태그 칸을 이어서 고친다.
    func finishEditing(commit: Bool, restoreFocus: Bool, thenMove forward: Bool? = nil) {
        guard let edit = inlineEdit, let table else { return }
        inlineEdit = nil
        let value = edit.field?.stringValue ?? edit.session.original
        if restoreFocus { table.window?.makeFirstResponder(table) }
        edit.cell?.endEditing()
        if commit {
            let targets = TrackListTagEditing.changes(edit.session, committing: value)
            if !targets.isEmpty { store.tags.setTag(edit.session.key, value, rows: targets) }
        }
        refreshTagCells(table)
        if let forward, let next = TrackListTagEditing.column(after: edit.column, forward: forward, in: visibleColumnIDs(table)) {
            beginEditing(row: edit.row, column: next)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard inlineEdit?.field === control else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): finishEditing(commit: true, restoreFocus: true)
        case #selector(NSResponder.insertTab(_:)): finishEditing(commit: true, restoreFocus: true, thenMove: true)
        case #selector(NSResponder.insertBacktab(_:)): finishEditing(commit: true, restoreFocus: true, thenMove: false)
        case #selector(NSResponder.cancelOperation(_:)): finishEditing(commit: false, restoreFocus: true)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 다른 곳을 눌러 칸을 벗어나면 확정한다(태그 시트와 같다).
        guard let field = notification.object as? NSTextField, inlineEdit?.field === field else { return }
        finishEditing(commit: true, restoreFocus: false)
    }

    // MARK: - 키·평점·곡 색 고르기(#204·#65)

    /// 이 줄의 고르기 메뉴를 열 수 있는지: 쓰는 중이 아니고 그 칸을 고칠 수 있는 곡(USB·스트리밍, 평점·곡 색은 추가한 곡·확인 밖 곡 제외)
    func canPick(_ key: TagFields.Key, row index: Int) -> Bool {
        store.writeLockPolicy.allowsLibraryInteraction && rows.indices.contains(index)
            && TrackListTagEditing.unavailableReason(rows[index], key: key) == nil
    }

    struct Choice {
        let key: TagFields.Key
        let targets: [TrackRow]
        let value: String
    }

    /// 키 칸의 고르기 메뉴(`choiceMenu(.musicalKey, row:)`)
    func keyMenu(row index: Int) -> NSMenu? { choiceMenu(.musicalKey, row: index) }

    /// 고르기 메뉴: 키는 없음·Camelot 24개, 평점은 없음·별 1~5개, 곡 색은 없음·rekordbox 색(태그 시트와 같다). 지금 값에 체크하고, 고를 수 없는
    /// 현재 값(옛 표기 키·모르는 색 번호)은 맨 앞에 흐리게 보인다. 누른 줄이 고른 줄 안이면 고른 곡 모두(고칠 수 없는 곡은 빼고)가 대상이다.
    /// 값이 서로 다르면 아무 항목에도 체크하지 않는다.
    func choiceMenu(_ key: TagFields.Key, row index: Int) -> NSMenu? {
        guard canPick(key, row: index), let table else { return nil }
        let selected = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        let targets = TagChoice.targets(key, TrackListTagEditing.targets(anchor: rows[index], selection: selected))
        guard !targets.isEmpty else { return nil }
        return TagChoice.menu(key, current: store.tags.tagValue(key, rows: targets), colors: store.trackColors, targetCount: targets.count,
                              action: #selector(pickKey(_:)), target: self) { Choice(key: key, targets: targets, value: $0) }
    }

    @objc func pickKey(_ sender: NSMenuItem) {
        guard store.writeLockPolicy.allowsLibraryInteraction, let choice = sender.representedObject as? Choice,
              TagChoice.accepted(choice.key, choice.value, colors: store.trackColors) == choice.value else { return }
        // 초안은 고를 때만 만든다(열기·취소는 그대로, #5). 여러 값에서 "없음"을 고르면 모두 비운다.
        // 메뉴를 연 사이 목록이 바뀌어도 엉뚱한 곡에 들어가지 않게 줄 ID로 다시 찾는다.
        // 줄 ID는 계산 값이라 대상마다 줄 전체를 훑지 않고, 캐시한 ID(rowIDs)를 한 번만 훑는다(같은 ID가 겹치면 앞 줄).
        let wanted = Set(choice.targets.map(\.id))
        var firstIndex: [TrackRow.ID: Int] = [:]
        for (index, id) in rowIDs.enumerated() where wanted.contains(id) && firstIndex[id] == nil {
            firstIndex[id] = index
            if firstIndex.count == wanted.count { break }
        }
        let targets = choice.targets.compactMap { target in firstIndex[target.id].map { rows[$0] } }
        store.tags.setTag(choice.key, choice.value, rows: TagChoice.targets(choice.key, targets))
        if let table { refreshTagCells(table) }
    }
}
