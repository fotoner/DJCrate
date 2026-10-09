import RekordboxFixtures
@testable import djc
import Foundation
import RekordboxKit
import Testing

@Suite("lab 인증 정보 보호")
struct LabCredentialTests {
    let marker = "synthetic-private-value"

    func fixture() throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        try fixture.insert("agentRegistry", ["registry_id": .text("neutral"), "str_1": .text(marker), "text_2": .text(marker)])
        try fixture.insert("cloudAgentRegistry", ["ID": .text(marker), "str_1": .text(marker)])
        try fixture.execute("CREATE VIEW harmless_view AS SELECT str_1 AS value FROM agentRegistry")
        try fixture.execute("CREATE TABLE harmless_data (ID TEXT, access_token TEXT)")
        try fixture.execute("INSERT INTO harmless_data VALUES ('1', '\(marker)')")
        return fixture
    }

    func run(_ arguments: [String], fixture: RekordboxFixture) throws -> (Int32, String) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["lab"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJC_HOME": fixture.root.appending(path: "home").path, "DJC_REKORDBOX_DIR": fixture.root.path, "DJC_LANG": "ko",
        ]) { _, new in new }
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test(arguments: ["SELECT str_1 FROM agentRegistry", "SELECT str_1 FROM cloudAgentRegistry", "SELECT * FROM harmless_view", "SELECT * FROM harmless_data"])
    func 진단_연결은_인증_칸을_선택하기_전에_거부한다(_ sql: String) throws {
        let fixture = try fixture()
        let db = try CipherDatabase.diagnostic(path: fixture.database.path, key: RekordboxKey.derive())
        var read = false
        #expect(throws: (any Error).self) { try db.query(sql) { _ in read = true } }
        #expect(!read)
    }

    @Test func write_probe는_인증_행을_출력하지_않는다() throws {
        let fixture = try fixture()
        let snapshots = fixture.root.appending(path: "djc-snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.database, to: snapshots.appending(path: "master-test.db"))
        let (status, output) = try run(["write-probe"], fixture: fixture)
        #expect(status == 0)
        #expect(!output.contains(marker))
        #expect(output.contains("djmdCue 최대 usn"))
    }

    @Test func 재생_목록_감시는_인증값_없이_변경_카운터를_구분한다() throws {
        let fixture = try fixture()
        let before = try PlaylistLab.fingerprint(fixture.database)
        #expect(before.contains("변경 카운터 1000"))
        try fixture.execute("UPDATE agentRegistry SET int_1 = 1001 WHERE registry_id = 'localUpdateCount'")
        let after = try PlaylistLab.fingerprint(fixture.database)
        #expect(after.contains("변경 카운터 1001"))
        #expect(before != after)
        #expect(!before.contains(marker) && !after.contains(marker))
    }

    @Test func 재생_목록_재현은_안전한_변경_카운터를_읽는다() throws {
        let fixture = try fixture()
        #expect(try PlaylistLab.Library(fixture.database).counter == 1000)
    }

    @Test(arguments: ["SELECT * FROM agentRegistry", "SELECT * FROM cloudAgentRegistry", "SELECT * FROM harmless_view", "SELECT * FROM harmless_data"])
    func SQL은_직접_조회와_뷰를_통한_인증값_조회도_막는다(_ sql: String) throws {
        let fixture = try fixture()
        let (_, output) = try run(["sql", fixture.database.path, sql], fixture: fixture)
        #expect(!output.contains(marker))
        #expect(output.contains("허용하지") || output.contains("prohibited") || output.contains("authorized"))
    }

    @Test func db_diff는_인증_값과_인증_행_키를_출력하지_않는다() throws {
        let before = try RekordboxFixture(), after = try fixture()
        try before.insert("agentRegistry", ["registry_id": .text("neutral"), "str_1": .text("synthetic-old-value")])
        try before.execute("CREATE TABLE testData (ID TEXT PRIMARY KEY, secret TEXT, ordinary TEXT)")
        try after.execute("CREATE TABLE testData (ID TEXT PRIMARY KEY, secret TEXT, ordinary TEXT)")
        try before.execute("INSERT INTO testData VALUES ('1', 'old', 'before')")
        try after.execute("INSERT INTO testData VALUES ('1', 'new', 'after')")
        try before.execute("INSERT INTO testData VALUES ('session-setting', 'old', 'before')")
        try after.execute("INSERT INTO testData VALUES ('session-setting', 'new', 'after')")
        let (status, output) = try run(["db-diff", before.database.path, after.database.path], fixture: after)
        #expect(status == 0)
        #expect(!output.contains(marker) && !output.contains("synthetic-old-value"))
        #expect(output.contains("(바뀜)") && output.contains("before → after"))
    }
}
