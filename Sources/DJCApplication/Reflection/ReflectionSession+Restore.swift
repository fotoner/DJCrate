import DJCDomain
import Foundation

/// 쓰기 전으로 복원: DB를 쓰기 전으로 돌리고, 그때 쓴 초안을 DJCrate에 다시 살린다.
/// 쓴 뒤 같은 곡에 새로 만든 초안은 말없이 덮지 않고 고르게 한다(#175). 순서는 쓰기와 같다(꺼짐 확인 → 그 뒤 바뀐 것 확인 → 확인 → 복원).
/// 토스트에서 누른 복원은 그 뒤 변경·초안 충돌이 없으면 묻지 않는다(#210).
extension ReflectionSession {
    /// 화면 흐름
    /// - Parameter confirmed: 쓰기 결과 토스트의 복원 단추로 불렀는지(그 백업을 보고 누른 것이라 확인으로 본다)
    public func restore(_ backup: RekordboxWriteBackup, confirmed: Bool = false) async -> ReflectionOutcome {
        guard !ports.lock.isLocked() else { return .busy }
        guard !ports.runningApps.isRekordboxRunning() else {
            return publish(.notice(title: String(ui: "rekordbox가 켜져 있어 복원하지 않았습니다"), text: String(ui: "rekordbox를 완전히 종료한 뒤 다시 누르세요."),
                                   lines: []))
        }
        // 시점 복원 뒤의 옛 백업은 복원 직전 백업도 만들지 않고 이유와 할 일만 알린다(#225).
        if let reason = ports.backups.pointRestoreRefusal(backup.url, location.backupDirectory) {
            return publish(.notice(title: String(ui: "복원하지 않았습니다"), text: reason, lines: []))
        }
        lock(true)
        defer { lock(false) }
        stage(WriteStage(String(ui: "백업 뒤 바뀐 것을 확인하는 중…")))
        let changed = await libraryChangedSince(backup)
        // 쓴 뒤 같은 곡에 새로 만든 초안은 말없이 덮지 않고 고르게 한다(#175).
        let conflicts = restoreConflictDetails(backup)
        let later = ports.backups.laterCount(backup.url, location.backupDirectory)
        stage(nil)
        let keepingCurrentDrafts: Bool
        if conflicts.isEmpty {
            // 토스트의 복원 단추를 누른 것이 곧 확인이다. 그 뒤 rekordbox 변경·뒤 쓰기를 잃을 수 있으면 다시 묻는다(#210).
            if !(confirmed && changed == false && later == 0) {
                guard ports.confirmation.confirm(ReflectionPrompts.restoreConfirmation(backup, changedSince: changed, later: later)) else { return .declined }
            }
            keepingCurrentDrafts = true
        } else {
            switch ports.confirmation.choose(ReflectionPrompts.restoreConfirmation(backup, changedSince: changed, conflicts: conflicts, later: later)) {
            case .confirm: keepingCurrentDrafts = true
            case .alternate: keepingCurrentDrafts = false
            case .cancel: return .declined
            }
        }
        do {
            let restored = try await restoreFollowingUp(backup, keepingCurrentDrafts: keepingCurrentDrafts, to: target)
            return publish(.restored(backup, saved: restored.saved, fileWarning: ports.backups.fileWarning(restored.saved),
                                     followUp: restored.followUp))
        } catch {
            stage(nil)
            return publish(.restoreFailed(backup, error: error))
        }
    }

    /// 복원(단계): (켜져 있으면) 지금 초안 가운데 남길 것을 정하고 → 쓰기 관문으로 복원 → 백업의 초안을 되살린다.
    /// 앱 흐름·자가 테스트와 `djc rekordbox-restore`가 같이 쓴다(CLI는 되살리기를 끈다).
    /// - Parameter keepingCurrentDrafts: 쓴 뒤 새로 만든 초안을 남기고 그 곡의 백업 초안은 되살리지 않는다
    /// - Returns: 되돌리기 직전 상태를 남긴 백업
    @discardableResult
    public func restoreBackup(_ backup: RekordboxWriteBackup, keepingCurrentDrafts: Bool = true, to target: RekordboxWriteTarget) async throws -> URL {
        try await restoreFollowingUp(backup, keepingCurrentDrafts: keepingCurrentDrafts, to: target).saved
    }

    func restoreFollowingUp(_ backup: RekordboxWriteBackup, keepingCurrentDrafts: Bool,
                            to target: RekordboxWriteTarget) async throws -> (saved: URL, followUp: [String]) {
        apply(.followUp([]))
        stage(WriteStage(String(ui: "rekordbox를 복원하는 중…")))
        defer { stage(nil) }
        // 복원 전에: 남길 지금 초안을 정해 둔다(복원 뒤 덱이 다시 저장하는 값과 섞지 않게)
        let kept = options.revivesDrafts && keepingCurrentDrafts ? restoreConflicts(backup) : []
        let gate = ports.gate
        let saved = try await BlockingWork.run { try gate.restore(backup.url, target) }
        guard options.revivesDrafts else { return (saved, []) }
        return (saved, await reviveDrafts(from: backup, keeping: kept))
    }

    /// 백업 뒤 rekordbox에서 라이브러리가 바뀌었는지(되돌리면 그 변경도 사라진다).
    /// 명시한 사본으로 연 창은 스냅샷을 뜨지 않으므로 모른다(nil).
    public func libraryChangedSince(_ backup: RekordboxWriteBackup) async -> Bool? {
        guard location.allowsSnapshot, let expected = backup.finalUpdateCount else { return nil }
        let take = ports.snapshots.take, count = ports.backups.updateCount
        return try? await BlockingWork.run(qos: .default) {
            let snapshot = try take(false)
            return try count(snapshot) != expected
        }
    }

    // MARK: - 복원 충돌

    /// 백업이 되살릴 초안 중 같은 곡의 지금 초안과 다른 것. 지금 초안이 백업과 같거나 변경이 없으면 충돌이 아니다.
    /// 큐·그리드·게인은 저장하지 못한 입력이 있으면 그것이 지금 초안이고, 태그는 저장에 실패했을 수 있어 화면의 메모리 초안과 비교한다.
    public func restoreConflicts(_ backup: RekordboxWriteBackup) -> [RestoreDraftConflict] {
        let files = ports.drafts
        files.flush()
        let saved = ports.backups.drafts(backup.url), state = ports.library.state()
        var conflicts: [RestoreDraftConflict] = []
        for draft in saved.cues {
            let current = files.pendingCue(draft.trackUUID) ?? files.cueDraft(draft.trackUUID)
            if let current, current.hasChanges, current != draft { conflicts.append(.init(kind: .cue, uuid: draft.trackUUID)) }
        }
        for grid in saved.grids {
            let current = files.pendingGrid(grid.trackUUID) ?? files.gridDraft(grid.trackUUID)
            if let current, current.hasChanges, current != grid { conflicts.append(.init(kind: .grid, uuid: grid.trackUUID)) }
        }
        for (uuid, gain) in saved.gains.sorted(by: { $0.key < $1.key }) {
            let current = files.pendingGain(uuid) ?? (try? files.gainDrafts())?[uuid]
            if let current, current != gain { conflicts.append(.init(kind: .gain, uuid: uuid)) }
        }
        for tag in saved.tags {
            if let current = state.tagDrafts[tag.trackUUID], current.hasChanges, current != tag { conflicts.append(.init(kind: .tag, uuid: tag.trackUUID)) }
        }
        for edit in saved.artworks {
            if let current = state.artworkDrafts[edit.trackUUID], current != edit.draft { conflicts.append(.init(kind: .artwork, uuid: edit.trackUUID)) }
        }
        let restoredIDs = Set(saved.merges.flatMap { $0.members.map(\.trackUUID) })
        for current in state.mergeDrafts where !saved.merges.contains(current)
            && !Set(current.members.map(\.trackUUID)).isDisjoint(with: restoredIDs) {
            conflicts.append(.init(kind: .merge, uuid: current.id))
        }
        return conflicts
    }

    /// 충돌한 곡(합치기는 묶인 곡 모두)
    func conflictTrackUUIDs(_ conflicts: [RestoreDraftConflict], merges: [DuplicateMergeDraft]) -> [String: [RestoreDraftConflict]] {
        var byTrack: [String: [RestoreDraftConflict]] = [:]
        for conflict in conflicts {
            let uuids = conflict.kind == .merge ? merges.first { $0.id == conflict.uuid }?.members.map(\.trackUUID) ?? [] : [conflict.uuid]
            for uuid in uuids { byTrack[uuid, default: []].append(conflict) }
        }
        return byTrack
    }

    /// 복원 확인 창에 보일 충돌 목록("• 곡 — 큐·태그").
    /// 제목은 지금 목록의 곡 → 쓰기 보고서 → 백업에 남긴 추가 목록 순으로 찾는다. 곡 넣기 백업에는 쓰기 보고서가 없고 넣은 추가 목록 곡은
    /// 더는 목록의 곡이 아니라서, 마지막 것이 없으면 UUID가 그대로 보인다(#197).
    public func restoreConflictDetails(_ backup: RekordboxWriteBackup) -> [String] {
        var outcomes: [RekordboxWriteOutcome] = []
        if let report = backup.report {
            outcomes = report.outcomes + (report.gridOutcomes ?? []) + (report.gainOutcomes ?? [])
            outcomes += (report.tagOutcomes ?? []) + (report.artworkOutcomes ?? [])
        }
        let titles = Dictionary(outcomes.map { ($0.trackUUID, $0.title) }, uniquingKeysWith: { first, _ in first })
        let stagedTitles = Dictionary((ports.backups.stagedTracks(backup.url) ?? []).map { ($0.uuid, $0.title) }, uniquingKeysWith: { first, _ in first })
        let conflicts = restoreConflicts(backup), state = ports.library.state()
        return conflictTrackUUIDs(conflicts, merges: state.mergeDrafts)
            .map { uuid, conflicts in (state.rows[uuid]?.title ?? titles[uuid] ?? stagedTitles[uuid] ?? uuid, conflicts) }
            .sorted { UIStrings.standardOrder($0.0, $1.0) == .orderedAscending }
            .map { title, conflicts in "• \(title) — \(conflicts.map(\.label).joined(separator: "·"))" }
    }

    // MARK: - 되살리기

    /// 복원한 뒤: 백업의 초안(합치기·큐·그리드·게인·태그·그림)을 되살리고, 재생 목록 편집·추가 목록을 다시 쌓는다.
    /// - Parameter kept: 복원 전에 남기기로 정한 지금 초안(그 곡의 백업 초안은 되살리지 않는다)
    /// - Returns: 복원 결과와 나눠 알릴 경고(#175)
    func reviveDrafts(from backup: RekordboxWriteBackup, keeping kept: [RestoreDraftConflict]) async -> [String] {
        func keeps(_ kind: RestoreDraftConflict.Kind, _ uuid: String) -> Bool { kept.contains(RestoreDraftConflict(kind: kind, uuid: uuid)) }
        let saved = ports.backups.drafts(backup.url), files = ports.drafts
        if !saved.merges.isEmpty {
            let current = ports.library.state().mergeDrafts
            let keptIDs = Set(current.filter { keeps(.merge, $0.id) }.flatMap { $0.members.map(\.trackUUID) })
            let revived = saved.merges.filter { Set($0.members.map(\.trackUUID)).isDisjoint(with: keptIDs) }
            let restoredIDs = Set(revived.flatMap { $0.members.map(\.trackUUID) })
            replaceMergeDrafts(current.filter { Set($0.members.map(\.trackUUID)).isDisjoint(with: restoredIDs) } + revived)
        }
        for draft in saved.cues where !keeps(.cue, draft.trackUUID) { files.saveCue(draft) }
        for grid in saved.grids where !keeps(.grid, grid.trackUUID) { files.saveGrid(grid) }
        for (uuid, gain) in saved.gains where !keeps(.gain, uuid) { files.saveGain(gain, trackUUID: uuid) }
        let tags = saved.tags.filter { !keeps(.tag, $0.trackUUID) }
        if !tags.isEmpty { replaceTagDrafts(tags) }
        // 그림 초안·사본도 되살리고, 옛 그림으로 돌아온 곡(되살린 초안·그 백업이 그림을 쓴 곡)은 목록·덱이 새로 읽게 한다.
        var artworks: [String: ArtworkDraft] = [:], artworkFailed = 0
        for edit in saved.artworks where !keeps(.artwork, edit.trackUUID) {
            do { try files.saveArtwork(edit) } catch { artworkFailed += 1; continue }
            artworks[edit.trackUUID] = edit.draft
        }
        let touched = (backup.report?.artworkWritten ?? []).map(\.trackUUID)
        apply(.artworkRestored(artworks, touched: touched))
        let artworkWarning = artworkFailed == 0 ? nil : Self.artworkRestoreFailureText(artworkFailed)
        let revivedUUIDs = Set(saved.cues.map(\.trackUUID)).union(saved.grids.map(\.trackUUID)).union(saved.gains.keys)
        let saveWarning = draftSaveWarning(for: revivedUUIDs, restoring: true)
        let keptWarning = kept.isEmpty ? nil : Self.keptDraftsText(conflictTrackUUIDs(kept, merges: ports.library.state().mergeDrafts).count)
        stage(WriteStage(String(ui: "복원한 라이브러리를 읽는 중…")))
        // 재생 목록 편집은 되돌린 rekordbox 상태에 다시 쌓는다. 다시 읽지 못하면 옛 목록 상태에 쌓지 않고 다음 읽기 뒤에 쌓는다.
        let reloaded = await ports.reload.reload(revivedUUIDs.union(saved.tags.map(\.trackUUID)).union(artworks.keys).union(touched),
                                                 saved.playlistEdits)
        let restaged = restoreStaged(from: backup)
        apply(.lastWriteBackup(nil))
        return finishFollowUp([saveWarning, artworkWarning, keptWarning,
                               Self.keptNewTrackDraftsText(restaged.keptDrafts, kinds: restaged.keptKinds)],
                              reloaded: reloaded, restoring: true)
    }

    struct RestoredStaged {
        /// 추가 목록에 다시 넣은 곡 수
        var restaged = 0
        /// 되돌린 새 곡에 남아 있던 태그·큐·그리드 초안 가운데 지우지 않고 연결 안 된 초안으로 남긴 곡 수.
        /// 사용자가 넣은 뒤 만든 초안이거나, 넣을 때 옮긴 사본인지 가릴 수 없는 초안이다.
        var keptDrafts = 0
        /// 남긴 초안의 종류(곡 수 알림 문구에 쓴다)
        var keptKinds: [AddedTrackDrafts.Kind] = []
    }

    /// 곡 추가를 되돌렸으면 그 곡들을 추가 목록에 다시 넣고, 새 곡으로 옮겼던 초안을 지운다.
    /// 새 곡에 남은 태그·큐·그리드 초안은 넣을 때 옮긴 사본이라고 확인될 때만 지운다(`AddedTrackDrafts.kept`). 나머지는 사용자가 넣은 뒤
    /// 만든 초안일 수 있어 지우지 않고 연결 안 된 초안으로 남기며(쓰기 대기 목록에서 버릴 수 있다, #197·#202) 결과가 알린다.
    @discardableResult
    func restoreStaged(from backup: RekordboxWriteBackup) -> RestoredStaged {
        let contentIDs = Set(backup.trackReport?.added.filter(\.written).compactMap(\.contentID) ?? [])
        if !contentIDs.isEmpty {
            let state = ports.library.state()
            apply(.playlistImportsReset(playlistEdits.resetImports(contentIDs: contentIDs, draft: state.playlistDraft,
                                                                   rekordbox: state.rekordboxPlaylists, imports: state.playlistImports,
                                                                   importsLoadFailed: state.playlistImportsLoadFailed)))
        }
        let files = ports.drafts
        files.flush()
        let outcomes = backup.trackReport?.added.filter { $0.written && $0.uuid != nil } ?? []
        let added = Set(outcomes.compactMap(\.uuid))
        let tracks = ports.backups.stagedTracks(backup.url)
        // 넣을 때 새 곡으로 옮긴 사본과 견줄 기준: 백업에 남은 추가한 곡의 큐·그리드 초안
        let saved = ports.backups.drafts(backup.url)
        let savedCues = Dictionary(saved.cues.map { ($0.trackUUID, $0) }, uniquingKeysWith: { first, _ in first })
        let savedGrids = Dictionary(saved.grids.map { ($0.trackUUID, $0) }, uniquingKeysWith: { first, _ in first })
        let state = ports.library.state()
        var result = RestoredStaged()
        var cleared: [TagDraft] = []
        var keptKinds: Set<AddedTrackDrafts.Kind> = []
        for outcome in outcomes {
            guard let uuid = outcome.uuid else { continue }
            let stagedUUID = tracks?.first { URL(filePath: $0.path).path.precomposedStringWithCanonicalMapping == outcome.path }?.uuid
            // 저장 실패로 저장 큐에 남은 기록까지 같이 비우려고 파일을 직접 지우지 않는다(#172). 저장 못 한 입력이 있으면 그것이 최신이다.
            let leftover = AddedTrackDrafts.Leftover(cue: files.pendingCue(uuid) ?? files.cueDraft(uuid),
                                                     grid: files.pendingGrid(uuid) ?? files.gridDraft(uuid),
                                                     tag: state.tagDrafts[uuid])
            let kept = AddedTrackDrafts.kept(after: outcome, leftover: leftover, stagedCue: stagedUUID.flatMap { savedCues[$0] },
                                             stagedGrid: stagedUUID.flatMap { savedGrids[$0] },
                                             stagedKey: stagedUUID.flatMap { AddedTrackDrafts.confirmedKey(state.tagDrafts[$0]) })
            if !kept.contains(.cue) {
                files.removeCue(uuid)
                apply(.draftsCleared(.cue, [uuid], cueCounts: false))
            }
            if !kept.contains(.grid) {
                files.removeGrid(uuid)
                apply(.draftsCleared(.grid, [uuid], cueCounts: false))
            }
            if leftover.tag != nil, !kept.contains(.tag) { cleared.append(TagDraft(trackUUID: uuid, base: TagFields())) }
            if !kept.isEmpty { result.keptDrafts += 1 }
            keptKinds.formUnion(kept)
        }
        result.keptKinds = AddedTrackDrafts.Kind.allCases.filter(keptKinds.contains)
        if !cleared.isEmpty { replaceTagDrafts(cleared) }
        if !added.isEmpty, let warning = draftSaveWarning(for: added, restoring: true) { apply(.libraryError(warning)) }
        if let tracks {
            let known = Set(ports.library.state().staged.map(\.uuid))
            let fresh = tracks.filter { !known.contains($0.uuid) }
            result.restaged = fresh.count
            if !fresh.isEmpty { apply(.restaged(fresh)) }
        }
        // 되돌린 곡을 추가 목록에 다시 넣었으니 그 곡의 초안은 더는 연결 안 된 초안이 아니고, 남긴 새 곡 초안은 연결 안 된 초안이다.
        apply(.unlinkedDraftsChanged)
        return result
    }

    // MARK: - 시점 스냅샷

    /// 시점 스냅샷 복원(#225). 대상은 쓰기와 같은 곳이다(#182). 쓰기 잠금 안에서 복원하고 다시 읽는다(덱에 올린 곡도 되돌린 큐·그리드를 읽게).
    /// 초안은 건드리지 않는다: 초안의 `base`가 복원한 rekordbox와 맞지 않는 곡은 쓸 때 걸러진다.
    /// - Parameters:
    ///   - snapshots: 시점 스냅샷 폴더
    ///   - autoDays: 자동 스냅샷 보관 일수(설정)
    ///   - changedTracks: 복원하면 바뀌는 곡(다시 읽은 뒤 덱에 알린다)
    @discardableResult
    public func restorePointSnapshot(_ entry: URL, snapshots: URL, autoDays: Int, now: Date, changedTracks: Set<String>,
                                     to target: RekordboxWriteTarget) async throws -> RekordboxPointRestoreReport {
        lock(true)
        defer { lock(false) }
        stage(WriteStage(String(ui: "시점 스냅샷으로 복원하는 중…")))
        defer { stage(nil) }
        let gate = ports.gate
        let report = try await BlockingWork.run { try gate.restorePointSnapshot(entry, target, snapshots, autoDays, now) }
        stage(WriteStage(String(ui: "복원한 라이브러리를 읽는 중…")))
        _ = await ports.reload.reload(changedTracks, [])
        apply(.writeBackupsChanged)
        return report
    }

    // MARK: - iTunes 동기화

    /// iTunes 동기화 선택을 rekordbox 라이브러리에 쓴다. 대상은 명시한 사본으로 열었으면 그 사본, 아니면 라이브(위치 값이 정한다).
    /// 다른 쓰기만 막고 덱은 잠그지 않는다(동기화는 덱 초안을 건드리지 않는다: 실행 취소 이력·재생 유지).
    /// - Parameter database: 화면이 연 사본(읽기 출처)
    /// - Returns: 쓴 DB와 rekordbox가 맞춘 동기화 파일
    public func syncITunes(_ change: ITunesSyncWrite, opened database: URL) async throws -> (target: URL, syncData: Data) {
        let target = RekordboxWriteTarget(database: location.iTunesSyncTarget(opened: database), shareRoot: nil, backups: location.backupDirectory)
        ports.lock.set(true, false)
        defer { ports.lock.set(false, false) }
        let gate = ports.gate
        let data = try await BlockingWork.run { try gate.syncITunes(change, target) }
        return (target.database, data)
    }
}
