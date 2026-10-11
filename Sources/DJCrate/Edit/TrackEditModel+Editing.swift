import DJCDomain
import Foundation
import SwiftUI

/// 곡 편집 창의 편집 명령: 원곡에서 고르기, 결과 타임라인 고치기(실행 취소), 누르기·끌기 동작 적용
extension TrackEditModel {
    // MARK: - 원곡에서 고르기

    /// 원곡 줄에서 끈 두 시각으로 구간을 고른다(가까운 마디 줄에 붙인다).
    func select(from a: Double, to b: Double) {
        guard let layout else { return }
        focus = .source
        selection = layout.selection(from: a, to: b)
    }

    /// 끌어 고르기를 마치면 원곡 재생선을 고른 구간 처음에 둔다(스페이스바로 바로 들어 본다).
    func finishSelection() {
        guard let selection, let layout else { return }
        seek(.source, to: layout.start(ofBar: selection.first))
    }

    /// 고른 구간을 고른 클립 바로 뒤(없으면 결과 끝)에 넣고 그 클립을 고른다. 맨 앞에 넣을 때만 곡 머리(0마디)를 살린다.
    func addSelection() {
        guard let selection, layout != nil else { return }
        let index = selectedIndex.map { $0 + 1 } ?? entries.count
        guard let range = selection.fitted(leading: index == 0) else {
            message = AppMessage(kind: .warning, text: String(ui: "곡 머리(0마디)는 결과 맨 앞에만 둘 수 있습니다. 1마디 이상을 함께 고르세요"))
            return
        }
        insert(EditInsertion(offset: index, range: range))
    }

    /// 원곡 구간을 결과의 `offset` 자리(앞 클립 수)에 넣고 그 클립을 고른다(⏎·끌어 넣기).
    func insert(_ insertion: EditInsertion) {
        message = nil
        let entry = Entry(id: UUID(), range: insertion.range)
        change(String(ui: "구간 넣기")) {
            entries.insert(entry, at: min(max(insertion.offset, 0), entries.count))
            selectedClip = entry.id
        }
    }

    // MARK: - 누르기·끌기(`EditPointer`)

    /// 두 줄의 누르기·끌기가 읽는 지금 상태
    var pointerContext: EditPointerContext {
        EditPointerContext(layout: layout, entries: entries, clips: clipLayout, selection: selection, hasEdit: edit != nil)
    }

    /// 누르기·끌기가 정한 동작을 차례로 한다.
    func apply(_ actions: [EditPointerAction]) {
        for action in actions {
            switch action {
            case .focus(let lane): focus = lane
            case let .scrub(lane, time): scrub(lane, to: time)
            case .endScrub: endScrub()
            case let .select(from, to): select(from: from, to: to)
            case .finishSelection: finishSelection()
            case .preview(let insertion): insertPreview = insertion
            case .insert(let insertion): insert(insertion)
            case let .seek(lane, time): seek(lane, to: time)
            case .selectClip(let id): selectedClip = id
            case let .moveClip(id, offset): moveClip(id, toOffset: offset)
            case let .trim(id, range): trim(id, to: range)
            }
        }
    }

    // MARK: - 결과 타임라인 편집(실행 취소 가능)

    /// 결과 재생선에서 가장 가까운 마디 줄로 클립을 자른다. 오른쪽 조각을 고른다.
    func splitAtPlayhead() {
        let time = position(.output)
        guard let edit, let split = edit.split(atOutput: time),
              let parts = entries[split.clip].range.split(at: split.bar) else {
            message = AppMessage(kind: .warning, text: String(ui: "재생선 가까이에 자를 마디 줄이 없습니다. 재생선을 클립 안쪽으로 옮긴 뒤 자르세요"))
            return
        }
        message = nil
        pause()
        let right = Entry(id: UUID(), range: parts[1])
        change(String(ui: "자르기")) {
            entries[split.clip].range = parts[0]
            entries.insert(right, at: split.clip + 1)
            selectedClip = right.id
        }
        placeOutputPlayhead(split.outputTime)
    }

    func remove(_ id: Entry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // 지운 클립을 골랐으면 그 자리의 다음(없으면 앞) 클립을 고른다(⌫를 이어 누를 수 있게).
        let wasSelected = selectedClip == id
        change(String(ui: "지우기")) {
            entries.remove(at: index)
            if wasSelected { selectedClip = entries.indices.contains(index) ? entries[index].id : entries.last?.id }
        }
    }

    /// 바로 뒤에 같은 구간을 하나 더 둔다(인트로 늘이기). 복사본을 고른다.
    func duplicate(_ id: Entry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let copy = Entry(id: UUID(), range: entries[index].range)
        change(String(ui: "복제")) {
            entries.insert(copy, at: index + 1)
            selectedClip = copy.id
        }
    }

    /// 목록에서 앞(−1)·뒤(+1)로 옮긴다. 끝이면 그대로.
    func move(_ id: Entry.ID, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index + offset) else { return }
        change(String(ui: "클립 옮기기")) { entries.swapAt(index, index + offset) }
    }

    /// 끌어 온 클립을 `offset`(놓을 자리 앞 클립 수, 옮기기 전 기준)으로 옮긴다.
    func moveClip(_ id: Entry.ID, toOffset offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(String(ui: "클립 옮기기")) {
            entries.move(fromOffsets: IndexSet(integer: index), toOffset: min(max(offset, 0), entries.count))
            selectedClip = id
        }
    }

    /// 시작 마디: 곡 머리(0마디, 있으면)부터 끝 마디까지
    func setFirst(_ id: Entry.ID, _ bar: Int) {
        guard let layout, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(String(ui: "마디 고치기")) {
            entries[index].range.first = min(max(bar, layout.hasLeadIn ? 0 : 1), entries[index].range.last)
        }
    }

    /// 끝 마디: 시작 마디(적어도 1마디)부터 곡의 마지막 마디까지
    func setLast(_ id: Entry.ID, _ bar: Int) {
        guard let layout, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(String(ui: "마디 고치기")) {
            entries[index].range.last = min(max(bar, entries[index].range.first, 1), layout.count)
        }
    }

    /// 가장자리를 끌어 다듬은 구간으로 바꾸고 그 클립을 고른다.
    func trim(_ id: Entry.ID, to range: BarRange) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        focus = .output
        change(String(ui: "클립 다듬기")) {
            entries[index].range = range
            selectedClip = id
        }
    }

    /// 고른 클립을 지우고·복제한다(⌫·⌘D).
    func removeSelected() { if let selectedClip { remove(selectedClip) } }
    func duplicateSelected() { if let selectedClip { duplicate(selectedClip) } }

    /// Esc: 고른 클립, 없으면 원곡에서 고른 구간을 놓는다. 놓을 것이 없으면 false.
    @discardableResult
    func clearSelection() -> Bool {
        if selectedClip != nil { selectedClip = nil; return true }
        if selection != nil { selection = nil; return true }
        return false
    }

    // MARK: - 실행 취소

    /// 목록을 바꾸고 바꾸기 전 상태를 실행 취소에 남긴다.
    private func change(_ name: String, _ body: () -> Void) {
        let before = (entries, selectedClip)
        body()
        guard entries != before.0 else { return }
        registerUndo(entries: before.0, selected: before.1, name: name)
    }

    private func registerUndo(entries old: [Entry], selected: Entry.ID?, name: String) {
        guard let undoManager else { return }
        // 이벤트 단위로 묶지 않는 곳(시험·자가 테스트)에서도 한 번에 하나씩 되돌리게 직접 묶는다.
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        let groupsByEvent = undoManager.groupsByEvent
        if grouping {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { target in
            let current = (target.entries, target.selectedClip)
            target.entries = old
            target.selectedClip = selected
            target.registerUndo(entries: current.0, selected: current.1, name: name)
        }
        undoManager.setActionName(name)
        if grouping {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupsByEvent
        }
        refreshUndo()
    }

    func undo() { undoManager?.undo() }
    func redo() { undoManager?.redo() }
}
