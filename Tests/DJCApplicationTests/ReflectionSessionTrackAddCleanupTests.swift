import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 곡 넣기 뒤 정리(R22, `finishAdd`)와 CLI 쓰기 전 정리: 넣기에 쓴 판만 지우고, 넣는 동안 생긴 새 판은 새 곡의 제안으로 옮긴다.
/// 옮긴 초안은 넣기로 쓴 값을 기준으로 삼고 쓴 값에서 새 판으로 바뀐 것만 얹는다. 막힌 칸은 새 판의 값을 그대로 옮긴다.
/// 정상 흐름과 정리 전에 멈춘 뒤의 재시작 정리가 같은 미정리 목록(곡 넣기 몫)으로 같은 결과를 낸다.
@MainActor
@Suite("반영 세션: 곡 넣기 정리")
struct ReflectionSessionTrackAddCleanupTests {
    let h = ReflectionHarness()
    typealias H = ReflectionHarness

    static let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let cueA = EditableCue(id: idA, kind: .hot(0), time: 12)
    static let cueB = EditableCue(id: idB, kind: .hot(1), time: 30)

    /// 넣기로 쓴 핫큐 A가 든 새 곡(넣은 뒤 다시 읽은 목록의 곡 행)
    func readBackNewTrack() {
        h.state.rows["new-s"] = TrackRow(track: H.row("new-s").track,
                                         cues: [Cue(id: "c-a", contentID: "new-s", kind: 1, inMsec: 12_000, name: "", colorTableIndex: nil)],
                                         playCount: 0)
    }

    /// 추가 목록 곡 s(핫큐 A 초안)를 넣는다. 넣기는 큐를 쓴다
    func stageWithCue() -> StagedTrack {
        let track = H.staged("s")
        h.state.staged = [track]
        var draft = CueDraft(trackUUID: "s")
        draft.place(Self.cueA)
        h.memory.save(draft)
        h.script.addPreview.added = [H.track(track.path)]
        var outcome = H.track(track.path, uuid: "new-s")
        outcome.cuesWritten = 1
        var report = RekordboxTrackWriteReport(dryRun: false)
        report.added = [outcome]
        report.backup = "/backups/add-1"
        h.script.add = report
        return track
    }

    /// 새 곡의 큐 초안이 넣기로 쓴 큐 A(rekordbox 행) 위에 B만 더한 제안인지
    func expectMovedCueSuggestion(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let moved = try #require(h.memory.cue("new-s"), sourceLocation: sourceLocation)
        #expect(moved.base.map(\.sourceID) == ["c-a"], "기준은 넣기로 쓴 새 곡의 큐다", sourceLocation: sourceLocation)
        #expect(moved.changes == [.added(Self.cueB)], "⌘S는 A를 다시 넣지 않고 B만 더한다", sourceLocation: sourceLocation)
        #expect(h.session.ports.drafts.suggestion(DraftKey(.cue, "new-s")) != nil, "자동 저장하지 않는 제안이다", sourceLocation: sourceLocation)
        #expect(h.memory.stamp(DraftKey(.cue, "new-s"))?.origins.contains(.cli) == true, "출처가 남는다", sourceLocation: sourceLocation)
        #expect(h.memory.cue("s") == nil, "옛 UUID에는 남기지 않는다", sourceLocation: sourceLocation)
    }

    @Test func 넣는_동안_CLI가_더한_큐는_넣은_뒤_새_곡에_쓴_큐_위의_제안으로_남는다() async throws {
        let track = stageWithCue()
        var later = CueDraft(trackUUID: "s")
        later.place(Self.cueA)
        later.place(Self.cueB)
        let snapshot = later
        h.script.duringAdd = { [memory = h.memory] in memory.save(snapshot, origin: .cli) }
        readBackNewTrack()
        let outcome = await h.session.addTracks(rows: [H.row("djc-s", path: track.path)])
        guard case .added = outcome else { Issue.record("넣었다: \(outcome)"); return }
        try expectMovedCueSuggestion()
        #expect(h.gateCalls.value.removedCleanupLists.count == 1, "정리를 마치고 목록을 지운다")
    }

    @Test func 정리_전에_멈춘_곡_넣기는_재시작_정리가_같은_결과를_낸다() async throws {
        // 넣기는 핫큐 A를 썼고, 그동안 CLI가 B를 더한 새 판을 남겼다. 정리 전에 멈춰 미정리 목록만 남았다
        var written = CueDraft(trackUUID: "s")
        written.place(Self.cueA)
        h.memory.save(written)
        let stamp = try #require(h.memory.stamp(DraftKey(.cue, "s")))
        var later = written
        later.place(Self.cueB)
        h.memory.save(later, origin: .cli)
        let add = DraftCleanupList.TrackAdd(stagedUUID: "s", trackUUID: "new-s",
                                            written: [WrittenDraft(key: DraftKey(.cue, "s"), revision: stamp.revision, contentHash: try DraftContentHash(of: written))],
                                            values: .init(cues: [Self.cueA]), blockedFields: [])
        h.script.cleanupLists = [DraftCleanupList(operationID: "op-add", target: MemoryWriteLocks.key(for: h.session.target.database),
                                                  draftHome: "/drafts", backupFolder: "add-1", trackAdds: [add])]
        readBackNewTrack()
        let resumed = await h.session.resumeCleanups()
        #expect(resumed.holds.isEmpty && resumed.finished == 1)
        try expectMovedCueSuggestion()
    }

    @Test func 키가_막힌_넣기_동안_제목이_바뀌면_새_곡에_새_제목과_키가_함께_제안으로_남는다() async throws {
        let track = H.staged("s")
        h.state.staged = [track]
        var tag = TagDraft(trackUUID: "s", base: TagFields())
        tag.fields.title = "처음 제목"
        tag.fields.musicalKey = "8A"
        h.memory.save(tag)
        h.state.tagDrafts["s"] = tag
        h.script.addPreview.added = [H.track(track.path)]
        var written = TagFields()
        written.title = "처음 제목"
        var outcome = H.track(track.path, uuid: "new-s")
        outcome.keyReason = "키를 쓰지 못했습니다"
        outcome.keyBase = written
        var report = RekordboxTrackWriteReport(dryRun: false)
        report.added = [outcome]
        report.backup = "/backups/add-1"
        h.script.add = report
        var later = tag
        later.fields.title = "새 제목"
        let snapshot = later
        h.script.duringAdd = { [memory = h.memory] in memory.save(snapshot, origin: .cli) }
        let result = await h.session.addTracks(rows: [H.row("djc-s", path: track.path)])
        guard case .added = result else { Issue.record("넣었다: \(result)"); return }
        let moved = try #require(h.memory.tag("new-s"))
        #expect(moved.base.title == "처음 제목" && moved.base.musicalKey.isEmpty, "기준은 넣기로 쓴 값이다(키는 막혀 쓰지 않았다)")
        #expect(moved.fields.title == "새 제목" && moved.fields.musicalKey == "8A")
        #expect(Set(moved.changedKeys) == [.title, .musicalKey])
        #expect(h.session.ports.drafts.suggestion(DraftKey(.tag, "new-s")) != nil)
        #expect(h.memory.tag("s") == nil)
    }

    @Test func 넣기에_쓴_판_그대로면_재시작_정리는_지우기만_한다() async throws {
        var written = CueDraft(trackUUID: "s")
        written.place(Self.cueA)
        h.memory.save(written)
        let stamp = try #require(h.memory.stamp(DraftKey(.cue, "s")))
        let add = DraftCleanupList.TrackAdd(stagedUUID: "s", trackUUID: "new-s",
                                            written: [WrittenDraft(key: DraftKey(.cue, "s"), revision: stamp.revision, contentHash: try DraftContentHash(of: written))],
                                            values: .init(cues: [Self.cueA]), blockedFields: [])
        h.script.cleanupLists = [DraftCleanupList(operationID: "op-add", target: MemoryWriteLocks.key(for: h.session.target.database),
                                                  draftHome: "/drafts", backupFolder: "add-1", trackAdds: [add])]
        readBackNewTrack()
        let resumed = await h.session.resumeCleanups()
        #expect(resumed.holds.isEmpty && h.memory.cue("s") == nil && h.memory.cue("new-s") == nil)
    }

    // MARK: - CLI 쓰기 전 정리

    @Test func CLI_쓰기는_그_대상의_미정리_목록을_먼저_정리한다() async throws {
        h.options = .cli(attachesAnalysis: false, writesArtwork: false)
        var written = CueDraft(trackUUID: "a")
        written.place(Self.cueA)
        h.memory.save(written)
        let stamp = try #require(h.memory.stamp(DraftKey(.cue, "a")))
        h.script.cleanupLists = [DraftCleanupList(operationID: "op-1", target: MemoryWriteLocks.key(for: h.session.target.database),
                                                  draftHome: "/drafts", backupFolder: "w1",
                                                  written: [WrittenDraft(key: DraftKey(.cue, "a"), revision: stamp.revision,
                                                                         contentHash: try DraftContentHash(of: written))])]
        try await h.session.cleanUpBeforeWrite(to: h.session.target, lock: MemoryWriteLocks().port)
        #expect(h.memory.cue("a") == nil && h.gateCalls.value.removedCleanupLists == ["op-1"])
    }

    @Test func CLI_쓰기는_정리를_마치지_못하면_쓰지_않는다() async throws {
        h.options = .cli(attachesAnalysis: false, writesArtwork: false)
        var written = CueDraft(trackUUID: "a")
        written.place(Self.cueA)
        h.memory.save(written)
        let stamp = try #require(h.memory.stamp(DraftKey(.cue, "a")))
        h.script.cleanupLists = [DraftCleanupList(operationID: "op-1", target: MemoryWriteLocks.key(for: h.session.target.database),
                                                  draftHome: "/drafts", backupFolder: "w1",
                                                  written: [WrittenDraft(key: DraftKey(.cue, "a"), revision: stamp.revision,
                                                                         contentHash: try DraftContentHash(of: written))])]
        h.failingRemoveWritten = true
        await #expect(throws: DJCError.self) { try await h.session.cleanUpBeforeWrite(to: h.session.target, lock: MemoryWriteLocks().port) }
        #expect(h.gateCalls.value.removedCleanupLists.isEmpty)
    }
}
