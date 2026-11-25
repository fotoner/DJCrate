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
    /// - base 없음: base 없이 저장한 게인(옛 형식·CLI, R23). base를 단 게인(덱 편집)은 대상 편집이다
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
            if state.gainDraftUUIDs.contains(uuid) {
                let key = DraftKey(.gain, uuid)
                // 지금 값의 판에 묶였고 만든 뒤 rekordbox 실행 경계를 건너지 않은 base만 대상 편집이다(R23, 컨실 S7·S8).
                // 화면 표시만 남고 디스크에 없는 초안(방금 썼다)은 저장 대기가 아니다
                if files.validGainBase(uuid) != nil { keys.append(key) } else if files.currentHash(key) != nil { inventory.leftoverKeys[key] = .noBase }
            }
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
        (inventory.steps, inventory.playlistUndetermined) = playlistSteps(state: state, files: files, judge: judge)
        inventory.known.formUnion(inventory.steps.compactMap(\.revision))
        return inventory
    }

    /// 재생 목록 단계마다 자동으로 쓸 수 있는지. 메모리 초안이 디스크와 같을 때만 본다(같지 않으면 저장을 마친 뒤 다음 판정이 본다)
    /// 메모리 초안을 판정할 수 없으면(디스크와 아직 맞추지 못함·저장하지 못함·다름) 단계마다 확인 필요로 남기고 `undetermined`다
    /// (저장 대기에서 사라지지 않게, 그동안 엔진은 재생 목록 판을 솎지 않는다)
    nonisolated static func playlistSteps(state: ReflectionLibraryState, files: DraftStore,
                                          judge: (DraftRevision) -> ReflectionLeftover?) -> (steps: [AutoReflectionInventory.Step], undetermined: Bool) {
        // 화면 목록이 비었어도 디스크를 본다(다시 켠 뒤 첫 읽기가 실패해 화면만 빈 경우): 디스크에 초안이 있으면 판정할 수 없다.
        // 디스크 초안을 읽지 못한 것은 빈 초안과 다르다(판정할 수 없다: 그동안 판을 솎지 않는다)
        let disk = try? files.readPlaylistDraft()
        func undetermined() -> (steps: [AutoReflectionInventory.Step], undetermined: Bool) {
            let steps = state.playlistDraft.isEmpty ? (disk?.steps ?? []) : state.playlistDraft.steps
            return (steps.map { AutoReflectionInventory.Step(playlist: $0.edit.playlist.layoutID, rows: 1, revision: nil,
                                                             leftover: .needsConfirmation) }, true)
        }
        guard let disk, !state.playlistDraftNeedsSync else { return undetermined() }
        guard !state.playlistDraft.isEmpty || !disk.isEmpty else { return ([], false) }
        guard !state.playlistDraftUnsaved, disk == state.playlistDraft else { return undetermined() }
        let stamps = files.playlistStamps(), suggestions = files.playlistSuggestions()
        let projection = disk.project(onto: state.rekordboxPlaylists, contentIDs: Set(state.rows.values.map(\.track.id)))
        let blocked = projection.blocked
        // 행 수는 단계를 차례로 적용하며 그 단계 직전·직후의 목록으로 센다(R14: 곡 빼기 뒤 남은 곡의 번호 다시 매기기까지). 막힌 단계는 적용하지 않는다
        var layout = state.rekordboxPlaylists
        let steps = disk.steps.indices.map { index in
            let step = disk.steps[index]
            let id = step.edit.playlist.layoutID
            let before = layout.item(id)?.entries
            if !(blocked.indices.contains(index) && blocked[index] != nil) { try? layout.apply(step.edit) }
            let rows = AutoReflectionInventory.Step.rows(of: step.edit, before: before, after: layout.item(id)?.entries)
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
            return AutoReflectionInventory.Step(playlist: id, rows: rows, revision: revision, leftover: leftover)
        }
        return (steps, false)
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
        /// 재생 목록 초안 파일 잠금을 잡지 못했거나 디스크 초안이 아직 달라 이번 묶음에 쓸 것이 없다(잠시 뒤 다시 한다).
        /// 일반 바쁨과 가른다: ⌘Q 저장은 이때 기다리지 않고 초안으로 남긴다(#406 컨실 2라운드 E)
        case playlistDraftBusy
        /// 다른 프로세스가 쓰기 잠금을 쥐고 있었다(관문이 기다리지 않았다, R9)
        case lockBusy
        /// rekordbox·Agent가 켜져 있다(관문도 다시 본다)
        case rekordboxRunning
        /// 쓰기 잠금을 걸기 직전에 다시 본 엔진 조건(편집 중·앱 보류 사유)이 어긋났다(쓰지 않았다)
        case held
        /// 미리 보기·음량 분석 뒤 관문을 부르기 직전에 엔진에 물으니 조용함이 끊겼다(#295 E4: 켜짐·오래된 표본·바깥 변경). 쓰지 않았다
        case quietLost
        case cancelled
        case failed(any Error)
    }

    /// 고른 묶음을 확인 창 없이 쓴다(R6: 배경에서 묻지 않는다). 쓰는 곡만 잠그고(R21) 덱 재생은 멈추지 않는다.
    /// 미리 보기에서 막힌 초안은 빼고 나머지를 쓴다. 재생 목록 단계가 하나라도 막히면 이번에는 재생 목록을 쓰지 않는다(AR-9).
    /// 결과는 화면에 자동 저장으로 알린다(토스트 없이 활동 기록, R15는 화면 몫). 실패 분류(멈춤·보류·중단)는 엔진이 한다.
    /// - Parameters:
    ///   - mayWrite: 쓰기 잠금을 걸기 직전(같은 메인 액터 구간)에 다시 보는 엔진 조건. false면 쓰지 않는다(R1·R16)
    ///   - mayCommit: 미리 보기·음량 분석 뒤 관문을 부르기 직전에 묻는 엔진의 확인 지점(#295 E4). false면 관문을 부르지 않고 `.quietLost`
    ///   - afterChanges: 관문이 라이브러리 변경을 모두 마친 자리(쓰기 잠금 안)에서 부를 일(#295 E4). 묶음의 작업에 실어 넘긴다
    public func autoWrite(_ chunk: AutoReflectionChunk, mayWrite: @MainActor () -> Bool = { true },
                          mayCommit: (@MainActor () async -> Bool)? = nil, afterChanges: DraftWriteProbe? = nil) async -> AutoWriteOutcome {
        guard !ports.lock.isLocked() else { return .busy }
        // 실행 확인은 프로세스 목록을 읽는 막는 일이라 메인 액터 밖에서 한다
        let running = ports.runningApps.isRekordboxRunning
        guard !(await BlockingWork.run(qos: .userInitiated) { running() }) else { return .rekordboxRunning }
        guard !ports.lock.isLocked() else { return .busy }
        let early = ports.library.state()
        let rows = chunk.tracks.keys.sorted().compactMap { early.rows[$0] }
        // 준비하는 동안(실행 확인 등) 편집을 시작했거나 앱 보류 사유가 생겼으면 잠그지 않는다. 이 확인과 잠금 사이에는 기다림이 없다
        guard mayWrite() else { return .held }
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
            // 여러 곡 역편집 묶음은 고를 때의 구성원·판 그대로일 때만 쓴다. 하나라도 빠지거나 다르면 묶음 전체를 쓰지 않고 다시 판정한다(컨실 S2·G5)
            if chunk.allOrNothing, batch.draftKeys != Set(chunk.tracks.values.flatMap(\.keys)) { return .held }
            guard !batch.isEmpty else {
                // 재생 목록을 넣지 못한 것(초안 파일을 잡지 못함·디스크 초안이 아직 다름)은 잠시 뒤 다시 한다(확인 필요로 보지 않는다)
                if chunk.playlistSteps > 0 { return .playlistDraftBusy }
                // 고른 초안이 하나도 묶음에 들지 않았다(바뀐 것이 없다): 새 편집 전까지 다시 고르지 않는다
                return .nothingWritten(unwritten: tracks)
            }
            freezeWrite(batch)
            let preview = try await previewBatch(batch, uuids: uuids, exclusions: [])
            try Task.checkCancellation()
            stage(nil)
            var writable = preview.writableBatch
            // 막힌 곡은 그 곡의 대상 초안을 모두 뺀다(R6 "그 곡만 빼고": 통과한 종류만 골라 쓰지 않는다)
            let heldTracks = Self.blockedTracks(preview.report)
            if !heldTracks.isEmpty { writable = writable.removingTracks(heldTracks) }
            var heldSteps: Set<DraftRevision> = []
            if batch.playlists != nil {
                if !preview.report.playlistBlocked.isEmpty {
                    // 미리 보기에서 막힌 단계가 든 단위부터 뒤는 확인 필요로 남긴다(AR-9). 그 앞 단위는 다음 판정이 따로 쓴다
                    heldSteps = Self.blockedStepRevisions(batch, outcomes: preview.report.playlistOutcomes ?? [])
                    writable.playlists = nil
                    writable.revisions.playlistSteps = []
                } else if writable.playlists == nil {
                    // 막히지 않았는데 쓸 단계가 없다(모두 이미 그 모양): 새 편집 전까지 다시 미리 보지 않는다
                    heldSteps = Set(batch.revisions.playlistSteps.map(\.revision))
                }
            }
            guard !writable.isEmpty else { return .nothingWritten(unwritten: tracks.union(heldSteps)) }
            // 관문이 쓰기 잠금을 기다리지 않고, 백업 뒤 실패를 그렇게 알리게 한다(R7·R9)
            writable.isAutoSave = true
            if let afterChanges { writable.operation?.afterChanges = afterChanges }
            let written = try await writeDraftsFollowingUp(writable, to: target, dryRun: false, beforeGate: mayCommit)
            // 전부 아니면 전무 쓰기를 입구가 모두 거절했으면 쓴 것이 없다: 쓴 것으로 알리지 않는다(컨실 G8)
            if writable.commitPolicy == .allOrNothing, Self.writtenRevisions(written.report, batch: writable).isEmpty {
                return .nothingWritten(unwritten: tracks.union(heldSteps))
            }
            publish(.autoWritten(written.report, followUp: written.followUp))
            let unwritten = tracks.subtracting(Self.writtenRevisions(written.report, batch: writable)).union(heldSteps)
            return .written(written.report, unwritten: unwritten)
        } catch is CancellationError {
            stage(nil)
            return .cancelled
        } catch is RekordboxWriteGate.LockBusy {
            stage(nil)
            return .lockBusy
        } catch is QuietLost {
            stage(nil)
            return .quietLost
        } catch {
            stage(nil)
            return .failed(error)
        }
    }

    /// 자동 저장 묶음: 고른 곡의 대상 편집 종류만(같은 곡의 대상 밖 초안은 넣지 않는다, R4), 재생 목록은 고른 단위까지의 앞부분.
    /// 곡 초안은 고른 판 그대로이고 사람 편집만이며 읽은 내용이 그 판을 저장한 때의 내용(도장의 해시)과 같을 때만 넣는다(R4·R5).
    /// 고른 뒤 판이 바뀌었거나(새 편집) 파일만 바뀐 초안(바깥 고침, 제안)은 넣지 않는다(다음 판정이 다시 본다). 맞춰 본 도장·해시를 그대로
    /// 묶음의 판으로 실어 쓰기·정리가 같은 값을 본다(R22). 재생 기록은 대상 밖이라 넣지 않는다
    func autoBatch(_ chunk: AutoReflectionChunk, rows: [TrackRow], withPlaylists: Bool) -> DraftWriteBatch {
        let files = ports.drafts, state = ports.library.state()
        var verified: [DraftKey: DraftBatchEntry] = [:]
        var cues: [CueDraft] = [], grids: [GridDraft] = [], tags: [TagDraft] = []
        var gains: [String: Double] = [:], gainBases: [String: Double] = [:]
        let allGains = chunk.tracks.keys.contains { chunk.tracks[$0]?[DraftKey(.gain, $0)] != nil } ? (try? files.gainDrafts()) ?? [:] : [:]
        for row in rows {
            let uuid = row.track.uuid
            for (key, revision) in (chunk.tracks[uuid] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let stamp = files.stamp(key), stamp.revision == revision, stamp.isHumanOnly else { continue }
                /// 읽은 내용이 도장의 해시와 같으면 그 판으로 싣는다
                func matches(_ hash: DraftContentHash?) -> Bool {
                    guard let hash, hash == stamp.contentHash else { return false }
                    verified[key] = DraftBatchEntry(stamp: stamp, contentHash: hash)
                    return true
                }
                switch key.kind {
                case .cue:
                    guard let raw = files.cueDraft(uuid) else { continue }
                    let full = raw.includingAutoCues(from: row.cues, newID: files.newCueID)
                    if full.hasChanges, matches(try? DraftContentHash(of: raw)) { cues.append(full) }
                case .grid:
                    if let grid = files.gridDraft(uuid), grid.hasChanges, matches(try? DraftContentHash(of: grid)) { grids.append(grid) }
                case .tag:
                    if let tag = files.tagDraft(uuid), tag.hasChanges, matches(try? DraftContentHash(of: tag)) { tags.append(tag) }
                case .gain:
                    // base를 단 게인만(R23). 관문이 base를 지금 rekordbox 값과 견준다
                    if let gain = allGains[uuid], let base = files.validGainBase(uuid), matches(try? DraftContentHash(of: gain)) {
                        gains[uuid] = gain
                        gainBases[uuid] = base.db
                    }
                case .artwork, .merge: continue
                }
            }
        }
        var playlists: PlaylistDraft?, verifiedSteps: [DraftBatchEntry]?
        if withPlaylists, chunk.playlistSteps > 0, !state.playlistDraftNeedsSync {
            let disk = files.playlistDraft(), stamps = files.playlistStamps(), count = chunk.playlistSteps
            if disk == state.playlistDraft, stamps.count == disk.steps.count, count <= disk.steps.count,
               stamps.prefix(count).map(\.revision) == chunk.stepRevisions {
                // 단계마다 사람 편집만이고 지금 내용이 그 판을 저장한 때의 내용인지 본다(R4·R5). 하나라도 어긋나면 재생 목록을 빼고
                // 다음 판정이 그 단계를 제안으로 남긴다. 맞춰 본 도장·해시를 그대로 묶음의 판으로 싣는다(R22)
                let entries = (0..<count).compactMap { index -> DraftBatchEntry? in
                    guard let hash = try? DraftContentHash(step: disk.steps[index], in: disk),
                          DraftSuggestion.judge(stamp: stamps[index], currentHash: hash) == nil else { return nil }
                    return DraftBatchEntry(stamp: stamps[index], contentHash: hash)
                }
                if entries.count == count {
                    var prefix = disk
                    prefix.removeSteps(at: count..<disk.steps.count)
                    playlists = prefix
                    verifiedSteps = entries
                }
            }
        }
        var batch = DraftWriteBatch(drafts: cues, grids: grids, gains: gains, tags: tags, playlists: playlists,
                                    commitPolicy: chunk.allOrNothing ? .allOrNothing : .writable)
        batch.gainBases = gainBases
        stampRevisions(&batch, rawCues: [:], verified: verified, verifiedSteps: verifiedSteps)
        return batch
    }

    /// 미리 보기에서 막힌 곡(종류와 상관없이)
    nonisolated static func blockedTracks(_ report: RekordboxWriteReport) -> Set<String> {
        let outcomes = report.blocked + report.gridBlocked + report.analysisBlocked + report.gainBlocked + report.tagBlocked + report.artworkBlocked
        return Set(outcomes.map(\.trackUUID))
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

    /// 관문을 부르기 직전 확인 지점(`beforeGate`)이 쓰지 말라고 했다(#295 E4)
    struct QuietLost: Error {}

    // MARK: - 재시작 정리(R22)

    /// 재시작 정리의 결과
    public struct CleanupResume: Equatable, Sendable {
        /// 찾은 미정리 목록 수
        public var found = 0
        /// 정리를 마치고 지운 목록 수
        public var finished = 0
        /// 다음 쓰기를 보류할 이유(`cleanupPending`·`cleanupStoreMissing`·`playlistCopyFailed`). 비면 쓰기를 막을 것이 없다
        public var holds: Set<ReflectionHold> = []
        /// 새 곡 행을 아직 읽지 못해 곡 넣기 몫만 미룬 목록 수(앱의 쓰기는 막지 않는다: 옛 UUID 초안은 rekordbox 곡에 닿지 않는다. CLI는 막는다)
        public var deferred = 0
        /// 목록을 읽지 못한 이유(`cleanupStoreMissing`일 때)
        public var storeError: String?

        public init(found: Int = 0, finished: Int = 0, holds: Set<ReflectionHold> = [], deferred: Int = 0, storeError: String? = nil) {
            self.found = found
            self.finished = finished
            self.holds = holds
            self.deferred = deferred
            self.storeError = storeError
        }
    }

    /// 쓰기 잠금 아래 기록 판정과 재시작 정리의 결과
    public enum JournalCleanup: Sendable {
        /// 다른 쪽이 쓰기 잠금을 쥐었거나 기록을 판정하지 못했다(판정·정리를 미뤘다)
        case busy
        /// 중단된 쓰기의 기록이 있다(정리하지 않았다: 기록으로 복원·"이대로 둔다"가 목록을 다룬다)
        case interrupted(RekordboxJournalFinding)
        /// 기록이 없어 정리했다
        case cleaned(CleanupResume)
    }

    /// 대상의 쓰기 잠금을 잡고, 쥔 채 쓰기 기록을 판정한다. 기록이 없을 때만 같은 잠금을 쥔 채 미정리 목록을 정리한 뒤 푼다(R9·R11·R22).
    /// 잠금 밖에서 정리하면 그 사이 다른 실행이 남긴 중단 기록의 초안을 지울 수 있다. 앱(시작·자동·수동)과 CLI가 모두 이 길로 정리한다.
    /// - Parameter waits: 잠금을 기다린다(CLI·수동 쓰기). 아니면 비차단 시도로, 못 잡으면 `.busy`다(자동 저장 판정)
    public func judgeAndResumeCleanups(lock: RekordboxWriteLock, waits: Bool = false, for target: RekordboxWriteTarget? = nil) async -> JournalCleanup {
        let gate = ports.gate, target = target ?? self.target
        let judged = try? await BlockingWork.run { () throws -> (verdict: RekordboxJournalVerdict, hold: RekordboxWriteLock.Hold?) in
            let key = try lock.key(target.database)
            guard let hold = waits ? try lock.lock(key) : try lock.tryLock(key) else { return (.inProgress, nil) }
            do {
                let verdict = try gate.journal(target, hold)
                guard case .none = verdict else {
                    hold.release()
                    return (verdict, nil)
                }
                return (verdict, hold)
            } catch {
                hold.release()
                throw error
            }
        }
        guard let judged else { return .busy }
        switch judged.verdict {
        case .inProgress: return .busy
        case let .interrupted(finding): return .interrupted(finding)
        case .none:
            defer { judged.hold?.release() }
            return .cleaned(await resumeCleanups(for: target))
        }
    }

    /// 정리 전에 멈춘 쓰기의 미정리 목록으로 같은 정리를 다시 한다(R22). 이 초안 저장소·대상의 목록만 다룬다.
    /// 그 대상의 쓰기 잠금을 쥐고 중단 기록이 없다고 판정한 채로만 부른다(`judgeAndResumeCleanups`). 기록이 있으면 기록으로 복원·"이대로 둔다"가
    /// 목록을 다룬다.
    /// 곡 초안은 목록에 적힌 판과 해시가 지금과 같을 때만 지우고(다시 해도 결과가 같다), 곡 넣기 몫은 `cleanUpTrackAdd`, 재생 목록은
    /// `EditPlaylists.resumeCleanup`이 한다. 끝나지 않은 목록(사본 실패·저장 실패)은 지우지 않고 남겨 그 대상의 다음 쓰기를 보류한다.
    /// 목록을 읽지 못하면 정리와 다음 쓰기를 보류한다
    /// 곡 넣기 정리가 새 곡 행을 찾지 못하면, 지금 목록을 읽은 사본이 쓰기 대상 라이브 DB와 같을 때만(그 사이 rekordbox에서 뺐다) 미루지 않고
    /// 옛 초안을 연결 안 된 초안으로 남긴 채 끝낸다(CLI가 그 목록 때문에 계속 거절하지 않게). 다르거나 모르면 미룬다
    /// - Parameter target: 정리할 대상(기본은 이 세션의 대상). CLI는 명령이 고른 대상을 준다
    public func resumeCleanups(for target: RekordboxWriteTarget? = nil) async -> CleanupResume {
        let gate = ports.gate, target = target ?? self.target, home = location.draftHome, files = ports.drafts
        let lists: [DraftCleanupList]
        do { lists = try await BlockingWork.run { try gate.cleanupLists(target, home) } } catch {
            return CleanupResume(holds: [.cleanupStoreMissing], storeError: error.localizedDescription)
        }
        var result = CleanupResume(found: lists.count)
        // 곡 넣기 몫이 있을 때만 읽은 사본이 라이브 DB와 같은지 본다(파일 상태를 보는 일이라 메인 밖에서, 잠금 아래에서)
        var readIsLatest = false
        if lists.contains(where: { !$0.trackAdds.isEmpty }), let snapshot = ports.library.state().readSnapshot {
            let judge = ports.library.readIsLatest
            readIsLatest = await BlockingWork.run { judge(snapshot) }
        }
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
                switch await cleanUpTrackAdd(add, unchanged: nil, readIsLatest: readIsLatest) {
                case .done: break
                case .deferred: deferred = true
                case .failed: complete = false
                }
            }
            if !list.playlistSteps.isEmpty || !list.newPlaylistIDs.isEmpty {
                let state = ports.library.state()
                if state.playlistDraftNeedsSync || state.playlistDraftUnsaved {
                    // 디스크 초안을 확인하지 못했거나 메모리에 저장하지 못한 편집이 있다: 디스크로 정리한 결과로 메모리를 덮지 않게
                    // 다음에 다시 한다(⌘S는 재생 목록 초안을 먼저 저장해 본다)
                    complete = false
                } else if let unlock = await BlockingWork.run({ files.lockPlaylistDraft(0) }) {
                    // 초안 파일 잠금을 쥔 채 읽고 정리하고 저장한다(그 사이 CLI가 더한 단계를 덮지 않게)
                    defer { unlock() }
                    // 잠금을 기다리는 동안(메인 액터를 내줬다) 앱의 재생 목록 저장이 실패했을 수 있다: 잡은 직후 다시 본다
                    let locked = ports.library.state()
                    guard !locked.playlistDraftNeedsSync, !locked.playlistDraftUnsaved else {
                        result.holds.insert(.cleanupPending)
                        continue
                    }
                    // 연결 기록은 디스크에서 읽는다(CLI도 같은 파일을 옮긴다). 읽지 못하면 옮기지 않는다
                    let imports = try? playlistEdits.loadImports()
                    let cleanup = playlistEdits.resumeCleanup(list, backups: target.backups, imports: imports ?? PlaylistImports(),
                                                              importsLoadFailed: imports == nil)
                    apply(.playlistWritten(cleanup))
                    if !cleanup.copyFailed.isEmpty { result.holds.insert(.playlistCopyFailed) }
                    complete = complete && cleanup.isComplete
                } else {
                    // 다른 곳(CLI)이 초안 파일을 고치는 중이다: 목록을 남겨 다음에 다시 한다
                    complete = false
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

    /// CLI 쓰기 전 정리(R22): 그 대상의 쓰기 잠금을 기다려 잡고 기록을 판정한 뒤, 기록이 없으면 남은 미정리 목록을 먼저 정리한다.
    /// 목록을 읽지 못했거나 정리를 마치지 못한 목록(곡 넣기 몫을 미룬 것 포함)이 있으면 쓰지 않는다(쓴 초안·재생 목록 단계를 다시 쓰지 않게).
    /// 중단 기록이 있으면 정리하지 않는다(쓰기 입구가 같은 기록으로 거절한다)
    public func cleanUpBeforeWrite(to target: RekordboxWriteTarget, lock: RekordboxWriteLock) async throws {
        guard case let .cleaned(resumed) = await judgeAndResumeCleanups(lock: lock, waits: true, for: target) else { return }
        if resumed.holds.contains(.cleanupStoreMissing) { throw DJCError.writeRefused(resumed.storeError ?? Self.playlistSaveFailureText) }
        guard resumed.holds.isEmpty else { throw DJCError.writeRefused(Self.playlistSaveFailureText) }
        // 새 곡 행을 읽어야 끝나는 곡 넣기 정리는 앱이 한다(CLI는 목록을 읽지 않는다)
        guard resumed.deferred == 0 else { throw DJCError.writeRefused(Self.trackAddCleanupPendingText) }
    }

    /// CLI 쓰기 전: 앱이 넣은 곡의 편집을 아직 새 곡으로 옮기지 못했다
    static var trackAddCleanupPendingText: String {
        String(ui: "DJCrate가 rekordbox에 넣은 곡의 편집을 아직 정리하지 못했으니 DJCrate를 켜 라이브러리를 다시 읽은 뒤 다시 시도하세요")
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
    /// 그 초안 키만 남긴 묶음(판도 남은 초안의 것만, 재생 목록·재생 기록은 뺀다): 여러 곡 역편집 묶음을 따로 쓸 때(컨실 S1)
    func restricted(to keys: Set<DraftKey>) -> DraftWriteBatch {
        var batch = self
        batch.drafts.removeAll { !keys.contains(DraftKey(.cue, $0.trackUUID)) }
        batch.grids.removeAll { !keys.contains(DraftKey(.grid, $0.trackUUID)) }
        batch.gains = batch.gains.filter { keys.contains(DraftKey(.gain, $0.key)) }
        batch.gainBases = batch.gainBases.filter { keys.contains(DraftKey(.gain, $0.key)) }
        batch.tags.removeAll { !keys.contains(DraftKey(.tag, $0.trackUUID)) }
        batch.artworks.removeAll { !keys.contains(DraftKey(.artwork, $0.trackUUID)) }
        batch.merges.removeAll { !keys.contains(DraftKey(.merge, $0.id)) }
        batch.playlists = nil
        batch.histories = []
        batch.revisions = batch.revisions.restricted(to: batch.draftKeys)
        batch.revisions.playlistSteps = []
        return batch
    }

    /// 그 초안 키를 뺀 묶음(⌘S의 묶음 밖 편집, 컨실 S1)
    func removingKeys(_ keys: Set<DraftKey>) -> DraftWriteBatch {
        guard !keys.isEmpty else { return self }
        var batch = self
        batch.drafts.removeAll { keys.contains(DraftKey(.cue, $0.trackUUID)) }
        batch.grids.removeAll { keys.contains(DraftKey(.grid, $0.trackUUID)) }
        batch.gains = batch.gains.filter { !keys.contains(DraftKey(.gain, $0.key)) }
        batch.gainBases = batch.gainBases.filter { !keys.contains(DraftKey(.gain, $0.key)) }
        batch.tags.removeAll { keys.contains(DraftKey(.tag, $0.trackUUID)) }
        batch.artworks.removeAll { keys.contains(DraftKey(.artwork, $0.trackUUID)) }
        batch.merges.removeAll { keys.contains(DraftKey(.merge, $0.id)) }
        let steps = batch.revisions.playlistSteps
        batch.revisions = batch.revisions.restricted(to: batch.draftKeys)
        batch.revisions.playlistSteps = steps
        return batch
    }

    /// 쓸 것이 하나도 없는 묶음
    public var isEmpty: Bool { draftKeys.isEmpty && playlists == nil && histories.isEmpty }

    /// 그 곡들의 곡 초안을 모두 뺀 묶음(판도 남은 초안의 것만)
    func removingTracks(_ uuids: Set<String>) -> DraftWriteBatch {
        var batch = self
        batch.drafts.removeAll { uuids.contains($0.trackUUID) }
        batch.grids.removeAll { uuids.contains($0.trackUUID) }
        batch.gains = batch.gains.filter { !uuids.contains($0.key) }
        batch.gainBases = batch.gainBases.filter { !uuids.contains($0.key) }
        batch.tags.removeAll { uuids.contains($0.trackUUID) }
        batch.artworks.removeAll { uuids.contains($0.trackUUID) }
        batch.revisions = batch.revisions.restricted(to: batch.draftKeys)
        return batch
    }
}
