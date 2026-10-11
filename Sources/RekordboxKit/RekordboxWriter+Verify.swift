import DJCDomain
import Foundation

/// 쓴 뒤 다시 읽어 검증·무결성 검사
extension RekordboxWriter {
    // MARK: - 검증

    /// 곡 하나가 의도한 상태인지 다시 읽어 확인한다(쓰기 트랜잭션 안과 커밋 뒤 두 번).
    static func verify(db: CipherDatabase, contentID: String, _ expected: Expectation) throws {
        func fail(_ reason: String) -> DJCError { .writeVerificationFailed("\(reason) (ContentID \(contentID))") }
        var rows: [CueRow] = []
        try db.query("""
            SELECT ID, Kind, InMsec, OutMsec, Comment, ColorTableIndex, ActiveLoop, BeatLoopSize FROM djmdCue WHERE ContentID = ?
            """, [.text(contentID)]) { r in
            rows.append(CueRow(id: r.string(0) ?? "", kind: r.int(1) ?? -1, inMsec: r.int(2) ?? 0, outMsec: r.int(3) ?? 0,
                               comment: r.string(4) ?? "", color: nil, colorTableIndex: r.int(5), activeLoop: r.int(6) ?? 0,
                               beatLoopSize: r.int(7) ?? 0,
                               inMpegFrame: 0, hasSeekInfo: false, deleted: false))
        }
        guard Set(rows.map(\.id)) == expected.untouchedIDs.union(expected.insertedIDs), rows.count == Set(rows.map(\.id)).count else {
            throw fail(String(ui: "큐 행 구성이 다릅니다"))
        }
        let editable = rows.map(\.cue).compactMap(EditableCue.init)
        guard key(editable, withSource: false) == expected.editable else { throw fail(String(ui: "큐 위치·종류가 초안과 다릅니다")) }
        // 새 큐의 탐색 칸(VBR MP3 MPEG 위치·FLAC SeekInfo)이 계산한 값 그대로인지
        for (id, seek) in expected.insertedSeek {
            var stored: [String] = []
            try db.query("""
                SELECT InMpegFrame, InMpegAbs, OutMpegFrame, OutMpegAbs, InPointSeekInfo, OutPointSeekInfo FROM djmdCue WHERE ID = ?
                """, [.text(id)]) { r in stored = (0..<6).map { r.string(Int32($0)) ?? "NULL" } }
            guard stored == seek else { throw fail(String(ui: "새 큐의 탐색 위치가 계산과 다릅니다")) }
        }

        var records: [(cues: String?, count: Int?, usn: Int?)] = []
        try db.query("SELECT Cues, rb_cue_count, rb_local_usn FROM contentCue WHERE ContentID = ?", [.text(contentID)]) { r in
            records.append((r.string(0), r.int(1), r.int(2)))
        }
        guard records.count == 1, let record = records.first, let text = record.cues,
              let objects = try? CueJSON.parse(text) else { throw fail(String(ui: "큐 기록(JSON)을 읽지 못했습니다")) }
        guard CueJSON.serialize(objects) == text else { throw fail(String(ui: "큐 기록(JSON) 모양이 rekordbox와 다릅니다")) }
        guard record.count == objects.count, record.usn == expected.cueUSN else { throw fail(String(ui: "큐 기록의 개수·변경 번호가 다릅니다")) }
        var seen: Set<String> = []
        for object in objects {
            guard case let .string(id)? = object["ID"], seen.insert(id).inserted else { throw fail(String(ui: "큐 기록에 ID가 없거나 겹칩니다")) }
            if let original = expected.untouchedJSON[id] {
                guard CueJSON.serialize([object]) == original else { throw fail(String(ui: "건드리지 않은 큐 기록이 바뀌었습니다")) }
            } else {
                guard expected.insertedIDs.contains(id) else { throw fail(String(ui: "모르는 큐 기록이 있습니다")) }
                // 새 큐는 JSON이 행의 모든 칸과 같아야 하고 칸 순서도 rekordbox와 같아야 한다.
                let columns = try rowValues(db: db, cueID: id)
                guard object.fields.map(\.key) == CueJSON.keyOrder.filter({ columns[$0] != nil }),
                      object.fields.allSatisfy({ columns[$0.key] == $0.value }) else { throw fail(String(ui: "새 큐의 기록(JSON)이 행과 다릅니다")) }
            }
        }
        guard seen == Set(rows.map(\.id)) else { throw fail(String(ui: "큐 기록(JSON)과 큐 행이 다릅니다")) }

        let contentUSN = try scalar(db, "SELECT rb_local_usn FROM djmdContent WHERE ID = ?", [.text(contentID)])
        guard contentUSN == expected.contentUSN else { throw fail(String(ui: "곡의 변경 번호가 다릅니다")) }
    }

    /// 큐 행의 값(NULL 칸은 뺀다). 시각은 JSON 형식으로 바꾼다.
    static func rowValues(db: CipherDatabase, cueID: String) throws -> [String: CueJSON.Value] {
        var values: [String: CueJSON.Value] = [:]
        let columns = CueJSON.keyOrder
        try db.query("SELECT " + columns.map { "\"\($0)\"" }.joined(separator: ", ") + " FROM djmdCue WHERE ID = ?", [.text(cueID)]) { r in
            for (index, column) in columns.enumerated() {
                if CueJSON.stringKeys.contains(column) {
                    guard var text = r.string(Int32(index)), !(column == "Comment" && text.isEmpty) else { continue }
                    if column == "created_at" || column == "updated_at" {
                        text = text.replacingOccurrences(of: " +", with: "+").replacingOccurrences(of: " ", with: "T")
                    }
                    values[column] = .string(text)
                } else if let number = r.int(Int32(index)) {
                    values[column] = .int(number)
                }
            }
        }
        return values
    }

    /// 파일 전체 무결성(SQLite 구조 + SQLCipher 페이지 인증).
    static func checkIntegrity(of database: URL) throws {
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
        var quick: [String] = []
        try db.query("PRAGMA quick_check") { quick.append($0.string(0) ?? "") }
        guard quick == ["ok"] else { throw DJCError.writeVerificationFailed(String(ui: "무결성 검사 실패: \(quick.prefix(3).joined(separator: " / "))")) }
        var cipher: [String] = []
        try db.query("PRAGMA cipher_integrity_check") { cipher.append($0.string(0) ?? "") }
        guard cipher.isEmpty else { throw DJCError.writeVerificationFailed(String(ui: "암호 페이지 검사 실패: \(cipher.prefix(3).joined(separator: " / "))")) }
    }
}
