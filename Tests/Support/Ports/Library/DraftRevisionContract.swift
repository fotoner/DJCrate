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
    try editOutside(cue("b", at: 9))
    let outside = WrittenDraft(key: DraftKey(.cue, "b"), revision: stamp.revision, contentHash: stamp.contentHash)
    #expect(try human.removeWritten([outside]) == DraftRemoval(suggested: [outside]))
    #expect(human.cueDraft("b") != nil)
}
