import DJCApplication
import DJCDomain
import Foundation

extension LibraryStore {
    var blockedPlaylistRecoveryIDs: [String] {
        var seen = Set<String>()
        return zip(playlistDraft.steps, playlistProjection.blocked).compactMap { step, reason in
            let id = step.edit.playlist.layoutID
            return reason != nil && seen.insert(id).inserted ? id : nil
        }
    }

    /// - Parameter prefetched: 복구 시트가 재생 목록 줄 여럿을 위해 한 번 읽어 둔 현재 라이브러리(`readPlaylistRecoveryPrefetch`)
    func preparePlaylistRecovery(playlist id: String, prefetched: PlaylistRecoveryCurrent? = nil) async throws -> PlaylistRecoveryReview {
        guard playlistRecoveryAllowed, !isRecoveringDraft else { throw playlistRecoveryChanged() }
        let original = playlistDraft
        isRecoveringDraft = true
        defer { isRecoveringDraft = false }
        let current: PlaylistRecoveryCurrent
        if let prefetched { current = prefetched } else { current = try await readPlaylistRecoveryCurrent() }
        try Task.checkCancellation()
        guard playlistRecoveryAllowed, playlistDraft == original else { throw playlistRecoveryChanged() }
        return try RecoverDrafts.review(playlist: id, draft: original, current: current)
    }

    /// - Parameter latest: 복구 시트가 저장하기 전에 한 번 다시 읽은 현재 라이브러리
    func applyPlaylistRecovery(_ review: PlaylistRecoveryReview, reapply: Bool, latest prefetched: PlaylistRecoveryCurrent? = nil) async throws {
        guard playlistRecoveryAllowed, !isRecoveringDraft, playlistDraft == review.original else { throw playlistRecoveryChanged() }
        isRecoveringDraft = true
        defer { isRecoveringDraft = false }
        let current: PlaylistRecoveryCurrent
        if let prefetched { current = prefetched } else { current = try await readPlaylistRecoveryCurrent() }
        try Task.checkCancellation()
        guard playlistRecoveryAllowed, playlistDraft == review.original else { throw playlistRecoveryChanged() }
        let resolved = try RecoverDrafts.resolvePlaylist(review, reapply: reapply, latest: current)
        // 새 기준을 저장하지 못했으면 메모리에도 적용하지 않아 다음 쓰기에서 조용히 풀리지 않는다.
        try useCases.playlists.saveDraft(resolved)
        playlistDraft = resolved
        playlistDraftUnsaved = false
        rekordboxPlaylists = current.layout
        let projected = resolved.project(onto: current.layout, contentIDs: current.contentIDs).layout
        let visibleIDs = Set(projected.subtree(of: review.playlistID).flatMap { projected.item($0)?.trackIDs ?? [] })
        for id in visibleIDs {
            if let row = current.rows[id] { updateRecoveryRow(row) }
        }
        undoManager?.removeAllActions(withTarget: self)
        refreshPlaylists()
    }

    private var playlistRecoveryAllowed: Bool {
        !isWritingRekordbox && !isLoading && (allowsLibrarySync?() ?? true)
    }

    private func playlistRecoveryChanged() -> DJCError { RecoverDrafts.changedError }

    /// 복구 시트가 재생 목록 줄 전체를 위해 현재 라이브러리를 한 번 읽는다(줄마다 사본을 뜨지 않게, #232).
    func readPlaylistRecoveryPrefetch() async throws -> PlaylistRecoveryCurrent {
        guard playlistRecoveryAllowed, !isRecoveringDraft else { throw playlistRecoveryChanged() }
        isRecoveringDraft = true
        defer { isRecoveringDraft = false }
        let current = try await readPlaylistRecoveryCurrent()
        try Task.checkCancellation()
        return current
    }

    private func readPlaylistRecoveryCurrent() async throws -> PlaylistRecoveryCurrent {
        recoverySnapshotReads += 1
        let source = RecoverDrafts.playlistSource(location: location, opened: snapshotURL)
        return try await useCases.recover.readPlaylistCurrent(source: source.database, share: source.share)
    }
}
