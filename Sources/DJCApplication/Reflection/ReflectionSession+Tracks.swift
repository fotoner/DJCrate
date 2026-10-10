import DJCDomain
import Foundation

/// rekordbox 컬렉션에 곡을 바로 넣고 뺀다(rekordbox를 켜지 않고). 둘 다 새 스냅샷 사본으로 미리 보고, 쓰기 직전 백업을 떠서 되돌릴 수 있다.
/// 넣기: 추가한 곡의 태그 초안·그리드 초안·음량으로 곡 행과 분석 파일(파형·그리드·오토게인)을 만들고, 큐 초안과 고른 키(#5)도 같은 트랜잭션에서 쓴다.
/// 분석까지 붙이는 곡은 음원의 아트워크로 아트워크 파일도 만든다(`Options.writesArtwork`).
/// 빼기: 곡 행과 딸린 큐·재생 목록 항목·재생 기록·분석 파일·아트워크 파일을 지운다(음원 파일은 그대로).
extension ReflectionSession {
    // MARK: - 넣기

    /// 화면 흐름: 추가한 곡을 rekordbox 컬렉션에 넣는다(그리드·파형·오토게인까지). 흐름은 쓰기와 같다.
    public func addTracks(rows: [TrackRow]) async -> ReflectionOutcome {
        guard !ports.lock.isLocked() else { return .busy }
        guard !ports.runningApps.isRekordboxRunning() else {
            return publish(.notice(title: String(ui: "rekordbox가 켜져 있어 넣지 않았습니다"), text: ReflectionPrompts.quitRekordboxText, lines: []))
        }
        let adding = ReflectionTargets.add(rows)
        guard !adding.isEmpty else {
            return publish(.notice(title: String(ui: "rekordbox에 넣을 곡이 없습니다"), text: String(ui: "DJCrate에 추가한 곡만 rekordbox에 넣을 수 있습니다."),
                                   lines: []))
        }
        lock(true)
        defer { lock(false) }
        do {
            stage(WriteStage(String(ui: "넣을 곡을 확인하는 중…"), completed: 0, total: adding.count, cancellable: true))
            try Task.checkCancellation()
            let preview = try await previewAdd(rows: adding)
            try Task.checkCancellation()
            stage(nil)
            // 넣지 않은 이유는 결과 토스트와 결과 보기에 있다(#230).
            guard preview.report.added.contains(where: \.written) else { return publish(.nothingAdded(preview)) }
            let canBackUp = ports.backups.canWrite(location.backupDirectory), writesArtwork = options.writesArtwork
            if !WriteConfirmPolicy.addReasons(preview, writesArtwork: writesArtwork, canBackUp: canBackUp).isEmpty {
                guard ports.confirmation.confirm(ReflectionPrompts.addConfirmation(preview, writesArtwork: writesArtwork, canBackUp: canBackUp))
                else { return .declined }
            }
            try Task.checkCancellation()
            // 넣기는 끝났지만 백업에 추가 목록·초안을 남기지 못했다는 경고는 결과와 나눠 덧붙인다(#202).
            let written = try await addFollowingUp(preview, to: target)
            return publish(.added(written.report, preview: preview, followUp: written.followUp))
        } catch is CancellationError {
            stage(nil)
            return publish(.cancelled)
        } catch {
            stage(nil)
            return publish(.failed(title: String(ui: "rekordbox에 넣지 않았습니다"), error: error, exclusions: []))
        }
    }

    /// 넣기 미리 보기(단계): 곡마다 계획(파일 태그 + 태그 초안)을 만들고, 새 스냅샷 사본으로 DB 쓰기를 시험한다
    /// (분석 파일은 만들지 않지만 큐는 함께 시험해 막히는 이유를 미리 본다).
    public func previewAdd(rows: [TrackRow]) async throws -> TrackAddPreview {
        let staged = ports.library.state().staged
        let tracks = ReflectionTargets.add(rows).compactMap { row in staged.first { $0.id == row.id } }
            .map { StagedTrackRequest(uuid: $0.uuid, path: $0.path, title: $0.title) }
        // 저장에 실패한 큐·그리드 초안이 있으면 디스크의 옛 초안을 넣지 않는다(#170).
        try requireDraftSaves(for: Set(tracks.map(\.uuid)))
        // 미리 보기는 라이브에서 스냅샷을 뜬다: 명시한 사본으로 연 창은 사용자 스냅샷 폴더를 바꾸지 않게 막는다
        guard location.allowsSnapshot else { throw DJCError.writeRefused(Self.snapshotRefusedMessage) }
        var plans: [TrackAddPlan] = [], uuids: [String: String] = [:], without: [String: String] = [:], unreadable: [String] = []
        var cues: [String: [EditableCue]] = [:], keys: [String: String] = [:]
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            stage(WriteStage(String(ui: "넣을 곡을 확인하는 중…"), completed: index, total: tracks.count, cancellable: true))
            do {
                let candidate = try await addCandidate(track)
                let path = candidate.plan.path
                plans.append(candidate.plan)
                uuids[path] = track.uuid
                if let trackCues = candidate.cues { cues[path] = trackCues }
                if let key = candidate.key { keys[path] = key }
                if let reason = candidate.withoutAnalysis { without[path] = reason }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unreadable.append("\(track.title): \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        let gate = ports.gate
        let report = try await onSnapshotCopy { [plans, cues, keys] copy in
            try gate.addTracks(TrackAddBatch(plans: plans, cues: cues, keys: keys), copy, true)
        }
        return TrackAddPreview(report: report, plans: plans, stagedUUIDs: uuids, withoutAnalysis: without, cues: cues, keys: keys,
                               unreadable: unreadable)
    }

    /// 추가한 곡 하나의 넣기 계획. 음원을 읽지 못하면 던진다(그 곡만 빠진다).
    func addCandidate(_ track: StagedTrackRequest) async throws -> TrackAddCandidate {
        let url = URL(filePath: track.path)
        var tags = try await ports.audio.tags(url)
        let state = ports.library.state()
        if let fields = state.tagDrafts[track.uuid]?.fields { AddedTrackDrafts.apply(fields, to: &tags) }
        var candidate = TrackAddCandidate(plan: try ports.audio.addPlan(url, tags))
        if let draft = ports.drafts.cueDraft(track.uuid), !draft.cues.isEmpty { candidate.cues = draft.cues }
        // 고른 키는 곡을 넣은 뒤 같은 쓰기에서 쓴다(넣을 때 `KeyID` '0' → 키 저장). 음원 파일의 키 태그는 그대로다.
        candidate.key = AddedTrackDrafts.confirmedKey(state.tagDrafts[track.uuid])
        if ports.drafts.gridDraft(track.uuid)?.segments.first.map({ $0.bpm > 0 }) != true {
            candidate.withoutAnalysis = state.estimatingGrids ? String(ui: "그리드를 아직 추정하는 중") : String(ui: "그리드가 없음")
        } else if let reason = ports.audio.unsupported(url) {
            candidate.withoutAnalysis = reason
        }
        return candidate
    }

    /// 넣기(단계): 미리 본 곡 가운데 받아들인 곡만 넣는다. 분석을 붙일 곡은 음량을 재고, (켜져 있으면) 넣은 뒤 처리를 한다.
    public func add(_ preview: TrackAddPreview, to target: RekordboxWriteTarget) async throws -> RekordboxTrackWriteReport {
        try await addFollowingUp(preview, to: target).report
    }

    func addFollowingUp(_ preview: TrackAddPreview, to target: RekordboxWriteTarget) async throws -> (report: RekordboxTrackWriteReport, followUp: [String]) {
        apply(.followUp([]))
        // 미리 본 뒤 저장이 실패했을 수도 있다(그러면 디스크의 초안은 옛것이다).
        try requireDraftSaves(for: Set(preview.stagedUUIDs.values))
        let accepted = Set(preview.report.added.filter(\.written).map(\.path))
        let plans = preview.plans.filter { accepted.contains($0.path) }
        let analysisPlans = plans.filter { preview.withoutAnalysis[$0.path] == nil }
        stage(WriteStage(String(ui: "음량을 재는 중…"), completed: 0, total: analysisPlans.count, cancellable: true))
        defer { stage(nil) }
        var analyses: [String: RekordboxTrackAnalysis] = [:]
        for (index, plan) in analysisPlans.enumerated() {
            try Task.checkCancellation()
            stage(WriteStage(String(ui: "음량을 재는 중…"), completed: index, total: analysisPlans.count, cancellable: true))
            guard let uuid = preview.stagedUUIDs[plan.path], let grid = ports.drafts.gridDraft(uuid) else { continue }
            let measured = await ports.audio.loudness(URL(filePath: plan.path))
            try Task.checkCancellation()
            analyses[plan.path] = .init(segments: grid.segments, loudness: measured)
        }
        try Task.checkCancellation()
        stage(WriteStage(String(ui: "rekordbox에 곡과 분석 파일을 넣는 중…")))
        let batch = TrackAddBatch(plans: plans, analyses: analyses, cues: preview.cues.filter { accepted.contains($0.key) },
                                  keys: preview.keys.filter { accepted.contains($0.key) })
        let gate = ports.gate
        let report = try await BlockingWork.run { try gate.addTracks(batch, target, false) }
        guard options.followsUp else { return (report, []) }
        return (report, await finishAdd(report, preview: preview, analysed: Set(analyses.keys)))
    }

    /// 음원 계획으로 바로 넣는다(단계, `djc track-add`: 추가 목록 없이 음원과 분석을 받는다)
    public func addTracks(_ batch: TrackAddBatch, to target: RekordboxWriteTarget, dryRun: Bool) throws -> RekordboxTrackWriteReport {
        try ports.gate.addTracks(batch, target, dryRun)
    }

    /// 넣은 뒤: 초안 옮기기(큐가 막힌 곡은 새 곡의 반영 대기로, 그리드는 분석 파일에 들어갔으면 끝, 못 붙였으면 새 곡 초안으로),
    /// 추가 목록 정리와 백업에 사본 남기기, 다시 읽기. 넣은 곡의 옛 UUID 초안은 백업에 사본을 남긴 것만 정리한다(#202).
    /// - Returns: 넣기 결과와 나눠 알릴 경고(백업에 남기지 못한 것, #202)
    func finishAdd(_ report: RekordboxTrackWriteReport, preview: TrackAddPreview, analysed: Set<String>) async -> [String] {
        var unstaged: Set<String> = []
        for outcome in report.added where outcome.written {
            guard let old = preview.stagedUUIDs[outcome.path], let new = outcome.uuid else { continue }
            unstaged.insert(old)
            if outcome.cuesWritten == nil, let cues = ports.drafts.cueDraft(old), !cues.cues.isEmpty {
                ports.drafts.saveCue(AddedTrackDrafts.movedCueDraft(from: cues, to: new))
            }
            if !analysed.contains(outcome.path), let grid = ports.drafts.gridDraft(old) {
                ports.drafts.saveGrid(AddedTrackDrafts.movedGridDraft(from: grid, to: new))
            }
        }
        // 키가 막힌 곡의 키도 같은 자리에서(다시 읽기 전에) 새 곡의 초안으로 옮긴다: 읽기가 실패해도 결과 창이 알린 "쓰기 대기"가 사실이 되게.
        let movedKeys = AddedTrackDrafts.blockedKeyDrafts(report, keys: preview.keys)
        if !movedKeys.isEmpty { replaceTagDrafts(movedKeys) }
        ports.drafts.flush()
        let state = ports.library.state()
        // 덱에 올린 추가한 곡을 넣었으면 새로 읽을 때 새 rekordbox 곡으로 바꿔 올린다(덱을 비우지 않게).
        if let deckUUID = state.deckStagedUUID,
           let moved = report.added.first(where: { $0.written && preview.stagedUUIDs[$0.path] == deckUUID })?.contentID {
            apply(.deckTrackMoved(moved))
        }
        let removed = state.staged.filter { unstaged.contains($0.uuid) }
        if !removed.isEmpty { apply(.unstaged(unstaged)) }
        // 백업에 추가 목록과 추가한 곡의 초안 사본을 남긴다. 남기지 못한 것은 넣기 결과에 경고로 알린다(넣기는 이미 끝났으니 실패로 바꾸지 않는다, #202).
        var notes: [String] = []
        if let backup = report.backup.map({ URL(filePath: $0) }) {
            if !removed.isEmpty, (try? ports.backups.saveStagedTracks(removed, backup)) == nil { notes.append(Self.stagedBackupFailureText) }
            let unsaved = saveStagedDrafts(uuids: unstaged, in: backup)
            if !unsaved.isEmpty { notes.append(Self.stagedDraftsBackupFailureText(unsaved.count)) }
        }
        stage(WriteStage(String(ui: "넣은 곡을 읽는 중…")))
        _ = await ports.reload.reload([], [])
        if let first = report.added.first(where: \.written), let id = first.contentID { apply(.showAdded(id)) }
        apply(.lastWriteBackup(report.backup.map { URL(filePath: $0) }))
        apply(.followUp(notes))
        return notes
    }

    /// 넣은 추가 목록 곡의 태그·큐·그리드 초안을 백업에 두고, 백업에 사본이 있는 초안은 옛 UUID에서 정리한다(#202).
    /// 넣기에 쓰였거나(큐·그리드·태그) 새 곡의 초안으로 옮겼고, 백업에 남았으니 "쓰기 전으로 복원…"이 곡을 추가 목록으로 되돌리며
    /// 이 초안도 되살린다(#197). 그대로 두면 어느 곡에도 이어지지 않는 초안(#175)으로 쓰기 대기 목록에 남는다.
    /// 사본을 남기지 못한 초안은 되돌릴 때 이어질 유일한 사본이라 지우지 않는다(추가 목록에 돌아온 곡의 초안으로 이어진다).
    /// - Returns: 사본을 남기지 못해 초안을 지우지 않은 곡 UUID
    func saveStagedDrafts(uuids: Set<String>, in backup: URL) -> Set<String> {
        func put(_ draft: RekordboxBackupDraft) -> Bool { (try? ports.backups.saveDraft(draft, backup)) != nil }
        let tagDrafts = ports.library.state().tagDrafts
        var unsaved: Set<String> = []
        var clearedTags: [TagDraft] = []
        for uuid in uuids.sorted() {
            // 변경이 없는 초안은 되살릴 것이 없어 사본 없이 정리한다.
            if let draft = ports.drafts.cueDraft(uuid) {
                if !draft.hasChanges || put(.cue(draft)) {
                    ports.drafts.removeCue(uuid)
                    apply(.draftsCleared(.cue, [uuid], cueCounts: false))
                } else { unsaved.insert(uuid) }
            }
            if let grid = ports.drafts.gridDraft(uuid) {
                if grid.segments.isEmpty || put(.grid(grid)) {
                    ports.drafts.removeGrid(uuid)
                    apply(.draftsCleared(.grid, [uuid], cueCounts: false))
                } else { unsaved.insert(uuid) }
            }
            if let tag = tagDrafts[uuid] {
                if !tag.hasChanges || put(.tag(tag)) {
                    clearedTags.append(TagDraft(trackUUID: uuid, base: TagFields()))
                } else { unsaved.insert(uuid) }
            }
        }
        if !clearedTags.isEmpty { replaceTagDrafts(clearedTags) }
        ports.drafts.flush()
        return unsaved
    }

    // MARK: - 빼기

    /// 화면 흐름: rekordbox 컬렉션에서 곡을 뺀다(음원 파일은 그대로). 흐름은 쓰기와 같고 확인 창은 늘 묻는 경고 모양이다.
    public func deleteTracks(rows: [TrackRow]) async -> ReflectionOutcome {
        guard !ports.lock.isLocked() else { return .busy }
        guard !ports.runningApps.isRekordboxRunning() else {
            return publish(.notice(title: String(ui: "rekordbox가 켜져 있어 빼지 않았습니다"), text: ReflectionPrompts.quitRekordboxText, lines: []))
        }
        let deleting = ReflectionTargets.delete(rows, iTunesSelection: ports.library.state().iTunesSelection)
        guard !deleting.isEmpty else {
            return publish(.notice(title: String(ui: "rekordbox에서 뺄 곡이 없습니다"),
                                   text: String(ui: "rekordbox 컬렉션의 로컬 곡만 뺄 수 있습니다(스트리밍·추가한 곡 제외)."), lines: []))
        }
        lock(true)
        defer { lock(false) }
        do {
            stage(WriteStage(String(ui: "뺄 곡을 확인하는 중…"), completed: 0, total: deleting.count, cancellable: true))
            try Task.checkCancellation()
            let preview = try await previewDelete(rows: deleting)
            try Task.checkCancellation()
            stage(nil)
            // 빼지 않은 이유는 결과 토스트와 결과 보기에 있다(#230).
            guard preview.report.deleted.contains(where: \.written) else { return publish(.nothingDeleted(preview)) }
            guard ports.confirmation.confirm(ReflectionPrompts.deleteConfirmation(preview)) else { return .declined }
            try Task.checkCancellation()
            let written = try await delete(preview, from: target)
            return publish(.deleted(written, preview: preview))
        } catch is CancellationError {
            stage(nil)
            return publish(.cancelled)
        } catch {
            stage(nil)
            return publish(.failed(title: String(ui: "rekordbox에서 빼지 않았습니다"), error: error, exclusions: []))
        }
    }

    /// 빼기 미리 보기(단계): 새 스냅샷 사본으로 빼기를 시험한다.
    public func previewDelete(rows: [TrackRow]) async throws -> TrackDeletePreview {
        guard location.allowsSnapshot else { throw DJCError.writeRefused(Self.snapshotRefusedMessage) }
        let ids = ReflectionTargets.delete(rows, iTunesSelection: ports.library.state().iTunesSelection).map(\.track.id)
        try Task.checkCancellation()
        let gate = ports.gate
        let report = try await onSnapshotCopy { copy in try gate.deleteTracks(ids, copy, true) }
        try Task.checkCancellation()
        return TrackDeletePreview(report: report, contentIDs: ids)
    }

    /// 빼기(단계): 미리 보기에서 뺄 수 있다고 나온 곡만 뺀다(음원 파일은 그대로). (켜져 있으면) 뺀 뒤 다시 읽는다.
    public func delete(_ preview: TrackDeletePreview, from target: RekordboxWriteTarget) async throws -> RekordboxTrackWriteReport {
        guard !ports.library.state().iTunesSelection else { throw DJCError.writeRefused(String(ui: "iTunes 동기화 목록의 곡은 Music에서 빼세요.")) }
        let ids = preview.report.deleted.filter(\.written).compactMap(\.contentID)
        try Task.checkCancellation()
        stage(WriteStage(String(ui: "rekordbox에서 곡을 빼는 중…")))
        defer { stage(nil) }
        let gate = ports.gate
        let report = try await BlockingWork.run { try gate.deleteTracks(ids, target, false) }
        guard options.followsUp else { return report }
        apply(.deselected(Set(report.deleted.filter(\.written).compactMap(\.contentID))))
        stage(WriteStage(String(ui: "라이브러리를 다시 읽는 중…")))
        _ = await ports.reload.reload([], [])
        apply(.lastWriteBackup(report.backup.map { URL(filePath: $0) }))
        return report
    }

    /// ContentID로 바로 뺀다(단계, `djc track-delete`)
    public func deleteTracks(_ ids: [String], from target: RekordboxWriteTarget, dryRun: Bool) throws -> RekordboxTrackWriteReport {
        try ports.gate.deleteTracks(ids, target, dryRun)
    }
}
