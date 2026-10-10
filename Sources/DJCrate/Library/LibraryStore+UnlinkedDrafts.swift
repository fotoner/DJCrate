import DJCApplication
import DJCDomain
import Foundation

/// 스냅샷의 곡·추가한 곡 어디에도 이어지지 않는 초안(#175). 찾기·자세한 목록은 유스케이스 `WatchDrafts`가 하고, 여기서는 표시와 버린 뒤 상태를 맞춘다. 시트는 `UnlinkedDraftsModel`이 맡는다.
extension LibraryStore {
    /// 목록 위 안내에 쓸 연결되지 않은 초안 곡을 다시 센다(파일 이름만 본다). 라이브러리를 읽기 전에는 모른다.
    func refreshUnlinkedDrafts() {
        guard case .loaded = phase, !rowsByUUID.isEmpty else {
            if !unlinkedDraftUUIDs.isEmpty { unlinkedDraftUUIDs = [] }
            return
        }
        let unlinked = useCases.watch.unlinked(linked: Set(rowsByUUID.keys).union(staged.map(\.uuid)))
        if unlinked != unlinkedDraftUUIDs { unlinkedDraftUUIDs = unlinked }
    }

    /// 연결되지 않은 초안 시트를 띄운다(띄울 때마다 새 화면 모델)
    func openUnlinkedDrafts() {
        unlinkedDraftsSheet = UnlinkedDraftsModel(store: self)
    }

    /// 고른 곡의 초안(큐·그리드·게인·태그·그림)을 버리고(유스케이스 `WatchDrafts.discardUnlinked`) 표시를 맞춘다. 버리지 못한 곡 수를 돌려준다.
    func discardUnlinkedDrafts(_ uuids: Set<String>) -> Int {
        let targets = uuids.intersection(unlinkedDraftUUIDs)
        guard !targets.isEmpty, !isWritingRekordbox else { return 0 }
        let result = useCases.watch.discardUnlinked(targets, attemptedTags: tagSaveAttempts)
        for uuid in result.removedArtwork {
            artworkDrafts[uuid] = nil
            artworkChangeCount += 1
        }
        if !result.clearedTags.isEmpty {
            for uuid in result.clearedTags { tagDrafts[uuid] = nil }
            rememberTagSaves(result.clearedTags.map { TagDraft(trackUUID: $0, base: TagFields()) })
            tagRevision += 1
        }
        applyMovedDrafts(result.moved)
        refreshUnlinkedDrafts()
        return result.failed.count
    }
}
