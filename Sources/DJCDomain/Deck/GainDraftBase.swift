import Foundation

/// 게인 초안의 base(R23, #405): 초안을 만들 때 본 rekordbox 오토게인(dB)과 rekordbox 실행 경계, 그 base가 묶인 게인 값의 판.
/// 판이 지금 게인 값의 판과 다르거나 실행 경계가 지금과 다르면(만든 뒤 rekordbox가 켜졌거나 알 수 없다) base 없는 초안으로 본다(자동으로 쓰지 않는다)
public struct GainDraftBase: Codable, Hashable, Sendable {
    /// 초안을 만들 때 본 rekordbox 오토게인(dB). 쓰기 입구가 지금 값과 견준다
    public var db: Double
    /// 만들 때의 rekordbox 실행 경계(없으면 모름)
    public var run: String?
    /// 이 base가 묶인 게인 값의 판(값보다 뒤에 같은 초안 잠금 안에서 적는다)
    public var revision: DraftRevision?

    public init(db: Double, run: String?, revision: DraftRevision? = nil) {
        self.db = db
        self.run = run
        self.revision = revision
    }
}
