import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 곡 넣기로 새 곡에 옮긴 초안의 규칙(#197·#202). 되돌릴 때 새 곡에 남은 초안 가운데 넣을 때 옮긴 사본만 지우고, 사용자가 만든 것은 남긴다.
/// 옛 시험(`TrackWritePathTests`)은 합성 DB에 실제로 넣고 되돌려 같은 판정을 봤다. 넣기·되돌리기 왕복은 그쪽에 소수만 남겼다.
@Suite("곡 넣기로 옮긴 초안")
struct AddedTrackDraftsTests {
    static let new = "new-uuid", staged = "staged-uuid"

    static func cue(_ uuid: String, times: [Double]) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        for time in times { draft.place(EditableCue(kind: .memory, time: time)) }
        return draft
    }

    static func grid(_ uuid: String, bpm: Double = 120) -> GridDraft {
        GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 1, bpm: bpm, firstBeatNumber: 1)])
    }

    static func outcome(cuesWritten: Int? = 1, keyReason: String? = nil) -> RekordboxTrackWriteOutcome {
        var outcome = RekordboxTrackWriteOutcome(path: "/a.mp3", contentID: "1", title: "곡", written: true)
        outcome.uuid = new
        outcome.cuesWritten = cuesWritten
        outcome.keyReason = keyReason
        return outcome
    }

    static func keyDraft(_ key: String, comment: String? = nil) -> TagDraft {
        var draft = TagDraft(trackUUID: new, base: TagFields())
        draft.fields.musicalKey = key
        if let comment { draft.fields.comment = comment }
        return draft
    }

    @Test func 옮긴_모양은_큐의_출처를_지우고_그리드의_기준을_비운다() {
        var source = Self.cue(Self.staged, times: [1, 2])
        source.cues[0].sourceID = "old"
        let moved = AddedTrackDrafts.movedCueDraft(from: source, to: Self.new)
        #expect(moved.trackUUID == Self.new && moved.cues.count == 2 && moved.cues.allSatisfy { $0.sourceID == nil })
        var grid = Self.grid(Self.staged)
        grid.base = [GridSegment(start: 0, bpm: 100, firstBeatNumber: 1)]
        let movedGrid = AddedTrackDrafts.movedGridDraft(from: grid, to: Self.new)
        #expect(movedGrid.trackUUID == Self.new && movedGrid.base.isEmpty && movedGrid.segments == grid.segments)
    }

    @Test func 키가_막히면_쓰기_결과의_태그_값을_기준으로_새_곡의_키_초안을_만든다() {
        var blocked = Self.outcome(keyReason: "12B 줄이 없음")
        blocked.keyBase = TagFields()
        var written = Self.outcome()
        written.path = "/b.mp3"
        written.keyWritten = "8A"
        var report = RekordboxTrackWriteReport(dryRun: false)
        report.added = [blocked, written]
        let drafts = AddedTrackDrafts.blockedKeyDrafts(report, keys: ["/a.mp3": "12B", "/b.mp3": "8A"])
        #expect(drafts.count == 1 && drafts.first?.trackUUID == Self.new)
        #expect(drafts.first?.changedKeys == [.musicalKey] && drafts.first?.fields.musicalKey == "12B" && drafts.first?.base == TagFields())
    }

    // MARK: 되돌릴 때

    @Test func 넣을_때_옮긴_큐_그리드_사본은_지운다() {
        let stagedCue = Self.cue(Self.staged, times: Array(0..<11).map { Double($0) + 0.5 }), stagedGrid = Self.grid(Self.staged)
        let leftover = AddedTrackDrafts.Leftover(cue: AddedTrackDrafts.movedCueDraft(from: stagedCue, to: Self.new),
                                                 grid: AddedTrackDrafts.movedGridDraft(from: stagedGrid, to: Self.new))
        #expect(AddedTrackDrafts.kept(after: Self.outcome(cuesWritten: nil), leftover: leftover, stagedCue: stagedCue, stagedGrid: stagedGrid,
                                      stagedKey: nil).isEmpty)
    }

    @Test func 넣은_뒤_새_곡에_만들거나_고친_큐_그리드는_남긴다() {
        let stagedCue = Self.cue(Self.staged, times: [1])
        var edited = AddedTrackDrafts.movedCueDraft(from: stagedCue, to: Self.new)
        edited.place(EditableCue(kind: .hot(0), time: 1.25))
        let leftover = AddedTrackDrafts.Leftover(cue: edited, grid: Self.grid(Self.new, bpm: 125))
        #expect(AddedTrackDrafts.kept(after: Self.outcome(cuesWritten: nil), leftover: leftover, stagedCue: stagedCue, stagedGrid: Self.grid(Self.staged),
                                      stagedKey: nil) == [.cue, .grid])
        // 큐를 넣었으면(옮기지 않았으면) 새 곡의 큐 초안은 옮긴 사본일 수 없다
        let copy = AddedTrackDrafts.Leftover(cue: AddedTrackDrafts.movedCueDraft(from: stagedCue, to: Self.new))
        #expect(AddedTrackDrafts.kept(after: Self.outcome(cuesWritten: 1), leftover: copy, stagedCue: stagedCue, stagedGrid: nil, stagedKey: nil) == [.cue])
        // 옛 백업이라 추가한 곡의 초안이 없으면 사본인지 알 수 없어 남긴다
        #expect(AddedTrackDrafts.kept(after: Self.outcome(cuesWritten: nil), leftover: copy, stagedCue: nil, stagedGrid: nil, stagedKey: nil) == [.cue])
    }

    @Test func 변경이_없는_초안은_남기지_않는다() {
        let leftover = AddedTrackDrafts.Leftover(cue: CueDraft(trackUUID: Self.new),
                                                 grid: GridDraft(trackUUID: Self.new, base: [], segments: []))
        #expect(AddedTrackDrafts.kept(after: Self.outcome(), leftover: leftover, stagedCue: nil, stagedGrid: nil, stagedKey: nil).isEmpty)
    }

    @Test func 옮겨_둔_키만_있는_태그_초안은_추가_목록_곡의_키와_같을_때만_지운다() {
        let blocked = Self.outcome(keyReason: "키 줄 없음")
        let moved = AddedTrackDrafts.Leftover(tag: Self.keyDraft("12B"))
        #expect(AddedTrackDrafts.kept(after: blocked, leftover: moved, stagedCue: nil, stagedGrid: nil, stagedKey: "12B").isEmpty)
        // 추가 목록 곡의 키를 모르면(옛 백업·버린 초안·추가 목록 저장 실패) 누가 만든 키인지 몰라 남긴다
        #expect(AddedTrackDrafts.kept(after: blocked, leftover: moved, stagedCue: nil, stagedGrid: nil, stagedKey: nil) == [.tag])
        #expect(AddedTrackDrafts.kept(after: blocked, leftover: moved, stagedCue: nil, stagedGrid: nil, stagedKey: "8A") == [.tag])
        // 넣은 뒤 다른 칸도 고쳤거나, 키가 막히지 않았는데 생긴 키 초안은 사용자 것이다
        let edited = AddedTrackDrafts.Leftover(tag: Self.keyDraft("12B", comment: "넣은 뒤 고친 코멘트"))
        #expect(AddedTrackDrafts.kept(after: blocked, leftover: edited, stagedCue: nil, stagedGrid: nil, stagedKey: "12B") == [.tag])
        #expect(AddedTrackDrafts.kept(after: Self.outcome(), leftover: moved, stagedCue: nil, stagedGrid: nil, stagedKey: "12B") == [.tag])
    }
}
