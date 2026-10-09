import DJCDomain
import Foundation

/// 사본 DB의 구조(CREATE 문)와 DB 버전(`djc schema-dump`: 시험 픽스처의 스키마를 뽑는다). 데이터는 한 줄도 읽지 않는다.
public enum RekordboxSchema {
    /// 표를 먼저, 그다음 색인·트리거를 이름 순으로. 버전을 읽지 못하면 "?"
    public static func dump(database path: String) throws -> (statements: [String], version: String) {
        let db = try CipherDatabase(path: path, key: RekordboxKey.derive())
        var statements: [String] = []
        try db.query("""
            SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
            ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END, name
            """) { statements.append(($0.string(0) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }
        var version = "?"
        try? db.query("SELECT DBVersion FROM djmdProperty LIMIT 1") { version = $0.string(0) ?? "?" }
        return (statements, version)
    }
}
