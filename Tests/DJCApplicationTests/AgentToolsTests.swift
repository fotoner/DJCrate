import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Testing

@Suite("AI 에이전트 도구 설치")
struct AgentToolsTests {
    let fake = MemoryAgentToolFiles()
    let home = URL(filePath: "/home/me")
    let source = URL(filePath: "/Apps/DJCrate.app/Contents/Resources/skills/djcrate")
    let bundled = URL(filePath: "/Apps/DJCrate.app/Contents/Helpers/djc")
    let v1 = AgentPayloadVersion(version: "0.1.0", build: "100")
    let v2 = AgentPayloadVersion(version: "0.2.0", build: "120")
    var tools: AgentTools { AgentTools(files: fake.port, home: home) }

    init() throws {
        try fake.put(source.appending(path: "SKILL.md"), "skill v1")
        try fake.put(source.appending(path: "references/cli.md"), "cli v1")
        fake.setPayload(source: source, version: v1, command: bundled)
        fake.putFolder(home.appending(path: ".claude/projects"))
    }

    func path(_ relative: String) -> URL { home.appending(path: relative) }
    func target(_ relative: String, _ kind: AgentKind = .claudeCode) -> AgentTarget { AgentTarget(kind: kind, folder: path(relative)) }
    func state(_ relative: String, custom: [URL] = []) -> AgentSkillState? {
        tools.report(customClaudeFolders: custom).skills.first { $0.target.folder == path(relative) }?.state
    }

    /// 사용자가 손으로 둔 모양(이 Mac의 실제 손 설치와 같은 꼴): 메인 체크아웃을 가리키는 링크, 복사본, 다른 djc를 부르는 스크립트
    func putHandInstalls() throws {
        try fake.putLink(path(".claude-goondori/skills/djcrate"), to: "/Users/me/dev/DJCrate/skills/djcrate")
        try fake.put(path(".agents/skills/djcrate/SKILL.md"), "hand copy")
        try fake.put(path(".local/bin/djc"), "#!/bin/sh\nexec ~/.local/lib/djcrate/djc \"$@\"\n")
    }

    // MARK: - 자리와 상태

    @Test func 설치_자리는_Claude_설정_폴더마다와_고른_자리_그리고_Codex다() throws {
        try fake.put(path(".claude-goondori/skills/other/SKILL.md"), "x")
        try fake.put(path(".claude.json"), "{}")
        let custom = URL(filePath: "/Volumes/Work/claude/skills/djcrate")
        let targets = tools.targets(customClaudeFolders: [custom, path(".claude/skills/djcrate")])
        #expect(targets == [target(".claude/skills/djcrate"), target(".claude-goondori/skills/djcrate"),
                            AgentTarget(kind: .claudeCode, folder: custom, isCustom: true), target(".agents/skills/djcrate", .codex)])
    }

    @Test func 손_설치는_DJCrate가_설치하지_않은_것으로_보인다() throws {
        try putHandInstalls()
        let report = tools.report(customClaudeFolders: [])
        #expect(report.version == v1)
        #expect(state(".claude/skills/djcrate") == .notInstalled)
        #expect(state(".claude-goondori/skills/djcrate") == .foreign(.link(destination: "/Users/me/dev/DJCrate/skills/djcrate")))
        #expect(state(".agents/skills/djcrate") == .foreign(.folder))
        #expect(report.command.state == .foreign(.file))
        #expect(!report.needsUpdate)
    }

    // MARK: - 설치

    @Test func 빈_자리에는_묻지_않고_설치한다() throws {
        #expect(tools.perform(.install(target(".claude/skills/djcrate"))) == .done(failures: []))
        #expect(state(".claude/skills/djcrate") == .installed(v1, isCurrent: true, changes: AgentUserChanges()))
        #expect(fake.content(path(".claude/skills/djcrate/references/cli.md")) == "cli v1")
        // 이미 같으면 다시 쓰지 않는다
        #expect(tools.perform(.install(target(".claude/skills/djcrate"))) == .done(failures: []))
        #expect(fake.applied.count == 1)
    }

    @Test func 손_설치를_바꾸기_전에_묻고_확인한_것만_바꾼다() throws {
        try putHandInstalls()
        let goondori = target(".claude-goondori/skills/djcrate")
        let expected = AgentConfirmation(items: [.init(path: goondori.folder, reason: .foreign)])
        #expect(tools.perform(.install(goondori)) == .needsConfirmation(expected))
        #expect(fake.applied.isEmpty)
        // 다른 자리를 확인한 것으로는 바꾸지 않는다
        let other = AgentConfirmation(items: [.init(path: path(".agents/skills/djcrate"), reason: .foreign)])
        #expect(tools.perform(.install(goondori), confirmed: other) == .needsConfirmation(expected))
        #expect(tools.perform(.install(goondori), confirmed: expected) == .done(failures: []))
        #expect(state(".claude-goondori/skills/djcrate") == .installed(v1, isCurrent: true, changes: AgentUserChanges()))
        #expect(fake.trashed() == ["djcrate"])
    }

    // MARK: - 갱신

    @Test func 앱이_바뀌면_옛_설치본을_모두_갱신한다() throws {
        #expect(tools.perform(.install(target(".claude/skills/djcrate"))) == .done(failures: []))
        #expect(tools.perform(.install(target(".agents/skills/djcrate", .codex))) == .done(failures: []))
        try fake.put(source.appending(path: "SKILL.md"), "skill v2")
        fake.setPayload(source: source, version: v2, command: bundled)
        let report = tools.report(customClaudeFolders: [])
        #expect(report.needsUpdate)
        #expect(report.skills.filter { $0.state.needsUpdate }.count == 2)
        #expect(tools.perform(.updateAll) == .done(failures: []))
        #expect(state(".claude/skills/djcrate") == .installed(v2, isCurrent: true, changes: AgentUserChanges()))
        #expect(state(".agents/skills/djcrate") == .installed(v2, isCurrent: true, changes: AgentUserChanges()))
        #expect(fake.content(path(".agents/skills/djcrate/SKILL.md")) == "skill v2")
        // 설치하지 않은 자리는 모두 갱신이 건드리지 않는다
        #expect(state(".claude-goondori/skills/djcrate") == nil)
    }

    @Test func 앱_판만_바뀌고_스킬이_같으면_알리지_않고_건드리지_않는다() throws {
        #expect(tools.perform(.install(target(".claude/skills/djcrate"))) == .done(failures: []))
        fake.setPayload(source: source, version: v2, command: bundled)
        let report = tools.report(customClaudeFolders: [])
        #expect(!report.needsUpdate)
        #expect(state(".claude/skills/djcrate") == .installed(v2, isCurrent: true, changes: AgentUserChanges()))
        #expect(tools.perform(.updateAll) == .done(failures: []))
        #expect(fake.applied.count == 1)
    }

    @Test func 모두_갱신은_고친_파일을_덮기_전에_묻는다() throws {
        #expect(tools.perform(.install(target(".claude/skills/djcrate"))) == .done(failures: []))
        try fake.put(path(".claude/skills/djcrate/SKILL.md"), "my notes")
        try fake.put(source.appending(path: "SKILL.md"), "skill v2")
        fake.setPayload(source: source, version: v2, command: bundled)
        #expect(state(".claude/skills/djcrate")?.badge == .modified)
        let expected = AgentConfirmation(items: [.init(path: path(".claude/skills/djcrate/SKILL.md"), reason: .modified)])
        #expect(tools.perform(.updateAll) == .needsConfirmation(expected))
        #expect(fake.content(path(".claude/skills/djcrate/SKILL.md")) == "my notes")
        #expect(tools.perform(.updateAll, confirmed: expected) == .done(failures: []))
        #expect(fake.content(path(".claude/skills/djcrate/SKILL.md")) == "skill v2")
        #expect(fake.trashed() == ["SKILL.md"])
    }

    @Test func 모두_갱신은_실패한_자리를_알리고_나머지를_끝까지_한다() throws {
        #expect(tools.perform(.install(target(".claude/skills/djcrate"))) == .done(failures: []))
        #expect(tools.perform(.install(target(".agents/skills/djcrate", .codex))) == .done(failures: []))
        try fake.put(source.appending(path: "SKILL.md"), "skill v2")
        fake.setPayload(source: source, version: v2, command: bundled)
        fake.fail([path(".claude/skills/djcrate")])
        guard case let .done(failures) = tools.perform(.updateAll) else { Issue.record("갱신하지 않았다"); return }
        #expect(failures.map(\.path) == [path(".claude/skills/djcrate")])
        #expect(state(".agents/skills/djcrate") == .installed(v2, isCurrent: true, changes: AgentUserChanges()))
    }

    // MARK: - 제거

    @Test func 제거는_DJCrate가_설치한_자리만_한다() throws {
        try putHandInstalls()
        #expect(tools.perform(.install(target(".claude/skills/djcrate"))) == .done(failures: []))
        #expect(tools.perform(.remove(target(".claude/skills/djcrate"))) == .done(failures: []))
        #expect(state(".claude/skills/djcrate") == .notInstalled)
        // 손 설치는 건드리지 않는다
        #expect(tools.perform(.remove(target(".agents/skills/djcrate", .codex))) == .done(failures: []))
        #expect(tools.perform(.remove(target(".claude-goondori/skills/djcrate"))) == .done(failures: []))
        #expect(fake.content(path(".agents/skills/djcrate/SKILL.md")) == "hand copy")
        #expect(state(".claude-goondori/skills/djcrate") == .foreign(.link(destination: "/Users/me/dev/DJCrate/skills/djcrate")))
        #expect(fake.applied.count == 2)
    }

    @Test func 고친_파일이_있으면_제거_전에_묻는다() throws {
        #expect(tools.perform(.install(target(".claude/skills/djcrate"))) == .done(failures: []))
        try fake.put(path(".claude/skills/djcrate/references/cli.md"), "edited")
        let expected = AgentConfirmation(items: [.init(path: path(".claude/skills/djcrate/references/cli.md"), reason: .modified)])
        #expect(tools.perform(.remove(target(".claude/skills/djcrate"))) == .needsConfirmation(expected))
        #expect(tools.perform(.remove(target(".claude/skills/djcrate")), confirmed: expected) == .done(failures: []))
        #expect(state(".claude/skills/djcrate") == .notInstalled)
        #expect(fake.trashed() == ["cli.md"])
    }

    // MARK: - djc

    @Test func djc_링크를_만들고_지운다() {
        #expect(tools.perform(.linkCommand) == .done(failures: []))
        #expect(tools.report(customClaudeFolders: []).command.state == .linked)
        #expect(tools.perform(.unlinkCommand) == .done(failures: []))
        #expect(tools.report(customClaudeFolders: []).command.state == .missing)
    }

    @Test func 다른_djc가_있으면_바꾸기_전에_묻는다() throws {
        try putHandInstalls()
        let expected = AgentConfirmation(items: [.init(path: path(".local/bin/djc"), reason: .foreign)])
        #expect(tools.perform(.linkCommand) == .needsConfirmation(expected))
        #expect(fake.content(path(".local/bin/djc")) != nil)
        // 남의 djc는 지우기에서 건드리지 않는다
        #expect(tools.perform(.unlinkCommand) == .done(failures: []))
        #expect(tools.report(customClaudeFolders: []).command.state == .foreign(.file))
        #expect(tools.perform(.linkCommand, confirmed: expected) == .done(failures: []))
        #expect(tools.report(customClaudeFolders: []).command.state == .linked)
    }

    @Test func 옮긴_앱의_옛_링크는_모두_갱신이_묻지_않고_바꾼다() throws {
        try fake.putLink(path(".local/bin/djc"), to: "/Users/me/Downloads/DJCrate.app/Contents/Helpers/djc")
        let report = tools.report(customClaudeFolders: [])
        #expect(report.command.state == .staleLink(destination: "/Users/me/Downloads/DJCrate.app/Contents/Helpers/djc"))
        #expect(report.needsUpdate)
        #expect(tools.perform(.updateAll) == .done(failures: []))
        #expect(tools.report(customClaudeFolders: []).command.state == .linked)
    }

    @Test func 링크를_만들_수_없는_빌드와_자리() {
        fake.setPayload(source: source, version: v1, command: nil)
        #expect(tools.perform(.linkCommand) == .unavailable(nil))
        fake.setPayload(source: source, version: v1, command: URL(filePath: "/private/var/folders/x/AppTranslocation/A/d/DJCrate.app/Contents/Helpers/djc"))
        #expect(tools.perform(.linkCommand) == .unavailable(.translocated))
        #expect(tools.report(customClaudeFolders: []).command.blocked == .translocated)
        fake.setPayload(source: nil)
        #expect(tools.perform(.install(target(".claude/skills/djcrate"))) == .unavailable(nil))
        #expect(tools.report(customClaudeFolders: []).version == nil)
    }

    @Test func PATH_판정은_로그인_셸에서_읽은_값으로_한다() {
        fake.setShell(AgentShellInfo(shell: "/bin/zsh", path: "/usr/bin:/home/me/.local/bin"))
        #expect(tools.pathStatus().inPath == true)
        fake.setShell(AgentShellInfo(shell: "/bin/bash", path: "/usr/bin:/bin"))
        #expect(tools.pathStatus() == AgentPathStatus(inPath: false, guide: AgentCommandRules.pathGuide(shell: "/bin/bash")))
        // 셸을 시간 안에 읽지 못하면 모른다고 보인다(안내만)
        fake.setShell(AgentShellInfo(shell: "/bin/zsh", path: nil))
        #expect(tools.pathStatus().inPath == nil)
    }

    @Test func Codex_옛_자리의_사본을_알린다() throws {
        #expect(tools.report(customClaudeFolders: []).legacyCodexCopy == nil)
        try fake.put(path(".codex/skills/djcrate/SKILL.md"), "old")
        #expect(tools.report(customClaudeFolders: []).legacyCodexCopy == path(".codex/skills/djcrate"))
    }
}
