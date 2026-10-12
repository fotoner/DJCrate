@testable import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 임시 폴더의 실제 파일로 꾸미는 손. 휴지통은 시험 폴더 안 `trash`다
private struct FolderBench: AgentToolFilesBench {
    let trash: URL

    func put(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func putLink(_ url: URL, to destination: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    func content(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func trashed() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [] }
}

@Suite("AI 에이전트 설치 자리 — 실제 파일")
struct AgentToolFilesLiveTests {
    @Test func 계약() throws {
        let folder = try TemporaryFolder(prefix: "djc-agent")
        let root = folder.url.resolvingSymlinksInPath()
        let layout = AgentBundleLayout(skillSource: root.appending(path: "payload/skills/djcrate"), command: nil,
                                       version: AgentPayloadVersion(version: "1.0.0", build: "10"))
        let trash = root.appending(path: "trash")
        try agentToolFilesContract(.live(layout: layout, trash: trash), bench: FolderBench(trash: trash), root: root)
    }

    @Test func 앱_번들_안_재료_자리와_판() throws {
        let folder = try TemporaryFolder(prefix: "djc-agent")
        let app = folder.url.appending(path: "DJCrate.app")
        #expect(AgentBundleLayout.appBundle(app, info: [:]) == AgentBundleLayout(skillSource: nil, command: nil,
                                                                                 version: AgentPayloadVersion(version: "dev", build: "0")))
        let bench = FolderBench(trash: folder.url)
        try bench.put(app.appending(path: "Contents/Resources/skills/djcrate/SKILL.md"), "skill")
        try bench.put(app.appending(path: "Contents/Helpers/djc"), "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appending(path: "Contents/Helpers/djc").path)
        let layout = AgentBundleLayout.appBundle(app, info: ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "321"])
        #expect(layout == AgentBundleLayout(skillSource: app.appending(path: "Contents/Resources/skills/djcrate"),
                                            command: app.appending(path: "Contents/Helpers/djc"),
                                            version: AgentPayloadVersion(version: "0.2.0", build: "321")))
    }

    @Test func Finder_파일은_사용자가_고친_것으로_보지_않는다() throws {
        let folder = try TemporaryFolder(prefix: "djc-agent")
        let bench = FolderBench(trash: folder.url)
        try bench.put(folder.url.appending(path: "s/SKILL.md"), "a")
        try bench.put(folder.url.appending(path: "s/.DS_Store"), "finder")
        try bench.put(folder.url.appending(path: "s/\(AgentInstallManifest.fileName)"), "{}")
        #expect(Set(AgentToolFiles.hashes(under: folder.url.appending(path: "s")).keys) == ["SKILL.md"])
    }

    @Test func 상대_링크는_링크_폴더_기준으로_푼다() throws {
        let folder = try TemporaryFolder(prefix: "djc-agent")
        let link = folder.url.appending(path: "bin/djc")
        try FolderBench(trash: folder.url).putLink(link, to: "../lib/djc")
        #expect(AgentToolFiles.entry(link) == .link(destination: folder.url.appending(path: "lib/djc").path))
    }

    @Test func 셸_PATH를_시간_안에_읽는다() {
        let home = FileManager.default.temporaryDirectory
        #expect(AgentToolFiles.readPath(shell: "/bin/sh", arguments: ["-c"], home: home, timeout: .seconds(10)) != nil)
        // 끝나지 않는 셸 설정(예: 입력을 기다리는 rc 파일)은 기다리지 않는다
        #expect(AgentToolFiles.readPath(shell: "/bin/sh", arguments: ["-c", "sleep 30"], home: home, timeout: .milliseconds(200)) == nil)
        // 시험 프로세스는 사용자 홈으로 셸을 띄우지 않는다
        let live = AgentToolFiles.live(layout: AgentBundleLayout(skillSource: nil, command: nil, version: .init(version: "1", build: "1")))
        #expect(live.shell(FileManager.default.homeDirectoryForCurrentUser).path == nil)
    }

    @Test func 대화형_셸이_시간을_넘기면_끝낸다() throws {
        // 대화형 zsh는 SIGTERM을 무시한다. 시간을 넘긴 셸이 남지 않게 끝까지 끝낸 뒤 돌아온다
        let folder = try TemporaryFolder(prefix: "djc-agent-shell")
        try Data("sleep 30\n".utf8).write(to: folder.url.appending(path: ".zshrc"))
        var launched: pid_t?
        #expect(AgentToolFiles.readPath(shell: "/bin/zsh", arguments: ["-l", "-i", "-c"], home: folder.url, timeout: .milliseconds(300),
                                        launched: { launched = $0 }) == nil)
        let pid = try #require(launched)
        // 이 시험이 띄운 셸 PID만 본다(kill 0은 신호를 보내지 않고 있는지만 묻는다)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func 갱신은_폴더나_밖을_가리키는_링크가_있는_자리에_쓰지_않는다() throws {
        let folder = try TemporaryFolder(prefix: "djc-agent")
        let root = folder.url.resolvingSymlinksInPath()
        let bench = FolderBench(trash: root.appending(path: "trash"))
        let source = root.appending(path: "payload/skills/djcrate"), target = root.appending(path: "home/.claude/skills/djcrate")
        try bench.put(source.appending(path: "SKILL.md"), "v2")
        try bench.put(source.appending(path: "ref/a.md"), "r2")
        let files = AgentToolFiles.live(layout: AgentBundleLayout(skillSource: source, command: nil, version: .init(version: "2", build: "2")),
                                        trash: root.appending(path: "trash"))
        // SKILL.md 자리에 사용자가 둔 폴더, ref는 바깥 폴더를 가리키는 링크
        try bench.put(target.appending(path: "SKILL.md/notes.txt"), "mine")
        let outside = root.appending(path: "outside")
        try bench.put(outside.appending(path: "a.md"), "outside")
        try bench.putLink(target.appending(path: "ref"), to: outside.path)
        let manifest = AgentInstallManifest(app: .init(version: "1", build: "1"), files: ["SKILL.md": "x", "ref/a.md": "y"])
        try manifest.encoded().write(to: target.appending(path: AgentInstallManifest.fileName))
        let plan = AgentSkillRules.installPlan(for: files.inspectSkill(target), payload: try #require(files.payload()).skill)
        #expect(throws: (any Error).self) { try files.applySkill(AgentSkillChange(folder: target, source: source, plan: plan)) }
        #expect(bench.content(target.appending(path: "SKILL.md/notes.txt")) == "mine")
        #expect(bench.content(outside.appending(path: "a.md")) == "outside")
        // 지우기·휴지통도 링크를 따라 밖으로 나가지 않는다
        let remove = AgentSkillPlan(delete: ["ref/a.md"])
        #expect(throws: (any Error).self) { try files.applySkill(AgentSkillChange(folder: target, source: source, plan: remove)) }
        #expect(bench.content(outside.appending(path: "a.md")) == "outside")
    }

    @Test func 시험_프로세스는_임시_폴더_밖과_macOS_휴지통에_쓰지_않는다() throws {
        let outside = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".djc-agent-guard-\(UUID().uuidString)/skills/djcrate")
        let files = AgentToolFiles.live(layout: AgentBundleLayout(skillSource: nil, command: nil, version: .init(version: "1", build: "1")))
        let plan = AgentSkillPlan(manifest: AgentInstallManifest(app: .init(version: "1", build: "1"), files: [:]))
        #expect(throws: (any Error).self) { try files.applySkill(AgentSkillChange(folder: outside, source: outside, plan: plan)) }
        #expect(throws: (any Error).self) { try files.link(outside, outside, .none) }
        #expect(AgentToolFiles.entry(outside.deletingLastPathComponent().deletingLastPathComponent()) == .missing)
        // 휴지통을 주지 않으면 남의 것을 치우지 못한다(사용자 휴지통에 시험 파일을 넣지 않는다)
        let folder = try TemporaryFolder(prefix: "djc-agent")
        let foreign = folder.url.appending(path: "skills/djcrate")
        try FolderBench(trash: folder.url).put(foreign.appending(path: "SKILL.md"), "hand")
        #expect(throws: (any Error).self) {
            try files.applySkill(AgentSkillChange(folder: foreign, source: foreign, plan: AgentSkillPlan(replaces: .folder)))
        }
        #expect(FolderBench(trash: folder.url).content(foreign.appending(path: "SKILL.md")) == "hand")
    }
}
