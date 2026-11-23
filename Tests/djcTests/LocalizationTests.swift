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

    private func run(_ arguments: [String], language: String, withoutResources: Bool = false,
                     appBundleLink: Bool = false) throws -> (status: Int32, stdout: Data, stderr: Data) {
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
        } else if appBundleLink {
            process.executableURL = try installAppBundle(executable, in: home)
            process.currentDirectoryURL = home
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

    /// 릴리스 앱 번들 꼴(scripts/build-app.sh, #262): djc는 Contents/Helpers, 리소스 번들은 Contents/Resources, SQLCipher는 Contents/Frameworks.
    /// 다른 폴더의 링크(`~/.local/bin/djc` 꼴)로 부른다
    private func installAppBundle(_ executable: URL, in home: URL) throws -> URL {
        let fm = FileManager.default, built = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = home.appending(path: "Apps/DJCrate.app/Contents")
        for folder in ["Helpers", "Resources", "Frameworks"] { try fm.createDirectory(at: contents.appending(path: folder), withIntermediateDirectories: true) }
        let helper = contents.appending(path: "Helpers/djc")
        try fm.copyItem(at: executable, to: helper)
        try fm.copyItem(at: built.appending(path: "DJCrate_djc.bundle"), to: contents.appending(path: "Resources/DJCrate_djc.bundle"))
        try fm.copyItem(at: built.appending(path: "SQLCipher.framework"), to: contents.appending(path: "Frameworks/SQLCipher.framework"))
        // 빌드 폴더를 가리키는 rpath를 빼서 번들 안 Frameworks만으로 SQLCipher를 찾는지 본다
        var rpaths: [String] = [], inRpath = false
        for line in try xcrun(["otool", "-l", helper.path]).split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line == "cmd LC_RPATH" { inRpath = true } else if inRpath, line.hasPrefix("path ") {
                rpaths.append(String(line.dropFirst("path ".count)).components(separatedBy: " (offset")[0])
                inRpath = false
            }
        }
        for rpath in rpaths { _ = try xcrun(["install_name_tool", "-delete_rpath", rpath, helper.path]) }
        _ = try xcrun(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", helper.path])
        _ = try xcrun(["codesign", "--force", "--sign", "-", helper.path])
        let link = home.appending(path: "bin/djc")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: helper)
        return link
    }

    private func xcrun(_ arguments: [String]) throws -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(arguments[0]) 실패")
        return String(decoding: data, as: UTF8.self)
    }

    @Test func 앱_번들_안_djc를_링크로_불러도_번역한다() throws {
        let output = try run(["search", "--json"], language: "en", appBundleLink: true)
        #expect(output.status == 1 && output.stdout.isEmpty)
        let envelope = try #require(JSONSerialization.jsonObject(with: output.stderr) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: String])
        #expect(error["message"] == "The number of arguments is incorrect. Run djc to see usage")
    }

    @Test func 리소스_번들은_실행_파일_옆_다음_앱_번들_안에서_찾는다() {
        let helpers = URL(filePath: "/Applications/DJCrate.app/Contents/Helpers")
        #expect(CLILocalization.resourceBundles(executableDirectory: helpers)
            == [helpers.appending(path: "DJCrate_djc.bundle"), URL(filePath: "/Applications/DJCrate.app/Contents/Resources/DJCrate_djc.bundle")])
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

    private func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 번역 검사 스크립트(`scripts/i18n.swift`)는 작업 트리가 `/tmp`·`/var/folders`처럼 `/private`를 거치는 경로여도
    /// 소스의 `.stringsdata`를 찾는다(#381). 컴파일러는 실제 경로(`/private/…`)를 `source`에 남긴다.
    /// 합성 저장소에 스크립트 사본을 두고, 안쪽 `swift build`·`xcstringstool`은 PATH 앞의 가짜로 흉내 낸다.
    @Test(arguments: ["실제 경로", "링크 경로"])
    func 번역_검사는_작업_트리가_private_아래여도_소스를_찾는다(sourceForm: String) throws {
        let fm = FileManager.default
        // TMPDIR이 /private 밖인 러너에서도 재현되게 /tmp(= /private/tmp) 아래에 둔다
        let sandbox = URL(filePath: "/tmp").appending(path: "djc-i18n-private-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }
        let repo = URL(filePath: realPath(sandbox.path)).appending(path: "repo")
        try #require(repo.path.hasPrefix("/private/"), "임시 폴더가 /private 아래가 아니라 이 결함을 재현할 수 없습니다: \(repo.path)")

        let realRoot = URL(filePath: realPath(URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path))
        let script = repo.appending(path: "scripts/i18n.swift")
        let source = repo.appending(path: "Sources/DJCrate/A.swift")
        let catalog = "{\n  \"sourceLanguage\" : \"ko\",\n  \"strings\" : {\n\n  },\n  \"version\" : \"1.0\"\n}\n"
        let stringsdata = repo.appending(path: ".build/out/Intermediates.noindex/Pkg/Debug/A.stringsdata")
        let bin = sandbox.appending(path: "bin")
        let log = sandbox.appending(path: "xcstringstool.log")
        for folder in [script, source, stringsdata].map({ $0.deletingLastPathComponent() }) + [bin, repo.appending(path: "Sources/DJCrate/Resources")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try fm.copyItem(at: realRoot.appending(path: "scripts/i18n.swift"), to: script)
        for name in ["Localizable", "InfoPlist"] {
            try catalog.write(to: repo.appending(path: "Sources/DJCrate/Resources/\(name).xcstrings"), atomically: true, encoding: .utf8)
        }
        // 한 줄짜리 소스: `String(ui:)` 밖의 지역화 문구라 검사가 상대 경로로 문제를 알린다
        try "let x = Text(\"안녕\")\n".write(to: source, atomically: true, encoding: .utf8)
        let sourceInData = sourceForm == "실제 경로" ? source.path : String(source.path.dropFirst("/private".count))
        let entry: [String: Any] = ["key": "안녕", "location": ["startingLine": 1, "startingColumn": 5]]
        try JSONSerialization.data(withJSONObject: ["source": sourceInData, "tables": ["Localizable": [entry]], "version": 1] as [String: Any])
            .write(to: stringsdata)
        let fakes = ["swift": "#!/bin/sh\nexit 0\n",
                     "xcrun": "#!/bin/sh\nif [ \"$1\" = xcstringstool ]; then echo \"$@\" >> \"$FAKE_XCSTRINGSTOOL_LOG\"; exit 0; fi\nexec /usr/bin/xcrun \"$@\"\n"]
        for (name, body) in fakes {
            let file = bin.appending(path: name)
            try body.write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        let stdout = sandbox.appending(path: "stdout.txt"), stderr = sandbox.appending(path: "stderr.txt")
        fm.createFile(atPath: stdout.path, contents: nil)
        fm.createFile(atPath: stderr.path, contents: nil)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["swift", script.path, "check"]
        process.currentDirectoryURL = repo
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
            "FAKE_XCSTRINGSTOOL_LOG": log.path,
        ]) { _, new in new }
        process.standardOutput = try FileHandle(forWritingTo: stdout)
        process.standardError = try FileHandle(forWritingTo: stderr)
        try process.run()
        process.waitUntilExit()

        let output = (try? String(contentsOf: stdout, encoding: .utf8)) ?? "", errors = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
        #expect(!errors.contains(".stringsdata가 없습니다"), "\(errors)")
        // 문구를 찾았으니 검사는 문제 하나로 실패한다. 상대 경로는 저장소 뿌리를 뗀다
        #expect(process.terminationStatus == 1, "\(output)\(errors)")
        #expect(output.contains("    Sources/DJCrate/A.swift:1:"), "\(output)")
        #expect(!output.contains("/private"), "\(output)")
        let calls = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(calls.contains("--stringsdata \(stringsdata.path)"), "\(calls)")
    }
}
