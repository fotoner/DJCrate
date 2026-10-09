import DJCApplication
import DJCDomain
import Foundation

extension DeckModel {
    var draftSnapshot: DeckDraftSnapshot? {
        draft.map { DeckDraftSnapshot(cue: $0, grid: gridDraft, gain: gainDraft, gridBlockedReason: gridEditBlockedReason) }
    }

    /// 곡·원본이 바뀌거나 반영을 시작하면 이전 기준의 초안을 되살리지 않는다.
    func clearDraftUndo() {
        undoManager?.removeAllActions(withTarget: self)
        pendingDraftUndo = nil
        gridDragBase = nil
        cueDragBase = nil
    }

    func registerDraftUndo(from before: DeckDraftSnapshot?, name: String) {
        guard let before, let after = draftSnapshot,
              let change = DraftChange(before: before, after: after) else { return }
        registerDraftUndo(change, name: name)
    }

    private func registerDraftUndo(_ change: DraftChange<DeckDraftSnapshot>, name: String) {
        guard let undoManager else { return }
        // 한 이벤트 안에서 일어난 별개의 편집도 각각 한 단계로 남긴다.
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        let groupsByEvent = undoManager.groupsByEvent
        if grouping {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { target in
            guard !target.isWriteLocked, target.row?.track.uuid == change.before.cue.trackUUID else { return }
            target.restoreDraft(change.before)
            target.registerDraftUndo(change.reversed, name: name)
        }
        undoManager.setActionName(name)
        if grouping {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupsByEvent
        }
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
