import DJCDomain
import AppKit
import SwiftUI

extension SheetCoordinator {
    // MARK: - 편집

    func beginEditing(initialText: String? = nil) {
        // 키·평점·곡 색 칸은 글자를 쓰지 않고 목록에서 고른다(더블클릭·Return·타이핑 모두)
        if editing == nil, rows.indices.contains(cursor.row), let key = editableKey(row: cursor.row, column: cursor.column), TagChoice.keys.contains(key) {
            anchor = cursor
            presentKeyMenu(row: cursor.row, column: cursor.column)
            return
        }
        guard editing == nil, let table, rows.indices.contains(cursor.row),
              editableKey(row: cursor.row, column: cursor.column) != nil,
              let cell = table.view(atColumn: cursor.column, row: cursor.row, makeIfNecessary: true) as? SheetCell
        else { return }
        anchor = cursor
        syncAccessibilitySelection(announceFocus: false)
        editing = cursor
        editingOriginal = text(row: cursor.row, column: cursor.column)
        let field = cell.beginEditing(text: initialText ?? editingOriginal)
        field.delegate = self
        table.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let length = (field.stringValue as NSString).length
            editor.selectedRange = initialText == nil ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
        }
    }

    func cancelEditing() {
        finishEditing(commit: false, then: nil)
    }

    var isEditing: Bool { editing != nil }

    func finishEditing(commit: Bool, then move: (rows: Int, columns: Int)?) {
        guard let position = editing, let table else { return }
        editing = nil
        let cell = table.view(atColumn: position.column, row: position.row, makeIfNecessary: false) as? SheetCell
        let value = cell?.editingField?.stringValue ?? editingOriginal
        cell?.endEditing()
        table.window?.makeFirstResponder(table)
        if commit, value != editingOriginal, let key = editableKey(row: position.row, column: position.column) {
            store.applyTagEdits([(row: rows[position.row], key: key, value: value)])
        } else {
            reloadVisible()
        }
        if let move { self.move(rows: move.rows, columns: move.columns, extend: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(commit: true, then: (1, 0)); return true
        case #selector(NSResponder.insertTab(_:)):
            finishEditing(commit: true, then: (0, 1)); return true
        case #selector(NSResponder.insertBacktab(_:)):
            finishEditing(commit: true, then: (0, -1)); return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(commit: false, then: nil); return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 다른 곳을 클릭해 포커스를 잃으면 확정한다.
        if editing != nil { finishEditing(commit: true, then: nil) }
    }

    // MARK: - 일괄 작업

    private func editableCells(in rect: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)) -> [(row: TrackRow, key: TagFields.Key)] {
        rect.rows.filter { rows.indices.contains($0) }.flatMap { r in
            rect.columns.compactMap { c in editableKey(row: r, column: c).map { (row: rows[r], key: $0) } }
        }
    }

    func clearSelection() {
        guard !rows.isEmpty else { return }
        applyChanges(editableCells(in: selectionRect).map { ($0.row, $0.key, "") })
    }

    func copySelection() {
        guard !rows.isEmpty else { return }
        let rect = selectionRect
        let tsv = rect.rows.filter { rows.indices.contains($0) }
            .map { r in rect.columns.map { TSV.quote(text(row: r, column: $0)) }.joined(separator: "\t") }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tsv, forType: .string)
    }

    func paste() {
        paste(string: NSPasteboard.general.string(forType: .string))
    }

    /// 붙여넣을 글자를 직접 받는다(시험이 사용자 클립보드를 건드리지 않게)
    func paste(string: String?) {
        defer { table?.updateFillDownCommand() }
        guard let string, !rows.isEmpty else { return }
        let block = TSV.parse(string)
        guard !block.isEmpty else { return }
        let rect = selectionRect
        var changes: [(row: TrackRow, key: TagFields.Key, value: String)] = []
        if block.count == 1, block[0].count == 1 {
            // 값 하나 → 선택 범위 전체를 채운다.
            changes = editableCells(in: rect).map { ($0.row, $0.key, block[0][0]) }
        } else {
            for (i, line) in block.enumerated() {
                let r = rect.rows.lowerBound + i
                guard rows.indices.contains(r) else { break }
                for (j, value) in line.enumerated() {
                    let c = rect.columns.lowerBound + j
                    guard c < columnCount, let key = editableKey(row: r, column: c) else { continue }
                    changes.append((rows[r], key, value))
                }
            }
            cursor = CellPosition(row: min(rect.rows.lowerBound + block.count - 1, rows.count - 1),
                                  column: min(rect.columns.lowerBound + (block.map(\.count).max() ?? 1) - 1, columnCount - 1))
            anchor = CellPosition(row: rect.rows.lowerBound, column: rect.columns.lowerBound)
        }
        applyChanges(changes)
    }

    /// 선택 범위 맨 윗줄 값으로 아래 줄들을 채운다.
    func fillDown() {
        let rect = selectionRect
        guard rect.rows.count > 1, rows.indices.contains(rect.rows.lowerBound) else { return }
        var changes: [(row: TrackRow, key: TagFields.Key, value: String)] = []
        for c in rect.columns {
            guard let key = spec(atColumn: c)?.key else { continue }
            let value = store.tagCell(rows[rect.rows.lowerBound], key)
            for r in rect.rows.dropFirst() where editableKey(row: r, column: c) != nil {
                changes.append((rows[r], key, value))
            }
        }
        applyChanges(changes)
    }

    private func applyChanges(_ requested: [(row: TrackRow, key: TagFields.Key, value: String)]) {
        // 키·평점·곡 색 칸은 붙여넣기·채우기가 고를 수 있는 값(1A~12B, 별 1~5개, rekordbox 색)이나 빈칸만 받는다(보이는 별·색 이름도 받는다).
        // 지금 값과 같은 칸은 건드리지 않으니 세지 않는다.
        var skipped: [TagFields.Key: Int] = [:]
        let changes: [(row: TrackRow, key: TagFields.Key, value: String)] = requested.compactMap { change in
            guard TagChoice.keys.contains(change.key), store.tagCell(change.row, change.key) != change.value else { return change }
            guard let value = TagChoice.accepted(change.key, change.value, colors: store.trackColors) else {
                skipped[change.key, default: 0] += 1
                return nil
            }
            return (change.row, change.key, value)
        }
        let before = changes.map { store.tagCell($0.row, $0.key) }
        store.applyTagEdits(changes)
        let changed = zip(changes, before).filter { store.tagCell($0.0.row, $0.0.key) != $0.1 }.count
        reloadVisible()
        syncAccessibilitySelection(announceFocus: false)
        if changed > 0 || !skipped.isEmpty {
            let message = changed > 0 ? String(ui: "\(changed)칸 바뀜") : ""
            let skippedMessages = TagFields.Key.allCases.compactMap { key in skipped[key].map { TagChoice.skippedMessage(key, count: $0) } }
            announce(([message] + skippedMessages).filter { !$0.isEmpty }.joined(separator: ", "))
        }
    }

    // MARK: - 키·평점·곡 색 고르기

    /// 고른 값을 칸이 가리키던 곡에 적는다. 메뉴가 열려 있는 동안 줄이 바뀌어도 엉뚱한 곡에 들어가지 않게 곡 ID로 찾는다.
    final class KeyChoice: NSObject {
        let key: TagFields.Key
        let rowID: TrackRow.ID
        let value: String
        init(key: TagFields.Key = .musicalKey, rowID: TrackRow.ID, value: String) { self.key = key; self.rowID = rowID; self.value = value }
    }

    /// 키 칸의 고르기 메뉴(`choiceMenu(.musicalKey, row:)`)
    func keyMenu(row: Int) -> NSMenu? { choiceMenu(.musicalKey, row: row) }

    /// 고르기 메뉴: 키는 없음·Camelot 24개, 평점은 없음·별 1~5개, 곡 색은 없음·rekordbox 색(곡 목록과 같다). 지금 값에 체크하고,
    /// 고를 수 없는 현재 값(옛 표기 키·모르는 색 번호)은 맨 앞에 고를 수 없는 항목으로 보인다.
    func choiceMenu(_ key: TagFields.Key, row: Int) -> NSMenu? {
        // 열이 어디에 놓였든 같은 곡의 그 칸을 고칠 수 있는지만 본다(열 위치는 상관없다)
        guard rows.indices.contains(row), TrackListTagEditing.unavailableReason(rows[row], key: key) == nil else { return nil }
        let id = rows[row].id
        return TagChoice.menu(key, current: (store.tagCell(rows[row], key), false), colors: store.trackColors, targetCount: 1,
                              action: #selector(pickKey(_:)), target: self) { KeyChoice(key: key, rowID: id, value: $0) }
    }

    private func presentKeyMenu(row: Int, column: Int) {
        guard let table, let key = spec(atColumn: column)?.key, let menu = choiceMenu(key, row: row) else { return }
        let rect = table.frameOfCell(atColumn: column, row: row)
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: rect.minX, y: rect.maxY), in: table)
    }

    @objc func pickKey(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? KeyChoice, let row = rows.first(where: { $0.id == choice.rowID }) else { return }
        applyChanges([(row: row, key: choice.key, value: choice.value)])
    }
}
