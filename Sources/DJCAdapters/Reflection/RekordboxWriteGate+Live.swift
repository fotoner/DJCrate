import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

extension RekordboxWriteGate {
    /// 실제 쓰기 관문. `writeGuard`는 시험이 시점 스냅샷 복원의 라이브 판정·단계 훅·잠금 폴더를 바꿀 때만 준다.
    /// 입구는 스스로 쓰기 잠금(R9)을 잡고 쓰기 기록(R11)을 남긴다. 앱의 쓰기·곡 넣기는 묶음의 작업(`operation`)으로 기록에 초안의 판을 적고
    /// 라이브러리 변경을 마친 뒤 미정리 목록을 적는다(R22).
    public static func live(guard writeGuard: RekordboxWriteGuard = .system) -> Self {
        var gate = Self(
            write: { batch, inputs, target, dryRun in
                try RekordboxWriter.write(drafts: batch.drafts, grids: batch.grids, gains: batch.gains, tags: batch.tags, artworks: batch.artworks,
                                          analysisInputs: inputs, playlistDraft: batch.playlists, merges: batch.merges,
                                          histories: batch.histories, to: target.database, dryRun: dryRun, backups: target.backups, shareRoot: target.shareRoot,
                                          guard: writeGuard, record: dryRun ? nil : batch.draftRecord)
            },
            preview: { batch, inputs, source, copied in
                try await WritePreviewSnapshot.withCopy(from: source.database, shareRoot: source.shareRoot ?? RekordboxShare.directory,
                                                        grids: batch.grids, merges: batch.merges,
                                                        artworks: batch.artworks.map(\.trackUUID), guard: writeGuard) { snapshot, share in
                    await copied()
                    try Task.checkCancellation()
                    // 사본에 끝까지 써 보는 일은 오래 막는 DB 입출력이라 협력 풀 밖에서 한다(사본 뜨기도 풀 밖에서 작업 취소를 보며 한다)
                    return try await BlockingWork.run {
                        try RekordboxWriter.write(drafts: batch.drafts, grids: batch.grids, gains: batch.gains, tags: batch.tags,
                                                  artworks: batch.artworks, analysisInputs: inputs, playlistDraft: batch.playlists,
                                                  merges: batch.merges, histories: batch.histories, to: snapshot, dryRun: true,
                                                  backups: snapshot.deletingLastPathComponent().appending(path: "backups"), shareRoot: share,
                                                  guard: writeGuard)
                    }
                }
            },
            restore: { backup, target in
                try RekordboxWriter.restore(backup, to: target.database, backups: target.backups, guard: writeGuard, shareRoot: target.shareRoot)
            },
            addTracks: { batch, target, dryRun in
                try RekordboxTrackWriter.add(batch.plans, analyses: batch.analyses, cues: batch.cues, keys: batch.keys, to: target.database,
                                             shareRoot: target.shareRoot, dryRun: dryRun, backups: target.backups, guard: writeGuard,
                                             record: dryRun ? nil : batch.draftRecord)
            },
            deleteTracks: { ids, target, dryRun in
                try RekordboxTrackWriter.delete(contentIDs: ids, from: target.database, shareRoot: target.shareRoot, dryRun: dryRun,
                                                backups: target.backups, guard: writeGuard)
            },
            restorePointSnapshot: { entry, target, snapshots, autoDays, now in
                try RekordboxWriter.restore(pointSnapshot: entry, to: target.database, shareRoot: target.shareRoot, snapshots: snapshots,
                                            backups: target.backups, autoDays: autoDays, now: now, guard: writeGuard)
            },
            writePlaylists: { edits, target, dryRun in
                try RekordboxWriter.write(drafts: [], playlists: edits, to: target.database, dryRun: dryRun, backups: target.backups,
                                          shareRoot: target.shareRoot, guard: writeGuard)
            },
            syncITunes: { change, target in
                _ = try RekordboxWriter.write(drafts: [], iTunesSync: RekordboxITunesSyncChange(base: change.base, source: change.source,
                                                                                                 selection: change.selection),
                                              to: target.database, dryRun: false, backups: target.backups, guard: writeGuard)
                // rekordbox가 쓰기 뒤 맞춘 동기화 파일(선택 창이 다음에 열 때의 원문)
                return try Data(contentsOf: target.database.deletingLastPathComponent().appending(path: "playlists3.sync"))
            })
        gate.journal = { target, hold in
            if let hold, hold.key != (try RekordboxWriteLocks.key(target.database)) {
                throw DJCError.writeRefused(String(ui: "넘긴 쓰기 잠금이 이 라이브러리의 것이 아니라 쓰기 기록을 판정하지 않았습니다"))
            }
            guard let judgment = try RekordboxWriter.judgeJournal(database: target.database, backups: target.backups, locked: hold != nil,
                                                                 guard: writeGuard) else { return .inProgress }
            switch judgment {
            case .none: return .none
            case .undecided: return .inProgress
            case let .interrupted(journal, changedSince, database):
                return .interrupted(RekordboxJournalFinding(journal: journal, changedSince: changedSince, database: database))
            }
        }
        gate.restoreJournal = { target, request in
            switch try RekordboxWriter.restoreJournal(database: target.database, operationID: request.operationID, databaseStamp: request.database,
                                                      backups: target.backups, shareRoot: target.shareRoot, guard: writeGuard) {
            case .nothing: .nothing
            case .changed: .changed
            case let .done(.restored(backup)): .restored(backup: backup)
            case .done(.alreadyRestored): .alreadyRestored
            }
        }
        gate.keepJournal = { target, request, apply in
            switch try RekordboxWriter.keepJournal(database: target.database, operationID: request.operationID, databaseStamp: request.database,
                                                   backups: target.backups, shareRoot: target.shareRoot, guard: writeGuard, apply: apply) {
            case .nothing: .nothing
            case .changed: .changed
            case .done: .kept
            }
        }
        gate.cleanupLists = { target, draftHome in
            let key = try RekordboxWriteLocks.key(target.database)
            let home = draftHome.standardizedFileURL.path
            return try RekordboxWriter.cleanupLists(in: target.backups)
                .filter { $0.target == key && URL(filePath: $0.draftHome).standardizedFileURL.path == home }
        }
        gate.removeCleanupList = { list, target in
            try RekordboxWriter.removeCleanupList(operationID: list.operationID, in: target.backups)
        }
        return gate
    }
}

extension DraftWriteBatch {
    /// 앱 쓰기의 정리 할 일(R11·R22): 쓰기 기록에 이 묶음 초안의 판을 적고, 쓴 결과로 미정리 목록을 만든다. 작업이 없으면(CLI·시험) nil.
    /// 쓴 것은 지금의 쓴 뒤 정리(`finishWrite`)와 같다: 큐·그리드(분석 붙이기 포함)·게인·태그·그림·합치기의 쓴 결과,
    /// 재생 목록은 시도한 단계마다 결과(`playlistOutcomes`가 단계와 같은 차례), 새 목록의 연결 ID(`new:키` → 실제 목록 ID).
    var draftRecord: RekordboxDraftRecord<RekordboxWriteReport>? {
        guard let operation else { return nil }
        let revisions = revisions, steps = playlists?.steps ?? []
        let drafts = RekordboxWriteJournal.Drafts(home: operation.draftHome.path, written: revisions.written(revisions.tracks.keys),
                                                  playlistSteps: revisions.playlistSteps.map(\.revision))
        return RekordboxDraftRecord(operationID: operation.id, drafts: drafts) { report in
            let keys = report.written.map { DraftKey(.cue, $0.trackUUID) }
                + (report.gridWritten + report.analysisWritten).map { DraftKey(.grid, $0.trackUUID) }
                + report.gainWritten.map { DraftKey(.gain, $0.trackUUID) } + report.tagWritten.map { DraftKey(.tag, $0.trackUUID) }
                + report.artworkWritten.map { DraftKey(.artwork, $0.trackUUID) } + report.mergeWritten.map { DraftKey(.merge, $0.trackUUID) }
            let outcomes = report.playlistOutcomes ?? []
            var tried: [DraftCleanupList.PlaylistStep] = []
            for index in steps.indices where revisions.playlistSteps.indices.contains(index) {
                let entry = revisions.playlistSteps[index]
                let outcome: DraftCleanupList.StepOutcome = switch outcomes.indices.contains(index) ? outcomes[index].status : nil {
                case .written?: .written
                case .blocked?: .blocked(outcomes[index].reason ?? "")
                default: .notTried
                }
                tried.append(DraftCleanupList.PlaylistStep(revision: entry.revision, contentHash: entry.contentHash, outcome: outcome))
            }
            var newIDs: [String: String] = [:]
            for outcome in outcomes where outcome.status == .written {
                if case let .create(key, _, _, _) = outcome.edit, let id = outcome.playlistID { newIDs[PlaylistRef.new(key).description] = id }
            }
            // 대상 키·백업 폴더는 입구가 채운다
            return DraftCleanupList(operationID: operation.id, target: RekordboxWriteLockKey(device: 0, inode: 0), draftHome: operation.draftHome.path,
                                    backupFolder: "", written: revisions.written(Set(keys)), playlistSteps: tried, newPlaylistIDs: newIDs)
        }
    }
}

extension TrackAddBatch {
    /// 앱 곡 넣기의 정리 할 일(R11·R22): 넣기에 실은 초안의 판을 기록에 적고, 넣은 곡마다 옛·새 UUID, 넣기로 쓴 값과 그 판, 막힌 칸을 적는다
    var draftRecord: RekordboxDraftRecord<RekordboxTrackWriteReport>? {
        guard let operation else { return nil }
        let revisions = revisions, stagedUUIDs = stagedUUIDs, cues = cues, analyses = analyses
        let plans = Dictionary(plans.map { ($0.path, $0) }) { first, _ in first }
        let drafts = RekordboxWriteJournal.Drafts(home: operation.draftHome.path, written: revisions.written(revisions.tracks.keys))
        return RekordboxDraftRecord(operationID: operation.id, drafts: drafts) { report in
            let adds = report.added.filter(\.written).compactMap { outcome -> DraftCleanupList.TrackAdd? in
                guard let old = stagedUUIDs[outcome.path], let new = outcome.uuid else { return nil }
                var written: [DraftKey] = [], blocked: [String] = []
                var values = DraftCleanupList.TrackAddValues()
                if outcome.cuesWritten != nil {
                    written.append(DraftKey(.cue, old))
                    values.cues = cues[outcome.path]
                } else if outcome.cueReason != nil {
                    blocked.append("cues")
                }
                if let analysis = analyses[outcome.path] {
                    written.append(DraftKey(.grid, old))
                    values.grid = analysis.segments
                }
                // 태그 초안은 넣기 계획에 실려(제목·아티스트 등) 곡 행에 들어갔다. 키는 같은 쓰기에서 따로 쓰고, 막히면 그 칸만 막힌 칸이다
                if let plan = plans[outcome.path], revisions.tracks[DraftKey(.tag, old)] != nil || outcome.keyWritten != nil {
                    written.append(DraftKey(.tag, old))
                    var tags = TagFields()
                    tags.title = plan.title
                    tags.artist = plan.artist ?? ""
                    tags.album = plan.album ?? ""
                    tags.albumArtist = plan.albumArtist ?? ""
                    tags.genre = plan.genre ?? ""
                    tags.composer = plan.composer ?? ""
                    tags.year = plan.year > 0 ? String(plan.year) : ""
                    tags.trackNumber = plan.trackNumber > 0 ? String(plan.trackNumber) : ""
                    tags.comment = plan.comment
                    tags.musicalKey = outcome.keyWritten ?? ""
                    values.tags = tags
                }
                if let key = outcome.keyWritten {
                    values.musicalKey = key
                } else if outcome.keyReason != nil {
                    blocked.append(TagFields.Key.musicalKey.rawValue)
                }
                return DraftCleanupList.TrackAdd(stagedUUID: old, trackUUID: new, written: revisions.written(written), values: values,
                                                 blockedFields: blocked)
            }
            return DraftCleanupList(operationID: operation.id, target: RekordboxWriteLockKey(device: 0, inode: 0), draftHome: operation.draftHome.path,
                                    backupFolder: "", trackAdds: adds)
        }
    }
}
