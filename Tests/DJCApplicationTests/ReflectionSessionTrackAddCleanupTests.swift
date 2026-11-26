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

    // MARK: - 2라운드

    /// 넣기가 쓴 판(written)과 막힌 칸·쓴 값으로 남은 곡 넣기 몫의 미정리 목록
    func trackAddList(written: [WrittenDraft], values: DraftCleanupList.TrackAddValues, blocked: [String] = []) {
        let add = DraftCleanupList.TrackAdd(stagedUUID: "s", trackUUID: "new-s", written: written, values: values, blockedFields: blocked)
        h.script.cleanupLists = [DraftCleanupList(operationID: "op-add", target: MemoryWriteLocks.key(for: h.session.target.database),
                                                  draftHome: "/drafts", backupFolder: "add-1", trackAdds: [add])]
    }

    /// 넣기는 핫큐 A를 썼고 CLI가 B를 더한 새 판을 남겼다
    func writtenCueThenLater() throws {
        var written = CueDraft(trackUUID: "s")
        written.place(Self.cueA)
        h.memory.save(written)
        let stamp = try #require(h.memory.stamp(DraftKey(.cue, "s")))
        var later = written
        later.place(Self.cueB)
        h.memory.save(later, origin: .cli)
        trackAddList(written: [WrittenDraft(key: DraftKey(.cue, "s"), revision: stamp.revision, contentHash: try DraftContentHash(of: written))],
                     values: .init(cues: [Self.cueA]))
        readBackNewTrack()
    }

    @Test func 새_곡에_옮긴_초안을_저장하지_못하면_옛_초안과_목록을_남긴다() async throws {
        try writtenCueThenLater()
        h.failingDraftSaves.insert("new-s")
        let resumed = await h.session.resumeCleanups()
        #expect(resumed.holds.contains(.cleanupPending) && h.gateCalls.value.removedCleanupLists.isEmpty)
        #expect(h.memory.cue("s")?.cues.count == 2, "옛 UUID의 새 판을 지우지 않는다")
    }

    @Test func 옮기는_동안_옛_UUID에_더_새_판이_생기면_목록을_남겨_다시_한다() async throws {
        try writtenCueThenLater()
        let memory = h.memory
        let once = LockedFlag()
        var newer = CueDraft(trackUUID: "s")
        newer.place(Self.cueA)
        newer.place(EditableCue(id: UUID(), kind: .hot(2), time: 45))
        let snapshot = newer
        h.onVariantCueSave = { draft in
            guard draft.trackUUID == "new-s", !once.value else { return }
            once.value = true
            memory.save(snapshot, origin: .cli)
        }
        let resumed = await h.session.resumeCleanups()
        #expect(resumed.finished == 0 && h.gateCalls.value.removedCleanupLists.isEmpty, "끝난 것으로 보지 않고 목록을 남긴다")
        #expect(h.memory.cue("s")?.cues.contains { $0.time == 45 } == true, "옛 UUID의 더 새 판은 지우지 않는다")
    }

    @Test func 태그를_원래_값으로_되돌린_칸도_새_곡의_제안으로_옮긴다() async throws {
        var base = TagFields()
        base.title = "A"
        var tag = TagDraft(trackUUID: "s", base: base)
        tag.fields.title = "B"
        h.memory.save(tag)
        let stamp = try #require(h.memory.stamp(DraftKey(.tag, "s")))
        // 넣는 동안 제목을 파일 값(A)으로 되돌리고 키를 골랐다
        var later = tag
        later.fields.title = "A"
        later.fields.musicalKey = "8A"
        h.memory.save(later, origin: .cli)
        var written = TagFields()
        written.title = "B"
        trackAddList(written: [WrittenDraft(key: DraftKey(.tag, "s"), revision: stamp.revision, contentHash: try DraftContentHash(of: tag))],
                     values: .init(tags: written))
        _ = await h.session.resumeCleanups()
        let moved = try #require(h.memory.tag("new-s"))
        #expect(moved.base.title == "B" && moved.fields.title == "A" && moved.fields.musicalKey == "8A")
    }

    @Test func 같은_시각의_큐가_여럿이라_대응이_모호하면_옮기지_않고_옛_초안을_남긴다() async throws {
        let m1 = EditableCue(id: UUID(), kind: .memory, time: 12), m2 = EditableCue(id: UUID(), kind: .memory, time: 12)
        var written = CueDraft(trackUUID: "s")
        written.place(m1)
        written.place(m2)
        h.memory.save(written)
        let stamp = try #require(h.memory.stamp(DraftKey(.cue, "s")))
        var later = written
        var edited = m2
        edited.time = 20
        later.place(edited)
        h.memory.save(later, origin: .cli)
        trackAddList(written: [WrittenDraft(key: DraftKey(.cue, "s"), revision: stamp.revision, contentHash: try DraftContentHash(of: written))],
                     values: .init(cues: [m1, m2]))
        h.state.rows["new-s"] = TrackRow(track: H.row("new-s").track, cues: [
            Cue(id: "c-1", contentID: "new-s", kind: 0, inMsec: 12_000, name: "", colorTableIndex: nil),
            Cue(id: "c-2", contentID: "new-s", kind: 0, inMsec: 12_000, name: "", colorTableIndex: nil),
        ], playCount: 0)
        let resumed = await h.session.resumeCleanups()
        #expect(resumed.finished == 1)
        #expect(h.memory.cue("new-s") == nil && h.memory.cue("s") != nil, "다른 큐를 고치지 않게 옛 초안을 연결 안 된 초안으로 남긴다")
    }

    @Test func 키가_막힌_태그_초안은_재시작_정리가_막힌_키를_새_곡에_옮긴_뒤_지운다() async throws {
        var tag = TagDraft(trackUUID: "s", base: TagFields())
        tag.fields.title = "제목"
        tag.fields.musicalKey = "8A"
        h.memory.save(tag)
        let stamp = try #require(h.memory.stamp(DraftKey(.tag, "s")))
        var written = TagFields()
        written.title = "제목"
        trackAddList(written: [WrittenDraft(key: DraftKey(.tag, "s"), revision: stamp.revision, contentHash: try DraftContentHash(of: tag))],
                     values: .init(tags: written), blocked: [TagFields.Key.musicalKey.rawValue])
        _ = await h.session.resumeCleanups()
        #expect(h.memory.tag("new-s")?.fields.musicalKey == "8A", "막힌 키는 새 곡의 쓰기 대기로 옮긴다")
        #expect(h.memory.tag("s") == nil)
    }

    @Test func 새_곡에_같은_종류_초안이_이미_있으면_덮지_않고_옛_초안을_남긴다() async throws {
        try writtenCueThenLater()
        // 다시 읽은 뒤 사용자가 새 곡에 핫큐 C를 찍었다
        var user = CueDraft(trackUUID: "new-s")
        user.place(EditableCue(id: UUID(), kind: .hot(2), time: 60))
        h.memory.save(user)
        let resumed = await h.session.resumeCleanups()
        #expect(resumed.finished == 1)
        #expect(h.memory.cue("new-s") == user && h.memory.cue("s") != nil)
    }

    @Test func 초안_없이_넣는_동안_CLI가_저장한_큐는_새_곡의_제안으로_옮긴다() async throws {
        let track = H.staged("s")
        h.state.staged = [track]
        h.script.addPreview.added = [H.track(track.path)]
        var report = RekordboxTrackWriteReport(dryRun: false)
        report.added = [H.track(track.path, uuid: "new-s")]
        report.backup = "/backups/add-1"
        h.script.add = report
        var later = CueDraft(trackUUID: "s")
        later.place(Self.cueB)
        let snapshot = later
        h.script.duringAdd = { [memory = h.memory] in memory.save(snapshot, origin: .cli) }
        let outcome = await h.session.addTracks(rows: [H.row("djc-s", path: track.path)])
        guard case .added = outcome else { Issue.record("넣었다: \(outcome)"); return }
        #expect(h.memory.cue("new-s")?.cues.map(\.id) == [Self.idB])
        #expect(h.session.ports.drafts.suggestion(DraftKey(.cue, "new-s")) != nil, "사람 편집으로 옮기지 않는다")
    }

    @Test func 넣기_판은_미리_볼_때_읽은_초안의_것이다() async throws {
        let track = H.staged("s")
        h.state.staged = [track]
        var first = CueDraft(trackUUID: "s")
        first.place(Self.cueA)
        h.memory.save(first)
        h.script.addPreview.added = [H.track(track.path)]
        var outcome = H.track(track.path, uuid: "new-s")
        outcome.cuesWritten = nil
        outcome.cueReason = "큐를 쓰지 못했습니다"
        var report = RekordboxTrackWriteReport(dryRun: false)
        report.added = [outcome]
        report.backup = "/backups/add-1"
        h.script.add = report
        // 확인 창이 떠 있는 동안 CLI가 새 판을 저장했다(넣기는 미리 볼 때 읽은 첫 판을 쓴다)
        h.canBackUp = false
        var later = first
        later.place(Self.cueB)
        h.onPrompt = { [memory = h.memory] in memory.save(later, origin: .cli) }
        let result = await h.session.addTracks(rows: [H.row("djc-s", path: track.path)])
        guard case .added = result else { Issue.record("넣었다: \(result)"); return }
        #expect(h.gateCalls.value.adds.last?.revisions.tracks[DraftKey(.cue, "s")]?.contentHash == (try DraftContentHash(of: first)))
        #expect(h.memory.cue("new-s")?.cues.count == 2)
        #expect(h.session.ports.drafts.suggestion(DraftKey(.cue, "new-s")) != nil, "넣는 동안 생긴 새 판은 사람 편집으로 옮기지 않는다")
    }

    // MARK: - 2라운드 S20·G12

    @Test func CLI_쓰기는_미정리_목록을_읽지_못하면_쓰지_않는다() async throws {
        h.options = .cli(attachesAnalysis: false, writesArtwork: false)
        h.script.cleanupListsError = DJCError.writeRefused("초안 정리 목록(op.json)을 읽지 못했습니다. 이 DJCrate가 모르는 형식이면 DJCrate를 업데이트한 뒤 다시 시도하세요")
        await #expect(throws: DJCError.self) { try await h.session.cleanUpBeforeWrite(to: h.session.target, lock: MemoryWriteLocks().port) }
    }

    @Test func CLI_쓰기는_곡_넣기_정리를_미룬_목록이_있으면_쓰지_않는다() async throws {
        h.options = .cli(attachesAnalysis: false, writesArtwork: false)
        // 넣기는 핫큐 A를 썼고 CLI가 B를 더했다. 새 곡 행을 읽지 못해(CLI는 목록을 읽지 않는다) 옮기기를 미룬다
        var written = CueDraft(trackUUID: "s")
        written.place(Self.cueA)
        h.memory.save(written)
        let stamp = try #require(h.memory.stamp(DraftKey(.cue, "s")))
        var later = written
        later.place(Self.cueB)
        h.memory.save(later, origin: .cli)
        trackAddList(written: [WrittenDraft(key: DraftKey(.cue, "s"), revision: stamp.revision, contentHash: try DraftContentHash(of: written))],
                     values: .init(cues: [Self.cueA]))
        await #expect(throws: DJCError.self) { try await h.session.cleanUpBeforeWrite(to: h.session.target, lock: MemoryWriteLocks().port) }
        #expect(h.gateCalls.value.removedCleanupLists.isEmpty)
    }

    // MARK: - 3라운드 G11

    @Test func 넣기_계획과_태그_판은_같은_태그_초안에서_잡는다() async throws {
        let track = H.staged("s")
        h.state.staged = [track]
        // 앱 메모리는 A, 디스크는 CLI가 저장한 B(앱이 아직 받지 않았다)
        var memoryTag = TagDraft(trackUUID: "s", base: TagFields())
        memoryTag.fields.title = "A"
        var diskTag = memoryTag
        diskTag.fields.title = "B"
        h.memory.save(diskTag, origin: .cli)
        h.state.tagDrafts["s"] = memoryTag
        h.script.addPreview.added = [H.track(track.path)]
        var report = RekordboxTrackWriteReport(dryRun: false)
        report.added = [H.track(track.path, uuid: "new-s")]
        report.backup = "/backups/add-1"
        h.script.add = report
        let outcome = await h.session.addTracks(rows: [H.row("djc-s", path: track.path)])
        guard case .added = outcome else { Issue.record("넣었다: \(outcome)"); return }
        #expect(h.gateCalls.value.adds.last?.revisions.tracks[DraftKey(.tag, "s")]?.contentHash == (try DraftContentHash(of: memoryTag)),
                "계획에 쓴 메모리 초안의 해시를 싣는다")
        #expect(h.memory.tag("s")?.fields.title == "B" || h.memory.tag("new-s")?.fields.title == "B", "디스크의 B를 넣기에 쓴 판으로 오인해 지우지 않는다")
    }

    // MARK: - 3라운드 S23 + S18

    enum TagMove: CaseIterable { case albumArtistNotInDraft, estimatedKey, revertedTitle }

    @Test(arguments: TagMove.allCases)
    func 태그_옮기기는_사용자가_바꾼_칸과_계획에_실린_칸과_막힌_칸만_옮긴다(_ scenario: TagMove) {
        var base = TagFields(), written = TagFields()
        let current: TagDraft, hadDraft: Bool, expected: [TagFields.Key: String]
        switch scenario {
        case .albumArtistNotInDraft:
            // 태그 초안 없이 넣었다: 음원의 앨범 아티스트 X가 쓰였고 추가 목록 행에는 없다. 넣는 동안 코멘트만 고쳤다
            base.title = "곡"
            written.title = "곡"
            written.albumArtist = "X"
            var draft = TagDraft(trackUUID: "s", base: base)
            draft.fields.comment = "새 코멘트"
            current = draft
            hadDraft = false
            expected = [.comment: "새 코멘트"]
        case .estimatedKey:
            // 추정 키 8A(고르지 않았다: base = fields)는 쓰지 않았다. 넣는 동안 제목만 고쳤다
            base.title = "곡"
            base.musicalKey = "8A"
            written.title = "곡"
            var draft = TagDraft(trackUUID: "s", base: base)
            draft.fields.title = "새 제목"
            current = draft
            hadDraft = true
            expected = [.title: "새 제목"]
        case .revertedTitle:
            // 넣기는 제목 B를 썼고, 넣는 동안 제목을 파일 값 A로 되돌리고 키를 골랐다
            base.title = "A"
            written.title = "B"
            var draft = TagDraft(trackUUID: "s", base: base)
            draft.fields.musicalKey = "8A"
            current = draft
            hadDraft = true
            expected = [.title: "A", .musicalKey: "8A"]
        }
        let moved = AddedTrackDrafts.movedTagDraft(current, written: written, blocked: [], hadDraft: hadDraft, to: "new-s")
        #expect(moved.base == written)
        #expect(Set(moved.changedKeys) == Set(expected.keys), "\(scenario): \(moved.changedKeys)")
        for (key, value) in expected { #expect(moved.fields[key] == value) }
    }

    // MARK: - 3라운드 O16

    @Test func 다시_읽은_라이브러리에_새_곡이_없으면_옛_초안을_연결_안_된_초안으로_두고_정리를_끝낸다() async throws {
        try writtenCueThenLater()
        h.state.rows["new-s"] = nil
        let deferred = await h.session.resumeCleanups()
        #expect(deferred.deferred == 1 && deferred.finished == 0)
        // 다시 읽은 사본이 쓰기 대상 라이브 DB와 같다
        h.readIsLatest.value = true
        let resumed = await h.session.resumeCleanups()
        #expect(resumed.finished == 1 && h.gateCalls.value.removedCleanupLists == ["op-add"])
        #expect(h.memory.cue("s") != nil && h.memory.cue("new-s") == nil)
    }

    // MARK: - 4라운드 S24·G14

    @Test func 넣기에서_쓴_키를_되돌린_새_판은_키_지우기도_새_곡으로_옮긴다() async throws {
        var tag = TagDraft(trackUUID: "s", base: TagFields())
        tag.fields.musicalKey = "8A"
        h.memory.save(tag)
        let stamp = try #require(h.memory.stamp(DraftKey(.tag, "s")))
        // 넣는 동안 키를 비우고(원래 값) 코멘트를 고쳤다
        var later = tag
        later.fields.musicalKey = ""
        later.fields.comment = "새 코멘트"
        h.memory.save(later, origin: .cli)
        var written = TagFields()
        written.musicalKey = "8A"
        trackAddList(written: [WrittenDraft(key: DraftKey(.tag, "s"), revision: stamp.revision, contentHash: try DraftContentHash(of: tag))],
                     values: .init(musicalKey: "8A", tags: written))
        _ = await h.session.resumeCleanups()
        let moved = try #require(h.memory.tag("new-s"))
        #expect(moved.base.musicalKey == "8A" && moved.fields.musicalKey.isEmpty && moved.fields.comment == "새 코멘트")
    }

    // MARK: - 4라운드 O20

    @Test func 저장하지_못한_태그_초안이_있으면_다시_저장해_보고_안_되면_넣지_않는다() async throws {
        let track = H.staged("s")
        h.state.staged = [track]
        h.state.failedTagSaves = ["s"]
        await #expect(throws: DJCError.self) { _ = try await h.session.previewAdd(rows: [H.row("djc-s", path: track.path)]) }
        #expect(h.log.contains("retry tag saves") && h.gateCalls.value.adds.isEmpty)
    }
}
