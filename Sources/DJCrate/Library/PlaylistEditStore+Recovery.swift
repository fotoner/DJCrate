import DJCApplication
import DJCDomain
import Foundation

extension PlaylistEditStore {
    var blockedPlaylistRecoveryIDs: [String] {
        var seen = Set<String>()
        return zip(playlistDraft.steps, playlistProjection.blocked).compactMap { step, reason in
            let id = step.edit.playlist.layoutID
            return reason != nil && seen.insert(id).inserted ? id : nil
        }
    }

    /// - Parameter prefetched: 복구 시트가 재생 목록 줄 여럿을 위해 한 번 읽어 둔 현재 라이브러리(`readPlaylistRecoveryPrefetch`)
    func preparePlaylistRecovery(playlist id: String, prefetched: PlaylistRecoveryCurrent? = nil) async throws -> PlaylistRecoveryReview {
        resyncForRecovery()
        guard playlistRecoveryAllowed, !library.isRecoveringDraft else { throw playlistRecoveryRefused() }
        let original = playlistDraft
        library.isRecoveringDraft = true
        defer { library.isRecoveringDraft = false }
        let current: PlaylistRecoveryCurrent
        if let prefetched { current = prefetched } else { current = try await readPlaylistRecoveryCurrent() }
        try Task.checkCancellation()
        guard playlistRecoveryAllowed, Self.sameSteps(playlistDraft, original) else { throw playlistRecoveryRefused() }
        return try RecoverDrafts.review(playlist: id, draft: original, current: current)
    }

    /// - Parameter latest: 복구 시트가 저장하기 전에 한 번 다시 읽은 현재 라이브러리
    func applyPlaylistRecovery(_ review: PlaylistRecoveryReview, reapply: Bool, latest prefetched: PlaylistRecoveryCurrent? = nil) async throws {
        guard playlistRecoveryAllowed, !library.isRecoveringDraft, Self.sameSteps(playlistDraft, review.original) else { throw playlistRecoveryRefused() }
        library.isRecoveringDraft = true
        defer { library.isRecoveringDraft = false }
        let current: PlaylistRecoveryCurrent
        if let prefetched { current = prefetched } else { current = try await readPlaylistRecoveryCurrent() }
        try Task.checkCancellation()
        guard playlistRecoveryAllowed, Self.sameSteps(playlistDraft, review.original) else { throw playlistRecoveryRefused() }
        let resolved = try RecoverDrafts.resolvePlaylist(review, reapply: reapply, latest: current)
        // 새 기준을 저장하지 못했으면 메모리에도 적용하지 않아 다음 쓰기에서 조용히 풀리지 않는다.
        // 저장에 실패한 동안 기억한 출처를 식별자 없는 단계에 더하고, 저장하면 비운다(#295 리뷰 F10)
        try library.useCases.playlists.saveDraft(resolved, carrying: unsavedStepOrigins)
        unsavedStepOrigins = []
        playlistDraft = resolved
        // 저장이 준 단계 식별자를 받는다: 받지 않으면 다음 저장(다음 복구 줄 등)이 식별자 없는 단계를 새 사람 단계로 다시 쓴다(#295 리뷰 F11)
        adoptSavedIdentifiers()
        // 저장했으니 저장 실패 표시와 알림을 거둔다(#295 리뷰 F17)
        applyPlaylistSave(nil)
        rekordboxPlaylists = current.layout
        let projected = resolved.project(onto: current.layout, contentIDs: current.contentIDs).layout
        let visibleIDs = Set(projected.subtree(of: review.playlistID).flatMap { projected.item($0)?.trackIDs ?? [] })
        for id in visibleIDs {
            if let row = current.rows[id] { library.updateRecoveryRow(row) }
        }
        library.clearLibraryUndo()
        refreshPlaylists()
    }

    /// 디스크 초안을 읽지 못했으면(저장한 단계의 식별자를 다시 받지 못함 포함) 복구하지 않는다: 메모리 초안으로 디스크 초안을 덮지 않게(#295 리뷰 F11)
    private var playlistRecoveryAllowed: Bool {
        !library.libraryBusy && !library.isLoading && !playlistDraftNeedsSync && (library.allowsLibrarySync?() ?? true)
    }

    /// 복구를 막은 이유: 디스크 초안을 읽지 못했으면 그 이유(현재값을 다시 가져와도 풀리지 않는다), 아니면 비교 뒤 바뀜(#295 리뷰 F16)
    private func playlistRecoveryRefused() -> DJCError {
        playlistDraftNeedsSync ? .writeRefused(Self.syncFailureText) : RecoverDrafts.changedError
    }

    /// 복구를 열 때: 디스크 초안을 읽지 못했던 상태면 먼저 다시 읽는다. 권한을 되찾았는데 파일 수정 시각이 그대로면 감시가 다시 읽지 않는다(#295 리뷰 F16)
    private func resyncForRecovery() {
        if playlistDraftNeedsSync { _ = syncExternal() }
    }

    /// 내용과 단계 식별자가 모두 같은지. `PlaylistDraft.==`는 식별자를 보지 않아, 그새 식별자가 채워진 초안에 낡은 준비(식별자 없음)를
    /// 적용하면 저장하지 못했던 단계가 새 사람 단계로 다시 쓰인다(#295 리뷰 F15)
    static func sameSteps(_ lhs: PlaylistDraft, _ rhs: PlaylistDraft) -> Bool { lhs == rhs && lhs.stepIDs == rhs.stepIDs }

    /// 복구 시트가 재생 목록 줄 전체를 위해 현재 라이브러리를 한 번 읽는다(줄마다 사본을 뜨지 않게, #232).
    func readPlaylistRecoveryPrefetch() async throws -> PlaylistRecoveryCurrent {
        resyncForRecovery()
        guard playlistRecoveryAllowed, !library.isRecoveringDraft else { throw playlistRecoveryRefused() }
        library.isRecoveringDraft = true
        defer { library.isRecoveringDraft = false }
        let current = try await readPlaylistRecoveryCurrent()
        try Task.checkCancellation()
        return current
    }

    private func readPlaylistRecoveryCurrent() async throws -> PlaylistRecoveryCurrent {
        library.recoverySnapshotReads += 1
        let source = RecoverDrafts.playlistSource(location: library.location, opened: library.snapshotURL)
        return try await library.useCases.recover.readPlaylistCurrent(source: source.database, share: source.share)
    }
}
