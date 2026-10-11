import AppKit
import DJCDomain

/// 셀 선택·키보드·마우스를 엑셀처럼 다루는 NSTableView.
final class SheetTableView: NSTableView, NSViewToolTipOwner {
    weak var coordinator: SheetCoordinator?
    /// 표 하나에 붙인 툴팁 영역(시험용으로 읽는다)
    private(set) var toolTipTag: NSView.ToolTipTag?
    private(set) var toolTipRect = NSRect.zero

    override var acceptsFirstResponder: Bool { true }

    // 칸마다 toolTip을 달면 칸을 다시 쓸 때마다 추적 영역이 생겨, 스크롤 때 표가 추적 영역을 다시 계산하느라
    // 프레임이 밀렸다(#140). 표 하나에 영역 하나만 두고 마우스 밑 칸의 글자를 그때 알려 준다.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard toolTipTag == nil || toolTipRect != bounds else { return }
        if let toolTipTag { removeToolTip(toolTipTag) }
        toolTipRect = bounds
        toolTipTag = bounds.isEmpty ? nil : addToolTip(bounds, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let hitRow = row(at: point), hitColumn = column(at: point)
        guard let coordinator, coordinator.rows.indices.contains(hitRow), let spec = coordinator.spec(atColumn: hitColumn) else { return "" }
        let text = coordinator.text(row: hitRow, column: hitColumn)
        guard let reason = TrackListTagEditing.unavailableReason(coordinator.rows[hitRow], key: spec.key) else { return text }
        return text.isEmpty ? reason : text + "\n" + reason
    }

    override func accessibilitySelectedCells() -> [Any]? {
        guard let coordinator, !coordinator.rows.isEmpty else { return [] }
        let rect = coordinator.selectionRect
        return rect.rows.flatMap { row in
            rect.columns.compactMap { accessibilityCell(forColumn: $0, row: row) }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { updateFillDownCommand(focused: true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { coordinator?.store.canFillDownTags = false }
        return accepted
    }

    func updateFillDownCommand(focused: Bool? = nil) {
        let enabled = (focused ?? (window?.firstResponder === self))
            && canEditSelection && (coordinator?.selectionRect.rows.count ?? 0) > 1
        if coordinator?.store.canFillDownTags != enabled { coordinator?.store.canFillDownTags = enabled }
    }

    private func position(for event: NSEvent) -> CellPosition? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        guard row >= 0, column >= 0 else { return nil }
        return CellPosition(row: row, column: column)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let coordinator, let position = position(for: event) else { return }
        coordinator.select(position, extend: event.modifierFlags.contains(.shift))
        if event.clickCount == 2 { coordinator.beginEditing() }
    }

    /// 오른쪽 클릭: 고른 범위 밖이면 그 칸으로 커서를 옮기고(엑셀처럼) 덱에 불러오기 메뉴를 띄운다.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator, let position = position(for: event) else { return nil }
        if !coordinator.isSelected(position) { coordinator.select(position, extend: false) }
        return coordinator.contextMenu(forRow: position.row)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let coordinator, let position = position(for: event) else { return }
        autoscroll(with: event)
        if position != coordinator.cursor { coordinator.select(position, extend: true) }
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return super.keyDown(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        // ⌘→: 커서 줄을 덱에 올린다(곡 목록과 같다). ⌘ 없는 →는 옆 칸으로.
        if LoadToDeckCommand.matches(event) {
            coordinator.loadCursorRow()
            return
        }
        if event.modifierFlags.contains(.control), event.specialKey == .tab || event.specialKey == .backTab {
            if shift || event.specialKey == .backTab { window?.selectPreviousKeyView(nil) }
            else { window?.selectNextKeyView(nil) }
            return
        }
        switch event.specialKey {
        case .upArrow: coordinator.move(rows: -1, columns: 0, extend: shift)
        case .downArrow: coordinator.move(rows: 1, columns: 0, extend: shift)
        case .leftArrow: coordinator.move(rows: 0, columns: -1, extend: shift)
        case .rightArrow: coordinator.move(rows: 0, columns: 1, extend: shift)
        case .tab: coordinator.move(rows: 0, columns: 1, extend: false)
        case .backTab: coordinator.move(rows: 0, columns: -1, extend: false)
        case .carriageReturn, .enter: coordinator.beginEditing()
        case .delete, .deleteForward, .backspace: coordinator.clearSelection()
        case .pageUp: coordinator.move(rows: -20, columns: 0, extend: shift)
        case .pageDown: coordinator.move(rows: 20, columns: 0, extend: shift)
        default:
            // 글자를 치면 그 글자로 편집을 시작한다(엑셀과 같다).
            if let characters = event.characters, !characters.isEmpty,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                // 글자를 직접 넣으면 한글 입력기가 조합하지 못한다(ㅎ+ㅏ가 따로 들어감).
                // 빈 칸으로 편집을 시작하고 같은 키 이벤트를 편집기에 넘겨 입력기가 처리하게 한다.
                coordinator.beginEditing(initialText: "")
                if coordinator.isEditing, let editor = window?.firstResponder as? NSTextView {
                    editor.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    @objc func copy(_ sender: Any?) { coordinator?.copySelection() }
    @objc func cut(_ sender: Any?) {
        guard canEditSelection else { return }
        coordinator?.copySelection()
        coordinator?.clearSelection()
    }
    @objc func paste(_ sender: Any?) {
        guard canEditSelection else { return }
        coordinator?.paste()
    }
    @objc func delete(_ sender: Any?) {
        guard canEditSelection else { return }
        coordinator?.clearSelection()
    }
    override func selectAll(_ sender: Any?) { coordinator?.selectAll() }
    @objc func fillDown(_ sender: Any?) {
        guard canEditSelection else { return }
        coordinator?.fillDown()
    }

    var canEditSelection: Bool {
        guard let coordinator, !coordinator.store.isWritingRekordbox else { return false }
        let rect = coordinator.selectionRect
        return rect.rows.contains { row in
            rect.columns.contains { coordinator.editableKey(row: row, column: $0) != nil }
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(selectAll(_:)):
            return coordinator?.rows.isEmpty == false
        case #selector(cut(_:)), #selector(delete(_:)):
            return canEditSelection
        case #selector(paste(_:)):
            return canEditSelection && NSPasteboard.general.canReadItem(withDataConformingToTypes: ["public.utf8-plain-text"])
        case #selector(fillDown(_:)):
            return canEditSelection && (coordinator?.selectionRect.rows.count ?? 0) > 1
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
