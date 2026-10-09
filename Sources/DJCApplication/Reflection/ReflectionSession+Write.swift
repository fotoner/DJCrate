import DJCDomain
import Foundation

/// 초안 쓰기: 큐·그리드·게인·태그·앨범아트·재생 목록·합치기 초안을 rekordbox DB에 직접 쓴다(rekordbox가 꺼져 있을 때만).
/// 분석 전 곡(분석 파일 없음)의 그리드 초안은 분석 파일(파형·그리드·오토게인)을 만들어 붙인다(`Options.attachesAnalysis`).
extension ReflectionSession {
    /// 화면 흐름: 꺼짐 확인 → 대상 → 미리 보기 → (막힘·제외·손실이 있을 때만) 확인 → 쓸 수 있는 것만 쓰기 → 쓴 뒤 처리 → 결과.
    /// - Parameter playlists: 재생 목록 초안도 함께 쓸지(곡을 골라 쓰는 오른쪽 클릭 메뉴는 곡 초안만 쓴다)
    public func write(rows: [TrackRow], playlists: Bool = true) async -> ReflectionOutcome {
        guard !ports.lock.isLocked() else { return .busy }
        guard !ports.runningApps.isRekordboxRunning() else {
            return publish(.notice(title: String(ui: "rekordbox가 켜져 있어 쓰지 않았습니다"), text: ReflectionPrompts.quitRekordboxText, lines: []))
        }
        let chosen = writeTargets(rows)
        let withPlaylists = playlists && !ports.library.state().playlistDraft.isEmpty
        guard !chosen.isEmpty || withPlaylists else {
            return publish(.notice(title: String(ui: "쓸 초안이 없습니다"), text: String(ui: "고른 곡에 rekordbox와 다른 큐·그리드·게인·태그 초안이 없습니다."),
                                   lines: exclusions(for: rows, blockedOnly: false)))
        }
        lock(true)
        defer { lock(false) }
        do {
            stage(WriteStage(String(ui: "바꿀 내용을 확인하는 중…"), completed: 0, total: chosen.count, cancellable: true))
            try Task.checkCancellation()
            let preview = try await previewWrite(rows: rows, playlists: withPlaylists)
            try Task.checkCancellation()
            stage(nil)
            // 창 대신 결과에 제외한 초안까지 남긴다(#230). 막힌 초안은 화면이 복구 시트로 고치게 한다(#232).
            guard preview.hasWritable else { return publish(.nothingWritable(preview, targets: chosen)) }
            // 막힘·제외·손실이 없으면 묻지 않고 쓴다. 결과 토스트와 메뉴의 "쓰기 전으로 복원…"으로 되돌린다(#210).
            let canBackUp = ports.backups.canWrite(location.backupDirectory)
            if !WriteConfirmPolicy.reasons(preview.report, exclusions: preview.exclusions, canBackUp: canBackUp).isEmpty {
                guard ports.confirmation.confirm(ReflectionPrompts.confirmation(preview.report, exclusions: preview.exclusions, canBackUp: canBackUp))
                else { return .declined }
            }
            try Task.checkCancellation()
            // 분석을 붙이는 곡도 그리드 초안으로 쓴다(`writableBatch`). 쓰기 결과와 뒤따른 일의 경고는 나눠 알린다(#175).
            let written = try await writeDraftsFollowingUp(preview.writableBatch, to: target, dryRun: false)
            return publish(.written(written.report, preview: preview.report, followUp: written.followUp))
        } catch is CancellationError {
            stage(nil)
            return publish(.cancelled)
        } catch {
            stage(nil)
            // 미리 보기에서 제외한 초안은 따로 창을 띄우지 않고 실패 알림에 합친다(#230).
            return publish(.failed(title: String(ui: "rekordbox에 쓰지 않았습니다"), error: error, exclusions: exclusions(for: rows, blockedOnly: true)))
        }
    }

    /// 미리 보기(단계): 초안을 확인해 묶고, 위치의 rekordbox에서 새 사본을 떠 끝까지 써 본다(rekordbox는 건드리지 않는다).
    /// - Parameter playlists: 재생 목록 초안도 함께 볼지(곡 초안과 달리 곡을 골라 나누지 않는다)
    public func previewWrite(rows: [TrackRow], playlists: Bool) async throws -> WritePreview {
        ports.drafts.flush()
        ports.library.retryTagSaves()
        let targets = writeTargets(rows)
        let uuids = Set(targets.map(\.track.uuid))
        // 읽지 못한 초안 파일이 미리 보기에서 조용히 빠지지 않게 먼저 옮기고 알린다(#174).
        try requireReadableDrafts(for: uuids, playlists: playlists)
        try requireDraftSaves(for: uuids)
        guard ports.library.state().failedTagSaves.isDisjoint(with: uuids) else { throw DJCError.writeRefused(DraftSaveFailure.tagSaveMessage) }
        if playlists { try requirePlaylistDraftSaved() }
        let batch = try draftBatch(for: targets, playlists: playlists)
        // 미리 보기는 길이만 잰다(음량은 쓸 때 잰다. 막히는지 보는 데는 필요 없다).
        let inputs = try await analysisInputs(for: batch.grids, measuringLoudness: false)
        try requireDraftSaves(for: uuids)
        stage(WriteStage(String(ui: "미리 보기 1/2단계 · 사본을 만드는 중…"), completed: 0, total: 2, cancellable: true))
        let gate = ports.gate, stage = ports.lock.stage, source = target
        let task = Task.detached(priority: .userInitiated) {
            try await gate.preview(batch, inputs, source) {
                await stage(WriteStage(String(ui: "미리 보기 2/2단계 · 바꿀 내용을 검사하는 중…"), completed: 1, total: 2, cancellable: true))
            }
        }
        let report = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return WritePreview(report: report, batch: batch, exclusions: exclusions(for: rows, blockedOnly: true))
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
        stage(WriteStage(String(ui: "rekordbox에 쓰는 중…")))
        let gate = ports.gate
        let report = try await Task.detached(priority: .userInitiated) {
            try gate.write(batch, inputs, target, dryRun)
        }.value
        guard options.followsUp else { return (report, []) }
        return (report, await finishWrite(report, batch: batch))
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
        throw DJCError.writeRefused(String(ui: "읽지 못한 초안 파일을 damaged-drafts에 옮겨 두었으니 남은 초안을 확인한 뒤 쓰기를 다시 시도하세요."))
    }

    /// 쓸 곡(차례대로)의 초안 묶음. 변경 없는 초안은 뺀다.
    func draftBatch(for rows: [TrackRow], playlists: Bool) throws -> DraftWriteBatch {
        let state = ports.library.state(), files = ports.drafts
        let uuids = Set(rows.map(\.track.uuid))
        let merges = state.mergeDrafts.filter { $0.members.contains { uuids.contains($0.trackUUID) } }
        // 자동 큐를 빼고 만든 옛 초안에는 곡의 자동 큐를 채운다(#145, 쓰기도 같은 일을 한다).
        let cues = rows.compactMap { row in files.cueDraft(row.track.uuid)?.includingAutoCues(from: row.cues, newID: files.newCueID) }
            .filter(\.hasChanges)
        let grids = rows.compactMap { files.gridDraft($0.track.uuid) }.filter(\.hasChanges)
        let allGains: [String: Double]
        do { allGains = try files.gainDrafts() } catch {
            // 읽지 못하면 빈 값으로 넘기지 않고 쓰기를 막는다.
            throw DJCError.writeRefused(String(ui: "게인 초안 파일을 읽지 못했으니 DJCrate 데이터 폴더의 접근 권한을 확인한 뒤 쓰기를 다시 시도하세요."))
        }
        let gains = Dictionary(uniqueKeysWithValues: rows.compactMap { row in allGains[row.track.uuid].map { (row.track.uuid, $0) } })
        let tags = rows.compactMap { files.tagDraft($0.track.uuid) }.filter(\.hasChanges)
        let artworks = try rows.compactMap { row -> ArtworkEdit? in
            guard state.artworkDrafts[row.track.uuid] != nil else { return nil }
            do { return try files.artworkEdit(row.track.uuid) } catch {
                // 읽지 못한 초안은 옮겨 보관하고 쓰기를 막는다(`requireReadableDrafts`가 먼저 옮긴다).
                throw DJCError.writeRefused(String(ui: "앨범아트 초안을 읽지 못했으니 그 곡의 앨범아트를 다시 고른 뒤 쓰기를 다시 시도하세요."))
            }
        }
        let playlistDraft = playlists && !state.playlistDraft.isEmpty ? state.playlistDraft : nil
        return DraftWriteBatch(drafts: cues, grids: grids, gains: gains, tags: tags, artworks: artworks, playlists: playlistDraft, merges: merges)
    }

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
    /// - Returns: 쓰기 결과와 나눠 알릴 경고(#175)
    func finishWrite(_ report: RekordboxWriteReport, batch: DraftWriteBatch) async -> [String] {
        let uuids = batch.trackUUIDs
        // 스냅샷을 다시 읽으면 초안도 파일에서 다시 읽으므로 그 전에 쓴 편집을 뺀다.
        let merged = Set(report.mergeWritten.map(\.trackUUID))
        if !merged.isEmpty { replaceMergeDrafts(ports.library.state().mergeDrafts.filter { !merged.contains($0.id) }) }
        if let playlists = batch.playlists {
            let state = ports.library.state()
            apply(.playlistWritten(playlistEdits.finishWrite(playlists, outcomes: report.playlistOutcomes ?? [], current: state.playlistDraft,
                                                             imports: state.playlistImports,
                                                             importsLoadFailed: state.playlistImportsLoadFailed)))
        }
        // 저장 실패로 저장 큐에 남은 기록까지 같이 비우려고 파일을 직접 고치지 않는다(#174).
        let gains = report.gainWritten.map(\.trackUUID)
        gains.forEach(ports.drafts.removeGain)
        if !gains.isEmpty { apply(.draftsCleared(.gain, gains, cueCounts: false)) }
        let cues = report.written.map(\.trackUUID)
        cues.forEach(ports.drafts.removeCue)
        if !cues.isEmpty { apply(.draftsCleared(.cue, cues, cueCounts: true)) }
        // 분석을 붙인 곡도 그리드 초안이 분석 파일에 들어갔다.
        let grids = (report.gridWritten + report.analysisWritten).map(\.trackUUID)
        grids.forEach { ports.drafts.removeGrid($0) }
        if !grids.isEmpty { apply(.draftsCleared(.grid, grids, cueCounts: false)) }
        let tagWritten = Set(report.tagWritten.map(\.trackUUID))
        let clearedTags = batch.tags.filter { tagWritten.contains($0.trackUUID) }.map { draft in
            var cleared = draft
            cleared.fields = cleared.base
            return cleared
        }
        if !clearedTags.isEmpty { replaceTagDrafts(clearedTags) }
        // 쓴 그림 초안을 지우고 목록·덱이 그 곡의 그림을 새로 읽게 한다(바꾸기는 ImagePath가 그대로라 캐시 열쇠를 바꾼다).
        let artworks = report.artworkWritten.map(\.trackUUID)
        if !artworks.isEmpty {
            var failed = 0
            for uuid in artworks {
                do { try ports.drafts.removeArtwork(uuid) } catch { failed += 1 }
            }
            apply(.artworkCleared(artworks, failed: failed))
        }
        let saveWarning = draftSaveWarning(for: uuids, restoring: false)
        // 쓴 재생 목록 편집을 초안에서 빼지 못하면 다음에 같은 편집을 또 쓸 수 있으니 따로 알린다(#174·#175).
        let playlistWarning = batch.playlists != nil && ports.library.state().playlistDraftUnsaved
            ? String(ui: "rekordbox에는 썼지만 재생 목록 초안을 정리하지 못했습니다.") + " " + Self.playlistSaveFailureText : nil
        // 화면을 처음부터 다시 불러오지 않고 뒤에서 조용히 다시 읽는다.
        // 덱은 새 스냅샷을 읽은 뒤에만 그 곡을 다시 읽는다(그리드만 바뀐 곡도 초안·그리드를 맞춘다). 읽지 못하면 다음 읽기까지 미룬다.
        stage(.reloadingLibrary)
        let written = Set(cues).union(report.gridWritten.map(\.trackUUID)).union(gains).union(report.analysisWritten.map(\.trackUUID))
            .union(tagWritten).union(artworks)
            .union(batch.merges.filter { merged.contains($0.id) }.flatMap { $0.members.map(\.trackUUID) })
        let reloaded = await ports.reload.reload(written, [])
        apply(.lastWriteBackup(report.backup.map { URL(filePath: $0) }))
        return finishFollowUp([saveWarning, playlistWarning] + (report.warnings ?? []), reloaded: reloaded, restoring: false)
    }

    // MARK: - 재생 목록 편집(CLI)

    /// 재생 목록 편집(JSON 배열)을 적힌 순서대로 쓴다(`djc playlist-write`, 사본만). 앱의 재생 목록 초안은 `write(rows:)`가 함께 쓴다.
    public func writePlaylistEdits(_ edits: [PlaylistEdit], to target: RekordboxWriteTarget, dryRun: Bool) throws -> RekordboxWriteReport {
        try ports.gate.writePlaylists(edits, target, dryRun)
    }
}
