import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 곡별 초안 파일(`DraftFiles`, CLI `djc draft`·XML 가져오기·LINK 큐)의 도장 계약(R5): 저장하면 포트의 출처·새 판·읽은 내용의 해시를 적고,
/// 다른 출처가 고치면 출처가 모이고, 고친 것이 없는 저장·삭제는 도장도 지운다. 가짜(`MemoryDraftFiles`)는 DJCApplicationTests가,
/// 실제 구현은 DJCAdaptersTests가 같은 함수로 돌린다.
/// - Parameters:
///   - make: 같은 저장소를 그 출처로 읽고 쓰는 포트
///   - editOutside: 바깥(도장을 적지 않는 프로세스)이 큐 초안 파일 내용만 고치는 일
public func draftFilesStampContract(_ make: (DraftOrigin) -> DraftFiles, editOutside: (CueDraft) throws -> Void) throws {
    let bare = make(.unknown), cli = make(.cli), human = make(.human)
    #expect(bare.origin == .unknown && cli.origin == .cli && human.origin == .human)
    func cue(_ uuid: String, at time: Double) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.cues = [EditableCue(id: cli.newCueID(), sourceID: nil, kind: .memory, time: time)]
        return draft
    }
    #expect(cli.stamp(DraftKey(.cue, "a")) == nil)

    // 저장하면 출처·판·읽은 내용의 해시를 적는다
    try cli.saveCue(cue("a", at: 1))
    let first = try #require(cli.stamp(DraftKey(.cue, "a")))
    let saved = try #require(try cli.cue("a"))
    let savedHash = try DraftContentHash(of: saved)
    #expect(first.origins == [.cli] && first.contentHash == savedHash)

    // 다른 출처가 고치면 새 판이고 출처가 모인다(사람 편집과 섞이면 제안이다)
    try human.saveCue(cue("a", at: 2))
    let second = try #require(cli.stamp(DraftKey(.cue, "a")))
    #expect(second.revision > first.revision && second.origins == [.cli, .human] && !second.isHumanOnly)

    // 곡·종류가 달라도 판은 겹치지 않는다
    try cli.saveGrid(GridDraft(trackUUID: "a", base: [GridSegment(start: 0.1, bpm: 120, firstBeatNumber: 1)],
                               segments: [GridSegment(start: 0.2, bpm: 124, firstBeatNumber: 1)]))
    var tag = TagDraft(trackUUID: "a", base: TagFields())
    tag.fields.comment = "코멘트"
    try cli.saveTag(tag)
    let revisions = [second.revision, try #require(cli.stamp(DraftKey(.grid, "a"))).revision, try #require(cli.stamp(DraftKey(.tag, "a"))).revision]
    #expect(Set(revisions).count == 3)

    // 출처를 정하지 않은 포트는 모름이다(제안)
    try bare.saveCue(cue("b", at: 1))
    #expect(bare.stamp(DraftKey(.cue, "b"))?.origins == [.unknown])

    // 바깥이 내용만 고치면(도장을 적지 않는다) 도장은 그대로이고 지금 내용의 해시가 어긋난다
    let before = try #require(bare.stamp(DraftKey(.cue, "b")))
    try editOutside(cue("b", at: 9))
    #expect(bare.stamp(DraftKey(.cue, "b")) == before)
    let current = try #require(try bare.cue("b"))
    let currentHash = try DraftContentHash(of: current)
    #expect(before.contentHash != currentHash)

    // 고친 것이 없는 저장과 삭제는 도장도 지운다
    try cli.saveCue(CueDraft(trackUUID: "a"))
    #expect(try cli.cue("a") == nil && cli.stamp(DraftKey(.cue, "a")) == nil)
    try cli.removeTag("a")
    #expect(try cli.tag("a") == nil && cli.stamp(DraftKey(.tag, "a")) == nil)
    // 지운 뒤 다시 만들면 이전 출처를 이어받지 않는다
    try human.saveCue(cue("a", at: 3))
    #expect(human.stamp(DraftKey(.cue, "a"))?.origins == [.human])
}
