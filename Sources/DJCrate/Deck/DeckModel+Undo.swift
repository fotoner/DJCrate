import DJCApplication
import DJCDomain
import Foundation

extension DeckModel {
    /// 지금 덱 초안과 그 기준(rekordbox 그리드·오토게인). 기준은 저장 뒤 ⌘Z가 쓴 편집인지 가르고 역편집의 base가 된다(R12)
    var draftSnapshot: DeckDraftSnapshot? {
        draft.map { DeckDraftSnapshot(cue: $0, grid: gridDraft, gain: gainDraft, gridBlockedReason: gridEditBlockedReason,
                                      gridBase: gridDraft?.base ?? originalGrid.map(GridDraft.segments(from:)), gainBase: rekordboxGainDB) }
    }

    /// 곡·원본이 바뀌거나 복원·곡 넣기처럼 통째로 잠그는 쓰기를 시작하면 이전 기준의 초안을 되살리지 않는다.
    /// 초안을 쓴 뒤 다시 읽기(`refreshAfterWrite`)는 지우지 않는다: ⌘Z가 지금 rekordbox 값 위의 역편집이 된다(R12)
    func clearDraftUndo() {
        draftUndoSteps.removeAll(undoManager)
        pendingDraftUndo = nil
        gridDragBase = nil
        cueDragBase = nil
    }

    func registerDraftUndo(from before: DeckDraftSnapshot?, name: String) {
        guard let before, let after = draftSnapshot,
              let change = DraftChange(before: before, after: after) else { return }
        registerDraftUndo(change, name: name)
    }

    func registerDraftUndo(_ change: DraftChange<DeckDraftSnapshot>, name: String) {
        guard let undoManager else { return }
        // 한 이벤트 안에서 일어난 별개의 편집도 각각 한 단계로 남긴다.
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        let groupsByEvent = undoManager.groupsByEvent
        if grouping {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        // 단계마다 따로 건다: 저장 뒤 되돌릴 수 없게 되면(분석 붙이기·큐를 정할 수 없음) 그 단계만 빼 ⌘Z가 꺼진다(`pruneDraftUndo`)
        draftUndoSteps.register(undoManager, canUndo: { [weak self] in self?.canUndoDraft(change) ?? false }) { [weak self] in
            guard let self, !editsFrozen, row?.track.uuid == change.before.cue.trackUUID else { return }
            undoDraft(change, name: name)
        }
        undoManager.setActionName(name)
        if grouping {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupsByEvent
        }
    }

    /// ⌘Z·⇧⌘Z 한 단계: 편집 전으로 되돌린다. 그 편집을 이미 rekordbox에 썼으면 지금 rekordbox 값을 base로 한 역편집 초안으로 둔다(자동 저장이 쓴다, R12).
    /// 쓴 큐를 지금 큐에서 찾지 못하면(새 큐 ID를 정할 수 없다) 되돌리지 않는다. 이 곡을 쓰는 중이면 되돌리지 않고 단계를 다시 맨 위에 둔다(쓴 뒤 다시 ⌘Z)
    /// - Parameter registersRedo: 다시 실행(⇧⌘Z) 단계를 남긴다. 잠긴 동안 눌러 미뤘다가 실행하는 요청은 남기지 않는다
    private func undoDraft(_ change: DraftChange<DeckDraftSnapshot>, name: String, registersRedo: Bool = true) {
        if isEditLocked {
            // 쓰는 중에는 되돌리지 않고 누른 요청으로 줄에 둔다: 잠금이 풀리면 누른 차례대로 실행한다(`pendingUndo`, 컨실 S6·O3)
            if undoManager?.isRedoing != true {
                pendingUndo.append(ready: { [weak self] in self.map { !$0.isEditLocked } ?? true }) { [weak self] in
                    guard let self, !editsFrozen, row?.track.uuid == change.before.cue.trackUUID else { return }
                    undoDraft(change, name: name, registersRedo: false)
                }
            }
            return
        }
        guard let current = draftSnapshot, let applied = change.before.rebased(from: change.after, onto: current) else { return }
        restoreDraft(applied)
        // 되돌린 지금 상태에서 다시 실행할 단계(그사이 저장해도 같은 규칙으로 옮긴다)
        if registersRedo, let redo = DraftChange(before: current, after: applied) { registerDraftUndo(redo, name: name) }
    }

    /// 그 단계를 지금 되돌릴 수 있는지: 지금 덱 곡의 단계이고, 저장했으면 지금 rekordbox 값 위로 옮길 수 있다(R12)
    func canUndoDraft(_ change: DraftChange<DeckDraftSnapshot>) -> Bool {
        guard row?.track.uuid == change.before.cue.trackUUID, let current = draftSnapshot else { return false }
        return change.before.rebased(from: change.after, onto: current) != nil
    }

    /// 저장 뒤 되돌릴 수 없게 된 단계를 기록에서 뺀다(메뉴가 꺼진다). 쓴 뒤 새 값을 덱에 다 적용한 때 부른다
    func pruneDraftUndo() { draftUndoSteps.prune(undoManager) }

    /// 쓴 뒤 다시 읽은 큐에 쓰기 전 덱 초안의 큐 ID를 잇는다(R12): 새로 넣은 큐는 쓰기가 돌려준 새 rekordbox ID로, 건드리지 않은 큐는 rekordbox ID로 찾는다.
    /// 그래야 ⌘Z의 편집 전후 스냅샷이 다시 읽은 큐를 같은 ID로 찾는다. 쓴 큐를 하나라도 찾지 못하면 nil(⌘Z를 끈다).
    /// 이 곡의 큐 초안이 디스크에 남았으면(쓰지 않았다) 그대로 둔다
    static func keepingCueIdentity(_ fresh: CueDraft, written previous: CueDraft?, cueIDs: [String: String]) -> CueDraft? {
        guard let previous, previous.trackUUID == fresh.trackUUID, !fresh.hasChanges else { return fresh }
        var ids: [String: EditableCue.ID] = [:]
        for cue in previous.base { if let source = cue.sourceID { ids[source] = cue.id } }
        for cue in previous.cues { if let source = cueIDs[cue.id.uuidString] ?? cue.sourceID { ids[source] = cue.id } }
        let sources = Set(fresh.cues.compactMap(\.sourceID))
        guard previous.cues.allSatisfy({ (cueIDs[$0.id.uuidString] ?? $0.sourceID).map(sources.contains) == true }) else { return nil }
        func identified(_ cue: EditableCue) -> EditableCue {
            var cue = cue
            if let source = cue.sourceID, let id = ids[source] { cue.id = id }
            return cue
        }
        let base = fresh.base.map(identified)
        guard Set(base.map(\.id)).count == base.count else { return nil }
        return CueDraft(trackUUID: fresh.trackUUID, base: base, cues: fresh.cues.map(identified))
    }

    private func restoreDraft(_ snapshot: DeckDraftSnapshot) {
        let previous = draftSnapshot
        draft = snapshot.cue
        gridDraft = snapshot.grid
        gainDraft = snapshot.gain
        gridEditBlockedReason = snapshot.gridBlockedReason
        if previous?.cue != snapshot.cue { persist(snapshot.cue) }
        if previous?.grid != snapshot.grid {
            if let gridDraft { persistGrid(gridDraft) }
            else { removeGridDraft(snapshot.cue.trackUUID) }
            onDraftChange?(snapshot.cue.trackUUID, .grid, snapshot.grid?.hasChanges == true)
            if row?.isStaged == true { onStagedGridChange?(snapshot.cue.trackUUID, snapshot.grid?.segments.first?.bpm) }
        }
        if previous?.gain != snapshot.gain {
            persistGain(snapshot.gain, uuid: snapshot.cue.trackUUID)
            onDraftChange?(snapshot.cue.trackUUID, .gain, snapshot.gain != nil)
        }
        if cue(selectedCueID) == nil { selectedCueID = nil }
        if cue(engagedLoopID)?.loop == nil { engagedLoopID = nil }
        refreshGrid()
        refreshSuggestions()
        refreshSuggestionNote()
        audio.resetClicks()
        applyGain()
        syncAudioLoop()
    }
}
