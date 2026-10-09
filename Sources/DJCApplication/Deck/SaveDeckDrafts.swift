import DJCDomain
import Foundation

/// 덱의 큐·그리드·게인 초안 저장. 덱 화면 모델은 초안 저장소(`DraftStore`)를 들지 않고 이 유스케이스만 부른다.
/// 조립 지점이 라이브러리와 같은 초안 저장소(같은 저장 큐)로 만든다. 저장하지 못한 입력이 디스크보다 최신이다(#174).
public struct SaveDeckDrafts: Sendable {
    let drafts: DraftStore

    public init(drafts: DraftStore) {
        self.drafts = drafts
    }

    /// 새 큐 ID
    public func newCueID() -> UUID { drafts.newCueID() }

    /// 지금의 그리드 초안(저장하지 못한 입력 포함, 지우기였으면 nil)
    public func currentGrid(_ uuid: String) -> GridDraft? { drafts.currentGrid(uuid) }

    public func saveCue(_ draft: CueDraft, completion: @escaping @Sendable (DraftSaveFailure?) -> Void) {
        drafts.saveCue(draft, completion)
    }

    public func saveGrid(_ draft: GridDraft, completion: @escaping @Sendable (DraftSaveFailure?) -> Void) {
        drafts.saveGrid(draft, completion)
    }

    public func removeGrid(_ uuid: String, completion: @escaping @Sendable (DraftSaveFailure?) -> Void) {
        drafts.removeGrid(uuid, completion: completion)
    }

    public func saveGain(_ gain: Double?, trackUUID: String, completion: @escaping @Sendable (DraftSaveFailure?) -> Void) {
        drafts.saveGain(gain, trackUUID, completion)
    }

    /// 실패한 마지막 입력(저장이든 지우기든)을 그대로 다시 저장한다
    public func retry(_ kind: DraftSaveKind, trackUUID: String, completion: @escaping @Sendable (DraftSaveFailure?) -> Void) {
        _ = drafts.retry(kind, trackUUID, completion)
    }

    /// 그 곡의 지금 저장 실패: 덱이 받은 실패 가운데 뒤의 저장으로 해소되지 않은 것(목록에서 복구하거나 되돌려 덱 밖에서 해소된 실패는 뺀다)에
    /// 덱이 받지 못한 종류의 저장소 실패를 더한다.
    public func currentFailures(_ uuid: String, reported: [DraftSaveFailure]) -> [DraftSaveFailure] {
        let reported = reported.filter { $0.trackUUID == uuid && !drafts.isResolved($0) }
        let known = drafts.failures().filter { $0.trackUUID == uuid }
        return reported + known.filter { failure in !reported.contains { $0.kind == failure.kind } }
    }
}
