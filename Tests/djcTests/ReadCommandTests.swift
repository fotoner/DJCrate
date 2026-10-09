import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 읽기 명령(`report`·`search`·`duplicates`·`histories`·`history`)을 `.build/debug/djc` 프로세스로 띄워 JSON 봉투·종료 코드를 본다.
/// 읽기 규칙 자체는 DJCStorageTests의 `LibraryReadTests`·`HistoryReadTests`·`DuplicateReadTests`가 본다.
@Suite("CLI 읽기 명령")
struct ReadCommandTests {
    func run(_ arguments: [String], fixture: RekordboxFixture) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJC_HOME": fixture.root.appending(path: "home").path,
            "DJC_REKORDBOX_DIR": fixture.root.path,
            // 출력 문구를 비교하므로 실행 환경의 로캘(CI 러너는 en_US)과 상관없이 한국어로 낸다
            "DJC_LANG": "ko",
        ]) { _, new in new }
        process.standardOutput = out; process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }

    @Test(arguments: ["none", "anisong"])
    func CLI_프리셋은_앱_설정_없이_명시한_값만_쓴다(preset: String) throws {
        let fixture = try readLibraryFixture()
        let result = try run(["report", "--json", "--comment-preset", preset, "--db", fixture.database.path], fixture: fixture)
        #expect(result.status == 0 && result.stderr.isEmpty)
        let envelope = try #require(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        let report = try #require(envelope["data"] as? [String: Any])
        if preset == "anisong" {
            #expect(report["commentClasses"] as? [String: Int] == ["convention": 1, "empty": 1])
            #expect(report["prefixes"] as? [String: Int] == ["TVA": 1])
            #expect(report["usages"] as? [String: Int] == ["OP": 1])
        } else {
            #expect(report["commentClasses"] == nil && report["prefixes"] == nil && report["usages"] == nil)
        }
    }

    @Test(arguments: [["--comment-preset", "unknown"], ["--comment-preset"], ["--filter", "off-convention"]])
    func CLI는_잘못된_프리셋과_꺼진_필터를_DB보다_먼저_검사한다(options: [String]) throws {
        let fixture = try RekordboxFixture()
        let result = try run(["search", "", "--json", "--db", fixture.root.appending(path: "missing.db").path] + options, fixture: fixture)
        #expect(result.status == 1 && result.stdout.isEmpty)
        let envelope = try #require(JSONSerialization.jsonObject(with: result.stderr) as? [String: Any])
        #expect((envelope["error"] as? [String: String])?["code"] == "invalid_arguments")
    }

    @Test(arguments: [false, true])
    func CLI는_삭제한_필터를_DB를_열기_전에_거절한다(json: Bool) throws {
        let fixture = try RekordboxFixture()
        let result = try run(["search", "", "--filter", "backlog", "--db", fixture.root.appending(path: "missing.db").path]
            + (json ? ["--json"] : []), fixture: fixture)
        #expect(result.status == 1 && result.stdout.isEmpty)
        let message: String
        if json {
            let document = try #require(JSONSerialization.jsonObject(with: result.stderr) as? [String: Any])
            #expect(document["schemaVersion"] as? Int == 1 && document["command"] as? String == "search")
            let error = try #require(document["error"] as? [String: String])
            #expect(error["code"] == "invalid_arguments")
            message = try #require(error["message"])
        } else {
            message = String(decoding: result.stderr, as: UTF8.self)
        }
        #expect(message.contains("backlog"))
        #expect(message.contains("--filter empty-comment"))
    }

    @Test func CLI는_후보와_빈목록과_잘못된_인자를_JSON으로_출력한다() throws {
        let fixture = try duplicateLibraryFixture()
        for invalid in [false, true] {
            let result = try run(["duplicates", "--db", fixture.database.path, "--json"] + (invalid ? ["--merge"] : []), fixture: fixture)
            #expect(result.status == (invalid ? 1 : 0))
            #expect(invalid ? result.stdout.isEmpty : result.stderr.isEmpty)
            let envelope = try #require(JSONSerialization.jsonObject(with: invalid ? result.stderr : result.stdout) as? [String: Any])
            #expect(envelope["schemaVersion"] as? Int == 1)
            #expect(envelope["command"] as? String == "duplicates")
            if invalid {
                #expect((envelope["error"] as? [String: String])?["code"] == "invalid_arguments")
            } else {
                let data = try #require(envelope["data"] as? [String: Any])
                #expect((data["groups"] as? [Any])?.count == 1)
            }
        }
        let empty = try RekordboxFixture()
        let read = try LibraryRead(snapshot: empty.database, home: empty.root.appending(path: "home"), shareRoot: empty.shareRoot)
        #expect(read.duplicates().groups.isEmpty)
    }

    @Test func CLI는_기록목록과_순번과_오류를_JSON으로_출력한다() throws {
        let fixture = try historyFixture()
        for (arguments, status) in [(["histories"], 0), (["history", "new-a"], 0),
                                     (["history", "unknown"], 1), (["history"], 1)] {
            let result = try run(arguments + ["--db", fixture.database.path, "--json"], fixture: fixture)
            #expect(result.status == status)
            #expect(status == 0 ? result.stderr.isEmpty : result.stdout.isEmpty)
            let envelope = try #require(JSONSerialization.jsonObject(with: status == 0 ? result.stdout : result.stderr) as? [String: Any])
            #expect(envelope["schemaVersion"] as? Int == 1)
            #expect(envelope["command"] as? String == arguments[0])
            if status == 0 {
                let data = try #require(envelope["data"] as? [String: Any])
                if arguments[0] == "histories" {
                    #expect((data["histories"] as? [[String: Any]])?.map { $0["id"] as? String } == ["new-a", "new-b", "old", "undated"])
                } else {
                    #expect((data["entries"] as? [[String: Any]])?.map { $0["trackNumber"] as? Int } == [1, 2, 3])
                }
            } else {
                #expect((envelope["error"] as? [String: String])?["code"] == (arguments.count == 1 ? "invalid_arguments" : "not_found"))
            }
        }
    }

    @Test func 텍스트_경로는_라이브러리_순서로_JSON은_ID_순서로_보이고_현황은_사본부터_보인다() throws {
        let fixture = try RekordboxFixture()
        var later = TrackSpec(id: "900"), earlier = TrackSpec(id: "100")
        later.title = "합성 나중"; later.folderPath = "/합성/나중.mp3"
        earlier.title = "합성 처음"; earlier.folderPath = "/합성/처음.mp3"
        try fixture.add(later)
        try fixture.add(earlier)
        let libraryOrder = try RekordboxLibrary.load(snapshot: fixture.database).tracks.map(\.folderPath)
        let text = try run(["path", "합성", "--db", fixture.database.path], fixture: fixture)
        #expect(text.status == 0 && String(decoding: text.stdout, as: UTF8.self) == libraryOrder.map { $0 + "\n" }.joined())
        let json = try run(["path", "합성", "--json", "--db", fixture.database.path], fixture: fixture)
        let envelope = try #require(JSONSerialization.jsonObject(with: json.stdout) as? [String: Any])
        #expect((envelope["data"] as? [String: Any])?["paths"] as? [String] == ["/합성/처음.mp3", "/합성/나중.mp3"])
        let report = try run(["report", "--db", fixture.database.path], fixture: fixture)
        let lines = String(decoding: report.stdout, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(report.status == 0 && lines.first.map(String.init) == "스냅샷: \(fixture.database.path)" && lines.dropFirst(2).first == "## 컬렉션")
    }
}
