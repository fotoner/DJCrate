import DJCApplication
import DJCDomain
import Foundation

/// rekordbox 쓰기(반영 세션, DJCApplication `ReflectionSession`)가 보는 이 화면의 초안 상태와, 세션이 쓰거나 되돌린 결과를 화면에 맞추는 곳.
/// 무엇을 지우고 되살리고 옮길지는 세션이 정한다. 이 확장은 메모리 초안·표시·선택만 맞춘다(조립 지점 `AppComposition.reflection`이 세션의 포트에 잇는다).
extension LibraryStore {
    /// 고른 곡 가운데 rekordbox에 쓸 곡(메뉴·툴바가 보일지·곡 수를 정한다). 반영 세션과 같은 규칙(`ReflectionTargets`, 저장 대기 입력 포함)
    func writeTargets(_ rows: [TrackRow]) -> [TrackRow] {
        ReflectionTargets.write(rows, pending: ReflectionTargets.pending(marked: pendingUUIDs, unsaved: useCases.watch.unsavedUUIDs()))
    }

    /// 고른 곡 가운데 rekordbox 컬렉션에서 뺄 곡(메뉴가 보일지·곡 수를 정한다). 반영 세션과 같은 규칙
    func deleteTargets(_ rows: [TrackRow]) -> [TrackRow] { ReflectionTargets.delete(rows, iTunesSelection: isITunesSelection) }

    /// 세션이 읽는 지금 상태(메모리 초안·표시·추가 목록)
    func reflectionState() -> ReflectionLibraryState {
        ReflectionLibraryState(rows: rowsByUUID, cueDraftUUIDs: cueDraftUUIDs, gridDraftUUIDs: gridDraftUUIDs, gainDraftUUIDs: gainDraftUUIDs,
                               tagDrafts: tagDrafts, artworkDrafts: artworkDrafts, mergeDrafts: mergeDrafts, playlistDraft: playlistDraft,
                               playlistDraftUnsaved: playlistDraftUnsaved, rekordboxPlaylists: rekordboxPlaylists,
                               playlistImports: playlistImports, playlistImportsLoadFailed: playlistImportsLoadFailed, unreadableDraftKinds: unreadableDraftKinds, failedTagSaves: failedTagSaves(),
                               staged: staged, estimatingGrids: gridJob != nil, iTunesSelection: isITunesSelection,
                               deckStagedUUID: deckTrackID.flatMap { rowsByID[$0] }.flatMap { $0.isStaged ? $0.track.uuid : nil },
                               lastError: lastError, pendingHistories: history.pendingHistoryImports)
    }

    /// 세션이 알린 결과로 메모리 초안·표시를 맞춘다
    func applyReflection(_ change: ReflectionLibraryChange) {
        switch change {
        case let .draftsCleared(kind, uuids, cueCounts):
            for uuid in uuids {
                if cueCounts { draftCueCounts[uuid] = nil }
                draftChanged(trackUUID: uuid, kind: DeckModel.DraftKind(kind), exists: false)
            }
        case let .tagDrafts(drafts): replaceTagDrafts(drafts)
        case let .mergeDrafts(drafts, failure, moved): applyMergeDraftsAfterWrite(drafts, failure: failure, moved: moved)
        case let .playlistWritten(cleanup): applyPlaylistWrite(cleanup)
        case let .artworkCleared(uuids, failed): clearWrittenArtwork(uuids, failed: failed)
        case let .artworkRestored(drafts, touched): showRestoredArtwork(drafts, touched: touched)
        case let .unstaged(uuids): _ = unstage(uuids: uuids)
        case let .restaged(tracks): _ = restage(tracks)
        case let .deckTrackMoved(id): moveDeckTrack(to: id)
        case let .playlistImportsReset(reset): applyPlaylistImportsReset(reset)
        case .unlinkedDraftsChanged: refreshUnlinkedDrafts()
        case let .libraryError(text): reportLibraryError(text)
        case let .showAdded(id):
            sidebar = .filter(.all)
            search = ""
            selection = [id]
        case let .deselected(ids): selection.subtract(ids)
        case let .lastWriteBackup(url): lastWriteBackup = url
        case let .followUp(notes): writeFollowUp = notes
        case .writeBackupsChanged: refreshWriteBackups()
        case let .historyMarkFailed(warning): toast = .notice(ArchiveUsbHistories.queueSaveFailureTitle, warning)
        }
    }

    /// 쓰는 동안 잠근다. `deck`이면 덱도 재생을 멈추고 조작을 막는다(iTunes 동기화는 덱을 잠그지 않는다).
    func setWriteLock(_ locked: Bool, deck: Bool = true) {
        isWritingRekordbox = locked
        if deck { onWriteLock?(locked) }
    }

    /// 쓰기·복원 뒤 조용히 다시 읽는다. 쓴 곡은 새 스냅샷을 읽은 뒤 덱에 알리고, 되살린 재생 목록 편집은 읽은 뒤 쌓는다(읽지 못하면 다음 읽기 뒤에).
    func reloadAfterWrite(written: Set<String>, playlistEdits: [PlaylistEdit]) async -> Bool {
        writtenAwaitingReload.formUnion(written)
        playlistEditsAwaitingReload += playlistEdits
        return await reloadAfterWrite()
    }

    /// 태그 초안을 통째로 바꿨다(쓴 뒤 비운 초안, 되돌린 뒤 백업의 초안, 반영 세션이 저장했다). 변경이 없는 초안은 메모리에서 지운다.
    /// 쓰는 동안은 잠겨 있고 되돌리기 목록도 비어 있어 되돌리기 단위로 남기지 않는다.
    func replaceTagDrafts(_ drafts: [TagDraft]) {
        guard !drafts.isEmpty else { return }
        for draft in drafts {
            tagDrafts[draft.trackUUID] = draft.hasChanges ? draft : nil
            updateEdited(draft.trackUUID)
        }
        rememberTagSaves(drafts)
        tagRevision += 1
        if case .pending = sidebar { refreshBase() }
    }
}

extension DeckModel.DraftKind {
    init(_ kind: DraftSaveKind) {
        switch kind {
        case .cue: self = .cue
        case .grid: self = .grid
        case .gain: self = .gain
        }
    }
}
