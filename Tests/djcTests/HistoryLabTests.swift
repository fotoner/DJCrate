@testable import djc
import DJCTestKit
import RekordboxFixtures
import Foundation
import RekordboxKit
import Testing

/// 재현 도구가 실물 볼륨·사용자 폴더에 사본을 만들지 않고, 실패를 성공 종료로 알리지 않게 한다.
@Suite("재생 기록 사본 재현 도구")
struct HistoryLabTests {
    @Test func 작업_폴더는_임시_폴더의_빈_폴더만_받는다() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-history-lab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try HistoryLab.refuseLibraryFolder(root.appending(path: "work"))
        #expect(throws: (any Error).self) { try HistoryLab.refuseLibraryFolder(URL(filePath: "/")) }
        #expect(throws: (any Error).self) { try HistoryLab.refuseLibraryFolder(URL(filePath: "/Volumes/djc-history-lab")) }
        try Data("이미 있는 결과".utf8).write(to: root.appending(path: "result.txt"))
        #expect(throws: (any Error).self) { try HistoryLab.refuseLibraryFolder(root) }
    }

    @Test func 비교할_새_기록이_없으면_실패한다() async throws {
        let fixture = try RekordboxFixture()
        let work = fixture.root.appending(path: "history-repro")
        await #expect(throws: (any Error).self) {
            try await HistoryLab.repro(["history-repro", "--old", fixture.database.path, "--new", fixture.database.path,
                                        "--work", work.path])
        }
    }

    @Test func 같은_글자의_INTEGER와_TEXT를_다르게_읽는다() throws {
        let fixture = try RekordboxFixture()
        try fixture.execute("CREATE TABLE HistoryTypeProbe (ID TEXT PRIMARY KEY, value)")
        try fixture.execute("INSERT INTO HistoryTypeProbe VALUES ('integer', 1), ('text', '1')")
        let table = try #require(try HistoryLab.load(fixture.database, key: RekordboxKey.derive())["HistoryTypeProbe"])
        #expect(table.value("integer", "value") == table.value("text", "value"))
        #expect(table.differingStorage("integer", from: table, key: "text", skip: ["ID"]) == ["value"])
    }

    @Test func 인접한_REAL_값도_다르게_읽는다() throws {
        let fixture = try RekordboxFixture()
        try fixture.execute("CREATE TABLE HistoryRealProbe (ID TEXT PRIMARY KEY, value REAL)")
        try fixture.execute("INSERT INTO HistoryRealProbe VALUES ('first', 1.0), ('next', 1.0000000000000002)")
        let table = try #require(try HistoryLab.load(fixture.database, key: RekordboxKey.derive())["HistoryRealProbe"])
        #expect(table.differingStorage("first", from: table, key: "next", skip: ["ID"]) == ["value"])
    }

    @Test(arguments: [true, false])
    func 비교_맵에서_사라지는_중복_항목과_모르는_새_행을_거부한다(_ duplicatedEntry: Bool) {
        let h = HistoryLab.Table(columns: ["ID", "Attribute"], rows: [:])
        let e = HistoryLab.Table(columns: ["ID", "HistoryID", "ContentID", "TrackNo", "UUID"], rows: [:])
        let c = HistoryLab.Table(columns: ["ID", "Title"], rows: ["track": ["track", "같은 제목"]])
        let base = ["djmdHistory": h, "djmdSongHistory": e, "djmdContent": c]
        var theirs = base
        if duplicatedEntry {
            theirs["djmdSongHistory"]?.rows = [
                "00000000-0000-4000-8000-000000000001": ["00000000-0000-4000-8000-000000000001", "h", "track", "1", "00000000-0000-4000-8000-000000000003"],
                "00000000-0000-4000-8000-000000000002": ["00000000-0000-4000-8000-000000000002", "h", "track", "1", "00000000-0000-4000-8000-000000000004"],
            ]
        } else {
            theirs["djmdHistory"]?.rows["other"] = ["other", "2"]
        }
        var problems: [String] = []
        HistoryLab.compare(base: base, ours: base, theirs: theirs, problems: &problems)
        #expect(problems.contains { $0.contains(duplicatedEntry ? "중복 행" : "비교하지 못한 Attribute") })
    }

    @Test(arguments: [true, false])
    func 곡_행의_저장_형식과_모든_칸의_값을_비교한다(_ typeOnly: Bool) {
        let h = HistoryLab.Table(columns: ["ID", "Attribute"], rows: [:])
        let emptyEntries = HistoryLab.Table(columns: ["ID", "HistoryID", "ContentID", "TrackNo", "UUID"], rows: [:])
        let entryID = "00000000-0000-4000-8000-000000000001"
        let entryUUID = "00000000-0000-4000-8000-000000000002"
        let entries = HistoryLab.Table(columns: emptyEntries.columns, rows: [entryID: [entryID, "h", "track", "1", entryUUID]])
        let columns = ["ID", "DJPlayCount", "Title"]
        let baseContent = HistoryLab.Table(columns: columns, rows: ["track": ["track", "0", "옛 제목"]])
        let ours = HistoryLab.Table(columns: columns, rows: ["track": ["track", "1", "첫 제목"]],
                                    storage: ["track": ["text:track", "integer:31", "text:first"]])
        let theirs = HistoryLab.Table(columns: columns, rows: ["track": ["track", "1", typeOnly ? "첫 제목" : "다른 제목"]],
                                      storage: ["track": ["text:track", typeOnly ? "text:31" : "integer:31", typeOnly ? "text:first" : "text:other"]])
        var problems: [String] = []
        HistoryLab.compare(base: ["djmdHistory": h, "djmdSongHistory": emptyEntries, "djmdContent": baseContent],
                           ours: ["djmdHistory": h, "djmdSongHistory": entries, "djmdContent": ours],
                           theirs: ["djmdHistory": h, "djmdSongHistory": entries, "djmdContent": theirs], problems: &problems)
        #expect(problems.contains { $0.contains("저장 형식") && $0.contains(typeOnly ? "DJPlayCount" : "Title") })
    }
}
