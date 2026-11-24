import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 자동 저장 엔진(#403): 가짜 시계·가짜 실행 상태·가짜 관문으로 언제 쓰고 언제 쓰지 않는지 본다.
/// 수치는 시험이 준 값(T_edit 3초·T_quiet 10초·T_bulk 30초·M 50·K 200)으로만 단정한다.
@MainActor
@Suite("자동 저장 엔진")
struct AutoReflectionEngineTests {
    // MARK: - R1 트리거

    @Test func T_edit_전에는_쓰지_않고_지나면_사용자_조작_없이_한_번_쓴다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        // 조용함(T_quiet)은 편집 전부터 지켜본다
        try await w.advance(10)
        w.cue("a")
        try await w.edited()
        try await w.advance(2)
        #expect(w.writes.isEmpty && w.engine.status == .pending)
        try await w.advance(1)
        #expect(w.writes.count == 1 && w.writes.first?.drafts.map(\.trackUUID) == ["a"])
        // 배경에서 확인 창을 띄우지 않는다(R6), 결과는 자동 저장으로 알린다
        #expect(w.h.prompts.isEmpty)
        #expect(w.h.published.contains { if case .autoWritten = $0 { true } else { false } })
        #expect(w.engine.status == .saved && w.h.memory.cue("a") == nil)
    }

    @Test func 편집이_이어지면_미룬다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        w.cue("a")
        try await w.edited()
        for _ in 0..<5 {
            try await w.advance(2)
            try await w.edited()
        }
        #expect(w.writes.isEmpty)
        try await w.advance(3)
        #expect(w.writes.count == 1)
    }

    @Test(arguments: [EditActivity.fieldEditing, .composing, .pointerDown, .editorOpen])
    func 편집_중_신호가_켜진_동안은_쓰지_않고_끝나면_T_edit_뒤에_쓴다(_ signal: EditActivity) async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        w.cue("a")
        try await w.edited()
        w.engine.setActivity(signal)
        try await w.settle()
        try await w.advance(30)
        #expect(w.writes.isEmpty && w.engine.conditions.holds.contains(.editing))
        w.engine.setActivity([])
        try await w.settle()
        try await w.advance(2)
        #expect(w.writes.isEmpty, "편집이 끝난 뒤 T_edit를 다시 센다")
        try await w.advance(1)
        #expect(w.writes.count == 1)
    }

    @Test func 앱이_알린_편집_중도_쓰지_않는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.appHolds = [.editing]
        try await w.start()
        try await w.advance(40)
        #expect(w.writes.isEmpty)
        w.appHolds = []
        try await w.advance(3)
        #expect(w.writes.count == 1)
    }

    @Test func 시작_때_남은_초안은_재시작_정리_뒤에_같은_조건으로_저장한다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        // 정리 전에 멈춘 앞 쓰기의 미정리 목록(곡 b는 쓴 판 그대로 남아 있다)
        w.cue("b")
        let stamp = try #require(w.h.memory.stamp(DraftKey(.cue, "b")))
        let written = WrittenDraft(key: DraftKey(.cue, "b"), revision: stamp.revision,
                                   contentHash: try DraftContentHash(of: ReflectionHarness.cue("b")))
        w.h.script.cleanupLists = [DraftCleanupList(operationID: "op-1", target: MemoryWriteLocks.key(for: w.h.session.target.database),
                                                    draftHome: "/drafts", backupFolder: "w1", written: [written])]
        try await w.start()
        #expect(w.h.memory.cue("b") == nil && w.h.gateCalls.value.removedCleanupLists == ["op-1"])
        #expect(w.writes.isEmpty, "남은 편집도 T_edit·조용함을 기다린다")
        try await w.advance(10)
        #expect(w.writes.count == 1 && w.writes.first?.drafts.map(\.trackUUID) == ["a"])
        let order = w.h.gateCalls.value.order
        #expect(order.firstIndex(of: "remove cleanup list")! < order.firstIndex(of: "write")!)
    }

    // MARK: - R2 rekordbox 켜짐과 조용함

    @Test(arguments: [RekordboxRunState.running, .agentOnly, .unknown])
    func 켜져_있는_동안은_쓰지_않고_꺼진_뒤_T_quiet가_지나야_쓴다(_ state: RekordboxRunState) async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.fakes.setRunState(state)
        try await w.start()
        try await w.advance(60)
        #expect(w.writes.isEmpty)
        #expect(w.engine.status == .rekordboxRunning(agentOnly: state == .agentOnly))
        // 꺼진 것은 다음 관찰(1초 뒤)에서 보고 그때부터 T_quiet를 센다
        w.fakes.setRunState(.stopped)
        try await w.advance(10)
        #expect(w.writes.isEmpty && w.engine.status == .quietWaiting)
        try await w.advance(1)
        #expect(w.writes.count == 1)
    }

    @Test func 남은_wal이나_shm이_있으면_쓰지_않는다() async throws {
        for stamps in [LibraryQuietStamps(walSize: 8, shmExists: false, database: RekordboxFileStamp(size: 4096, modifiedNanoseconds: 1), playlistsXML: nil),
                       LibraryQuietStamps(walSize: nil, shmExists: true, database: RekordboxFileStamp(size: 4096, modifiedNanoseconds: 1), playlistsXML: nil)] {
            let w = AutoReflectionWorld()
            w.writable("a")
            w.cue("a")
            w.fakes.setQuietStamps(stamps)
            try await w.start()
            try await w.advance(30)
            #expect(w.writes.isEmpty)
            #expect(w.engine.status == .held(stamps.shmExists ? .shmRemains : .walRemains))
            // 0바이트 -wal은 조건을 채운다
            w.fakes.setQuietStamps(LibraryQuietStamps(walSize: 0, shmExists: false, database: stamps.database, playlistsXML: nil))
            try await w.advance(1)
            #expect(w.writes.count == 1)
        }
    }

    @Test func master_db나_재생_목록_XML이_바뀌는_동안은_조용함을_다시_센다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        try await w.start()
        for second in 1...15 {
            w.fakes.setQuietStamps(LibraryQuietStamps(walSize: nil, shmExists: false, database: RekordboxFileStamp(size: 4096, modifiedNanoseconds: Int64(second)),
                                                      playlistsXML: nil))
            try await w.advance(1)
        }
        #expect(w.writes.isEmpty && w.engine.status == .quietWaiting)
        try await w.advance(5)
        w.fakes.setQuietStamps(LibraryQuietStamps(walSize: nil, shmExists: false, database: RekordboxFileStamp(size: 4096, modifiedNanoseconds: 15),
                                                  playlistsXML: RekordboxFileStamp(size: 10, modifiedNanoseconds: 1)))
        try await w.advance(10)
        #expect(w.writes.isEmpty, "재생 목록 XML이 바뀌면 다시 센다")
        try await w.advance(1)
        #expect(w.writes.count == 1)
    }

    // MARK: - R4 대상 밖 편집

    static func merge(_ id: String, members: [String]) -> DuplicateMergeDraft {
        DuplicateMergeDraft(keeping: .init(contentID: id, trackUUID: id, title: "남김", duration: 1, offset: 0, cues: []),
                            removing: members.map { .init(contentID: $0, trackUUID: $0, title: "뺌", duration: 1, offset: 0, cues: []) }, base: "")
    }

    static let layout = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가", entries: [PlaylistEntry(trackNo: 1, contentID: "1")]), 1),
                                        (PlaylistLayout.Item(id: "B", name: "나"), 2)])

    enum OutsideKind: CaseIterable { case analysisAttach, artwork, merge, stagedTrack, gainWithoutBase, playlistDelete }

    @Test(arguments: OutsideKind.allCases)
    func 대상_밖_편집은_종류마다_자동으로_쓰지_않는다(_ kind: OutsideKind) async throws {
        let w = AutoReflectionWorld()
        switch kind {
        case .analysisAttach:
            // 분석 파일이 없는 곡의 그리드는 분석 붙이기다
            w.h.state.rows["g"] = ReflectionHarness.row("g", analysis: nil)
            w.h.state.gridDraftUUIDs = ["g"]
            w.h.memory.save(ReflectionHarness.grid("g"))
        case .artwork:
            w.h.state.rows["w"] = ReflectionHarness.row("w")
            w.h.state.artworkDrafts["w"] = ArtworkDraft(trackUUID: "w", change: .delete, base: ArtworkBase(imagePath: ""))
        case .merge:
            ["m", "r"].forEach { w.h.state.rows[$0] = ReflectionHarness.row($0) }
            w.h.state.mergeDrafts = [Self.merge("m", members: ["r"])]
        case .stagedTrack:
            w.cue("djc-s")
        case .gainWithoutBase:
            w.h.state.rows["n"] = ReflectionHarness.row("n")
            w.h.state.gainDraftUUIDs = ["n"]
            w.h.memory.save(gain: -1, "n")
        case .playlistDelete:
            var draft = PlaylistDraft()
            _ = try draft.append(.delete(playlist: .id("B")), rekordbox: Self.layout)
            try w.h.memory.store.savePlaylistDraft(draft)
            w.h.state.rekordboxPlaylists = Self.layout
            w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        }
        try await w.start()
        try await w.advance(40)
        #expect(w.writes.isEmpty && w.previews.isEmpty)
        #expect(w.engine.conditions.leftovers.contains(kind == .gainWithoutBase ? .noBase : .outsideScope))
        #expect(w.engine.status == .leftover(count: 1) || w.engine.status == .leftover(count: 2))
    }

    /// R23(#405): base를 단 게인 초안은 대상 편집이라 자동으로 쓰고, 관문에 base를 함께 넘긴다(지금 rekordbox 값과 다르면 관문이 막는다)
    @Test func base가_있는_게인_초안은_자동으로_쓰고_base를_함께_넘긴다() async throws {
        let w = AutoReflectionWorld()
        w.h.script.preview.gainOutcomes = [ReflectionHarness.outcome("n", .written)]
        w.h.state.rows["n"] = ReflectionHarness.row("n")
        w.h.state.gainDraftUUIDs = ["n"]
        w.h.memory.save(gain: -1, base: -3, "n")
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.count == 1)
        #expect(w.writes.first?.gains == ["n": -1] && w.writes.first?.gainBases == ["n": -3])
        #expect(!w.engine.conditions.leftovers.contains(.noBase))
    }

    // MARK: - 저장 뒤 ⌘Z의 역편집 묶음(R12, #405)

    /// 여러 곡의 태그 역편집(저장 뒤 ⌘Z가 만든 사람 편집 초안)과 그 묶음
    func undoGroup(_ w: AutoReflectionWorld, _ uuids: [String], rows: Int? = nil) -> ReflectionUndoEdit {
        var tags: [TagDraft] = []
        for uuid in uuids {
            let tag = ReflectionHarness.tag(uuid, title: "되돌린 제목")
            w.h.state.rows[uuid] = ReflectionHarness.row(uuid)
            w.h.state.tagDrafts[uuid] = tag
            w.h.memory.save(tag)
            tags.append(tag)
        }
        return ReflectionUndoEdit(id: "undo-1", batch: DraftWriteBatch(tags: tags, commitPolicy: .allOrNothing), rowCount: rows ?? uuids.count)
    }

    @Test func 여러_곡_역편집은_한_묶음으로_전부_아니면_전무로_쓴다() async throws {
        let w = AutoReflectionWorld()
        w.h.script.preview.tagOutcomes = ["a", "b"].map { ReflectionHarness.outcome($0, .written) }
        let edit = undoGroup(w, ["a", "b"])
        w.writable("c")
        w.cue("c")
        try await w.start()
        w.engine.enqueue(.undo(edit))
        try await w.advance(10)
        // 역편집 묶음을 먼저 따로 쓴다(다른 곡 편집과 섞지 않는다)
        #expect(w.writes.count == 2)
        #expect(w.writes.first?.commitPolicy == .allOrNothing && w.writes.first?.tags.map(\.trackUUID).sorted() == ["a", "b"])
        #expect(w.writes.first?.drafts.isEmpty == true && w.writes.last?.commitPolicy == .writable)
    }

    @Test func 여러_곡_역편집_가운데_한_곡이라도_막히면_하나도_쓰지_않는다() async throws {
        let w = AutoReflectionWorld()
        w.h.script.preview.tagOutcomes = [ReflectionHarness.outcome("a", .written), ReflectionHarness.outcome("b", .blocked, reason: "바뀌었습니다")]
        let edit = undoGroup(w, ["a", "b"])
        try await w.start()
        w.engine.enqueue(.undo(edit))
        try await w.advance(10)
        #expect(w.previews.first?.commitPolicy == .allOrNothing)
        #expect(w.writes.isEmpty)
        #expect(w.h.memory.tag("a") != nil && w.h.memory.tag("b") != nil)
        // 쓰지 못한 결과는 다음 판정이 알린다
        try await w.advance(2)
        #expect(w.writes.isEmpty && w.previews.count == 1, "새 편집 전까지 다시 미리 보지 않는다")
        #expect(w.engine.conditions.leftovers.contains(.needsConfirmation))
    }

    /// 여러 곡의 값을 지우는 역편집(채운 코멘트를 저장 뒤 ⌘Z)도 대량 유예를 거친다(R14)
    @Test func 여러_곡의_값을_지우는_역편집은_대량_유예를_거친다() async throws {
        let w = AutoReflectionWorld()
        var tags: [TagDraft] = []
        for uuid in ["a", "b"] {
            var base = TagFields()
            base.comment = "채운 코멘트"
            let tag = TagDraft(trackUUID: uuid, base: base)
            var cleared = tag
            cleared.fields.comment = ""
            w.h.state.rows[uuid] = ReflectionHarness.row(uuid)
            w.h.state.tagDrafts[uuid] = cleared
            w.h.memory.save(cleared)
            tags.append(cleared)
        }
        w.h.script.preview.tagOutcomes = ["a", "b"].map { ReflectionHarness.outcome($0, .written) }
        try await w.start()
        w.engine.enqueue(.undo(ReflectionUndoEdit(id: "undo-clear", batch: DraftWriteBatch(tags: tags, commitPolicy: .allOrNothing), rowCount: 2)))
        try await w.advance(15)
        #expect(w.writes.isEmpty)
        if case .grace = w.engine.status {} else { Issue.record("대량 유예가 아니다: \(w.engine.status)") }
        try await w.advance(31)
        #expect(w.writes.count == 1 && w.writes.first?.commitPolicy == .allOrNothing)
    }

    /// 역편집 묶음이 둘 이상이어도 모두 합쳐 대량 유예를 판정한다(컨실 G7)
    @Test func 역편집_묶음_여럿을_합쳐_대량_유예를_판정한다() async throws {
        let w = AutoReflectionWorld()
        w.timing.bulkTracks = 3
        w.h.script.preview.tagOutcomes = ["a", "b", "c", "d"].map { ReflectionHarness.outcome($0, .written) }
        let first = undoGroup(w, ["a", "b"])
        var second = undoGroup(w, ["c", "d"])
        second.id = "undo-2"
        try await w.start()
        w.engine.enqueue(.undo(first))
        w.engine.enqueue(.undo(second))
        try await w.advance(15)
        #expect(w.writes.isEmpty)
        if case .grace = w.engine.status {} else { Issue.record("대량 유예가 아니다: \(w.engine.status)") }
    }

    /// 일반 저장 대기와 역편집 묶음을 합쳐 M곡 이상이면 대량 유예를 거친다(따로 보면 둘 다 M곡 아래, 컨실 2라운드 D·G7)
    @Test func 일반_대기와_역편집_묶음을_합쳐_대량_유예를_판정한다() async throws {
        let w = AutoReflectionWorld()
        w.timing.bulkTracks = 3
        w.writable("x")
        w.cue("x")
        w.h.script.preview.tagOutcomes = ["a", "b"].map { ReflectionHarness.outcome($0, .written) }
        let edit = undoGroup(w, ["a", "b"])
        try await w.start()
        w.engine.enqueue(.undo(edit))
        try await w.advance(15)
        #expect(w.writes.isEmpty)
        if case .grace = w.engine.status {} else { Issue.record("대량 유예가 아니다: \(w.engine.status)") }
    }

    @Test func K행을_넘는_역편집은_자동으로_쓰지_않고_남긴다() async throws {
        let w = AutoReflectionWorld()
        w.timing.rowLimit = 1
        w.h.script.preview.tagOutcomes = ["a", "b"].map { ReflectionHarness.outcome($0, .written) }
        let edit = undoGroup(w, ["a", "b"])
        try await w.start()
        w.engine.enqueue(.undo(edit))
        try await w.advance(10)
        #expect(w.writes.isEmpty && w.previews.isEmpty)
        #expect(w.engine.conditions.leftovers.contains(.undoOverRowLimit))
    }

    /// 게인 초안을 만든 뒤 rekordbox가 한 번 켜졌다 꺼졌으면 base 없는 초안으로 다룬다(R23, 컨실 S7): 자동으로 쓰지 않고 ⌘S·저장 단추로 쓴다
    @Test func 만든_뒤_rekordbox가_켜졌다_꺼진_게인_초안은_자동으로_쓰지_않는다() async throws {
        let w = AutoReflectionWorld()
        w.h.script.preview.gainOutcomes = [ReflectionHarness.outcome("n", .written)]
        w.h.state.rows["n"] = ReflectionHarness.row("n")
        w.h.state.gainDraftUUIDs = ["n"]
        w.h.memory.save(gain: -1, base: -3, "n")
        try await w.start()
        w.fakes.setRunState(.running)
        try await w.advance(2)
        w.fakes.setRunState(.stopped)
        try await w.advance(25)
        #expect(w.writes.isEmpty)
        #expect(w.engine.conditions.leftovers.contains(.noBase))
    }

    /// 수동 쓰기(확인 창 포함) 동안에도 rekordbox 실행 경계를 넘긴다: 그동안 켜졌다 꺼졌으면 base 없는 초안이다(R23, 컨실 2라운드 K)
    @Test func 수동_쓰기_동안_rekordbox가_켜졌다_꺼진_게인_초안은_자동으로_쓰지_않는다() async throws {
        let w = AutoReflectionWorld()
        w.h.script.preview.gainOutcomes = [ReflectionHarness.outcome("n", .written)]
        w.h.state.rows["n"] = ReflectionHarness.row("n")
        w.h.state.gainDraftUUIDs = ["n"]
        w.h.memory.save(gain: -1, base: -3, "n")
        w.appHolds = [.editing]
        try await w.start()
        var release: CheckedContinuation<Void, Never>?
        let manual = Task { @MainActor in await w.engine.exclusive({ await withCheckedContinuation { release = $0 } }) }
        while release == nil { await Task.yield() }
        try await w.settle()
        w.fakes.setRunState(.running)
        try await w.advance(2)
        w.fakes.setRunState(.stopped)
        try await w.advance(2)
        release?.resume()
        await manual.value
        w.appHolds = []
        try await w.edited()
        try await w.advance(25)
        #expect(w.writes.isEmpty)
        #expect(w.engine.conditions.leftovers.contains(.noBase))
    }

    /// R23의 경계는 "만든 뒤 한 번 켜졌다 꺼진" 것이다: rekordbox가 켜진 동안 만든 게인은 만든 뒤 켜짐이 없어 꺼진 뒤 자동으로 쓴다
    /// (그사이 rekordbox가 게인을 바꿨으면 쓰기 입구가 base와 지금 값을 견줘 막는다)
    @Test func rekordbox가_켜진_동안_만든_게인_초안은_꺼진_뒤_자동으로_쓴다() async throws {
        let w = AutoReflectionWorld()
        w.h.script.preview.gainOutcomes = [ReflectionHarness.outcome("n", .written)]
        w.h.state.rows["n"] = ReflectionHarness.row("n")
        w.fakes.setRunState(.running)
        try await w.start()
        try await w.advance(2)
        w.h.state.gainDraftUUIDs = ["n"]
        w.h.memory.save(gain: -1, base: -3, "n")
        try await w.edited()
        w.fakes.setRunState(.stopped)
        try await w.advance(25)
        #expect(w.writes.count == 1 && w.writes.first?.gains == ["n": -1] && w.writes.first?.gainBases == ["n": -3])
        #expect(!w.engine.conditions.leftovers.contains(.noBase))
    }

    @Test func 같은_곡에_큐와_앨범아트가_있으면_큐만_자동으로_쓰고_앨범아트는_남긴다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.h.state.artworkDrafts["a"] = ArtworkDraft(trackUUID: "a", change: .delete, base: ArtworkBase(imagePath: ""))
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.count == 1 && w.writes.first?.drafts.map(\.trackUUID) == ["a"] && w.writes.first?.artworks.isEmpty == true)
        #expect(w.h.state.artworkDrafts["a"] != nil && w.engine.status == .leftover(count: 1))
    }

    @Test func 사람이_한_재생_목록_편집은_얼려_자동으로_쓰고_쓴_단계만_정리한다() async throws {
        let w = AutoReflectionWorld()
        var draft = PlaylistDraft()
        _ = try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["9"]), rekordbox: Self.layout)
        _ = try draft.append(.rename(playlist: .id("B"), name: "새 이름"), rekordbox: Self.layout)
        try w.h.memory.store.savePlaylistDraft(draft)
        w.h.state.rekordboxPlaylists = Self.layout
        w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        // 넣는 곡은 컬렉션에 있다(없으면 막힌 편집이다)
        w.h.state.rows["9"] = ReflectionHarness.row("9")
        w.h.script.preview.playlistOutcomes = [PlaylistOutcome(edit: draft.steps[0].edit, playlistID: "A", name: "가", status: .written),
                                               PlaylistOutcome(edit: draft.steps[1].edit, playlistID: "B", name: "새 이름", status: .written)]
        try await w.start()
        try await w.advance(10)
        let batch = try #require(w.writes.first)
        #expect(w.writes.count == 1 && batch.playlists?.steps.count == 2)
        #expect(batch.revisions.playlistSteps.count == 2 && batch.operation != nil)
        // 묶음을 만든 자리에서 쓰는 단계를 얼린다(R21)
        #expect(w.h.changeNames.contains("frozen 2 histories 0"))
        #expect(w.h.memory.store.playlistDraft().isEmpty && w.engine.status == .saved)
    }

    @Test func 재생_목록_편집이_막히면_그_뒤_재생_목록_편집도_자동으로_쓰지_않는다() async throws {
        let w = AutoReflectionWorld()
        var draft = PlaylistDraft()
        _ = try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["9"]), rekordbox: Self.layout)
        _ = try draft.append(.rename(playlist: .id("B"), name: "새 이름"), rekordbox: Self.layout)
        try w.h.memory.store.savePlaylistDraft(draft)
        // 편집을 만든 뒤 rekordbox에서 A가 바뀌었다: 첫 단계가 막힌다
        w.h.state.rekordboxPlaylists = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가", entries: []), 1),
                                                       (PlaylistLayout.Item(id: "B", name: "나"), 2)])
        w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        try await w.start()
        try await w.advance(40)
        #expect(w.writes.isEmpty && w.previews.isEmpty)
        #expect(w.engine.conditions.leftovers.contains(.needsConfirmation) && w.engine.status == .leftover(count: 2))
    }

    // MARK: - R6 확인 필요

    @Test func 막힌_곡만_빼고_나머지를_묻지_않고_쓰며_막힌_곡은_새_편집_전까지_다시_보지_않는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.writable("b", status: .blocked)
        w.cue("a")
        w.cue("b")
        try await w.start()
        try await w.advance(10)
        #expect(w.h.prompts.isEmpty)
        #expect(w.writes.count == 1 && w.writes.first?.drafts.map(\.trackUUID) == ["a"])
        #expect(w.h.memory.cue("b") != nil && w.engine.conditions.leftovers.contains(.needsConfirmation))
        #expect(w.engine.status == .leftover(count: 1))
        let previews = w.previews.count
        try await w.advance(60)
        #expect(w.previews.count == previews, "새 편집 전에는 다시 미리 보지 않는다")
        // 새 편집(새 판)이 생기면 다시 시도한다
        w.cue("b", at: 20)
        try await w.edited()
        try await w.advance(3)
        #expect(w.previews.count == previews + 1)
    }

    // MARK: - R7 실패

    @Test func 백업_뒤_실패하면_멈추고_다시_켜도_멈춘_채이며_수동_저장에_성공하면_다시_시작한다() async throws {
        let fakes = AutoReflectionFakes()
        let w = AutoReflectionWorld(fakes: fakes)
        w.writable("a")
        w.cue("a")
        w.h.script.writeError = DJCError.writeRolledBack("검증 실패")
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.count == 1 && w.engine.status == .stopped(.stoppedAfterFailure))
        await w.engine.recordSaved()
        #expect(fakes.records.record.stop == .afterFailure)
        // 다음 편집 뒤에도 자동으로 쓰지 않는다
        w.cue("a", at: 30)
        try await w.edited()
        try await w.advance(20)
        #expect(w.writes.count == 1)
        w.engine.stop()
        // 다시 켜도(같은 기록) 쓰지 않는다
        let again = AutoReflectionWorld(fakes: fakes)
        again.writable("a")
        again.cue("a")
        try await again.start()
        try await again.advance(20)
        #expect(again.writes.isEmpty && again.engine.status == .stopped(.stoppedAfterFailure))
        // ⌘S·저장 단추로 저장에 성공하면 멈춤이 풀린다
        _ = await again.engine.exclusive { ReflectionOutcome.written(ReflectionHarness.report(), preview: ReflectionHarness.report(), followUp: []) }
        await again.engine.recordSaved()
        #expect(fakes.records.record.stop == nil)
        try await again.advance(3)
        #expect(again.writes.count == 1)
    }

    @Test func 기록을_읽지_못하면_멈춤으로_본다() async throws {
        let w = AutoReflectionWorld()
        w.fakes.records.failLoading()
        w.writable("a")
        w.cue("a")
        try await w.start()
        try await w.advance(20)
        #expect(w.writes.isEmpty && w.engine.status == .stopped(.stoppedAfterFailure))
    }

    @Test func 백업_전_실패가_같은_원인으로_두_번_나면_보류하고_새_편집_뒤_다시_시도한다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.h.script.writeError = DJCError.writeRefused("백업 폴더에 쓰지 못했습니다")
        try await w.start()
        try await w.advance(12)
        #expect(w.writes.count == 2 && w.engine.status == .held(.preBackupFailure))
        try await w.advance(30)
        #expect(w.writes.count == 2)
        // 새 편집(사람 편집의 새 판)
        w.cue("a", at: 30)
        try await w.edited()
        try await w.advance(3)
        #expect(w.writes.count == 3)
    }

    @Test func 쓰기_기록이_남았으면_중단으로_보고_쓰지_않는다() async throws {
        let w = AutoReflectionWorld()
        let journal = RekordboxWriteJournal(operationID: "op", kind: .counter, entry: .drafts)
        w.h.script.journal = .interrupted(RekordboxJournalFinding(journal: journal, changedSince: false, database: nil))
        w.writable("a")
        w.cue("a")
        try await w.start()
        try await w.advance(30)
        #expect(w.writes.isEmpty && w.engine.status == .interrupted(recoveryFailed: false))
        #expect(w.h.gateCalls.value.order.allSatisfy { $0 != "cleanup lists" }, "중단 기록이 있으면 미정리 목록을 정리하지 않는다")
    }

    @Test func 이대로_둔다_뒤_기록을_다시_보면_자동_저장이_이어진다() async throws {
        let w = AutoReflectionWorld()
        let journal = RekordboxWriteJournal(operationID: "op", kind: .counter, entry: .drafts)
        let finding = RekordboxJournalFinding(journal: journal, changedSince: false, database: nil)
        w.h.script.journal = .interrupted(finding)
        w.writable("a")
        w.cue("a")
        try await w.start()
        try await w.advance(20)
        #expect(w.writes.isEmpty && w.engine.status == .interrupted(recoveryFailed: false))
        // 사용자가 "이대로 둔다"를 골라 기록이 지워졌다(엔진이 쓰는 관문의 기록)
        #expect(try w.engine.session.ports.gate.keepJournal(w.engine.session.target, finding.request) {} == .kept)
        w.engine.recheckJournal()
        try await w.settle()
        try await w.advance(1)
        #expect(w.writes.count == 1)
    }

    @Test func 커밋_전에_켜진_것을_보면_멈추지_않고_조용함부터_다시_센다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.h.script.writeError = DJCError.rekordboxRunning
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.count == 1 && w.engine.status == .quietWaiting)
        #expect(w.fakes.records.record.stop == nil)
    }

    // MARK: - R8 복원 뒤(E2: 사용자가 한 복원은 멈추지 않는다)

    /// 저장 알림(confirmed)·메뉴의 「저장 전으로 복원」 뒤 자동 저장은 멈추지 않는다. 되살린 초안은 제안으로 남고, 새 사람 편집은
    /// 조용함 조건을 채운 뒤 자동으로 쓴다(E2)
    @Test(arguments: [true, false])
    func 사용자가_한_복원_뒤에는_멈추지_않고_되살린_초안만_제안으로_남는다(_ fromToast: Bool) async throws {
        let w = AutoReflectionWorld()
        w.writable("a", "b")
        w.h.backupDrafts = RekordboxBackupDrafts(cues: [ReflectionHarness.cue("a")])
        w.h.state.rows["a"] = ReflectionHarness.row("a")
        try await w.start()
        try await w.advance(10)
        let outcome = await w.engine.exclusive { [session = w.h.session] in await session.restore(ReflectionHarness.backup(), confirmed: fromToast) }
        guard case .restored = outcome else { Issue.record("복원했다: \(outcome)"); return }
        #expect(w.h.memory.stamp(DraftKey(.cue, "a"))?.origins == [.restored])
        w.h.state.cueDraftUUIDs = ["a"]
        w.cue("b")
        try await w.edited()
        try await w.advance(3)
        #expect(w.engine.status != .stopped(.stoppedAfterRestore) && w.fakes.records.record.stop == nil, "사용자가 한 복원 뒤 멈추지 않는다")
        #expect(w.writes.count == 1 && w.writes.first?.drafts.map(\.trackUUID) == ["b"], "새 사람 편집만 자동으로 쓴다")
        #expect(w.h.memory.cue("a") != nil && w.engine.conditions.leftovers.contains(.suggestion), "되살린 초안은 제안으로 남는다")
    }

    /// 기록으로 복원(R11)은 지금처럼 멈춘다(E2 범위 밖)
    @Test func 기록으로_복원하면_지금처럼_멈춘다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        w.engine.restoredFromJournal()
        try await w.settle()
        w.cue("a")
        try await w.edited()
        try await w.advance(20)
        #expect(w.writes.isEmpty && w.engine.status == .stopped(.stoppedAfterRestore))
        await w.engine.recordSaved()
        #expect(w.fakes.records.record.stop == .afterRestore)
    }

    /// 「복원하고 지금 편집 남기기」로 남긴 초안은 자동 저장 대상이다: base가 복원 DB와 같으면 쓰이고, 다르면 관문이 막아 확인 필요로 남는다(E2)
    @Test(arguments: [RekordboxWriteOutcome.Status.written, .blocked])
    func 복원이_남긴_지금_초안은_base가_같을_때만_자동으로_쓴다(_ status: RekordboxWriteOutcome.Status) async throws {
        let w = AutoReflectionWorld()
        w.writable("a", status: status)
        // 백업의 초안과 지금 초안이 달라 충돌이다: 「복원하고 지금 편집 남기기」(기본 고름)를 고른다
        w.h.backupDrafts = RekordboxBackupDrafts(cues: [ReflectionHarness.cue("a", at: 12)])
        w.cue("a", at: 30)
        w.h.choice = .confirm
        // 복원 전에 지금 초안이 저장되지 않게 편집 중으로 두고 복원한다
        w.appHolds = [.editing]
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.isEmpty)
        let outcome = await w.engine.exclusive { [session = w.h.session] in await session.restore(ReflectionHarness.backup(), confirmed: true) }
        guard case .restored = outcome else { Issue.record("복원했다: \(outcome)"); return }
        #expect(w.h.memory.stamp(DraftKey(.cue, "a"))?.origins == [.human], "남긴 지금 초안은 사람 편집 그대로다")
        w.appHolds = []
        try await w.edited()
        try await w.advance(3)
        #expect(w.engine.status != .stopped(.stoppedAfterRestore), "사용자가 한 복원 뒤 멈추지 않는다")
        if status == .written {
            #expect(w.writes.count == 1 && w.writes.first?.drafts.map(\.trackUUID) == ["a"])
        } else {
            // 막혀 뺀 판은 다음 판정이 확인 필요로 알린다
            try await w.advance(1)
            #expect(w.writes.isEmpty, "관문이 막아 쓰지 않는다")
            #expect(w.engine.conditions.leftovers.contains(.needsConfirmation))
        }
    }

    // MARK: - R13 시점 스냅샷·백업 조건

    @Test func 오늘_뜰_차례면_시점_스냅샷을_먼저_뜨고_쓴다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        w.cue("a")
        try await w.edited()
        try await w.advance(3)
        // 앱을 켠 직후 한 편집도 90초 주기를 기다리지 않는다
        #expect(w.snapshotCalls == [0] && w.writes.count == 1)
    }

    @Test(arguments: [ReflectionHold.lockBusy, .interrupted(recoveryFailed: false), .rekordboxRunning])
    func 스냅샷이_보류하면_쓰지_않는다(_ reason: ReflectionHold) async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.snapshot = .held(reason)
        try await w.start()
        try await w.advance(30)
        #expect(w.writes.isEmpty && !w.snapshotCalls.isEmpty)
        w.snapshot = .satisfied
        try await w.advance(1)
        #expect(w.writes.count == 1)
    }

    @Test(arguments: [(RekordboxBackupCondition.noClone, ReflectionHold.backupNoClone),
                      (.lowSpace(available: 1, required: 2), .lowDiskSpace), (.unknown, .backupNoClone)])
    func 백업_조건이_어긋나면_이유를_보이고_보류한다(_ condition: RekordboxBackupCondition, _ reason: ReflectionHold) async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.h.backupsMemory.condition = condition
        try await w.start()
        try await w.advance(30)
        #expect(w.writes.isEmpty && w.engine.conditions.holds.contains(reason))
        w.h.backupsMemory.condition = .ready
        try await w.advance(1)
        #expect(w.writes.count == 1)
    }

    @Test func 다른_프로세스가_쓰기_잠금을_쥐면_보류하고_풀리면_쓴다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        let key = MemoryWriteLocks.key(for: w.h.session.target.database)
        try await w.start()
        w.fakes.locks.holdElsewhere(key)
        try await w.advance(30)
        #expect(w.writes.isEmpty && w.engine.status == .held(.lockBusy))
        w.fakes.locks.holdElsewhere(key, false)
        try await w.advance(1)
        #expect(w.writes.count == 1)
    }

    // MARK: - R14 대량 유예·K행

    @Test func M곡_이상이면_T_bulk_동안_기다리고_그_뒤_쓴다() async throws {
        let w = AutoReflectionWorld()
        let uuids = (0..<50).map { String(format: "t%03d", $0) }
        w.writable(uuids)
        uuids.forEach { w.cue($0) }
        try await w.start()
        // T_edit(3초)가 지나면 유예를 시작해 30초 동안 기다린다
        try await w.advance(32)
        #expect(w.writes.isEmpty)
        #expect(w.engine.status == .grace(secondsLeft: 1))
        try await w.advance(1)
        #expect(w.writes.count == 1 && w.writes.first?.drafts.count == 50)
    }

    @Test func 유예를_취소하면_다시_켜도_새_편집_전까지_자동으로_쓰지_않는다() async throws {
        let fakes = AutoReflectionFakes()
        let w = AutoReflectionWorld(fakes: fakes)
        let uuids = (0..<50).map { String(format: "t%03d", $0) }
        w.writable(uuids)
        uuids.forEach { w.cue($0) }
        try await w.start()
        try await w.advance(15)
        w.engine.cancelGrace()
        try await w.settle()
        try await w.advance(60)
        #expect(w.writes.isEmpty && w.engine.status == .leftover(count: 50))
        await w.engine.recordSaved()
        #expect(fakes.records.record.cancelledRevisions.count == 50)
        w.engine.stop()
        let again = AutoReflectionWorld(fakes: fakes)
        again.writable(uuids)
        uuids.forEach { again.cue($0) }
        try await again.start()
        try await again.advance(60)
        #expect(again.writes.isEmpty)
        // 한 곡을 다시 고치면 그 곡(새 판)만 자동으로 쓴다
        again.cue("t000", at: 40)
        try await again.edited()
        try await again.advance(3)
        #expect(again.writes.count == 1 && again.writes.first?.drafts.map(\.trackUUID) == ["t000"])
    }

    // MARK: - 자동 저장 미리 보기 [취소](#404 4b): 대량 유예 [취소]와 같게 다룬다

    /// 자동 저장이 미리 보기에서 멈춘 상태로 만든다(시계 10초째: 쓸 때가 됐다)
    private func previewing(_ w: AutoReflectionWorld) async throws {
        w.h.previewHold.hold()
        try await w.start()
        try await w.advance(9)
        w.fakes.clock.advance(.seconds(1))
        for _ in 0..<2000 where !w.h.previewHold.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        #expect(w.h.previewHold.isWaiting)
    }

    @Test func 사용자가_자동_저장_미리_보기를_취소하면_시간이_지나도_다시_쓰지_않고_남은_편집으로_보인다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        try await previewing(w)
        #expect(w.engine.cancelAutoWrite(), "자동 저장이 쓰는 중이라 취소 대상이 있다")
        w.h.previewHold.release()
        try await w.settle()
        try await w.advance(60)
        #expect(w.writes.isEmpty && w.previews.count == 1, "취소한 판을 다시 미리 보거나 쓰지 않는다: 미리 보기 \(w.previews.count)번, 쓰기 \(w.writes.count)번")
        #expect(w.engine.status == .leftover(count: 1), "상태 줄은 취소한 유예와 같은 남은 편집 줄이다: \(w.engine.status)")
    }

    @Test func 취소한_자동_저장은_다시_켜도_이어지고_새_편집_뒤에_다시_쓴다() async throws {
        let fakes = AutoReflectionFakes()
        let w = AutoReflectionWorld(fakes: fakes)
        w.writable("a")
        w.cue("a")
        try await previewing(w)
        #expect(w.engine.cancelAutoWrite())
        w.h.previewHold.release()
        try await w.settle()
        await w.engine.recordSaved()
        #expect(fakes.records.record.cancelledRevisions.count == 1, "취소한 판을 기록에 남긴다")
        w.engine.stop()
        let again = AutoReflectionWorld(fakes: fakes)
        again.writable("a")
        again.cue("a")
        try await again.start()
        try await again.advance(60)
        #expect(again.writes.isEmpty, "다시 켜도 새 편집 전까지 자동으로 쓰지 않는다")
        // 같은 곡을 다시 고치면(새 판) 자동으로 쓴다
        again.cue("a", at: 40)
        try await again.edited()
        try await again.advance(3)
        #expect(again.writes.count == 1 && again.writes.first?.drafts.map(\.trackUUID) == ["a"])
    }

    @Test func 취소한_자동_저장의_판도_저장_단추로는_쓰고_그_뒤_새_편집은_다시_자동으로_쓴다() async throws {
        let fakes = AutoReflectionFakes()
        let w = AutoReflectionWorld(fakes: fakes)
        w.writable("a")
        w.cue("a")
        try await previewing(w)
        #expect(w.engine.cancelAutoWrite())
        w.h.previewHold.release()
        try await w.settle()
        // ⌘S·저장 단추는 취소한 판도 쓴다
        _ = await w.engine.exclusive { [session = w.h.session] in await session.write(rows: [ReflectionHarness.row("a")]) }
        try await w.settle()
        await w.engine.recordSaved()
        #expect(w.writes.count == 1, "저장 단추로 썼다")
        #expect(fakes.records.record.cancelledRevisions.isEmpty, "쓴 판은 취소 기록에서 풀린다")
        w.writable("a")
        w.cue("a", at: 40)
        try await w.edited()
        try await w.advance(3)
        #expect(w.writes.count == 2, "그 뒤 새 편집은 다시 자동으로 쓴다")
    }

    // MARK: - 5라운드: 사용자 취소는 받은 순간 기록한다(S16·S15)

    @Test func 사용자가_취소해도_미리_보기가_오류로_끝나면_그_취소를_기록하고_다시_쓰지_않는다() async throws {
        let fakes = AutoReflectionFakes()
        let w = AutoReflectionWorld(fakes: fakes)
        w.writable("a")
        w.cue("a")
        // 취소했지만 미리 보기는 취소 오류가 아닌 입출력 오류로 끝난다(멈춘 미리 보기를 풀면 던진다)
        w.h.script.previewError = CocoaError(.fileReadUnknown)
        try await previewing(w)
        #expect(w.engine.cancelAutoWrite())
        w.h.previewHold.release()
        try await w.settle()
        await w.engine.recordSaved()
        #expect(fakes.records.record.cancelledRevisions.count == 1, "미리 보기의 결과와 상관없이 사용자 취소를 기록한다")
        try await w.advance(60)
        #expect(w.writes.isEmpty && w.previews.count == 1, "취소한 판을 다시 미리 보거나 쓰지 않는다: 미리 보기 \(w.previews.count)번, 쓰기 \(w.writes.count)번")
    }

    @Test func 사용자_취소는_미리_보기가_돌아오기_전에_기록을_저장하기_시작한다() async throws {
        let fakes = AutoReflectionFakes()
        let w = AutoReflectionWorld(fakes: fakes)
        w.writable("a")
        w.cue("a")
        try await previewing(w)
        #expect(w.engine.cancelAutoWrite())
        // 미리 보기는 아직 멈춰 있다(앱을 이때 끄면 이 기록이 디스크에 있어야 다시 켠 뒤 같은 판을 쓰지 않는다)
        #expect(w.h.previewHold.isWaiting)
        await w.engine.recordSaved()
        #expect(fakes.records.record.cancelledRevisions.count == 1, "받은 순간 저장을 시작했다")
        w.h.previewHold.release()
        try await w.settle()
    }

    @Test func 사용자가_거절한_것이_아닌_취소는_판을_취소한_것으로_남기지_않고_다시_쓴다() async throws {
        let fakes = AutoReflectionFakes()
        let w = AutoReflectionWorld(fakes: fakes)
        w.writable("a")
        w.cue("a")
        try await previewing(w)
        #expect(w.engine.cancelAutoWrite(byUser: false), "앱 종료 같은 취소")
        w.h.previewHold.release()
        try await w.settle()
        await w.engine.recordSaved()
        #expect(fakes.records.record.cancelledRevisions.isEmpty)
        try await w.advance(3)
        #expect(w.writes.count == 1, "다음 판정에서 그대로 다시 쓴다")
    }

    @Test func 여러_곡의_값을_지우는_편집도_유예한다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a", "b")
        for uuid in ["a", "b"] {
            w.h.state.rows[uuid] = ReflectionHarness.row(uuid)
            w.h.state.cueDraftUUIDs.insert(uuid)
            var draft = CueDraft(trackUUID: uuid)
            draft.base = ReflectionHarness.cue(uuid).cues
            draft.cues = []
            w.h.memory.save(draft)
        }
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.isEmpty)
        guard case .grace = w.engine.status else { Issue.record("유예 중이다: \(w.engine.status)"); return }
        try await w.advance(30)
        #expect(w.writes.count == 1)
    }

    @Test func K행을_넘는_대기열은_나눠_차례로_쓴다() async throws {
        let w = AutoReflectionWorld()
        w.timing.rowLimit = 3
        w.writable("a", "b", "c", "d")
        ["a", "b", "c", "d"].forEach { w.cue($0) }
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.count >= 1 && w.writes.first?.drafts.map(\.trackUUID) == ["a", "b", "c"])
        try await w.advance(5)
        #expect(w.writes.count == 2 && w.writes.last?.drafts.map(\.trackUUID) == ["d"])
    }

    // MARK: - R16·R20 보류 사유

    @Test(arguments: [ReflectionHold.usbBusy, .linkServer, .libraryReading, .blockedDraftsOpen, .importSheetOpen, .shuttingDown, .pointSnapshot,
                      .unwritable(.counters)])
    func 앱_보류_사유가_있으면_쓰지_않는다(_ reason: ReflectionHold) async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.appHolds = [reason]
        try await w.start()
        try await w.advance(40)
        #expect(w.writes.isEmpty && w.previews.isEmpty && w.engine.conditions.holds.contains(reason))
        w.appHolds = []
        try await w.advance(1)
        #expect(w.writes.count == 1)
    }

    // MARK: - R18 실행 조건

    @Test(arguments: [AutoReflectionRun.Off.debugBuild, .explicitCopy, .diagnostic, .unsafeSelfTest])
    func 자동_저장하지_않는_실행은_쓰지_않고_수동_저장만_받는다(_ reason: AutoReflectionRun.Off) async throws {
        let w = AutoReflectionWorld()
        w.run = .off(reason)
        w.writable("a")
        w.cue("a")
        try await w.start()
        w.fakes.clock.advance(.seconds(3600))
        try await w.settle()
        #expect(w.writes.isEmpty && w.engine.status == .held(.notAutoRun(reason)))
        #expect(!w.engine.conditions.autoSaves && w.engine.conditions.hasPending)
    }

    // MARK: - R22 판 지정 정리

    @Test(arguments: [DraftOrigin.human, .cli])
    func 쓰는_도중_같은_곡에_새로_저장한_큐_초안은_쓰기_뒤에도_남는다(_ origin: DraftOrigin) async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.h.previewHold.hold()
        try await w.start()
        try await w.advance(9)
        w.fakes.clock.advance(.seconds(1))
        for _ in 0..<2000 where !w.h.previewHold.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        #expect(w.h.previewHold.isWaiting)
        // 쓰는 동안 같은 곡에 새 판(앱의 덱은 쓰는 곡을 막지만 CLI는 저장할 수 있다). 앱은 저장 대기가 바뀌면 편집 신호를 준다
        w.h.memory.save(ReflectionHarness.cue("a", at: 40), origin: origin)
        w.engine.edited()
        w.h.previewHold.release()
        try await w.settle()
        #expect(w.writes.count == 1)
        #expect(w.h.memory.cue("a")?.cues.first?.time == 40)
        // CLI가 다시 고친 초안은 출처가 섞여 제안이 된다(R5)
        #expect(w.h.memory.stamp(DraftKey(.cue, "a"))?.origins.contains(origin) == true)
    }

    @Test func 사본을_남기지_못한_미정리_목록은_남기고_다음_쓰기를_보류한다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        // 앞 쓰기가 쓴 재생 목록 단계를 바깥에서 고쳤고(해시가 다르다) 그 사본을 남기지 못한다
        let rekordbox = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가"), 1)])
        var draft = PlaylistDraft()
        _ = try draft.append(.rename(playlist: .id("A"), name: "새 이름"), rekordbox: rekordbox)
        try w.h.memory.store.savePlaylistDraft(draft)
        let disk = w.h.memory.store.playlistDraft()
        let stamp = try #require(w.h.memory.playlistStamps.first)
        let hash = try DraftContentHash(step: disk.steps[0], in: disk)
        var changed = PlaylistDraft()
        _ = try changed.append(.rename(playlist: .id("A"), name: "바깥 이름"), rekordbox: rekordbox)
        changed.setStepIDs(disk.stepIDs)
        w.h.memory.editPlaylistOutside(changed)
        w.h.memory.failPlaylistCopies()
        w.h.script.cleanupLists = [DraftCleanupList(operationID: "op-1", target: MemoryWriteLocks.key(for: w.h.session.target.database),
                                                    draftHome: "/drafts", backupFolder: "w1",
                                                    playlistSteps: [.init(revision: stamp.revision, contentHash: hash, outcome: .written)])]
        try await w.start()
        try await w.advance(30)
        #expect(w.writes.isEmpty && w.h.gateCalls.value.removedCleanupLists.isEmpty)
        #expect(w.engine.conditions.holds.contains(.playlistCopyFailed) || w.engine.conditions.holds.contains(.cleanupPending))
        // 사본을 남길 수 있게 되면 다음 정리 때 다시 하고 쓴다
        w.h.memory.failPlaylistCopies(false)
        try await w.advance(2)
        // 남은 목록을 먼저 정리해 지운 뒤 쓴다(그 쓰기도 정리를 마치고 자기 목록을 지운다)
        #expect(w.h.gateCalls.value.removedCleanupLists.first == "op-1" && w.writes.count == 1)
        let order = w.h.gateCalls.value.order
        #expect(order.firstIndex(of: "remove cleanup list")! < order.firstIndex(of: "write")!)
    }

    // MARK: - 리뷰에서 나온 경우

    @Test func 백업_전_실패는_오류_종류로_원인을_묶고_실패_뒤_곧바로_다시_쓰지_않는다() async throws {
        // 오류 문장에는 백업 폴더 경로·시각이 들어 매번 달라진다
        let first = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/backups/2026-11-24T100000-write"])
        let second = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/backups/2026-11-24T100001-write"])
        #expect(AutoReflection.failureCause(first) == AutoReflection.failureCause(second))
        #expect(AutoReflection.failureCause(DJCError.writeRefused("가")) == AutoReflection.failureCause(DJCError.writeRefused("나")))
        #expect(AutoReflection.failureCause(DJCError.writeRefused("가")) != AutoReflection.failureCause(DJCError.snapshotNotFound))
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.h.script.writeError = first
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.count == 1, "실패 뒤 쉬지 않고 다시 쓰지 않는다")
        try await w.advance(1)
        #expect(w.writes.count == 2 && w.engine.status == .held(.preBackupFailure))
    }

    @Test func 쓴_뒤_정리를_마치지_못하면_다음_쓰기_전에_다시_하고_그때까지_보류한다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.h.failingRemoveWritten = true
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.count == 1 && w.h.gateCalls.value.removedCleanupLists.isEmpty, "정리를 마치지 못해 목록이 남는다")
        try await w.advance(5)
        #expect(w.writes.count == 1 && w.engine.conditions.holds.contains(.cleanupPending))
        w.h.failingRemoveWritten = false
        try await w.advance(2)
        #expect(w.h.gateCalls.value.removedCleanupLists.count == 1 && w.h.memory.cue("a") == nil)
        #expect(w.writes.count == 1 && w.engine.status == .saved)
    }

    @Test func 정리를_마치지_못한_목록이_있으면_수동_저장도_쓰지_않고_알린다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        let stamp = try #require(w.h.memory.stamp(DraftKey(.cue, "a")))
        let written = WrittenDraft(key: DraftKey(.cue, "a"), revision: stamp.revision, contentHash: try DraftContentHash(of: ReflectionHarness.cue("a")))
        w.h.script.cleanupLists = [DraftCleanupList(operationID: "op-1", target: MemoryWriteLocks.key(for: w.h.session.target.database),
                                                    draftHome: "/drafts", backupFolder: "w1", written: [written])]
        w.h.failingRemoveWritten = true
        w.run = .off(.debugBuild)
        try await w.start()
        var ran = false
        let outcome = await w.engine.exclusive({ ran = true; return ReflectionOutcome.busy }, whenHeld: { _ in .declined })
        #expect(!ran && outcome.name == "declined")
    }

    @Test func 수동_쓰기_동안_지켜보지_못한_시간은_조용함에_잇지_않는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        w.cue("a")
        try await w.edited()
        // 확인 창을 띄운 동안(5초) rekordbox를 켰다 끄고 취소했다
        _ = await w.engine.exclusive { [fakes = w.fakes] () -> ReflectionOutcome in
            fakes.setRunState(.running)
            fakes.clock.advance(.seconds(5))
            fakes.setRunState(.stopped)
            return .declined
        }
        try await w.settle()
        try await w.advance(3)
        #expect(w.writes.isEmpty, "조용함을 처음부터 다시 센다")
        try await w.advance(8)
        #expect(w.writes.count == 1)
    }

    @Test func 미리_보기에서_막힌_재생_목록_단위_앞의_단위는_다음_판정에서_쓴다() async throws {
        let w = AutoReflectionWorld()
        var draft = PlaylistDraft()
        _ = try draft.append(.rename(playlist: .id("A"), name: "새 가"), rekordbox: Self.layout)
        _ = try draft.append(.rename(playlist: .id("B"), name: "새 나"), rekordbox: Self.layout)
        try w.h.memory.store.savePlaylistDraft(draft)
        w.h.state.rekordboxPlaylists = Self.layout
        w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        // B는 이 Mac의 사본에서는 쓸 수 있지만 새로 뜬 사본에서 막힌다
        w.h.script.preview.playlistOutcomes = [PlaylistOutcome(edit: draft.steps[0].edit, playlistID: "A", name: "새 가", status: .written),
                                               PlaylistOutcome(edit: draft.steps[1].edit, playlistID: "B", name: "나", status: .blocked,
                                                               reason: "바뀜")]
        try await w.start()
        try await w.advance(12)
        let batch = try #require(w.writes.first)
        #expect(w.writes.count == 1 && batch.playlists?.steps.map(\.edit) == [draft.steps[0].edit])
        #expect(w.engine.conditions.leftovers.contains(.needsConfirmation))
    }

    @Test func 중단은_가끔_다시_판정해_바깥에서_정리되면_이어진다() async throws {
        let w = AutoReflectionWorld()
        let finding = RekordboxJournalFinding(journal: RekordboxWriteJournal(operationID: "op", kind: .counter, entry: .drafts), changedSince: false,
                                              database: nil)
        w.h.script.journal = .interrupted(finding)
        w.writable("a")
        w.cue("a")
        try await w.start()
        try await w.advance(5)
        // CLI가 기록을 정리했다(엔진이 쓰는 관문의 기록)
        #expect(try w.engine.session.ports.gate.keepJournal(w.engine.session.target, finding.request) {} == .kept)
        try await w.advance(50)
        #expect(w.writes.isEmpty)
        try await w.advance(10)
        #expect(w.writes.count == 1)
    }

    @Test func 수동_저장이_백업_뒤_검증에_실패해_되돌려져도_멈춘다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        try await w.start()
        _ = await w.engine.exclusive {
            ReflectionOutcome.failed(title: "실패", error: DJCError.writeRolledBack("검증"), exclusions: [])
        }
        try await w.settle()
        try await w.advance(20)
        #expect(w.writes.isEmpty && w.engine.status == .stopped(.stoppedAfterFailure))
    }
}
