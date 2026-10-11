import DJCDomain
import Foundation

// 쓰기 경로가 rekordbox 큐로 편집용 큐·초안을 만들 때 새 무작위 ID를 붙인다. 순수 규칙(DJCDomain)은 ID를 받아서만 만든다(#167).
// 쓰기 관문 파일(`RekordboxWriter+Cues`·`+Verify`·`+Merge`, `RekordboxTrackWriter`)은 고치지 않으려고 둔 모양이다(`DuplicateMerge+IDs`와 같다).

extension EditableCue {
    /// rekordbox 큐 → 편집용(새 무작위 ID). 편집할 수 없는 큐(Kind 4)는 nil
    public init?(_ cue: Cue) {
        self.init(cue, id: UUID())
    }
}

extension CueDraft {
    /// rekordbox 큐로 시작하는 초안(큐마다 새 무작위 ID)
    public init(trackUUID: String, rekordboxCues: [Cue]) {
        self.init(trackUUID: trackUUID, rekordboxCues: rekordboxCues, newID: { UUID() })
    }

    /// 자동 큐를 채운다(채우는 큐마다 새 무작위 ID)
    public func includingAutoCues(from rekordboxCues: [Cue]) -> CueDraft {
        includingAutoCues(from: rekordboxCues, newID: { UUID() })
    }
}
