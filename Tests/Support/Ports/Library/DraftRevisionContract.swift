import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 초안 저장소의 출처·판 계약(R5·R22): 저장마다 새 판(저장소 전체에서 겹치지 않음)과 그때의 해시를 적고, 출처를 모은다.
/// 판 지정 삭제는 판과 해시가 모두 같은 초안만 지우고, 판이 다르면 두고, 판이 같은데 지금 해시가 다르면 제안으로 남긴다.
/// 가짜(`MemoryDrafts`)는 DJCApplicationTests가, 실제 구현은 W1-B(#400)가 DJCAdaptersTests에서 같은 함수로 돌린다.
/// `editOutside`는 바깥(다른 프로세스)이 초안 파일 내용만 고치는 일을 흉내 낸다(도장은 그대로).
public func draftRevisionContract(_ human: DraftStore, cli: DraftStore, editOutside: (CueDraft) throws -> Void) throws {
    func cue(_ uuid: String, at time: Double) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.cues = [EditableCue(id: human.newCueID(), sourceID: nil, kind: .memory, time: time)]
        return draft
    }
    human.saveCue(cue("a", at: 1))
    human.flush()
    let first = try #require(human.stamp(DraftKey(.cue, "a")))
    let saved = try DraftContentHash(of: try #require(human.cueDraft("a")))
    #expect(first.origins == [.human] && first.contentHash == saved)
    human.saveCue(cue("b", at: 1))
    human.flush()
    let other = try #require(human.stamp(DraftKey(.cue, "b")))
    #expect(other.revision != first.revision)

    // 다시 저장하면 새 판, 다른 출처가 고치면 출처가 모인다(제안이 된다)
    cli.saveCue(cue("a", at: 2))
    cli.flush()
    let second = try #require(human.stamp(DraftKey(.cue, "a")))
    #expect(second.revision > first.revision && second.origins == [.human, .cli] && !second.isHumanOnly)

    // 판이 다르면(쓰는 동안 새로 저장) 지우지 않는다
    let stale = WrittenDraft(key: DraftKey(.cue, "a"), revision: first.revision, contentHash: first.contentHash)
    #expect(try human.removeWritten([stale]) == DraftRemoval(kept: [stale]))
    #expect(human.cueDraft("a") != nil)

    // 판과 해시가 같으면 지운다
    let written = WrittenDraft(key: DraftKey(.cue, "a"), revision: second.revision, contentHash: second.contentHash)
    #expect(try human.removeWritten([written]) == DraftRemoval(removed: [written]))
    human.flush()
    #expect(human.cueDraft("a") == nil && human.stamp(DraftKey(.cue, "a")) == nil)

    // 판이 같아도 지금 해시가 다르면(바깥에서 고침) 지우지 않고 제안으로 남긴다
    let stamp = try #require(human.stamp(DraftKey(.cue, "b")))
    let savedB = try #require(human.cueDraft("b"))
    try editOutside(cue("b", at: 9))
    let outside = WrittenDraft(key: DraftKey(.cue, "b"), revision: stamp.revision, contentHash: stamp.contentHash)
    #expect(try human.removeWritten([outside]) == DraftRemoval(suggested: [outside]))
    #expect(human.cueDraft("b") != nil)
    // 제안으로 남긴 초안은 새 판과 함께 그 상태가 기록된다(S11): 파일이 저장 당시(쓴) 내용으로 돌아와도 사람 편집만 든 도장이 아니고,
    // 같은 미정리 목록으로 정리를 다시 해도(다시 켠 뒤) 판이 달라 지우지 않는다
    try editOutside(savedB)
    let suggested = try #require(human.stamp(DraftKey(.cue, "b")))
    #expect(suggested.revision > stamp.revision && suggested.origins.contains(.unknown) && !suggested.isHumanOnly)
    #expect(try human.removeWritten([outside]) == DraftRemoval(kept: [outside]))
    #expect(human.cueDraft("b") != nil)

    // "이대로 둔다": 판이 같은 초안만 새 판을 주고 제안으로 바꾸며 지우지 않는다. 판이 다르면(쓰는 동안 새로 저장) 그대로다
    human.saveCue(cue("c", at: 1))
    human.flush()
    let c = try #require(human.stamp(DraftKey(.cue, "c")))
    #expect(c.isHumanOnly)
    let staleC = WrittenDraft(key: DraftKey(.cue, "c"), revision: DraftRevision(c.revision.value + 1000), contentHash: c.contentHash)
    #expect(try human.markSuggestions([staleC], []).isEmpty && (human.stamp(DraftKey(.cue, "c"))?.isHumanOnly == true))
    let writtenC = WrittenDraft(key: DraftKey(.cue, "c"), revision: c.revision, contentHash: c.contentHash)
    let marked = try human.markSuggestions([writtenC], [])
    let markedC = try #require(human.stamp(DraftKey(.cue, "c")))
    #expect(marked == [c.revision: markedC.revision] && markedC.revision > c.revision)
    #expect(human.cueDraft("c") != nil && markedC.origins == [.human, .unknown])
    // 제안으로 바꾼 뒤 미정리 목록을 지우기 전에 멈춰 같은 목록으로 다시 정리해도(파일은 쓴 내용 그대로) 초안이 남는다
    #expect(try human.removeWritten([writtenC]) == DraftRemoval(kept: [writtenC]))
    #expect(human.cueDraft("c") != nil)
}

/// 재생 목록 단계의 판 계약(R22): 단계마다 판과 `DraftContentHash(step:in:)` 해시를 적는다. 쓴 단계는 판으로 찾아 빼고,
/// 지금 해시가 쓴 해시와 다르면(바깥에서 고침) 실제 목록 ID와 함께 사본을 남긴 뒤에만 뺀다. 사본을 남기지 못하면 그 단계를 남긴다.
/// 막힌 단계(쓰지 않은 단계)는 남는다. 판을 모르는 단계는 `notFound`다.
/// `editOutside`는 바깥이 단계 수를 바꾸지 않고 초안 파일 내용만 고치는 일, `failCopies`는 사본 쓰기 실패를 흉내 낸다.
@MainActor
public func playlistStepRevisionContract(_ store: DraftStore, backups: URL, editOutside: (PlaylistDraft) throws -> Void,
                                         failCopies: (Bool) -> Void, readCopy: (URL) throws -> PlaylistStepCopy?) throws {
    // 사본은 그 쓰기의 백업 폴더(백업 루트 기준 상대 경로, 미정리 목록의 `backupFolder`)에 남는다(S5)
    let backupFolder = "2026-11-24_120000"
    let copyFolder = backups.appending(path: backupFolder, directoryHint: .isDirectory)
    let rekordbox = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가"), 1), (PlaylistLayout.Item(id: "B", name: "나"), 2),
                                    (PlaylistLayout.Item(id: "C", name: "다"), 3)])
    func draft(renameB: String) throws -> PlaylistDraft {
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["9"]), rekordbox: rekordbox)
        try draft.append(.rename(playlist: .id("B"), name: renameB), rekordbox: rekordbox)
        try draft.append(.addTracks(playlist: .id("C"), contentIDs: ["8"]), rekordbox: rekordbox)
        return draft
    }
    let saved = try draft(renameB: "x")
    try store.savePlaylistDraft(saved)
    let stamps = store.playlistStamps()
    #expect(stamps.count == 3 && Set(stamps.map(\.revision)).count == 3)
    for (stamp, step) in zip(stamps, saved.steps) { #expect(stamp.contentHash == (try DraftContentHash(step: step, in: saved))) }
    let written = stamps.prefix(2).map { WrittenPlaylistStep(revision: $0.revision, contentHash: $0.contentHash) }

    // 쓴 둘 가운데 둘째만 바깥에서 고쳤다: 둘 다 빼되 둘째는 사본(실제 목록 ID B)을 남긴다. 쓰지 않은 셋째는 남는다
    try editOutside(try draft(renameB: "y"))
    let stray = DraftRevision(stamps.map(\.revision.value).max()! + 100)
    let removal = try store.removeWrittenSteps(PlaylistStepCleanup(written: written + [WrittenPlaylistStep(revision: stray, contentHash: stamps[0].contentHash)],
                                                                   newPlaylistIDs: [:], backups: backups, backupFolder: backupFolder))
    #expect(removal.removed == Set(written.map(\.revision)) && removal.copyFailed.isEmpty && removal.notFound == [stray])
    let copyURL = try #require(removal.copied[written[1].revision])
    #expect(copyURL == PlaylistStepCopy.url(folder: copyFolder, revision: written[1].revision))
    let copy = try #require(try readCopy(copyURL))
    #expect(copy.playlistID == "B" && copy.writtenHash == written[1].contentHash && copy.currentHash != copy.writtenHash)
    #expect(store.playlistDraft().edits == [.addTracks(playlist: .id("C"), contentIDs: ["8"])])
    #expect(store.playlistStamps().map(\.revision) == [stamps[2].revision])

    // 사본을 남기지 못하면 바깥에서 고친 단계는 남는다
    try store.savePlaylistDraft(try draft(renameB: "x"))
    let again = store.playlistStamps()
    try editOutside(try draft(renameB: "z"))
    failCopies(true)
    defer { failCopies(false) }
    let failed = try store.removeWrittenSteps(PlaylistStepCleanup(written: [WrittenPlaylistStep(revision: again[1].revision, contentHash: again[1].contentHash)],
                                                                  newPlaylistIDs: [:], backups: backups, backupFolder: backupFolder))
    #expect(failed.copyFailed == [again[1].revision] && failed.removed.isEmpty)
    #expect(store.playlistDraft().edits.count == 3)

    // "이대로 둔다": 판이 같은 단계에 새 판을 주고 제안으로 바꾸며 빼지 않는다. 같은 미정리 목록으로 다시 정리해도 그 단계는 남는다
    let marked = try store.markSuggestions([], [again[0].revision])
    let first = try #require(store.playlistStamps().first)
    #expect(marked == [again[0].revision: first.revision] && first.revision != again[0].revision && first.origins.contains(.unknown))
    let rerun = try store.removeWrittenSteps(PlaylistStepCleanup(written: [WrittenPlaylistStep(revision: again[0].revision, contentHash: again[0].contentHash)],
                                                                 newPlaylistIDs: [:], backups: backups, backupFolder: backupFolder))
    #expect(rerun.notFound == [again[0].revision] && rerun.removed.isEmpty && store.playlistDraft().edits.count == 3)
}

/// 재생 목록 단계 식별자 계약(R5·R22, 리뷰 S1~S3): 도장은 단계에 저장한 식별자로 단계를 잇는다. 해시로 다시 붙이지 않는다.
/// - 같은 내용의 단계가 둘이어도(넣기 → 빼기 → 다시 넣기) 초안 저장과 도장 갱신 사이에 멈춘 뒤 재시작 정리가 마지막 단계를 지우지 않는다
/// - 기존 단계에 합쳐진 편집은 새 판을 받고 출처를 합친다
/// - 바깥에서 고친 단계를 덮어쓰면 출처에 모름이 섞인다
/// 가짜(`MemoryDrafts`)는 DJCApplicationTests가, 실제 구현은 DJCAdaptersTests가 같은 함수로 돌린다.
/// - Parameters:
///   - rawWrite: 도장을 갱신하지 않고 초안 파일만 쓴다(정리 도중 멈춤, 바깥 수정)
///   - restart: 같은 저장소를 다시 연 새 포트(앱을 다시 켠 뒤)
@MainActor
public func playlistStepIdentityContract(human: DraftStore, cli: DraftStore, rawWrite: (PlaylistDraft) throws -> Void,
                                         restart: () -> DraftStore, backups: URL) throws {
    let rekordbox = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가"), 1), (PlaylistLayout.Item(id: "B", name: "나"), 2)])
    let add = PlaylistEdit.addTracks(playlist: .id("A"), contentIDs: ["9"])
    let remove = PlaylistEdit.removeTracks(playlist: .id("A"), entries: [PlaylistEntry(trackNo: 1, contentID: "9")])
    func draft(_ edits: [PlaylistEdit]) throws -> PlaylistDraft {
        var draft = PlaylistDraft()
        for edit in edits { try draft.append(edit, rekordbox: rekordbox) }
        return draft
    }

    // S1: 같은 내용의 단계 둘 + 정리 도중 멈춤 + 재시작 정리
    try human.savePlaylistDraft(try draft([add, remove, add]))
    let stamps = human.playlistStamps()
    #expect(stamps.count == 3 && Set(stamps.map(\.revision)).count == 3 && stamps[0].contentHash == stamps[2].contentHash)
    let written = [WrittenPlaylistStep(revision: stamps[0].revision, contentHash: stamps[0].contentHash)]
    var remaining = human.playlistDraft()
    remaining.removeSteps(at: [0])
    try rawWrite(remaining)
    let restarted = restart()
    let result = try restarted.removeWrittenSteps(PlaylistStepCleanup(written: written, newPlaylistIDs: [:], backups: backups, backupFolder: "b"))
    #expect(result.removed.isEmpty && result.notFound == [written[0].revision])
    #expect(restarted.playlistDraft().edits == [remove, add])
    #expect(restarted.playlistStamps().map(\.revision) == [stamps[1].revision, stamps[2].revision])

    // 처음부터 다시: 초안을 비운다
    try rawWrite(PlaylistDraft())
    #expect(restarted.playlistStamps().isEmpty)

    // S2: CLI가 만든 새 목록의 이름을 앱에서 바꾸면(만들기 단계에 합쳐짐) 새 판과 합친 출처를 받는다
    try cli.savePlaylistDraft(try draft([.create(key: "k", name: "새 목록", isFolder: false, parent: .root)]))
    let created = human.playlistStamps()
    #expect(created.count == 1 && created[0].origins == [.cli])
    var loaded = human.playlistDraft()
    try loaded.append(.rename(playlist: .new("k"), name: "고침"), rekordbox: rekordbox)
    #expect(loaded.steps.count == 1)
    try human.savePlaylistDraft(loaded)
    let merged = human.playlistStamps()
    #expect(merged.count == 1 && merged[0].revision > created[0].revision && merged[0].origins == [.cli, .human])
    #expect(human.playlistSuggestions() == [.mixedOrigins])

    // S3: 바깥에서 고친 단계(식별자는 그대로, 도장은 옛것)를 앱이 덮어쓰면 그 단계는 모름이 섞인다
    try rawWrite(PlaylistDraft())
    try human.savePlaylistDraft(try draft([add]))
    var outside = try draft([.addTracks(playlist: .id("A"), contentIDs: ["7"])])
    outside.setStepIDs(human.playlistDraft().stepIDs)
    try rawWrite(outside)
    var more = outside
    try more.append(.rename(playlist: .id("B"), name: "새"), rekordbox: rekordbox)
    try human.savePlaylistDraft(more)
    let overwritten = human.playlistStamps()
    #expect(overwritten.count == 2 && overwritten[0].origins == [.human, .unknown] && overwritten[1].origins == [.human])
    #expect(human.playlistSuggestions() == [.unknownOrigin, nil])
}
