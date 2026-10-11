import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("OneLibrary 스키마·호환 검사")
struct OneLibrarySchemaTests {
    struct ColumnInfo: Hashable { var name: String; var type: String; var pk: Int }

    static func tableInfo(_ fixture: OneLibraryFixture) throws -> (tables: [String: [ColumnInfo]], indexes: [String: String]) {
        let db = try fixture.open(.readOnly)
        defer { db.close() }
        var names: [String] = [], indexes: [String: String] = [:]
        try db.query("SELECT type, name, sql FROM sqlite_master ORDER BY rowid") { row in
            if row.string(0) == "table" { names.append(row.string(1) ?? "") }
            if row.string(0) == "index" { indexes[row.string(1) ?? ""] = row.string(2) ?? "" }
        }
        var tables: [String: [ColumnInfo]] = [:]
        for name in names {
            try db.query("PRAGMA table_info(\(name))") { row in
                // SQLite는 표준 자료형 이름을 대문자로 돌려준다
                tables[name, default: []].append(ColumnInfo(name: row.string(1) ?? "", type: (row.string(2) ?? "").lowercased(), pk: row.int(5) ?? -1))
            }
        }
        return (tables, indexes)
    }

    @Test func ddlMatchesResourceText() throws {
        let resource = try OneLibraryFixture.resourceStatements()
        #expect(resource.count == 26)
        #expect(OneLibrarySchema.ddl() == resource)
        #expect(OneLibrarySchema.tables.count == 22)
        #expect(OneLibrarySchema.indexes.count == 4)
        // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
        #expect(OneLibrarySchema.tables.first { $0.name == "album" }?.columns.contains { $0.name == "isComplation" } == true)
        #expect(OneLibrarySchema.tables.first { $0.name == "cue" }?.columns.contains { $0.name == "OutFileOffsetInBlock" } == true)
    }

    @Test func createdSchemaMatchesResource() throws {
        let fromCode = try OneLibraryFixture()
        let fromResource = try OneLibraryFixture(statements: OneLibraryFixture.resourceStatements())
        let code = try Self.tableInfo(fromCode), resource = try Self.tableInfo(fromResource)
        #expect(code.tables.count == 22)
        #expect(code.indexes.count == 4)
        #expect(code.tables == resource.tables)
        #expect(code.indexes == resource.indexes)
        // 표 순서·칸 순서도 같다
        #expect(code.tables["content"]?.first == ColumnInfo(name: "content_id", type: "integer", pk: 1))
        #expect(code.tables["property"]?.allSatisfy { $0.pk == 0 } == true)
        let db = try fromCode.open(.readOnly)
        defer { db.close() }
        try OneLibraryCompatibility.check(db)
    }

    /// 한 가지씩 바꾼 스키마는 모두 거부한다.
    @Test(arguments: ["extraColumn", "missingColumn", "missingTable", "typeDiffers", "dbVersion", "extraTable", "missingIndex", "columnOrder",
                      "noProperty", "notNull", "defaultValue", "autoincrement", "unique", "check"])
    func compatibilityRejects(_ change: String) throws {
        var statements = OneLibrarySchema.ddl()
        func replace(_ table: String, _ transform: (String) -> String) {
            guard let index = statements.firstIndex(where: { $0.hasPrefix("CREATE TABLE \(table)(") }) else {
                Issue.record("표 없음 \(table)"); return
            }
            statements[index] = transform(statements[index])
        }
        switch change {
        case "extraColumn": replace("genre") { $0.replacingOccurrences(of: "name varchar)", with: "name varchar, extra integer)") }
        case "missingColumn": replace("genre") { $0.replacingOccurrences(of: ", name varchar)", with: ")") }
        case "missingTable": statements.removeAll { $0.hasPrefix("CREATE TABLE recommendedLike(") }
        case "typeDiffers": replace("genre") { $0.replacingOccurrences(of: "name varchar)", with: "name text)") }
        case "extraTable": statements.append("CREATE TABLE futureTable(id integer primary key)")
        case "missingIndex": statements.removeAll { $0.hasPrefix("CREATE INDEX index_myTag_content_content_id ") }
        case "columnOrder": replace("color") { _ in "CREATE TABLE color(name varchar, color_id integer primary key)" }
        // 기본 키 말고 제약이 있는 모양(칸 이름·자료형은 같다)
        case "notNull": replace("genre") { $0.replacingOccurrences(of: "name varchar)", with: "name varchar NOT NULL)") }
        case "defaultValue": replace("genre") { $0.replacingOccurrences(of: "name varchar)", with: "name varchar DEFAULT 'x')") }
        case "autoincrement": replace("genre") { $0.replacingOccurrences(of: "integer primary key", with: "integer primary key autoincrement") }
        case "unique": replace("genre") { $0.replacingOccurrences(of: "name varchar)", with: "name varchar UNIQUE)") }
        case "check": replace("genre") { $0.replacingOccurrences(of: "name varchar)", with: "name varchar CHECK(name <> ''))") }
        default: break
        }
        let fixture = try OneLibraryFixture(statements: statements, property: change != "noProperty")
        if change == "dbVersion" { try fixture.setProperty(dbVersion: "1001") }
        let db = try fixture.open(.readOnly)
        defer { db.close() }
        let error = #expect(throws: UsbError.self) { try OneLibraryCompatibility.check(db) }
        if let error, case .formatUnsupported = error {} else { Issue.record("formatUnsupported가 아님: \(String(describing: error))") }
    }

    @Test func indexOnDifferentColumnRejected() throws {
        var statements = OneLibrarySchema.ddl()
        statements.removeAll { $0.hasPrefix("CREATE INDEX index_playlist_content_playlist_id ") }
        statements.append("CREATE INDEX index_playlist_content_playlist_id on playlist_content(content_id)")
        let fixture = try OneLibraryFixture(statements: statements)
        let db = try fixture.open(.readOnly)
        defer { db.close() }
        #expect(throws: UsbError.self) { try OneLibraryCompatibility.check(db) }
    }
}
