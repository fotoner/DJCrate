import DJCApplication
import DJCDomain
import Foundation

/// 초안 표시(곡마다 큐·그리드·게인·태그·앨범아트 초안이 있는지)와 바깥에서 바꾼 초안 파일 다시 읽기.
/// 파일 읽기·저장 다시 하기는 `WatchDrafts`(DJCApplication)가 하고(읽기는 메인 밖), 여기서는 결과를 관찰 값에 넣는다.
extension LibraryStore {
    /// 초안 폴더(조립 지점이 정한 위치, 앱은 데이터 폴더). 라이브러리 읽기·바깥 변경 확인·초안 저장이 모두 이 폴더를 쓴다.
    var draftFolder: URL { location.draftHome }

    // MARK: - 태그 초안 저장

    /// 이 저장소가 맡긴 태그 저장 가운데 실패한 곡을 메모리 입력으로 다시 저장한다(실패한 삭제도, 유스케이스 `WatchDrafts.retryFailedTags`)
    func retryFailedTagSaves() {
        rememberTagSaves(useCases.watch.retryFailedTags(attempted: tagSaveAttempts, memory: tagDrafts))
    }

    func failedTagSaves() -> Set<String> {
        useCases.watch.failedTagSaves(attempted: tagSaveAttempts)
    }

    // MARK: - 바깥 변경

    /// CLI·외부 편집의 원자적 파일 교체를 확인한다. DB·파형·재생은 다시 불러오지 않는다.
    /// 폴더 나열·초안 읽기·저장 기다리기는 메인 밖(`WatchDrafts.refresh`)에서 하고, 결과만 메인에서 적용한다.
    /// 읽는 사이 앱에서 초안을 고쳤거나(저장 입력·태그·앨범아트·초안 표시) 덱에서 큐·그리드를 끌기 시작했으면 결과를 버리고
    /// 다음 확인에서 다시 읽는다.
    func refreshExternalDrafts() async {
        guard case .loaded = phase, !isWritingRekordbox else { return }
        let watch = useCases.watch
        externalDraftRefreshCount += 1
        let request = externalDraftRefreshCount
        let tags = tagRevision, artwork = artworkChangeCount, marks = draftMarkRevision
        let refresh = await watch.refresh(since: draftFileStamps, preservingDamaged: location.movesDamagedDrafts)
        guard request == externalDraftRefreshCount, case .loaded = phase, !isWritingRekordbox, allowsLibrarySync?() ?? true,
              watch.saveRevision() == refresh.saveRevision, tagRevision == tags,
              artworkChangeCount == artwork, draftMarkRevision == marks else {
            // 이 확인이 옮긴 손상 파일은 다음 확인이 다시 보지 못하니 결과를 버려도 알리고 메모리 태그 초안을 다시 저장한다(#174).
            applyMovedDrafts(refresh.contents?.moved ?? [])
            return
        }
        let failedTags = refresh.failedTagSaves.intersection(tagSaveAttempts)
        if !failedTags.isEmpty { reportLibraryError(DraftSaveFailure.tagSaveMessage) }
        else if lastError == DraftSaveFailure.tagSaveMessage { clearLibraryError() }
        guard let contents = refresh.contents else { return }
        rememberDraftFileStamps(refresh.stamps)
        // 바깥에서 바뀐 파일 중 읽지 못하는 것은 옮겨 보관했다. 메모리 태그 초안은 아래에서 다시 저장한다(#174).
        let previousTags = tagDrafts
        // 자동 큐를 빼고 만든 옛 초안에는 곡의 자동 큐를 채운다(#145).
        let cues = watch.visibleCueDrafts(contents.cueDrafts) { self.rowsByUUID[$0]?.cues ?? [] }
        if let tags = WatchDrafts.externalTags(disk: contents.tagDrafts, memory: tagDrafts, failed: failedTags) {
            tagDrafts = tags
            // 외부 변경 뒤 옛 되돌리기가 새 초안을 덮지 않게 한다.
            undoManager?.removeAllActions(withTarget: self)
            tagRevision += 1
        }
        setDraftMarks(cue: Set(cues.keys), grid: contents.gridDraftUUIDs)
        draftCueCounts = cues.mapValues(CueCounts.init)
        draftPreviewCues = cues.mapValues { $0.cues.map(PreviewCueMark.init) }
        artworkDrafts = contents.artworkDrafts
        applyUnsavedDraftIndicators(refresh.unsaved)
        recountEdited()
        if case .pending = sidebar { refreshBase() }
        applyMovedDrafts(contents.moved, previousTags: previousTags)
        refreshUnlinkedDrafts()
        onCueDraftsReloaded?(cues)
    }

    /// 실패한 저장의 입력이 디스크보다 최신이므로 다시 읽어도 복구 진입점을 남긴다(저장 대기 입력은 메모리라 파일을 읽지 않는다).
    func applyUnsavedDraftIndicators(_ unsaved: UnsavedDrafts) {
        guard !unsaved.isEmpty else { return }
        var cue = cueDraftUUIDs, grid = gridDraftUUIDs, gain = gainDraftUUIDs
        let counted = unsaved.overlay(cue: &cue, grid: &grid, gain: &gain)
        // 바뀔 때만 넣어 표가 불필요하게 다시 그려지지 않게 한다.
        setDraftMarks(cue: cue != cueDraftUUIDs ? cue : nil, grid: grid != gridDraftUUIDs ? grid : nil,
                      gain: gain != gainDraftUUIDs ? gain : nil)
        for draft in counted { cueDraftChanged(draft) }
    }

    /// 덱에서 큐를 찍거나 지울 때마다 목록 숫자를 맞춘다.
    func cueDraftChanged(_ draft: CueDraft) {
        draftMarkRevision += 1
        let counts = draft.hasChanges ? CueCounts(draft) : nil
        if draftCueCounts[draft.trackUUID] != counts { draftCueCounts[draft.trackUUID] = counts }
        let marks = draft.hasChanges ? draft.cues.map(PreviewCueMark.init) : nil
        if draftPreviewCues[draft.trackUUID] != marks { draftPreviewCues[draft.trackUUID] = marks }
    }

    func draftChanged(trackUUID: String, kind: DeckModel.DraftKind, exists: Bool) {
        draftMarkRevision += 1
        setDraftMark(kind, trackUUID: trackUUID, exists: exists)
        if kind == .cue, !exists { draftPreviewCues[trackUUID] = nil }
        updateEdited(trackUUID)
        if case .pending = sidebar { refreshBase() }
    }

    func recoveryKinds(for row: TrackRow) -> [DraftRecoveryKind] {
        guard !row.isUsb, !row.isStaged, !row.track.isStreaming else { return [] }
        let uuid = row.track.uuid
        return DraftRecoveryKind.allCases.filter { kind in
            switch kind {
            case .tags: tagDrafts[uuid]?.hasChanges == true
            case .cues: cueDraftUUIDs.contains(uuid) || recoveryMemoryInput?(uuid, kind)?.hasChanges == true
            case .grid: gridDraftUUIDs.contains(uuid) || recoveryMemoryInput?(uuid, kind)?.hasChanges == true
            }
        }
    }

    func hasDraft(_ kind: DeckModel.DraftKind, trackUUID: String) -> Bool {
        switch kind {
        case .cue: cueDraftUUIDs.contains(trackUUID)
        case .grid: gridDraftUUIDs.contains(trackUUID)
        case .gain: gainDraftUUIDs.contains(trackUUID)
        }
    }

    /// 선택한 곡의 현재 정보만 갱신한다. 다른 종류의 초안은 다시 읽지 않는다.
    func updateRecoveryRow(_ current: TrackRow) {
        let previous = rowsByUUID[current.track.uuid]
        var row = TrackRow(track: current.track, cues: current.cues, playCount: current.playCount,
                           tempoChanges: previous?.tempoChanges ?? current.tempoChanges,
                           autoGain: previous?.autoGain ?? current.autoGain, commentRule: commentPreset.rule)
        row.fileMissing = previous?.fileMissing ?? current.fileMissing
        row.keyEstimated = previous?.keyEstimated ?? current.keyEstimated
        row.inPlaylist = previous?.inPlaylist ?? current.inPlaylist
        replaceRow(row)
        tagRevision += 1
    }

}
