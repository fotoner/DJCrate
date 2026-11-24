import DJCDomain
import Foundation

/// 초안 쓰기: 큐·그리드·게인·태그·앨범아트·재생 목록·합치기 초안과 USB에서 보존한 재생 기록(#43)을 rekordbox DB에 직접 쓴다(rekordbox가 꺼져 있을 때만).
/// 분석 전 곡(분석 파일 없음)의 그리드 초안은 분석 파일(파형·그리드·오토게인)을 만들어 붙인다(`Options.attachesAnalysis`).
extension ReflectionSession {
    /// 화면 흐름: 꺼짐 확인 → 대상 → 미리 보기 → (막힘·제외·손실이 있을 때만) 확인 → 쓸 수 있는 것만 쓰기 → 쓴 뒤 처리 → 결과.
    /// - Parameter playlists: 곡이 아닌 초안(재생 목록 초안·쓰기 대기 재생 기록)도 함께 쓸지(곡을 골라 쓰는 오른쪽 클릭 메뉴는 곡 초안만 쓴다)
    public func write(rows: [TrackRow], playlists: Bool = true) async -> ReflectionOutcome {
        guard !ports.lock.isLocked() else { return .busy }
        guard !ports.runningApps.isRekordboxRunning() else {
            return publish(.notice(title: String(ui: "rekordbox가 켜져 있어 저장하지 않았습니다"), text: ReflectionPrompts.quitRekordboxText, lines: []))
        }
        let chosen = writeTargets(rows)
        let early = ports.library.state()
        let hasPlaylistDraft = playlists && !early.playlistDraft.isEmpty
        let withHistories = playlists && !early.pendingHistories.isEmpty
        func nothing() -> ReflectionOutcome {
            publish(.notice(title: String(ui: "저장할 편집이 없습니다"), text: String(ui: "고른 곡에 rekordbox와 다른 큐·그리드·게인·태그 편집이 없습니다."),
                            lines: exclusions(for: rows, blockedOnly: false)))
        }
        guard !chosen.isEmpty || hasPlaylistDraft || withHistories else { return nothing() }
        // 쓰는 곡만 잠근다(R21): 고른 곡과 합치기로 묶인 곡. 덱 재생은 멈추지 않는다
        lockDraftWrite(tracks: lockedTracks(for: chosen))
        defer { unlockDraftWrite() }
        // 재생 목록을 묶음에 넣을지와 보류 안내는 쓰기 잠금을 건 뒤(초안 파일 잠금 시도·디스크 초안 동기화 뒤) 한 자리에서 정한다.
        // 메모리를 정본으로 정리하는 전제(쓰는 동안 초안 파일 잠금을 쥐고 디스크 초안과 같다)가 서지 않으면 이번 묶음에서 재생 목록만 뺀다.
        // 다른 종류 초안은 쓰고 결과에 이유를 담는다
        let state = ports.library.state()
        // 잠금 전 상태는 "아무것도 없음" 조기 종료에만 쓴다: 잠금 동안(동기화) 받은 초안도 묶음에 넣는다
        let hasPlaylists = playlists && !state.playlistDraft.isEmpty
        let withPlaylists = hasPlaylists && state.canWritePlaylists
        let playlistHeld = hasPlaylists && !state.canWritePlaylists
        guard !chosen.isEmpty || withPlaylists || withHistories else {
            if playlistHeld {
                return publish(.notice(title: String(ui: "rekordbox에 저장하지 않았습니다"), text: Self.playlistSyncHeldText, lines: []))
            }
            return nothing()
        }
        do {
            stage(WriteStage(String(ui: "바꿀 내용을 확인하는 중…"), completed: 0, total: chosen.count, cancellable: true))
            try Task.checkCancellation()
            let preview = try await previewWrite(rows: rows, playlists: withPlaylists || withHistories, withPlaylistDraft: withPlaylists)
            try Task.checkCancellation()
            stage(nil)
            // 창 대신 결과에 제외한 초안까지 남긴다(#230). 막힌 초안은 화면이 복구 시트로 고치게 한다(#232).
            guard preview.hasWritable else {
                // 곡이 막혀 쓸 것이 없어도 재생 목록을 건드리지 않은 이유를 "저장하지 않는 것"에 담는다
                var preview = preview
                if playlistHeld { preview.exclusions.append(Self.playlistSyncHeldText) }
                return publish(.nothingWritable(preview, targets: chosen))
            }
            // 막힘·제외·손실이 없으면 묻지 않고 쓴다. 결과 토스트와 메뉴의 "쓰기 전으로 복원…"으로 되돌린다(#210).
            let canBackUp = ports.backups.canWrite(location.backupDirectory)
            if !WriteConfirmPolicy.reasons(preview.report, exclusions: preview.exclusions, canBackUp: canBackUp).isEmpty {
                guard ports.confirmation.confirm(ReflectionPrompts.confirmation(preview.report, exclusions: preview.exclusions, canBackUp: canBackUp))
                else { return .declined }
            }
            try Task.checkCancellation()
            // 분석을 붙이는 곡도 그리드 초안으로 쓴다(`writableBatch`). 쓰기 결과와 뒤따른 일의 경고는 나눠 알린다(#175).
            let written = try await writeDraftsFollowingUp(preview.writableBatch, to: target, dryRun: false)
            return publish(.written(written.report, preview: preview.report,
                                    followUp: written.followUp + (playlistHeld ? [Self.playlistSyncHeldText] : [])))
        } catch is CancellationError {
            stage(nil)
            return publish(.cancelled)
        } catch {
            stage(nil)
            // 미리 보기에서 제외한 초안은 따로 창을 띄우지 않고 실패 알림에 합친다(#230).
            return publish(.failed(title: String(ui: "rekordbox에 저장하지 않았습니다"), error: error, exclusions: exclusions(for: rows, blockedOnly: true)))
        }
    }

    /// 쓰는 동안 편집을 막을 곡: 쓸 곡과, 그 곡이 든 합치기 초안으로 묶인 곡 모두(`DraftWriteBatch.trackUUIDs`와 같은 범위)
    func lockedTracks(for rows: [TrackRow]) -> Set<String> {
        let uuids = Set(rows.map(\.track.uuid))
        let merged = ports.library.state().mergeDrafts.filter { $0.members.contains { uuids.contains($0.trackUUID) } }
        return uuids.union(merged.flatMap { $0.members.map(\.trackUUID) })
    }

    /// 미리 보기(단계): 초안을 확인해 묶고, 위치의 rekordbox에서 새 사본을 떠 끝까지 써 본다(rekordbox는 건드리지 않는다).
    /// 최신 사본에 이미 있는 재생 기록은 실제로 쓰지 않고 보존본 연결만 갱신한다(쓰기 대기에서 빠진다).
    /// - Parameter playlists: 곡이 아닌 초안(재생 목록 초안·쓰기 대기 재생 기록)도 함께 볼지(곡 초안과 달리 곡을 골라 나누지 않는다)
    /// - Parameter withPlaylistDraft: 재생 목록 초안을 묶음에 넣을지(쓰기가 정한다: 초안 파일 잠금·동기화). `playlists`가 거짓이면 늘 넣지 않는다
    public func previewWrite(rows: [TrackRow], playlists: Bool, withPlaylistDraft: Bool = true) async throws -> WritePreview {
        ports.drafts.flush()
        ports.library.retryTagSaves()
        let targets = writeTargets(rows)
        let uuids = Set(targets.map(\.track.uuid))
        // 읽지 못한 초안 파일이 미리 보기에서 조용히 빠지지 않게 먼저 옮기고 알린다(#174).
        // 묶음에 넣지 않는 재생 목록 초안 파일은 이 쓰기를 막지 않는다(재생 기록만 넣는 묶음)
        try requireReadableDrafts(for: uuids, playlists: playlists && withPlaylistDraft)
        try requireDraftSaves(for: uuids)
        guard ports.library.state().failedTagSaves.isDisjoint(with: uuids) else { throw DJCError.writeRefused(DraftSaveFailure.tagSaveMessage) }
        // 재생 목록 초안을 묶음에 넣을 때만 저장을 다시 시도한다(재생 기록만 넣는 묶음은 하지 않는다: 보류한 초안으로 바깥 편집을 덮지 않게)
        if playlists, withPlaylistDraft { try requirePlaylistDraftSaved() }
        let batch = try draftBatch(for: targets, playlists: playlists, withPlaylistDraft: withPlaylistDraft)
        // 묶음을 만든 같은 메인 액터 구간에서 쓸 재생 목록 단계를 얼린다(R21): 쓰는 동안 들어온 재생 목록 편집은 뒤에 쌓인다
        freezeWrite(batch)
        return try await previewBatch(batch, uuids: uuids, exclusions: exclusions(for: rows, blockedOnly: true))
    }

    /// 쓸 재생 목록 단계와 재생 기록을 화면이 얼리게 한다(R21, `PlaylistEditStore.freezeWrite`). 곡 단위 초안 쓰기에서만 얼린다.
    /// 곡 초안만 쓰는 묶음도 빈 단계로 얼린다: 그래야 쓰는 동안 재생 목록·재생 기록 편집을 통째로 막지 않고 받는다
    func freezeWrite(_ batch: DraftWriteBatch) {
        apply(.playlistWriteFrozen(batch.playlists ?? PlaylistDraft(), histories: Set(batch.histories.map(\.id))))
    }

    /// 만든 묶음을 미리 본다(사본 뜨기 → 사본에 써 보기). 최신 사본에 이미 있는 재생 기록은 보존본 연결만 갱신한다
    func previewBatch(_ batch: DraftWriteBatch, uuids: Set<String>, exclusions: [String]) async throws -> WritePreview {
        // 미리 보기는 길이만 잰다(음량은 쓸 때 잰다. 막히는지 보는 데는 필요 없다).
        let inputs = try await analysisInputs(for: batch.grids, measuringLoudness: false)
        try requireDraftSaves(for: uuids)
        stage(WriteStage(String(ui: "미리 보기 1/2단계 · 사본을 만드는 중…"), completed: 0, total: 2, cancellable: true))
        // 미리 보기 포트는 async라 이 작업의 취소를 그대로 받는다. 사본 뜨기·시험 쓰기의 막는 입출력은 실제 구현이 맡는다
        let gate = ports.gate, stage = ports.lock.stage, source = target
        let report = try await gate.preview(batch, inputs, source) {
            await stage(WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true))
        }
        try Task.checkCancellation()
        let present = (report.historyOutcomes ?? []).filter { $0.status == .unchanged }
        if !present.isEmpty, let warning = await ports.library.recordHistories(present) {
            apply(.historyMarkFailed(warning))
        }
        return WritePreview(report: report, batch: batch, exclusions: exclusions)
    }

    /// 초안 쓰기(단계): 쓰기 직전 확인 → 분석 입력(음량까지) → 쓰기 관문 → (켜져 있으면) 쓴 뒤 처리.
    /// 앱 흐름·자가 테스트와 `djc cue-write`가 같이 쓴다(CLI는 쓴 뒤 처리를 끈다).
    public func writeDrafts(_ batch: DraftWriteBatch, to target: RekordboxWriteTarget, dryRun: Bool = false) async throws -> RekordboxWriteReport {
        try await writeDraftsFollowingUp(batch, to: target, dryRun: dryRun).report
    }

    func writeDraftsFollowingUp(_ batch: DraftWriteBatch, to target: RekordboxWriteTarget,
                                dryRun: Bool) async throws -> (report: RekordboxWriteReport, followUp: [String]) {
        try Task.checkCancellation()
        apply(.followUp([]))
        defer { stage(nil) }
        let uuids = batch.trackUUIDs
        try requireDraftSaves(for: uuids)
        if batch.playlists != nil { try requirePlaylistDraftSaved() }
        let inputs = try await analysisInputs(for: batch.grids, measuringLoudness: true)
        try Task.checkCancellation()
        try requireDraftSaves(for: uuids)
        stage(WriteStage(String(ui: "rekordbox에 저장하는 중…")))
        let gate = ports.gate
        let report = try await BlockingWork.run { try gate.write(batch, inputs, target, dryRun) }
        guard options.followsUp else { return (report, []) }
        return (report, await finishWrite(report, batch: batch, target: target))
    }

    // MARK: - 미리 보기 전 확인·묶기

    /// 대상 곡의 초안 파일이 손상돼 옮겼으면 쓰지 않고 알린다(미리 보기에서 조용히 빠지지 않게, #174)
    func requireReadableDrafts(for uuids: Set<String>, playlists: Bool) throws {
        let moved = ports.library.preserveDamagedDrafts()
        let affected = moved.contains { entry in
            if let uuid = entry.trackUUID { return uuids.contains(uuid) }
            return entry.name == "gain-drafts.json" || (playlists && entry.name == "playlist-drafts.json")
        }
        guard affected else { return }
        throw DJCError.writeRefused(String(ui: "읽지 못한 편집 파일을 damaged-drafts에 옮겨 두었으니 남은 편집을 확인한 뒤 저장을 다시 시도하세요."))
    }

    /// 쓸 곡(차례대로)의 초안 묶음. 변경 없는 초안은 뺀다.
    func draftBatch(for rows: [TrackRow], playlists: Bool, withPlaylistDraft: Bool = true) throws -> DraftWriteBatch {
        let state = ports.library.state(), files = ports.drafts
        let uuids = Set(rows.map(\.track.uuid))
        let merges = state.mergeDrafts.filter { $0.members.contains { uuids.contains($0.trackUUID) } }
        // 자동 큐를 빼고 만든 옛 초안에는 곡의 자동 큐를 채운다(#145, 쓰기도 같은 일을 한다).
        // 판의 해시는 디스크에서 읽은 그대로의 초안으로 잰다(쓴 뒤 정리가 지금 내용의 해시와 견준다, R22)
        let rawCues = Dictionary(rows.compactMap { row in files.cueDraft(row.track.uuid).map { (row.track.uuid, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        let cues = rows.compactMap { row in rawCues[row.track.uuid]?.includingAutoCues(from: row.cues, newID: files.newCueID) }
            .filter(\.hasChanges)
        let grids = rows.compactMap { files.gridDraft($0.track.uuid) }.filter(\.hasChanges)
        let allGains: [String: Double]
        do { allGains = try files.gainDrafts() } catch {
            // 읽지 못하면 빈 값으로 넘기지 않고 쓰기를 막는다.
            throw DJCError.writeRefused(String(ui: "게인 편집 파일을 읽지 못했으니 DJCrate 데이터 폴더의 접근 권한을 확인한 뒤 저장을 다시 시도하세요."))
        }
        let gains = Dictionary(uniqueKeysWithValues: rows.compactMap { row in allGains[row.track.uuid].map { (row.track.uuid, $0) } })
        let tags = rows.compactMap { files.tagDraft($0.track.uuid) }.filter(\.hasChanges)
        let artworks = try rows.compactMap { row -> ArtworkEdit? in
            guard state.artworkDrafts[row.track.uuid] != nil else { return nil }
            do { return try files.artworkEdit(row.track.uuid) } catch {
                // 읽지 못한 초안은 옮겨 보관하고 쓰기를 막는다(`requireReadableDrafts`가 먼저 옮긴다).
                throw DJCError.writeRefused(String(ui: "앨범아트 편집을 읽지 못했으니 그 곡의 앨범아트를 다시 고른 뒤 저장을 다시 시도하세요."))
            }
        }
        let playlistDraft = playlists && withPlaylistDraft && !state.playlistDraft.isEmpty && !state.playlistDraftNeedsSync ? state.playlistDraft : nil
        // 쓰기 대기 재생 기록(#43)도 재생 목록 초안처럼 곡을 고르지 않고 모두 본다. 관문이 막으면 막힘(이유)으로 돌아온다
        var batch = DraftWriteBatch(drafts: cues, grids: grids, gains: gains, tags: tags, artworks: artworks, playlists: playlistDraft, merges: merges,
                                    histories: playlists ? state.pendingHistories : [])
        stampRevisions(&batch, rawCues: rawCues)
        return batch
    }

    /// 묶음에 초안마다 판(도장과 읽어 넣은 내용의 해시)과 앱 쓰기의 작업을 싣는다(R11·R22). 그래야 관문이 쓰기 기록에 판을 적고 미정리 목록을 남기며,
    /// 쓴 뒤 정리가 실제로 쓴 판만 지운다. 도장이 없는 초안(판을 모름)은 빠진다. CLI(`followsUp` 꺼짐)는 작업을 싣지 않는다(미정리 목록 없음).
    /// 재생 목록은 디스크 초안이 묶음의 초안과 같을 때만 단계의 판을 싣고 디스크 초안(단계 식별자가 붙은)으로 바꿔 넣는다
    /// - Parameter verified: 읽어 넣을 때 도장과 내용을 이미 맞춰 본 곡 초안의 판(자동 저장). 주면 도장을 다시 읽지 않고 이것을 싣는다
    ///   (읽은 뒤 바뀐 도장을 읽은 내용에 붙이지 않게, R22)
    func stampRevisions(_ batch: inout DraftWriteBatch, rawCues: [String: CueDraft], verified: [DraftKey: DraftBatchEntry]? = nil) {
        let files = ports.drafts
        var tracks: [DraftKey: DraftBatchEntry] = [:]
        func put(_ key: DraftKey, _ content: () throws -> DraftContentHash) {
            guard let stamp = files.stamp(key), let hash = try? content() else { return }
            tracks[key] = DraftBatchEntry(stamp: stamp, contentHash: hash)
        }
        if let verified {
            let keys = batch.draftKeys
            tracks = verified.filter { keys.contains($0.key) }
        } else {
            for draft in batch.drafts {
                guard let raw = rawCues[draft.trackUUID] else { continue }
                put(DraftKey(.cue, draft.trackUUID)) { try DraftContentHash(of: raw) }
            }
            for grid in batch.grids { put(DraftKey(.grid, grid.trackUUID)) { try DraftContentHash(of: grid) } }
            for (uuid, gain) in batch.gains { put(DraftKey(.gain, uuid)) { try DraftContentHash(of: gain) } }
            for tag in batch.tags { put(DraftKey(.tag, tag.trackUUID)) { try DraftContentHash(of: tag) } }
            for artwork in batch.artworks { put(DraftKey(.artwork, artwork.trackUUID)) { try DraftContentHash(artwork: artwork) } }
            for merge in batch.merges { put(DraftKey(.merge, merge.id)) { try DraftContentHash(of: merge) } }
        }
        var steps: [DraftBatchEntry] = []
        if let playlists = batch.playlists {
            // 묶음의 초안은 디스크 초안 전체이거나 그 앞부분(자동 저장의 K행 나누기)이다. 해시는 디스크 초안 안에서 잰다(정리가 그 안에서 견준다)
            let disk = files.playlistDraft(), stamps = files.playlistStamps(), count = playlists.steps.count
            var source = disk
            if count < disk.steps.count { source.removeSteps(at: count..<disk.steps.count) }
            if count <= disk.steps.count, stamps.count == disk.steps.count, source == playlists {
                steps = zip(disk.steps.prefix(count), stamps.prefix(count)).compactMap { step, stamp in
                    (try? DraftContentHash(step: step, in: disk)).map { DraftBatchEntry(stamp: stamp, contentHash: $0) }
                }
                if steps.count == count { batch.playlists = source } else { steps = [] }
            }
        }
        batch.revisions = DraftBatchRevisions(tracks: tracks, playlistSteps: steps)
        if options.followsUp { batch.operation = DraftWriteOperation(id: newOperationID(), draftHome: location.draftHome) }
    }

    /// 앱 쓰기의 작업 ID. 핵심부는 ID를 스스로 만들지 않고 초안 저장소의 새 ID를 받는다(실제 구현은 무작위 UUID)
    func newOperationID() -> String { ports.drafts.newCueID().uuidString.lowercased() }

    /// 분석 전 곡(분석 파일 없음)의 그리드 초안에 붙일 음원 길이·음량·내장 그림(곡 UUID별). 분석 붙이기가 닫혀 있으면 비운다.
    /// 길이는 곡 넣기와 같은 값(AVFoundation), 음량은 쓸 때만 잰다. 내장 그림이 있으면 쓰기 관문이 아트워크도 넣는다(#87).
    public func analysisInputs(for grids: [GridDraft], measuringLoudness: Bool) async throws -> [String: RekordboxAnalysisInput] {
        guard options.attachesAnalysis else { return [:] }
        var inputs: [String: RekordboxAnalysisInput] = [:]
        for (index, grid) in grids.enumerated() {
            try Task.checkCancellation()
            stage(WriteStage(measuringLoudness ? String(ui: "음량을 재는 중…") : String(ui: "분석할 곡을 확인하는 중…"),
                             completed: index, total: grids.count, cancellable: true))
            guard let url = analysisAudioFile(grid.trackUUID) else { continue }
            guard let tags = try? await ports.audio.tags(url), tags.duration > 0 else { continue }
            let loudness = measuringLoudness ? await ports.audio.loudness(url) : nil
            try Task.checkCancellation()
            inputs[grid.trackUUID] = .init(duration: tags.duration, loudness: loudness, artwork: tags.artwork)
        }
        try Task.checkCancellation()
        return inputs
    }

    /// 분석을 붙일 곡의 음원: 목록의 rekordbox 로컬 곡 가운데 분석 파일이 없는 곡만
    func analysisAudioFile(_ uuid: String) -> URL? {
        guard let row = ports.library.state().rows[uuid], !row.isStaged, !row.track.isStreaming,
              ports.audio.needsAnalysis(row.track.analysisDataPath) else { return nil }
        return URL(filePath: row.track.folderPath)
    }

    // MARK: - 쓴 뒤

    /// 쓴 뒤: 쓴 초안을 정리하고(백업 폴더에 남는다) 새 스냅샷을 조용히 다시 읽어 덱에 알린다. 태그는 반영한 값이 새 base가 된다.
    /// 쓴 재생 기록(#43)은 다시 읽기 전에 보존본에 rekordbox 기록 ID를 남겨 쓰기 대기에서 뺀다(보존본은 지우지 않는다).
    /// - Returns: 쓰기 결과와 나눠 알릴 경고(#175)
    func finishWrite(_ report: RekordboxWriteReport, batch: DraftWriteBatch, target: RekordboxWriteTarget) async -> [String] {
        let uuids = batch.trackUUIDs
        // 스냅샷을 다시 읽으면 초안도 파일에서 다시 읽으므로 그 전에 쓴 편집을 뺀다.
        let merged = Set(report.mergeWritten.map(\.trackUUID))
        if !merged.isEmpty { replaceMergeDrafts(ports.library.state().mergeDrafts.filter { !merged.contains($0.id) }) }
        // 재생 목록은 쓴 단계만 판으로 찾아 뺀다(R22). 판을 모르는 묶음은 지금 동작(쓰는 동안 바뀌지 않았을 때 자리로 뺀다)이다
        var cleanupComplete = true
        if let playlists = batch.playlists {
            let state = ports.library.state()
            let cleanup = playlistEdits.finishWrite(playlists, outcomes: report.playlistOutcomes ?? [], current: state.playlistDraft,
                                                    imports: state.playlistImports, importsLoadFailed: state.playlistImportsLoadFailed,
                                                    entries: batch.revisions.playlistSteps, backups: target.backups,
                                                    backupFolder: report.backup.map { URL(filePath: $0).lastPathComponent } ?? "",
                                                    memoryUnsaved: state.playlistDraftUnsaved)
            cleanupComplete = cleanup.isComplete
            apply(.playlistWritten(cleanup))
        }
        let cleared = await removeWrittenDrafts(report, batch: batch)
        let tagWritten = Set(report.tagWritten.map(\.trackUUID))
        // 정리를 다 마쳤으면(초안과 연결 ID를 다 저장했다) 미정리 목록을 지운다. 끝나지 않았으면 남겨 다음 쓰기 전에 다시 한다(R22)
        if cleanupComplete, cleared.complete, let operation = batch.operation {
            await removeCleanupList(operation: operation, target: target)
        }
        // 다시 읽지 못해도 같은 기록을 또 쓰지 않게 다시 읽기 전에 남긴다.
        let historyWarning = (report.historyOutcomes ?? []).isEmpty ? nil : await ports.library.recordHistories(report.historyOutcomes ?? [])
        let saveWarning = draftSaveWarning(for: uuids, restoring: false)
        // 쓴 재생 목록 편집을 초안에서 빼지 못하면 다음에 같은 편집을 또 쓸 수 있으니 따로 알린다(#174·#175).
        let playlistWarning = batch.playlists != nil && ports.library.state().playlistDraftUnsaved
            ? String(ui: "rekordbox에는 저장했지만 재생 목록 편집을 정리하지 못했습니다.") + " " + Self.playlistSaveFailureText : nil
        // 화면을 처음부터 다시 불러오지 않고 뒤에서 조용히 다시 읽는다.
        // 덱은 새 스냅샷을 읽은 뒤에만 그 곡을 다시 읽는다(그리드만 바뀐 곡도 초안·그리드를 맞춘다). 읽지 못하면 다음 읽기까지 미룬다.
        let written = Set(report.written.map(\.trackUUID)).union(report.gridWritten.map(\.trackUUID)).union(report.gainWritten.map(\.trackUUID))
            .union(report.analysisWritten.map(\.trackUUID)).union(tagWritten).union(report.artworkWritten.map(\.trackUUID))
            .union(batch.merges.filter { merged.contains($0.id) }.flatMap { $0.members.map(\.trackUUID) })
        let reloaded = await reloadLibrary(during: .reloadingLibrary, written: written)
        apply(.lastWriteBackup(report.backup.map { URL(filePath: $0) }))
        return finishFollowUp([saveWarning, playlistWarning, historyWarning] + (report.warnings ?? []), reloaded: reloaded, restoring: false)
    }

    /// 쓴 곡 초안을 정리한 결과
    struct ClearedDrafts {
        var cues: [String] = []
        var grids: [String] = []
        var gains: [String] = []
        var tags: [String] = []
        var artworks: [String] = []
        /// 판 지정 정리를 마쳤다(저장소가 던지면 거짓: 미정리 목록을 남겨 다음 쓰기 전에 다시 한다)
        var complete = true
    }

    /// 쓴 곡 초안을 지우고 화면 표시를 맞춘다(R22). 판을 아는 초안은 판과 읽어 넣은 내용의 해시가 지금과 같을 때만 지운다:
    /// 쓰는 동안 같은 곡에 새로 저장한 초안(앱·CLI)은 판이 달라 남고, 판이 같은데 바깥에서 고친 초안은 제안으로 남는다.
    /// 판을 모르는 초안(도장이 없는 옛 초안)은 지금 동작대로 지운다. 저장 실패로 저장 큐에 남은 기록까지 같이 비우려고 파일을 직접 고치지 않는다(#174).
    func removeWrittenDrafts(_ report: RekordboxWriteReport, batch: DraftWriteBatch) async -> ClearedDrafts {
        // 분석을 붙인 곡도 그리드 초안이 분석 파일에 들어갔다.
        let keys = report.written.map { DraftKey(.cue, $0.trackUUID) } + (report.gridWritten + report.analysisWritten).map { DraftKey(.grid, $0.trackUUID) }
            + report.gainWritten.map { DraftKey(.gain, $0.trackUUID) } + report.tagWritten.map { DraftKey(.tag, $0.trackUUID) }
            + report.artworkWritten.map { DraftKey(.artwork, $0.trackUUID) }
        let known = batch.revisions.tracks, files = ports.drafts
        // 앱 쓰기 묶음(판·작업을 실음)에서 판을 모르던 초안(도장 없는 옛 초안)이라도 쓰는 동안 도장 있는 새 판이 저장됐으면(CLI 등) 지우지 않는다.
        // 판도 작업도 싣지 않은 묶음(손으로 만든 묶음)은 지금 동작대로 쓴 초안을 지운다
        let revised = !known.isEmpty || batch.operation != nil
        var removed = Set(keys.filter { known[$0] == nil && !(revised && files.stamp($0) != nil) })
        let legacy = removed
        var result = ClearedDrafts()
        let byRevision = batch.revisions.written(keys.filter { known[$0] != nil })
        if !byRevision.isEmpty {
            // 판 비교와 삭제는 초안 잠금(파일 잠금)을 기다릴 수 있어 메인 액터 밖에서 한다
            do { removed.formUnion(try await BlockingWork.run { try files.removeWritten(byRevision) }.removed.map(\.key)) } catch { result.complete = false }
        }
        func ids(_ kind: DraftKey.Kind) -> [String] { keys.filter { $0.kind == kind && removed.contains($0) }.map(\.id) }
        result.gains = ids(.gain)
        result.cues = ids(.cue)
        result.grids = ids(.grid)
        result.tags = ids(.tag)
        result.artworks = ids(.artwork)
        for uuid in result.gains where legacy.contains(DraftKey(.gain, uuid)) { ports.drafts.removeGain(uuid) }
        if !result.gains.isEmpty { apply(.draftsCleared(.gain, result.gains, cueCounts: false)) }
        for uuid in result.cues where legacy.contains(DraftKey(.cue, uuid)) { ports.drafts.removeCue(uuid) }
        if !result.cues.isEmpty { apply(.draftsCleared(.cue, result.cues, cueCounts: true)) }
        for uuid in result.grids where legacy.contains(DraftKey(.grid, uuid)) { ports.drafts.removeGrid(uuid) }
        if !result.grids.isEmpty { apply(.draftsCleared(.grid, result.grids, cueCounts: false)) }
        let clearedTags = batch.tags.filter { result.tags.contains($0.trackUUID) }.map { draft in
            var cleared = draft
            cleared.fields = cleared.base
            return cleared
        }
        // 판으로 지운 태그 초안은 파일이 이미 없다: 화면 메모리만 비운다. 판을 모르는 초안은 비운 초안으로 저장한다(파일째 지운다)
        let legacyTags = clearedTags.filter { legacy.contains(DraftKey(.tag, $0.trackUUID)) }
        if !legacyTags.isEmpty { replaceTagDrafts(legacyTags) }
        let revisedTags = clearedTags.filter { !legacy.contains(DraftKey(.tag, $0.trackUUID)) }
        if !revisedTags.isEmpty { apply(.tagDrafts(revisedTags)) }
        // 쓴 그림 초안을 지우고 목록·덱이 그 곡의 그림을 새로 읽게 한다(바꾸기는 ImagePath가 그대로라 캐시 열쇠를 바꾼다).
        if !result.artworks.isEmpty {
            var failed = 0
            for uuid in result.artworks where legacy.contains(DraftKey(.artwork, uuid)) {
                do { try ports.drafts.removeArtwork(uuid) } catch { failed += 1 }
            }
            apply(.artworkCleared(result.artworks, failed: failed))
        }
        return result
    }

    /// 정리를 마친 미정리 목록을 지운다(R22). 지우지 못하면 남겨 다음 쓰기 전 재시작 정리가 다시 한다(정리는 다시 해도 결과가 같다)
    func removeCleanupList(operation: DraftWriteOperation, target: RekordboxWriteTarget) async {
        let list = DraftCleanupList(operationID: operation.id, target: RekordboxWriteLockKey(device: 0, inode: 0),
                                    draftHome: operation.draftHome.path, backupFolder: "")
        let gate = ports.gate
        await BlockingWork.run { try? gate.removeCleanupList(list, target) }
    }

    // MARK: - 재생 목록 편집(CLI)

    /// 재생 목록 편집(JSON 배열)을 적힌 순서대로 쓴다(`djc playlist-write`, 사본만). 앱의 재생 목록 초안은 `write(rows:)`가 함께 쓴다.
    public func writePlaylistEdits(_ edits: [PlaylistEdit], to target: RekordboxWriteTarget, dryRun: Bool) throws -> RekordboxWriteReport {
        try ports.gate.writePlaylists(edits, target, dryRun)
    }
}
