import DJCDomain
import Foundation

/// 쓰기 도움 함수(변경 카운터·새 큐 ID·Kind·ms·검증 키)
extension RekordboxWriter {
    // MARK: - 도움

    static func localUpdateCount(_ db: CipherDatabase) throws -> Int {
        var values: [Int] = []
        try db.query("SELECT int_1 FROM agentRegistry WHERE registry_id = 'localUpdateCount'") { values.append($0.int(0) ?? -1) }
        guard values.count == 1, let value = values.first, value > 0 else {
            throw DJCError.writeRefused(String(ui: "rekordbox 변경 카운터를 찾지 못했습니다"))
        }
        // 카운터는 지금까지 나눠 준 번호보다 작으면 안 된다.
        let issued = max(try scalar(db, "SELECT ifnull(max(rb_local_usn), 0) FROM djmdContent", []) ?? 0,
                         try scalar(db, "SELECT ifnull(max(rb_local_usn), 0) FROM contentCue", []) ?? 0)
        guard issued <= value else { throw DJCError.writeRefused(String(ui: "rekordbox 변경 카운터가 예상과 다릅니다")) }
        try RekordboxCompatibility.checkCounters(local: value, cloud: RekordboxCompatibility.updateCounters(db).cloud)
        return value
    }

    /// 고친 행의 동기화 상태 칸: 256 → 257, 0·257은 그대로(docs/rekordbox-internals.md "공통: 변경 번호")
    static let savedStatus = "rb_data_status = CASE rb_data_status WHEN 256 THEN 257 ELSE rb_data_status END"
    /// `savedStatus`의 Swift 쪽(쓴 뒤 기대하는 상태)
    static func savedState(_ state: Int) -> Int { state == 256 ? 257 : state }
    static func savedState(_ state: Int?) -> Int? { state.map(savedState) }

    static func scalar(_ db: CipherDatabase, _ sql: String, _ values: [CipherDatabase.Value]) throws -> Int? {
        var result: Int?
        try db.query(sql, values) { result = $0.int(0) }
        return result
    }

    /// rekordbox처럼 32비트 난수 ID(겹치지 않게).
    static func newCueID(_ db: CipherDatabase) throws -> String {
        for _ in 0..<100 {
            let id = String(UInt32.random(in: 1...UInt32.max))
            if try scalar(db, "SELECT count(*) FROM djmdCue WHERE ID = ?", [.text(id)]) == 0 { return id }
        }
        throw DJCError.writeVerificationFailed(String(ui: "새 큐 ID를 만들지 못했습니다"))
    }

    /// 편집 큐 종류 → rekordbox Kind(메모리 0, 핫큐 A…H = 1,2,3,5,6,7,8,9)
    static func kind(for kind: EditableCue.Kind) -> Int {
        switch kind {
        case .memory: 0
        case let .hot(slot): [1, 2, 3, 5, 6, 7, 8, 9][slot]
        }
    }

    static func msec(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

    /// 쓴 뒤 rekordbox에 있어야 할 편집 큐. 초안이 바꾸지 않은 큐는 `base`(= 지금 rekordbox 값) 그대로다.
    /// `CueDraft.changes`는 1ms 미만 차이를 무시하므로(그리드 따라가기로 조금 움직인 큐) 초안 시각을 그대로 반올림하면
    /// rekordbox 값과 1ms 어긋날 수 있다(#73).
    public static func expectedCues(after draft: CueDraft) -> [EditableCue] {
        var replaced: Set<EditableCue.ID> = []
        var inserted: [EditableCue] = []
        for change in draft.changes {
            switch change {
            case let .removed(old): replaced.insert(old.id)
            case let .modified(old, new): replaced.insert(old.id); inserted.append(new)
            case let .added(new): inserted.append(new)
            }
        }
        return draft.base.filter { !replaced.contains($0.id) } + inserted
    }

    /// 큐 목록 비교용 열쇠(순서 무관)
    public static func key(_ cues: [EditableCue], withSource: Bool) -> [String] {
        cues.map { cue in
            let kind = switch cue.kind { case .memory: "m"; case let .hot(slot): "h\(slot)" }
            // 루프는 끝·활성·박 수까지 (루프가 아니면 예전과 같은 키)
            let loop = cue.loop.map { "|L\(msec($0.end))|\($0.active ? "a" : "-")|\(EditableCue.Loop.beatLoopSize(beats: $0.beats))" } ?? ""
            return (withSource ? (cue.sourceID ?? "-") + "|" : "") + "\(kind)|\(msec(cue.time))|\(cue.name)" + loop
        }.sorted()
    }
}
