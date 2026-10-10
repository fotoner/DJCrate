import DJCApplication
import DJCDomain
import Foundation
import RekordboxKit

extension RekordboxWriteGate {
    /// 실제 쓰기 관문. `writeGuard`는 시험이 시점 스냅샷 복원의 라이브 판정을 바꿀 때만 준다.
    public static func live(guard writeGuard: RekordboxWriteGuard = .system) -> Self {
        Self(
            write: { batch, inputs, target, dryRun in
                try RekordboxWriter.write(drafts: batch.drafts, grids: batch.grids, gains: batch.gains, tags: batch.tags, artworks: batch.artworks,
                                          analysisInputs: inputs, playlistDraft: batch.playlists, merges: batch.merges,
                                          histories: batch.histories, to: target.database, dryRun: dryRun, backups: target.backups, shareRoot: target.shareRoot,
                                          guard: writeGuard)
            },
            preview: { batch, inputs, source, copied in
                try await WritePreviewSnapshot.withCopy(from: source.database, shareRoot: source.shareRoot ?? RekordboxShare.directory,
                                                        grids: batch.grids, merges: batch.merges,
                                                        artworks: batch.artworks.map(\.trackUUID)) { snapshot, share in
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
                                             shareRoot: target.shareRoot, dryRun: dryRun, backups: target.backups, guard: writeGuard)
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
    }
}
