import AppKit
import DJCDomain

/// 곡 목록 표. 한 번 클릭은 고르기만 하고, 키 칸 더블클릭은 메뉴, 나머지 더블클릭·⌘→는 덱에 올린다(#93·#204).
/// 곡을 고른 채 Return·Enter를 누르거나 이미 고른 줄의 태그 칸을 다시 누르면 그 칸을 바로 고친다(#88). 나머지 키는 표가 처리한다.
final class TrackListTableView: NSTableView {
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        PerfProbe.measure("table.resize") { super.resize(withOldSuperviewSize: oldSize) }
    }

    override func sizeToFit() {
        PerfProbe.measure("table.columns") { super.sizeToFit() }
    }

    override func layout() {
        PerfProbe.measure("table.layout") { super.layout() }
    }

    weak var coordinator: TrackListCoordinator? {
        didSet {
            target = coordinator
            doubleAction = #selector(TrackListCoordinator.doubleClicked(_:))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, column) = noteClick(at: point)
        let slowEdit = TrackListTagEditing.startsSlowEdit(clickCount: event.clickCount, row: row, selected: selectedRowIndexes,
                                                          modifiers: event.modifierFlags)
        coordinator?.cancelPendingEdit()
        let drags = coordinator?.dragGeneration
        super.mouseDown(with: event)
        // 누른 채 끌어 놓았으면(끌기가 마우스를 놓기 전에 시작됨) 고치지 않는다.
        if slowEdit, coordinator?.dragGeneration == drags, tableColumns.indices.contains(column) {
            coordinator?.scheduleEdit(row: row, column: tableColumns[column].identifier.rawValue)
        }
    }

    /// 누른 자리를 조정자에 기억시키고 (줄 번호, 칸 번호)를 돌려준다. 숨긴 칸·옮긴 칸이 있어도 칸 번호가 아니라 이름으로 잇는다.
    /// mouseDown이 쓰는 길이라, 시험은 mouseDown(mouseUp까지 기다리는 추적 루프) 대신 이것을 부른다.
    @discardableResult
    func noteClick(at point: NSPoint) -> (row: Int, column: Int) {
        let row = row(at: point), column = column(at: point)
        coordinator?.noteClick(row: row, column: tableColumns.indices.contains(column) ? tableColumns[column].identifier.rawValue : nil)
        return (row, column)
    }

    override func keyDown(with event: NSEvent) {
        coordinator?.cancelPendingEdit()
        // ⌘→: 고른 곡을 덱에 올린다. 목록에서 ⌘ 조합은 덱 단축키로 가지 않고 여기로 온다(→·⇧→는 덱의 박·마디 이동).
        if LoadToDeckCommand.matches(event) {
            coordinator?.loadSelection()
            return
        }
        // Return(36)·Enter(76)는 덱 단축키로 줄 수 없는 예약 키라 덱과 부딪히지 않는다.
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           coordinator?.beginEditingSelection() == true { return }
        super.keyDown(with: event)
    }
}
