import DJCApplication
import DJCDomain

extension DeckModel {
    func inputForDraftRecovery(uuid: String, kind: DraftRecoveryKind) -> RecoveryDraft? {
        guard row?.track.uuid == uuid else { return nil }
        switch kind {
        case .tags: return nil
        case .cues: return draft.map(RecoveryDraft.cues)
        case .grid: return gridDraft.map(RecoveryDraft.grid)
        }
    }

    /// 저장이 확인된 종류만 바꾼다. 그리드 복구가 큐를 함께 옮기거나 게인을 다시 읽지 않는다.
    func applyDraftRecovery(_ recovered: RecoveryDraft, currentRow: TrackRow?, currentGrid: BeatGrid?) {
        guard row?.track.uuid == recovered.uuid else { return }
        clearDraftUndo()
        let kind: DraftSaveKind?
        switch recovered { case .tags: kind = nil; case .cues: kind = .cue; case .grid: kind = .grid }
        if let kind {
            let key = "\(kind):\(recovered.uuid)"
            draftSaveRevisions[key] = (draftSaveRevisions[key] ?? 0) + 1
            draftSaveFailures.removeAll { $0.kind == kind && $0.trackUUID == recovered.uuid }
        }
        if let currentRow { replaceRow(currentRow) }
        switch recovered {
        case .tags: break
        case let .cues(recovered):
            draft = recovered
            if cue(selectedCueID) == nil { selectedCueID = nil }
            if cue(engagedLoopID)?.loop == nil { engagedLoopID = nil }
            refreshSuggestions()
            syncAudioLoop()
        case let .grid(recovered):
            gridDraft = recovered
            originalGrid = currentGrid
            hasRekordboxGrid = currentGrid?.beats.isEmpty == false
            // 곡을 불러올 때와 같은 규칙으로 다시 판정한다. 지원하지 않는 원형은 현재값을 가져와도 계속 막는다.
            // 원본은 복구가 읽은 현재 그리드다(분석 경로가 없으면 nil, 박이 없으면 빈 그리드).
            if row != nil {
                let read: AnalysisGridRead = currentGrid.map { $0.beats.isEmpty ? .noBeats : .grid($0) } ?? .missing
                gridEditBlockedReason = DeckGridGate(trackUUID: recovered.trackUUID, read: read, savedDraft: recovered,
                                                     duration: duration).blockedReason
            }
            refreshGrid()
            refreshSuggestionNote()
            audio.resetClicks()
        }
    }
}
