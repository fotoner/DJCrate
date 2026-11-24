import DJCDomain
import Foundation

/// 자동 저장(#403)이 부르는 세션 단계: 저장 대기를 자동으로 쓸 것과 남길 것으로 나누고(`autoInventory`), 고른 묶음을 확인 창 없이 쓰고(`autoWrite`),
/// 정리 전에 멈춘 쓰기의 미정리 목록을 다시 정리한다(`resumeCleanups`). 쓸지 말지의 마지막 판정은 늘 쓰기 관문이 다시 한다.
extension ReflectionSession {
    // MARK: - 저장 대기 나누기(R4·R5·R6·R14·R23)

    /// 저장 대기를 자동으로 쓸 것과 남길 것으로 나눈다. 디스크 도장을 보므로 걸린 저장을 끝낸 뒤 메인 액터 밖에서 읽는다.
    /// - Parameters:
    ///   - cancelled: 대량 유예를 [취소]한 판(R14). 새 판을 받으면 저절로 풀린다
    ///   - needsConfirmation: 미리 보기에서 막혀(제외·손실 포함) 뺀 판(R6). 새 편집(새 판) 전까지 다시 미리 보지 않는다
    public func autoInventory(cancelled: Set<DraftRevision>, needsConfirmation: Set<DraftRevision>) async -> AutoReflectionInventory {
        let state = ports.library.state(), files = ports.drafts, needsAnalysis = ports.audio.needsAnalysis
        return await BlockingWork.run(qos: .utility) {
            files.flush()
            return Self.inventory(state: state, files: files, needsAnalysis: needsAnalysis, cancelled: cancelled, needsConfirmation: needsConfirmation)
        }
    }

    /// 나누는 규칙(값만 본다)
    /// - 대상 편집: 사람이 한 큐·그리드(분석 붙이기 제외)·태그(평점·곡 색 포함)·재생 목록 편집(지우기 제외)
    /// - 대상 밖: 분석 붙이기·앨범아트·합치기·추가한 곡 넣기·재생 기록·재생 목록 지우기. 같은 곡의 대상 편집은 그대로 자동으로 쓴다(R4)
    /// - base 없음: 게인(base가 없는 형식, R23)
    /// - 제안: 사람 편집만이 아니거나 해시가 맞지 않는 초안(R5)
    nonisolated static func inventory(state: ReflectionLibraryState, files: DraftStore, needsAnalysis: @Sendable (String?) -> Bool,
                                      cancelled: Set<DraftRevision>, needsConfirmation: Set<DraftRevision>) -> AutoReflectionInventory {
        var inventory = AutoReflectionInventory()
        func judge(_ revision: DraftRevision) -> ReflectionLeftover? {
            if cancelled.contains(revision) { return .cancelled }
            if needsConfirmation.contains(revision) { return .needsConfirmation }
            return nil
        }
        for uuid in state.pendingUUIDs.sorted() {
            // 목록에 없는 곡의 초안(연결되지 않은 초안)은 쓸 곳이 없다
            guard let row = state.rows[uuid] else { continue }
            var keys: [DraftKey] = []
            if state.cueDraftUUIDs.contains(uuid) { keys.append(DraftKey(.cue, uuid)) }
            if state.gridDraftUUIDs.contains(uuid) {
                if needsAnalysis(row.track.analysisDataPath) {
                    inventory.leftoverKeys[DraftKey(.grid, uuid)] = .outsideScope
                } else {
                    keys.append(DraftKey(.grid, uuid))
                }
            }
            if state.gainDraftUUIDs.contains(uuid) { inventory.leftoverKeys[DraftKey(.gain, uuid)] = .noBase }
            if state.tagDrafts[uuid]?.hasChanges == true { keys.append(DraftKey(.tag, uuid)) }
            if state.artworkDrafts[uuid] != nil { inventory.leftoverKeys[DraftKey(.artwork, uuid)] = .outsideScope }
            for merge in state.mergeDrafts where merge.members.contains(where: { $0.trackUUID == uuid }) {
                inventory.leftoverKeys[DraftKey(.merge, merge.id)] = .outsideScope
            }
            // 추가한 곡은 곡 넣기로만 쓴다(대상 밖)
            if row.isStaged {
                for key in keys { inventory.leftoverKeys[key] = .outsideScope }
                continue
            }
            for key in keys {
                // 화면 표시만 남고 디스크에 없는 초안(방금 지웠다)은 저장 대기가 아니다
                guard files.currentHash(key) != nil else { continue }
                let stamp = files.stamp(key)
                if let stamp { inventory.known.insert(stamp.revision) }
                guard let stamp, files.suggestion(key) == nil else {
                    inventory.leftoverKeys[key] = .suggestion
                    continue
                }
                if let leftover = judge(stamp.revision) {
                    inventory.leftoverKeys[key] = leftover
                } else {
                    inventory.tracks[uuid, default: [:]][key] = stamp.revision
                }
            }
            if let auto = inventory.tracks[uuid] {
                let clearsCues = auto[DraftKey(.cue, uuid)] != nil && files.cueDraft(uuid)?.clearsValues == true
                let clearsTags = auto[DraftKey(.tag, uuid)] != nil && files.tagDraft(uuid)?.clearsValues == true
                if clearsCues || clearsTags { inventory.clearing.insert(uuid) }
            }
        }
        inventory.histories = state.pendingHistories.count
        inventory.steps = playlistSteps(state: state, files: files, judge: judge)
        inventory.known.formUnion(inventory.steps.compactMap(\.revision))
        return inventory
    }

    /// 재생 목록 단계마다 자동으로 쓸 수 있는지. 메모리 초안이 디스크와 같을 때만 본다(같지 않으면 저장을 마친 뒤 다음 판정이 본다)
    nonisolated static func playlistSteps(state: ReflectionLibraryState, files: DraftStore,
                                          judge: (DraftRevision) -> ReflectionLeftover?) -> [AutoReflectionInventory.Step] {
        guard !state.playlistDraft.isEmpty, !state.playlistDraftNeedsSync, !state.playlistDraftUnsaved else { return [] }
        let disk = files.playlistDraft()
        guard disk == state.playlistDraft else { return [] }
        let stamps = files.playlistStamps(), suggestions = files.playlistSuggestions()
        let projection = disk.project(onto: state.rekordboxPlaylists, contentIDs: Set(state.rows.values.map(\.track.id)))
        let blocked = projection.blocked
        // 곡 빼기·옮기기는 그 목록의 남은 곡 번호를 다시 매긴다: 그 목록의 곡 수(rekordbox와 초안을 얹은 모양 중 큰 쪽)만큼 센다(R14)
        func size(_ id: String) -> Int {
            max(state.rekordboxPlaylists.item(id)?.entries.count ?? 0, projection.layout.item(id)?.entries.count ?? 0)
        }
        return disk.steps.indices.map { index in
            let step = disk.steps[index]
            let revision = stamps.indices.contains(index) ? stamps[index].revision : nil
            let leftover: ReflectionLeftover? = if case .delete = step.edit {
                .outsideScope
            } else if revision == nil || (suggestions.indices.contains(index) ? suggestions[index] : .unknownOrigin) != nil {
                .suggestion
            } else if blocked.indices.contains(index), blocked[index] != nil {
                .needsConfirmation
            } else {
                revision.flatMap(judge)
            }
            let id = step.edit.playlist.layoutID
            return AutoReflectionInventory.Step(playlist: id, rows: AutoReflectionInventory.Step.rows(of: step.edit, playlistSize: size(id)),
                                                revision: revision, leftover: leftover)
        }
    }

    // MARK: - 자동으로 쓰기(R1·R6·R21)

    /// 자동 저장 한 번의 결과
    public enum AutoWriteOutcome: Sendable {
        /// 썼다. `unwritten`은 묶음에 골랐지만 쓰지 않은 판(미리 보기에서 막힘·제외 → 확인 필요, R6)
        case written(RekordboxWriteReport, unwritten: Set<DraftRevision>)
        /// 미리 보니 쓸 것이 없다
        case nothingWritten(unwritten: Set<DraftRevision>)
        /// 이미 쓰는 중이다(다른 쓰기·복원)
        case busy
        /// rekordbox·Agent가 켜져 있다(관문도 다시 본다)
        case rekordboxRunning
        case cancelled
        case failed(any Error)
    }

    /// 고른 묶음을 확인 창 없이 쓴다(R6: 배경에서 묻지 않는다). 쓰는 곡만 잠그고(R21) 덱 재생은 멈추지 않는다.
    /// 미리 보기에서 막힌 초안은 빼고 나머지를 쓴다. 재생 목록 단계가 하나라도 막히면 이번에는 재생 목록을 쓰지 않는다(AR-9).
    /// 결과는 화면에 자동 저장으로 알린다(토스트 없이 활동 기록, R15는 화면 몫). 실패 분류(멈춤·보류·중단)는 엔진이 한다.
    public func autoWrite(_ chunk: AutoReflectionChunk) async -> AutoWriteOutcome {
        guard !ports.lock.isLocked() else { return .busy }
        // 실행 확인은 프로세스 목록을 읽는 막는 일이라 메인 액터 밖에서 한다
        let running = ports.runningApps.isRekordboxRunning
        guard !(await BlockingWork.run(qos: .userInitiated) { running() }) else { return .rekordboxRunning }
        guard !ports.lock.isLocked() else { return .busy }
        let early = ports.library.state()
        let rows = chunk.tracks.keys.sorted().compactMap { early.rows[$0] }
        lockDraftWrite(tracks: Set(rows.map(\.track.uuid)))
        defer { unlockDraftWrite() }
        // 재생 목록을 넣을지는 쓰기 잠금을 건 뒤(초안 파일 잠금 시도·디스크 초안 동기화 뒤) 한 번만 읽는다(⌘S와 같은 순서)
        let withPlaylists = chunk.playlistSteps > 0 && ports.library.state().canWritePlaylists
        do {
            try Task.checkCancellation()
            let files = ports.drafts
            await BlockingWork.run { files.flush() }
            ports.library.retryTagSaves()
            let uuids = Set(rows.map(\.track.uuid))
            try requireReadableDrafts(for: uuids, playlists: withPlaylists)
            try requireDraftSaves(for: uuids)
            if withPlaylists { try requirePlaylistDraftSaved() }
            let batch = autoBatch(chunk, rows: rows, withPlaylists: withPlaylists)
            let tracks = Set(chunk.tracks.values.flatMap(\.values))
            guard !batch.isEmpty else {
                // 재생 목록을 넣지 못한 것(초안 파일을 잡지 못함·디스크 초안이 아직 다름)은 잠시 뒤 다시 한다(확인 필요로 보지 않는다)
                if chunk.playlistSteps > 0 { return .busy }
                // 고른 초안이 하나도 묶음에 들지 않았다(바뀐 것이 없다): 새 편집 전까지 다시 고르지 않는다
                return .nothingWritten(unwritten: tracks)
            }
            freezeWrite(batch)
            let preview = try await previewBatch(batch, uuids: uuids, exclusions: [])
            try Task.checkCancellation()
            stage(nil)
            var writable = preview.writableBatch
            var blockedSteps: Set<DraftRevision> = []
            if writable.playlists != nil, !preview.report.playlistBlocked.isEmpty {
                // 미리 보기에서 막힌 단계가 든 단위부터 뒤는 확인 필요로 남긴다(AR-9). 그 앞 단위는 다음 판정이 따로 쓴다
                blockedSteps = Self.blockedStepRevisions(batch, outcomes: preview.report.playlistOutcomes ?? [])
                writable.playlists = nil
                writable.revisions.playlistSteps = []
            }
            guard !writable.isEmpty else { return .nothingWritten(unwritten: tracks.union(blockedSteps)) }
            let written = try await writeDraftsFollowingUp(writable, to: target, dryRun: false)
            publish(.autoWritten(written.report, followUp: written.followUp))
            let unwritten = tracks.subtracting(Self.writtenRevisions(written.report, batch: writable)).union(blockedSteps)
            return .written(written.report, unwritten: unwritten)
        } catch is CancellationError {
            stage(nil)
            return .cancelled
        } catch {
            stage(nil)
            return .failed(error)
        }
    }

    /// 자동 저장 묶음: 고른 곡의 대상 편집 종류만(같은 곡의 대상 밖 초안은 넣지 않는다, R4), 재생 목록은 고른 단위까지의 앞부분.
    /// 고른 뒤 판이 바뀐 초안(새 편집·바깥 고침)은 넣지 않는다(다음 판정이 다시 본다). 재생 기록은 대상 밖이라 넣지 않는다
    func autoBatch(_ chunk: AutoReflectionChunk, rows: [TrackRow], withPlaylists: Bool) -> DraftWriteBatch {
        let files = ports.drafts, state = ports.library.state()
        var rawCues: [String: CueDraft] = [:]
        var cues: [CueDraft] = [], grids: [GridDraft] = [], tags: [TagDraft] = []
        for row in rows {
            let uuid = row.track.uuid
            for (key, revision) in (chunk.tracks[uuid] ?? [:]).sorted(by: { $0.key < $1.key }) where files.stamp(key)?.revision == revision {
                switch key.kind {
                case .cue:
                    guard let raw = files.cueDraft(uuid) else { continue }
                    rawCues[uuid] = raw
                    let full = raw.includingAutoCues(from: row.cues, newID: files.newCueID)
                    if full.hasChanges { cues.append(full) }
                case .grid: if let grid = files.gridDraft(uuid), grid.hasChanges { grids.append(grid) }
                case .tag: if let tag = files.tagDraft(uuid), tag.hasChanges { tags.append(tag) }
                case .gain, .artwork, .merge: continue
                }
            }
        }
        var playlists: PlaylistDraft?
        if withPlaylists, chunk.playlistSteps > 0, !state.playlistDraftNeedsSync {
            let disk = files.playlistDraft(), stamps = files.playlistStamps()
            if disk == state.playlistDraft, stamps.count == disk.steps.count, chunk.playlistSteps <= disk.steps.count,
               stamps.prefix(chunk.playlistSteps).map(\.revision) == chunk.stepRevisions {
                var prefix = disk
                prefix.removeSteps(at: chunk.playlistSteps..<disk.steps.count)
                playlists = prefix
            }
        }
        var batch = DraftWriteBatch(drafts: cues, grids: grids, tags: tags, playlists: playlists)
        stampRevisions(&batch, rawCues: rawCues)
        return batch
    }

    /// 미리 보기에서 처음 막힌 단계가 든 단위부터 끝까지의 단계 판
    nonisolated static func blockedStepRevisions(_ batch: DraftWriteBatch, outcomes: [PlaylistOutcome]) -> Set<DraftRevision> {
        guard let steps = batch.playlists?.steps, let first = outcomes.firstIndex(where: { $0.status == .blocked }) else { return [] }
        let units = AutoReflectionInventory.units(steps.map { $0.edit.playlist.layoutID })
        let from = units.first { $0.contains(first) }?.lowerBound ?? first
        return Set(batch.revisions.playlistSteps.dropFirst(from).map(\.revision))
    }

    /// 쓴 초안의 판(곡 초안은 쓴 결과, 재생 목록은 쓰였거나 이미 그 모양인 단계)
    nonisolated static func writtenRevisions(_ report: RekordboxWriteReport, batch: DraftWriteBatch) -> Set<DraftRevision> {
        let keys = report.written.map { DraftKey(.cue, $0.trackUUID) } + (report.gridWritten + report.analysisWritten).map { DraftKey(.grid, $0.trackUUID) }
            + report.tagWritten.map { DraftKey(.tag, $0.trackUUID) } + report.gainWritten.map { DraftKey(.gain, $0.trackUUID) }
            + report.artworkWritten.map { DraftKey(.artwork, $0.trackUUID) } + report.mergeWritten.map { DraftKey(.merge, $0.trackUUID) }
        var revisions = Set(keys.compactMap { batch.revisions.tracks[$0]?.revision })
        for (index, outcome) in (report.playlistOutcomes ?? []).enumerated()
        where outcome.status != .blocked && batch.revisions.playlistSteps.indices.contains(index) {
            revisions.insert(batch.revisions.playlistSteps[index].revision)
        }
        return revisions
    }

    // MARK: - 재시작 정리(R22)

    /// 재시작 정리의 결과
    public struct CleanupResume: Equatable, Sendable {
        /// 찾은 미정리 목록 수
        public var found = 0
        /// 정리를 마치고 지운 목록 수
        public var finished = 0
        /// 다음 쓰기를 보류할 이유(`cleanupPending`·`cleanupStoreMissing`·`playlistCopyFailed`). 비면 쓰기를 막을 것이 없다
        public var holds: Set<ReflectionHold> = []
        /// 새 곡 행을 아직 읽지 못해 곡 넣기 몫만 미룬 목록 수(쓰기는 막지 않는다: 옛 UUID 초안은 rekordbox 곡에 닿지 않는다)
        public var deferred = 0

        public init(found: Int = 0, finished: Int = 0, holds: Set<ReflectionHold> = [], deferred: Int = 0) {
            self.found = found
            self.finished = finished
            self.holds = holds
            self.deferred = deferred
        }
    }

    /// 정리 전에 멈춘 쓰기의 미정리 목록으로 같은 정리를 다시 한다(R22). 이 초안 저장소·대상의 목록만 다룬다.
    /// 앱은 첫 읽기 뒤 시작 저장보다 먼저, 그리고 쓰기마다 그 전에 부른다. CLI는 쓰기 명령 전에 부른다(`cleanUpBeforeWrite`).
    /// 그 대상에 중단 기록이 없을 때만 부른다(기록으로 복원·"이대로 둔다"가 목록을 다룬다).
    /// 곡 초안은 목록에 적힌 판과 해시가 지금과 같을 때만 지우고(다시 해도 결과가 같다), 곡 넣기 몫은 `cleanUpTrackAdd`, 재생 목록은
    /// `EditPlaylists.resumeCleanup`이 한다. 끝나지 않은 목록(사본 실패·저장 실패)은 지우지 않고 남겨 그 대상의 다음 쓰기를 보류한다.
    /// 목록을 읽지 못하면 정리와 다음 쓰기를 보류한다
    /// - Parameter target: 정리할 대상(기본은 이 세션의 대상). CLI는 명령이 고른 대상을 준다
    public func resumeCleanups(for target: RekordboxWriteTarget? = nil) async -> CleanupResume {
        let gate = ports.gate, target = target ?? self.target, home = location.draftHome, files = ports.drafts
        let lists: [DraftCleanupList]
        do { lists = try await BlockingWork.run { try gate.cleanupLists(target, home) } } catch {
            return CleanupResume(holds: [.cleanupStoreMissing])
        }
        var result = CleanupResume(found: lists.count)
        for list in lists.sorted(by: { $0.operationID < $1.operationID }) {
            var complete = true, deferred = false
            if !list.written.isEmpty {
                do {
                    let removal = try await BlockingWork.run {
                        files.flush()
                        return try files.removeWritten(list.written)
                    }
                    clearRemovedDrafts(removal.removed.map(\.key))
                } catch {
                    complete = false
                }
            }
            for add in list.trackAdds {
                switch await cleanUpTrackAdd(add, unchanged: nil) {
                case .done: break
                case .deferred: deferred = true
                case .failed: complete = false
                }
            }
            if !list.playlistSteps.isEmpty || !list.newPlaylistIDs.isEmpty {
                let state = ports.library.state()
                if state.playlistDraftNeedsSync {
                    // 디스크 초안을 확인하지 못했다: 옛 메모리로 덮지 않게 다음에 다시 한다
                    complete = false
                } else {
                    // 연결 기록은 디스크에서 읽는다(CLI도 같은 파일을 옮긴다). 읽지 못하면 옮기지 않는다
                    let imports = try? playlistEdits.loadImports()
                    let cleanup = playlistEdits.resumeCleanup(list, backups: target.backups, imports: imports ?? PlaylistImports(),
                                                              importsLoadFailed: imports == nil)
                    apply(.playlistWritten(cleanup))
                    if !cleanup.copyFailed.isEmpty { result.holds.insert(.playlistCopyFailed) }
                    complete = complete && cleanup.isComplete
                }
            }
            if !complete {
                result.holds.insert(.cleanupPending)
            } else if deferred {
                result.deferred += 1
            } else if (try? await BlockingWork.run({ try gate.removeCleanupList(list, target) })) != nil {
                result.finished += 1
            } else {
                result.holds.insert(.cleanupPending)
            }
        }
        return result
    }

    /// CLI 쓰기 전 정리(R22): 그 대상에 남은 미정리 목록을 먼저 정리한다. 정리를 마치지 못한 목록이 있으면 쓰지 않는다
    /// (쓴 초안·재생 목록 단계를 다시 쓰지 않게). 곡 넣기 몫만 미뤄진 것은 막지 않는다
    public func cleanUpBeforeWrite(to target: RekordboxWriteTarget) async throws {
        let resumed = await resumeCleanups(for: target)
        // 목록을 읽지 못한 것(대상 폴더를 읽지 못함)은 막지 않는다: 그 쓰기는 관문이 같은 까닭으로 다시 거절한다
        guard resumed.holds.subtracting([.cleanupStoreMissing]).isEmpty else { throw DJCError.writeRefused(Self.playlistSaveFailureText) }
    }

    /// 재시작 정리가 지운 곡 초안을 화면 표시에서도 지운다
    func clearRemovedDrafts(_ keys: [DraftKey]) {
        func ids(_ kind: DraftKey.Kind) -> [String] { keys.filter { $0.kind == kind }.map(\.id).sorted() }
        if !ids(.cue).isEmpty { apply(.draftsCleared(.cue, ids(.cue), cueCounts: true)) }
        if !ids(.grid).isEmpty { apply(.draftsCleared(.grid, ids(.grid), cueCounts: false)) }
        if !ids(.gain).isEmpty { apply(.draftsCleared(.gain, ids(.gain), cueCounts: false)) }
        if !ids(.tag).isEmpty { apply(.tagDrafts(ids(.tag).map { TagDraft(trackUUID: $0, base: TagFields()) })) }
        if !ids(.artwork).isEmpty { apply(.artworkCleared(ids(.artwork), failed: 0)) }
    }
}

extension DraftWriteBatch {
    /// 쓸 것이 하나도 없는 묶음
    public var isEmpty: Bool { draftKeys.isEmpty && playlists == nil && histories.isEmpty }
}
