import DJCApplication
import DJCDomain
import Foundation

/// 스냅샷의 곡·추가한 곡 어디에도 이어지지 않는 초안(#175). 찾기·자세한 목록은 유스케이스 `WatchDrafts`가 하고, 여기서는 표시와 버리기를 맞춘다.
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

    /// 연결되지 않은 초안의 자세한 목록(최근에 고친 것부터)
    func unlinkedDrafts() -> [UnlinkedDraft] { useCases.watch.unlinkedDetails(unlinkedDraftUUIDs) }

    /// 고른 곡의 초안(큐·그리드·게인·태그·그림)을 버린다(유스케이스 `WatchDrafts.discardUnlinked`). 버리지 못한 곡이 있으면 이유와 할 일을 돌려준다.
    func discardUnlinkedDrafts(_ uuids: Set<String>) -> String? {
        let targets = uuids.intersection(unlinkedDraftUUIDs)
        guard !targets.isEmpty, !isWritingRekordbox else { return nil }
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
        guard !result.failed.isEmpty else { return nil }
        return String(ui: "\(result.failed.count)곡의 초안을 버리지 못했으니 초안 폴더의 접근 권한을 확인한 뒤 다시 버리세요.")
    }
}
