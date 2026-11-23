import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Testing

/// 초안 출처(R5)를 포트 조립이 정한다: CLI `djc draft`는 CLI, CDJ가 LINK로 보낸 큐 편집은 LINK. 앱의 편집 포트는 사람 편집이라
/// 사람이 한 초안만 자동 저장 대상이고, 나머지는 제안이다. 파일 없이 가짜 포트로 본다(실제 저장소는 DJCAdaptersTests).
@MainActor
@Suite("초안 출처와 제안 판정(가짜)")
struct DraftFilesOriginTests {
    @Test func 곡별_초안_파일_도장_계약() throws {
        let files = MemoryDraftFiles()
        try draftFilesStampContract({ files.files(origin: $0) }, editOutside: { files.put($0) })
    }

    @Test func 초안_파일_포트의_출처는_조립이_정한다() {
        let files = MemoryDraftFiles()
        // 정하지 않은 포트는 모름이다(제안)
        #expect(files.files.origin == .unknown)
        #expect(files.files(origin: .cli).origin == .cli && files.files.with(origin: .link).origin == .link)
        var bare = files.files
        bare.originVariant = nil
        #expect(bare.with(origin: .cli).origin == .cli)
    }

    /// 시험 셋 1(CLI 쪽): `djc draft`가 만든 큐·태그 초안은 CLI 출처다
    @Test func djc_draft가_만든_초안은_CLI_출처이고_제안이다() throws {
        let files = MemoryDraftFiles()
        let edits = EditDraftFiles(files: files.files(origin: .cli))
        let request = EditDraftFiles.CueRequest(time: 10, loopEnd: nil, beats: nil, slot: 1, name: "B", active: false)
        _ = try edits.addCue({ request }, track: EditDraftFilesTests.track, rekordboxCues: [], dryRun: false)
        var values: [TagFields.Key: String] = [:]
        values[.comment] = "AI가 고침"
        _ = try edits.setTags(values, track: EditDraftFilesTests.track, colors: [], inPlaylist: false, dryRun: false)
        let cue = try #require(files.stamp(DraftKey(.cue, "u7"))), tag = try #require(files.stamp(DraftKey(.tag, "u7")))
        #expect(cue.origins == [.cli] && tag.origins == [.cli])
        #expect(try DraftSuggestion.judge(stamp: cue, currentHash: DraftContentHash(of: #require(files.cue("u7")))) == .notHuman)
        // 미리 보기는 저장하지 않으니 도장도 없다
        let preview = MemoryDraftFiles()
        _ = try EditDraftFiles(files: preview.files(origin: .cli)).addCue({ request }, track: EditDraftFilesTests.track, rekordboxCues: [], dryRun: true)
        #expect(preview.stamp(DraftKey(.cue, "u7")) == nil)
    }

    @Test func LINK로_받은_큐_편집은_LINK_출처로_적는다() async throws {
        let files = MemoryDraftFiles()
        // 조립이 출처를 정하지 않아도 LINK 입구는 LINK 출처로 저장한다
        let drafts = LinkCueDrafts(edits: EditDraftFiles(files: files.files), flush: {})
        let edit = LinkCueEdit(contentID: "7", deleted: false, kind: 0, inMs: 5_000, outMs: nil, comment: "")
        #expect(try await drafts.apply(edit, track: EditDraftFilesTests.track, rekordboxCues: []) == .applied)
        #expect(files.stamp(DraftKey(.cue, "u7"))?.origins == [.link])
        // 바뀐 것이 없으면 저장하지 않으니 도장도 그대로다
        let before = files.stamp(DraftKey(.cue, "u7"))
        #expect(try await drafts.apply(edit, track: EditDraftFilesTests.track, rekordboxCues: []) == .unchanged)
        #expect(files.stamp(DraftKey(.cue, "u7")) == before)
    }

    // MARK: 제안 판정(앱 포트가 본다)

    @Test func 앱_편집_포트의_초안만_자동_저장_대상이고_나머지는_제안이다() throws {
        let memory = MemoryDrafts()
        let app = memory.store(origin: .human)
        func cue(_ uuid: String, at time: Double) -> CueDraft { ReflectionHarness.cue(uuid, at: time) }
        app.saveCue(cue("a", at: 1))
        #expect(app.suggestion(DraftKey(.cue, "a")) == nil)
        // 다른 출처가 고치면 섞인 초안이다
        memory.store(origin: .cli).saveCue(cue("a", at: 2))
        #expect(app.suggestion(DraftKey(.cue, "a")) == .mixedOrigins)
        // 출처가 사람이 아니면 제안이다
        memory.store(origin: .link).saveCue(cue("b", at: 1))
        #expect(app.suggestion(DraftKey(.cue, "b")) == .notHuman)
        // 바깥이 파일만 고치면 해시가 어긋난다
        app.saveCue(cue("c", at: 1))
        memory.editOutside(cue("c", at: 9))
        #expect(app.suggestion(DraftKey(.cue, "c")) == .contentChanged)
        // 없는 초안은 제안이 아니다
        #expect(app.suggestion(DraftKey(.cue, "없음")) == nil)
    }

    @Test func 모든_종류의_지금_해시를_포트로_읽는다() throws {
        let memory = MemoryDrafts()
        let app = memory.store(origin: .human)
        app.saveCue(ReflectionHarness.cue("a"))
        app.saveGain(-3, trackUUID: "a")
        var tag = TagDraft(trackUUID: "a", base: TagFields())
        tag.fields.comment = "x"
        app.saveTags([tag])
        app.saveGrid(GridDraft(trackUUID: "a", base: [], segments: [GridSegment(start: 1, bpm: 130, firstBeatNumber: 1)]))
        for kind in [DraftKey.Kind.cue, .grid, .gain, .tag] {
            let key = DraftKey(kind, "a")
            #expect(app.currentHash(key) == memory.stamp(key)?.contentHash && app.currentHash(key) != nil, "\(kind)")
        }
        #expect(app.currentHash(DraftKey(.cue, "없음")) == nil && app.currentHash(DraftKey(.artwork, "a")) == nil)
    }

    @Test func 재생_목록_단계_제안은_단계_차례대로_돌려준다() throws {
        let memory = MemoryDrafts()
        let rekordbox = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가"), 1), (PlaylistLayout.Item(id: "B", name: "나"), 2)])
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["9"]), rekordbox: rekordbox)
        try memory.store(origin: .human).savePlaylistDraft(draft)
        try draft.append(.rename(playlist: .id("B"), name: "새"), rekordbox: rekordbox)
        try memory.store(origin: .cli).savePlaylistDraft(draft)
        #expect(memory.store.playlistSuggestions() == [nil, .notHuman])
    }

    /// 재생 목록 단계 식별자 계약(S1~S3)을 가짜에 돌린다. 실제 저장소는 DJCAdaptersTests가 같은 함수로 돌린다
    @Test func 재생_목록_단계_식별자_계약() throws {
        let drafts = MemoryDrafts()
        try playlistStepIdentityContract(human: drafts.store(origin: .human), cli: drafts.store(origin: .cli),
                                         rawWrite: { drafts.editPlaylistOutside($0) }, restart: { drafts.store(origin: .human) },
                                         backups: URL(filePath: "/backups"))
    }
}
