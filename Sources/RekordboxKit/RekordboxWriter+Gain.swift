import DJCDomain
import Foundation

/// 오토게인 쓰기(djmdMixerParam)
extension RekordboxWriter {
    public static func gainDrafts(in backup: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: backup.appending(path: "gain-drafts.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
    }

    /// 오토게인을 고친 행이 쓴 뒤 가져야 할 칸(트랜잭션 안과 커밋 뒤에 다시 읽어 비교한다)
    struct GainExpectation {
        var title: String
        var rowID: String
        var columns: [String: CipherDatabase.Value]
    }

    /// 오토게인 한 곡(流れ行く命 −3.3→+0.65dB 실험과 같은 칸): GainHigh·GainLow·상태 256→257·rb_local_usn·updated_at
    static func applyGain(uuid: String, gainDB: Double, db: CipherDatabase, usn: inout Int,
                          stamp: (db: String, json: String)) throws -> (outcome: Outcome, expectation: GainExpectation) {
        var content: (id: String, title: String)?
        try db.query("SELECT ID, Title FROM djmdContent WHERE UUID = ? AND rb_local_deleted = 0", [.text(uuid)]) { content = ($0.string(0) ?? "", $0.string(1) ?? "") }
        guard let content else { throw Blocked(title: uuid, reason: String(ui: "rekordbox 컬렉션에서 곡을 찾지 못했으니 컬렉션에서 곡을 확인한 뒤 DJCrate에서 다시 동기화하세요")) }
        guard gainDB.isFinite, (-24...24).contains(gainDB) else { throw Blocked(title: content.title, reason: String(ui: "게인이 범위를 벗어납니다")) }
        var rows: [(id: String, status: CipherDatabase.Value)] = []
        try db.query("SELECT ID, rb_data_status FROM djmdMixerParam WHERE ContentID = ? AND rb_local_deleted = 0", [.text(content.id)]) {
            rows.append(($0.string(0) ?? "", raisedStatus($0.int(1))))
        }
        guard rows.count == 1, let row = rows.first else {
            throw Blocked(title: content.title, reason: rows.isEmpty ? String(ui: "rekordbox 오토게인 값이 없는 곡입니다(분석 전)") : String(ui: "오토게인 행이 여럿입니다"))
        }
        let value = Float(pow(10, gainDB / 20))
        let (high, low) = RekordboxAutoGain.halves(value)
        usn += 1
        try db.run("""
            UPDATE djmdMixerParam SET GainHigh = ?, GainLow = ?,
                \(savedStatus),
                rb_local_usn = ?, updated_at = ? WHERE ID = ?
            """, [.int(high), .int(low), .int(usn), .text(stamp.db), .text(row.id)])
        let expectation = GainExpectation(title: content.title, rowID: row.id, columns: [
            "GainHigh": .int(high), "GainLow": .int(low), "rb_data_status": row.status, "rb_local_usn": .int(usn), "updated_at": .text(stamp.db),
        ])
        try verifyGain(db: db, expectation)
        let outcome = Outcome(trackUUID: uuid, title: content.title, status: .written, reason: nil, removed: 0, added: Int((gainDB * 100).rounded()))
        return (outcome, expectation)
    }

    /// 오토게인 행이 쓴 그대로인지 다시 읽어 확인한다(트랜잭션 안과 커밋 뒤).
    static func verifyGain(db: CipherDatabase, _ expected: GainExpectation) throws {
        do {
            try RekordboxTrackWriter.verify(db, table: "djmdMixerParam", id: expected.rowID, expected.columns)
        } catch DJCError.writeVerificationFailed {
            throw DJCError.writeVerificationFailed(String(ui: "오토게인 확인 실패 (\(expected.title))"))
        }
    }
}
