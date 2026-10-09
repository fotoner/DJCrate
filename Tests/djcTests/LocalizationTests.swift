import RekordboxFixtures
@testable import djc
import Foundation
import Testing

@Suite("CLI 다국어")
struct LocalizationTests {
    @Test func 언어_선택은_환경_변수를_먼저_보고_지원하지_않으면_영어를_쓴다() {
        #expect(CLILocalization.language(override: "ja-JP", preferredLanguages: ["ko"]) == "ja")
        #expect(CLILocalization.language(override: "KO_kr", preferredLanguages: ["en"]) == "ko")
        #expect(CLILocalization.language(override: "fr", preferredLanguages: ["ko"]) == "en")
        #expect(CLILocalization.language(override: nil, preferredLanguages: ["ja-JP", "en-US"]) == "ja")
        #expect(CLILocalization.language(override: "  ", preferredLanguages: ["ko-KR"]) == "ko")
        #expect(CLILocalization.language(override: nil, preferredLanguages: ["fr-FR", "ja"]) == "ja")
        #expect(CLILocalization.language(override: nil, preferredLanguages: ["de", "fr"]) == "en")
        #expect(CLILocalization.language(override: nil, preferredLanguages: []) == "en")
    }

    private func run(_ arguments: [String], language: String, withoutResources: Bool = false) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-localization-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process(), out = Pipe(), err = Pipe()
        if withoutResources {
            let copy = home.appending(path: "djc")
            try FileManager.default.copyItem(at: executable, to: copy)
            // 실행 의존성은 옮기고 번역 리소스만 빠뜨린 경우를 재현한다.
            let framework = executable.resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "SQLCipher.framework")
            try FileManager.default.copyItem(at: framework, to: home.appending(path: "SQLCipher.framework"))
            process.executableURL = copy
        } else { process.executableURL = executable }
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJC_LANG": language, "DJC_HOME": home.path, "DJC_REKORDBOX_DIR": home.path,
        ]) { _, new in new }
        process.standardOutput = out; process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }

    @Test(arguments: ["ko", "en", "ja", "fr"])
    func JSON은_오류_메시지만_번역한다(language: String) throws {
        let output = try run(["search", "--json"], language: language)
        #expect(output.status == 1 && output.stdout.isEmpty)
        let envelope = try #require(JSONSerialization.jsonObject(with: output.stderr) as? [String: Any])
        #expect(Set(envelope.keys) == ["schemaVersion", "command", "error"])
        #expect(envelope["schemaVersion"] as? Int == 1)
        #expect(envelope["command"] as? String == "search")
        let error = try #require(envelope["error"] as? [String: String])
        #expect(Set(error.keys) == ["code", "message"])
        #expect(error["code"] == "invalid_arguments")
        let expected = ["ko": "명령 인자 수가 맞지 않습니다. djc로 사용법을 확인하세요",
                        "en": "The number of arguments is incorrect. Run djc to see usage",
                        "ja": "コマンド引数の数が正しくありません。djcで使い方を確認してください"]
        #expect(error["message"] == expected[language == "fr" ? "en" : language])
    }

    @Test func JSON의_성공_데이터는_언어와_관계없이_같다() throws {
        let arguments = ["parse", "TVA 시험 OP 1", "--json"]
        let korean = try run(arguments, language: "ko")
        for language in ["en", "ja", "fr"] {
            let translated = try run(arguments, language: language)
            #expect(translated.status == 0 && translated.stderr.isEmpty)
            #expect(translated.stdout == korean.stdout)
        }
    }

    @Test func 리소스_번들_없이_복사해도_원문으로_실행한다() throws {
        let output = try run(["search", "--json"], language: "en", withoutResources: true)
        #expect(output.status == 1 && output.stdout.isEmpty)
        let envelope = try #require(JSONSerialization.jsonObject(with: output.stderr) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: String])
        #expect(error["code"] == "invalid_arguments")
        #expect(error["message"] == "명령 인자 수가 맞지 않습니다. djc로 사용법을 확인하세요")
    }

    @Test(arguments: ["en", "ja"])
    func 하위_모듈의_오류도_번역한다(language: String) throws {
        let output = try run(["track", "101", "--json"], language: language)
        let envelope = try #require(JSONSerialization.jsonObject(with: output.stderr) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: String])
        #expect(error["code"] == "read_failed")
        let message = try #require(error["message"])
        #expect(message.contains("djc snapshot"))
        #expect(!message.contains("스냅샷"))
    }

    @Test(arguments: ["ko", "en", "ja"])
    func 곡_출력의_제목과_숫자는_보존하고_설명만_번역한다(language: String) throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "101", uuid: "synthetic-track")
        track.title = "합성 시험곡"
        track.length = 120
        try fixture.add(track)
        let output = try run(["track", "101", "--db", fixture.database.path], language: language)
        #expect(output.status == 0 && output.stderr.isEmpty)
        let text = String(decoding: output.stdout, as: UTF8.self)
        #expect(text.contains("합성 시험곡"))
        let length = ["ko": "길이: 120초", "en": "Length: 120 s", "ja": "長さ: 120秒"]
        #expect(text.contains(try #require(length[language])))
    }
}
