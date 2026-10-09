import DJCApplication
import DJCDomain
import Foundation

/// 막힌 초안 복구(#232)의 화면 쪽: 시트가 열린 동안 쓰기를 막고, 비교 사이 입력·화면 상태가 그대로인지 보고, 결과를 메모리 초안·표시에 얹는다.
/// 현재값 읽기·고른 대로 새 기준 만들기·저장은 유스케이스 `RecoverDrafts`가 한다.

extension LibraryStore {
    /// 막힌 초안 복구 시트가 열려 있는 동안은 rekordbox에 쓰는 입구(쓰기·넣기·빼기·복원)를 막는다. 시트를 저장하거나 취소하면 풀린다(#232).
    var writesBlockedBySheet: Bool { recoverySheet != nil }
    static var writesBlockedBySheetReason: String { String(ui: "막힌 초안 비교 창에서 저장하거나 취소한 뒤 다시 시도하세요") }

    /// 막힌 입구를 눌렀을 때 아무 반응이 없지 않게 알린다.
    func announceWritesBlockedBySheet() {
        toast = .notice(String(ui: "막힌 초안 비교가 열려 있어 쓰지 않았습니다"), String(ui: "비교 창에서 저장하거나 취소한 뒤 다시 시도하세요."))
    }

    /// 복구할 입력: 태그는 메모리 초안, 큐·그리드는 덱의 메모리 입력이 있으면 그것, 없으면 저장 대기 입력·초안 파일
    func recoveryInput(uuid: String, kind: DraftRecoveryKind) -> RecoveryDraft? {
        if kind == .tags { return tagDrafts[uuid].map(RecoveryDraft.tags) }
        if let memory = recoveryMemoryInput?(uuid, kind) { return memory }
        return useCases.recover.savedInput(uuid: uuid, kind: kind)
    }

    /// - Parameter prefetched: 복구 시트가 줄 여럿을 한 번에 읽어 둔 현재값(`readRecoveryPrefetches`). 이 초안의 것이 아니면 쓰지 않고 새로 읽는다.
    func prepareDraftRecovery(row: TrackRow, kind: DraftRecoveryKind,
                              readCurrent: ((RecoveryDraft) async throws -> RecoveryDraft)? = nil,
                              prefetched: RecoveryPrefetch? = nil) async throws -> DraftRecoveryReview {
        guard !isRecoveringDraft, !isWritingRekordbox, !isLoading, allowsLibrarySync?() ?? true,
              !row.isUsb, !row.isStaged, !row.track.isStreaming,
              rowsByUUID[row.track.uuid] != nil,
              let original = recoveryInput(uuid: row.track.uuid, kind: kind), original.hasChanges else {
            throw DJCError.writeRefused(String(ui: "복구할 초안을 확인하지 못했으니 편집을 저장하고 곡을 다시 선택하세요."))
        }
        isRecoveringDraft = true
        defer { isRecoveringDraft = false }
        useCases.recover.flush()
        let read: RecoveryRead
        if let prefetched, prefetched.original == original { read = prefetched.read } else { read = try await recoveryCurrent(original, reader: readCurrent) }
        try Task.checkCancellation()
        try checkRecoveryInput(original)
        return DraftRecoveryReview(original: original, current: read.draft, title: read.row?.title ?? row.title,
                                   currentRow: read.row, currentGrid: read.grid)
    }

    /// - Parameter latest: 복구 시트가 저장하기 전에 줄 여럿을 한 번에 다시 읽은 현재값. 이 초안의 것이 아니면 쓰지 않고 새로 읽는다.
    func applyDraftRecovery(_ review: DraftRecoveryReview, choice: DraftRecoveryChoice,
                            readCurrent: ((RecoveryDraft) async throws -> RecoveryDraft)? = nil,
                            save: ((RecoveryDraft) throws -> Void)? = nil,
                            latest prefetched: RecoveryPrefetch? = nil) async throws {
        guard !isRecoveringDraft else { throw recoveryChangedError() }
        isRecoveringDraft = true
        defer { isRecoveringDraft = false }
        try checkRecoveryInput(review.original)
        let latest: RecoveryRead
        if let prefetched, prefetched.original == review.original { latest = prefetched.read } else {
            latest = try await recoveryCurrent(review.original, reader: readCurrent)
        }
        try Task.checkCancellation()
        try checkRecoveryInput(review.original)
        let resolved = try RecoverDrafts.resolve(review, latest: latest, choice: choice)
        // 저장과 메모리 갱신 사이에는 양보하지 않는다. 먼저 걸린 비동기 저장부터 끝낸다.
        useCases.recover.flush()
        try checkRecoveryInput(review.original)
        if let save { try save(resolved) } else { try useCases.recover.save(resolved, restoring: review.original) }
        undoManager?.removeAllActions(withTarget: self)
        switch resolved {
        case let .tags(draft):
            tagDrafts[draft.trackUUID] = draft.hasChanges ? draft : nil
            tagRevision += 1
            updateEdited(draft.trackUUID)
        case let .cues(draft):
            cueDraftChanged(draft)
            draftChanged(trackUUID: draft.trackUUID, kind: .cue, exists: draft.hasChanges)
        case let .grid(draft): draftChanged(trackUUID: draft.trackUUID, kind: .grid, exists: draft.hasChanges)
        }
        if let row = latest.row { updateRecoveryRow(row) }
        onDraftRecovered?(resolved, latest.row.flatMap { rowsByUUID[$0.track.uuid] }, latest.grid)
        refreshBase()
    }

    private func checkRecoveryInput(_ original: RecoveryDraft) throws {
        guard !isWritingRekordbox, !isLoading, allowsLibrarySync?() ?? true,
              rowsByUUID[original.uuid] != nil,
              recoveryInput(uuid: original.uuid, kind: original.kind) == original else {
            throw recoveryChangedError()
        }
    }

    func recoveryChangedError() -> DJCError { RecoverDrafts.changedError }

    /// 한 번 읽어 둔 현재값과 그 초안. 초안이 달라졌으면 쓰지 않는다.
    /// 복구 시트가 곡 줄 전체의 현재값을 사본 하나로 읽는다(줄마다 사본을 뜨고 라이브러리 전체를 읽지 않게, #232).
    /// 곡을 찾지 못하는 등 초안마다의 실패는 그 초안의 결과로 남기고 나머지는 읽는다.
    func readRecoveryPrefetches(_ originals: [RecoveryDraft],
                                readCurrent: ((RecoveryDraft) async throws -> RecoveryDraft)? = nil) async throws -> [Result<RecoveryPrefetch, any Error>] {
        guard !originals.isEmpty else { return [] }
        guard !isRecoveringDraft, !isWritingRekordbox, !isLoading, allowsLibrarySync?() ?? true else { throw recoveryChangedError() }
        isRecoveringDraft = true
        defer { isRecoveringDraft = false }
        useCases.recover.flush()
        let reads = try await recoveryReads(originals, reader: readCurrent)
        try Task.checkCancellation()
        return zip(originals, reads).map { original, read in read.map { RecoveryPrefetch(original: original, read: $0) } }
    }

    private func recoveryCurrent(_ original: RecoveryDraft, reader: ((RecoveryDraft) async throws -> RecoveryDraft)?) async throws -> RecoveryRead {
        try await recoveryReads([original], reader: reader)[0].get()
    }

    private func recoveryReads(_ originals: [RecoveryDraft],
                               reader: ((RecoveryDraft) async throws -> RecoveryDraft)?) async throws -> [Result<RecoveryRead, any Error>] {
        recoverySnapshotReads += 1
        if let reader {
            var results: [Result<RecoveryRead, any Error>] = []
            for original in originals {
                do { results.append(.success(RecoveryRead(draft: try await reader(original), row: nil, grid: nil))) }
                catch { results.append(.failure(error)) }
            }
            return results
        }
        let source = try RecoverDrafts.draftSource(location: location, opened: snapshotURL)
        return try await useCases.recover.readCurrent(originals, source: source.database, share: source.share)
    }
}
