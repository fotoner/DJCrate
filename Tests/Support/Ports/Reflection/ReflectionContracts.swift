import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 쓰기 전 백업 폴더 이름(곡 넣기 백업)
public let backupContractName = "2026-10-09T120000-write"

/// 쓰기 전 백업 폴더(`RekordboxBackups`): 곡 넣기가 백업에 남긴 추가 목록·초안은 같은 백업에서 복원이 되살리는 모양으로 다시 읽힌다(#202).
/// 폴더 판정은 비어 있으면 0·nil이다. `folder` 안의 `backupContractName` 백업 폴더는 부르는 쪽이 만든다(실제는 쓰기 관문이 만든다).
public func backupsContract(_ backups: RekordboxBackups, folder: URL) throws {
    let backup = folder.appending(path: backupContractName)
    #expect(backups.stagedTracks(backup) == nil, "옛 백업(추가 목록 없음)")
    let staged = [StagedTrack(uuid: "s1", path: "/music/s1.mp3", title: "곡 s1", duration: 180, addedOn: "2026-10-09")]
    try backups.saveStagedTracks(staged, backup)
    #expect(backups.stagedTracks(backup) == staged)
    var cue = CueDraft(trackUUID: "s1")
    cue.place(EditableCue(kind: .hot(0), time: 4))
    let grid = GridDraft(trackUUID: "s1", base: [], segments: [GridSegment(start: 0.1, bpm: 128, firstBeatNumber: 1)])
    var tag = TagDraft(trackUUID: "s1", base: TagFields())
    tag.fields.musicalKey = "8A"
    try backups.saveDraft(.cue(cue), backup)
    try backups.saveDraft(.grid(grid), backup)
    try backups.saveDraft(.tag(tag), backup)
    let saved = backups.drafts(backup)
    #expect(saved.cues == [cue] && saved.grids == [grid] && saved.tags == [tag])
    #expect(saved.gains.isEmpty && saved.artworks.isEmpty && saved.merges.isEmpty && saved.playlistEdits.isEmpty)
    #expect(backups.laterCount(backup, folder) == 0 && backups.pointRestoreRefusal(backup, folder) == nil)
    #expect(backups.canWrite(folder.appending(path: "아직/없는/폴더")), "없는 폴더는 가장 가까운 있는 상위 폴더로 본다")
}

/// 백업에 남기지 못하는 백업 폴더: 추가 목록·초안 남기기가 던진다(세션은 그때 쓰지 않는다)
public func backupsSaveFailureContract(_ backups: RekordboxBackups, backup: URL) {
    #expect(throws: (any Error).self) { try backups.saveStagedTracks([], backup) }
    #expect(throws: (any Error).self) { try backups.saveDraft(.cue(CueDraft(trackUUID: "s1")), backup) }
}

/// 쓰기 관문(`RekordboxWriteGate`): 미리 보기는 사본을 만든 뒤 `copied`를 한 번 부르고 시험 결과를 돌려준다. 쓰기·넣기·빼기·재생 목록 쓰기는
/// `dryRun`을 결과에 적는다. 쓰면 대상의 백업 폴더에 백업을 남기고, 그 백업으로 복원하면 되돌리기 직전 상태를 같은 폴더에 남긴다.
public func writeGateContract(_ gate: RekordboxWriteGate, target: RekordboxWriteTarget, batch: DraftWriteBatch) async throws {
    let copied = Mutex(0)
    let preview = try await gate.preview(batch, [:], target) { copied.withLock { $0 += 1 } }
    #expect(copied.withLock { $0 } == 1 && preview.dryRun)
    #expect(try gate.write(batch, [:], target, true).dryRun)
    let written = try gate.write(batch, [:], target, false)
    let backup = URL(filePath: try #require(written.backup))
    #expect(!written.dryRun && samePath(backup.deletingLastPathComponent(), target.backups))
    let saved = try gate.restore(backup, target)
    #expect(samePath(saved.deletingLastPathComponent(), target.backups))
    #expect(try gate.addTracks(TrackAddBatch(plans: []), target, true).dryRun)
    #expect(try gate.deleteTracks([], target, true).dryRun)
    let edit = PlaylistEdit.create(key: "n", name: "새 목록", isFolder: false, parent: .root)
    #expect(try gate.writePlaylists([edit], target, true).dryRun)
}

/// 반영 XML 계획 묶음 저장(`ReflectionBatchStore`): 남긴 것을 그대로 읽고, nil을 남기면 지운다.
public func reflectionBatchStoreContract(_ store: ReflectionBatchStore) throws {
    #expect(store.load() == nil)
    let track = Track(id: "1", uuid: "u1", title: "곡", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil, releaseYear: nil,
                      trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180, folderPath: "/music/1.mp3", comment: "", importedOn: nil,
                      analysisDataPath: nil, imagePath: nil, isDeleted: false)
    let plan = ReflectionXMLPlan(trackID: "1", uuid: "u1", path: "/music/1.mp3", title: "곡",
                                 marks: [ReflectionXMLMark(name: "", type: 0, start: 4, end: nil, num: -1)],
                                 tempos: nil, blockers: [], cueChanged: true, gridChanged: false, before: ReflectionXMLMetadata(track), beforeMarks: [])
    let batch = ReflectionXMLBatch(createdAt: "2026-10-09 12:00:00", xmlPath: "/tmp/x.xml", plans: [plan],
                                   checks: ["1": ReflectionXMLCheck(result: .notYet, problems: [])])
    try store.save(batch)
    #expect(store.load() == batch)
    try store.save(nil)
    #expect(store.load() == nil)
}

/// 시점 스냅샷 파일(`PointSnapshotFiles`): 만든 것은 목록 맨 위(최근 것부터)이고 폴더 이름(ID)이나 겹치지 않는 이름으로 찾는다.
/// 고정한 것은 지우지 않고, 스냅샷 폴더 밖의 항목은 고치지도 지우지도 않는다. `database`는 뜰 수 있는 사본, `directory`는 빈 스냅샷 폴더
public func pointSnapshotFilesContract(_ files: PointSnapshotFiles, database: URL, shareRoot: URL?, directory: URL, now: Date) throws {
    #expect(files.list(directory).isEmpty && files.find("정리 전", directory) == nil)
    let first = try files.create("정리 전", database, shareRoot, directory, 7, now)
    #expect(first.metadata.name == "정리 전" && first.metadata.kind == .manual && !first.metadata.pinned)
    #expect(files.find(first.id, directory)?.id == first.id && files.find("정리 전", directory)?.id == first.id)
    #expect(files.find("없음", directory) == nil)
    // 이름이 겹치면 이름으로는 찾지 않는다(폴더 이름으로만)
    let second = try files.create("정리 전", database, shareRoot, directory, 7, now.addingTimeInterval(60))
    #expect(files.list(directory).map(\.id) == [second.id, first.id])
    #expect(files.find("정리 전", directory) == nil && files.find(second.id, directory)?.id == second.id)
    try files.setPinned(true, first.url, directory)
    #expect(files.find(first.id, directory)?.metadata.pinned == true)
    #expect(throws: (any Error).self) { try files.delete(first.url, directory) }
    try files.setPinned(false, first.url, directory)
    try files.delete(first.url, directory)
    let outside = directory.deletingLastPathComponent().appending(path: "스냅샷-폴더-밖")
    #expect(throws: (any Error).self) { try files.delete(outside, directory) }
    #expect(throws: (any Error).self) { try files.setPinned(true, outside, directory) }
    #expect(files.list(directory).map(\.id) == [second.id])
}
