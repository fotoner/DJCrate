import DJCDomain
import Foundation

extension DuplicateMerge {
    /// 옮긴 큐에 새 무작위 ID를 붙여 합친다(쓰기 경로가 쓴다). 순수 규칙은 ID를 받아서만 만든다(`cues(keeping:removing:newID:)`).
    public static func cues(keeping: DuplicateMergeDraft.Member, removing: [DuplicateMergeDraft.Member]) throws -> CueDraft {
        try cues(keeping: keeping, removing: removing, newID: { UUID() })
    }
}
