@testable import DJCDomain
import Foundation
import Testing

@Suite("AI 에이전트 설치 규칙")
struct AgentInstallRulesTests {
    let old = AgentPayloadVersion(version: "0.1.0", build: "100")
    let new = AgentPayloadVersion(version: "0.2.0", build: "120")

    func payload(_ files: [String: String], version: AgentPayloadVersion? = nil) -> AgentSkillPayload {
        AgentSkillPayload(version: version ?? new, files: files)
    }

    func ours(_ installed: [String: String], disk: [String: String], version: AgentPayloadVersion? = nil) -> AgentSkillFolder {
        AgentSkillFolder(entry: .folder, manifest: AgentInstallManifest(app: version ?? old, files: installed), files: disk)
    }

    // MARK: - 상태

    @Test func 자리가_비었거나_빈_폴더면_설치하지_않은_것이다() {
        let bundle = payload(["SKILL.md": "a"])
        #expect(AgentSkillRules.state(of: AgentSkillFolder(entry: .missing), payload: bundle) == .notInstalled)
        #expect(AgentSkillRules.state(of: AgentSkillFolder(entry: .folder), payload: bundle) == .notInstalled)
    }

    @Test func 표시가_없으면_DJCrate가_설치하지_않은_것이다() {
        let bundle = payload(["SKILL.md": "a"])
        // 사용자가 손으로 둔 링크(메인 체크아웃을 가리킴)·복사본·파일
        #expect(AgentSkillRules.state(of: AgentSkillFolder(entry: .link(destination: "/Users/me/dev/DJCrate/skills/djcrate")), payload: bundle)
            == .foreign(.link(destination: "/Users/me/dev/DJCrate/skills/djcrate")))
        #expect(AgentSkillRules.state(of: AgentSkillFolder(entry: .folder, files: ["SKILL.md": "a"]), payload: bundle) == .foreign(.folder))
        #expect(AgentSkillRules.state(of: AgentSkillFolder(entry: .file), payload: bundle) == .foreign(.file))
    }

    @Test func 판과_내용이_같으면_설치됨이다() {
        let state = AgentSkillRules.state(of: ours(["SKILL.md": "a"], disk: ["SKILL.md": "a"], version: new), payload: payload(["SKILL.md": "a"]))
        #expect(state == .installed(new, isCurrent: true, changes: AgentUserChanges()))
        #expect(state.badge == .installed)
        #expect(!state.needsUpdate)
    }

    @Test func 앱_판만_다르고_내용이_같으면_설치됨이다() {
        // 개발 설치마다 빌드 번호가 바뀐다. 스킬이 같으면 알리거나 갱신할 것이 없다
        let state = AgentSkillRules.state(of: ours(["SKILL.md": "a"], disk: ["SKILL.md": "a"]), payload: payload(["SKILL.md": "a"]))
        #expect(state == .installed(new, isCurrent: true, changes: AgentUserChanges()))
        #expect(state.badge == .installed)
        #expect(!state.needsUpdate)
        #expect(!AgentUpdateNotice.shouldShow(skills: [state], command: .linked, app: new, lastShown: nil))
        // 고친 파일이 있어도 판만 다른 것으로는 갱신하지 않는다(고친 파일은 따로 보인다)
        let modified = AgentSkillRules.state(of: ours(["SKILL.md": "a"], disk: ["SKILL.md": "a2"]), payload: payload(["SKILL.md": "a"]))
        #expect(modified.badge == .modified)
        #expect(!modified.needsUpdate)
    }

    @Test func 앱_판과_내용이_모두_다르면_옛_버전이다() {
        let state = AgentSkillRules.state(of: ours(["SKILL.md": "a"], disk: ["SKILL.md": "a"]), payload: payload(["SKILL.md": "b"]))
        #expect(state == .installed(old, isCurrent: false, changes: AgentUserChanges()))
        #expect(state.badge == .outdated)
        #expect(state.needsUpdate)
    }

    @Test func 판이_같아도_재료가_다르면_옛_버전이다() {
        // 개발 빌드는 판이 같은 채 스킬 내용만 바뀐다
        let state = AgentSkillRules.state(of: ours(["SKILL.md": "a"], disk: ["SKILL.md": "a"], version: new), payload: payload(["SKILL.md": "b"]))
        #expect(state.badge == .outdated)
    }

    @Test func 설치한_뒤_고치거나_지우거나_더한_파일을_찾는다() {
        let folder = ours(["SKILL.md": "a", "ref/a.md": "r", "ref/b.md": "s"], disk: ["SKILL.md": "a2", "ref/b.md": "s", "notes.md": "n"])
        // 새 앱은 ref/b.md를 바꿨다(옛 버전이면서 고친 파일도 있다)
        let state = AgentSkillRules.state(of: folder, payload: payload(["SKILL.md": "a", "ref/a.md": "r", "ref/b.md": "s2"]))
        let changes = AgentUserChanges(changed: ["SKILL.md"], removed: ["ref/a.md"], added: ["notes.md"])
        #expect(state == .installed(old, isCurrent: false, changes: changes))
        // 고친 파일이 있으면 옛 버전보다 먼저 알린다(덮기 전에 물어야 하므로)
        #expect(state.badge == .modified)
    }

    // MARK: - 설치·갱신 계획

    @Test func 처음_설치는_재료를_모두_쓰고_표시를_남긴다() {
        let bundle = payload(["SKILL.md": "a", "ref/x.md": "x"])
        let plan = AgentSkillRules.installPlan(for: AgentSkillFolder(entry: .missing), payload: bundle)
        #expect(plan.write == ["SKILL.md", "ref/x.md"])
        #expect(plan.delete.isEmpty && plan.trash.isEmpty && plan.replaces == nil)
        #expect(plan.manifest == AgentInstallManifest(app: new, files: bundle.files))
        #expect(!plan.needsConfirmation)
    }

    @Test func 남이_둔_것을_바꾸려면_묻고_통째로_휴지통에_옮긴다() {
        let link = AgentSkillFolder(entry: .link(destination: "/repo/skills/djcrate"))
        let plan = AgentSkillRules.installPlan(for: link, payload: payload(["SKILL.md": "a"]))
        #expect(plan.replaces == .link(destination: "/repo/skills/djcrate"))
        #expect(plan.write == ["SKILL.md"])
        #expect(plan.needsConfirmation)
    }

    @Test func 갱신은_바뀐_파일만_쓰고_빠진_파일은_지운다() {
        let folder = ours(["SKILL.md": "a", "old.md": "o", "same.md": "s"], disk: ["SKILL.md": "a", "old.md": "o", "same.md": "s"])
        let plan = AgentSkillRules.installPlan(for: folder, payload: payload(["SKILL.md": "b", "same.md": "s", "new.md": "n"]))
        #expect(plan.write == ["SKILL.md", "new.md"])
        #expect(plan.delete == ["old.md"])
        #expect(!plan.needsConfirmation)
        #expect(plan.manifest?.files == ["SKILL.md": "b", "same.md": "s", "new.md": "n"])
    }

    @Test func 사용자가_고친_파일을_덮을_때만_묻는다() {
        // SKILL.md는 사용자가 고쳤고 새 재료와 다르다 → 휴지통에 옮긴 뒤 쓴다(물음)
        // gone.md는 사용자가 지웠다 → 다시 만든다(묻지 않음). old.md는 고친 채 재료에서 빠졌다 → 지우지 않고 남긴다
        // done.md는 사용자가 고친 내용이 새 재료와 같다 → 쓰지 않는다
        let folder = ours(["SKILL.md": "a", "gone.md": "g", "old.md": "o", "done.md": "d"],
                          disk: ["SKILL.md": "mine", "old.md": "mine2", "done.md": "d2", "extra.md": "e"])
        let plan = AgentSkillRules.installPlan(for: folder, payload: payload(["SKILL.md": "b", "gone.md": "g", "done.md": "d2"]))
        #expect(plan.write == ["SKILL.md", "gone.md"])
        #expect(plan.trash == ["SKILL.md"])
        #expect(plan.delete.isEmpty)
        #expect(plan.needsConfirmation)
    }

    @Test func 판만_다르면_표시만_새로_쓴다() {
        let folder = ours(["SKILL.md": "a"], disk: ["SKILL.md": "a"])
        let plan = AgentSkillRules.installPlan(for: folder, payload: payload(["SKILL.md": "a"]))
        #expect(plan.write.isEmpty && plan.delete.isEmpty && plan.trash.isEmpty)
        #expect(plan.manifest == AgentInstallManifest(app: new, files: ["SKILL.md": "a"]))
    }

    // MARK: - 제거 계획

    @Test func 제거는_DJCrate가_넣은_그대로인_파일만_지운다() throws {
        let folder = ours(["SKILL.md": "a", "ref/a.md": "r", "gone.md": "g"], disk: ["SKILL.md": "mine", "ref/a.md": "r", "notes.md": "n"])
        let plan = try #require(AgentSkillRules.removePlan(for: folder))
        #expect(plan.delete == ["ref/a.md"])
        #expect(plan.trash == ["SKILL.md"])
        #expect(plan.write.isEmpty && plan.manifest == nil && plan.replaces == nil)
        #expect(plan.needsConfirmation)
    }

    @Test func 남이_둔_것은_제거하지_않는다() {
        #expect(AgentSkillRules.removePlan(for: AgentSkillFolder(entry: .link(destination: "/repo"))) == nil)
        #expect(AgentSkillRules.removePlan(for: AgentSkillFolder(entry: .folder, files: ["SKILL.md": "a"])) == nil)
        #expect(AgentSkillRules.removePlan(for: AgentSkillFolder(entry: .missing)) == nil)
    }

    // MARK: - djc 링크

    let bundled = "/Applications/DJCrate.app/Contents/Helpers/djc"

    @Test func djc_자리의_상태() {
        #expect(AgentCommandRules.state(of: .missing, bundled: bundled) == .missing)
        #expect(AgentCommandRules.state(of: .link(destination: bundled), bundled: bundled) == .linked)
        #expect(AgentCommandRules.state(of: .link(destination: "/Applications/DJCrate.app/Contents/Helpers/../Helpers/djc"), bundled: bundled) == .linked)
        // 옮기기 전 자리·옛 빌드의 앱을 가리키는 링크는 DJCrate가 만든 링크다
        #expect(AgentCommandRules.state(of: .link(destination: "/Users/me/Downloads/DJCrate.app/Contents/Helpers/djc"), bundled: bundled)
            == .staleLink(destination: "/Users/me/Downloads/DJCrate.app/Contents/Helpers/djc"))
        // 손으로 둔 스크립트·다른 곳을 가리키는 링크는 다른 djc다
        #expect(AgentCommandRules.state(of: .file, bundled: bundled) == .foreign(.file))
        #expect(AgentCommandRules.state(of: .link(destination: "/Users/me/.local/lib/djcrate/djc"), bundled: bundled)
            == .foreign(.link(destination: "/Users/me/.local/lib/djcrate/djc")))
        #expect(AgentCommandRules.state(of: .folder, bundled: bundled) == .foreign(.folder))
    }

    @Test func 격리된_자리에서_연_앱은_링크를_만들지_않는다() {
        #expect(AgentCommandRules.linkBlocked(bundled: bundled) == nil)
        #expect(AgentCommandRules.linkBlocked(bundled: "/private/var/folders/x/AppTranslocation/ABC/d/DJCrate.app/Contents/Helpers/djc") == .translocated)
    }

    @Test func PATH에_폴더가_있는지() {
        let home = "/Users/me"
        #expect(AgentCommandRules.pathContains("/Users/me/.local/bin", path: "/usr/bin:/Users/me/.local/bin:/bin", home: home))
        #expect(AgentCommandRules.pathContains("/Users/me/.local/bin", path: "/usr/bin:/Users/me/.local/bin/", home: home))
        #expect(AgentCommandRules.pathContains("/Users/me/.local/bin", path: "~/.local/bin:/bin", home: home))
        #expect(AgentCommandRules.pathContains("/Users/me/.local/bin", path: "$HOME/.local/bin", home: home))
        #expect(!AgentCommandRules.pathContains("/Users/me/.local/bin", path: "/usr/bin:/Users/me/.local/binx", home: home))
        #expect(!AgentCommandRules.pathContains("/Users/me/.local/bin", path: "", home: home))
    }

    @Test func 셸마다_PATH에_더할_줄() {
        #expect(AgentCommandRules.pathGuide(shell: "/bin/zsh") == AgentPathGuide(file: "~/.zshrc", line: #"export PATH="$HOME/.local/bin:$PATH""#))
        #expect(AgentCommandRules.pathGuide(shell: nil).file == "~/.zshrc")
        #expect(AgentCommandRules.pathGuide(shell: "/bin/bash") == AgentPathGuide(file: "~/.bash_profile", line: #"export PATH="$HOME/.local/bin:$PATH""#))
        #expect(AgentCommandRules.pathGuide(shell: "/opt/homebrew/bin/fish")
            == AgentPathGuide(file: "~/.config/fish/config.fish", line: "fish_add_path $HOME/.local/bin"))
    }

    // MARK: - 위치

    @Test func Claude_설정_폴더_찾기() {
        let entries = [
            AgentHomeEntry(name: ".claude-work", isDirectory: true, children: ["settings.json", "projects"]),
            AgentHomeEntry(name: ".claude.json", isDirectory: false),
            AgentHomeEntry(name: ".claude-fotone", isDirectory: true, children: ["skills"]),
            AgentHomeEntry(name: ".claude-empty", isDirectory: true, children: []),
            AgentHomeEntry(name: ".cache", isDirectory: true, children: ["settings.json"]),
            AgentHomeEntry(name: ".claude", isDirectory: true, children: ["projects"]),
        ]
        // 기본 폴더가 맨 앞, 나머지는 이름 차례. 설정 폴더로 보이지 않는 것은 뺀다
        #expect(AgentLocations.claudeConfigFolders(in: entries) == [".claude", ".claude-fotone", ".claude-work"])
        // 기본 폴더는 없어도 늘 보인다(Claude Code를 처음 쓰는 사용자)
        #expect(AgentLocations.claudeConfigFolders(in: []) == [".claude"])
    }

    @Test func 고른_폴더에서_설치_자리() {
        #expect(AgentLocations.skillFolder(picked: URL(filePath: "/x/.claude-work")) == URL(filePath: "/x/.claude-work/skills/djcrate"))
        #expect(AgentLocations.skillFolder(picked: URL(filePath: "/x/.claude-work/skills")) == URL(filePath: "/x/.claude-work/skills/djcrate"))
        #expect(AgentLocations.skillFolder(picked: URL(filePath: "/x/skills/djcrate")) == URL(filePath: "/x/skills/djcrate"))
    }

    @Test func 기본_자리() {
        let home = URL(filePath: "/Users/me")
        #expect(AgentLocations.defaultSkillFolder(.codex, home: home) == URL(filePath: "/Users/me/.agents/skills/djcrate"))
        #expect(AgentLocations.defaultSkillFolder(.claudeCode, home: home) == URL(filePath: "/Users/me/.claude/skills/djcrate"))
        #expect(AgentLocations.commandLink(home: home) == URL(filePath: "/Users/me/.local/bin/djc"))
    }

    // MARK: - 켤 때 알림

    @Test func 옛_설치본이_있으면_앱_판마다_한_번_알린다() {
        let outdated = AgentSkillState.installed(old, isCurrent: false, changes: AgentUserChanges())
        let current = AgentSkillState.installed(new, isCurrent: true, changes: AgentUserChanges())
        #expect(AgentUpdateNotice.shouldShow(skills: [current, outdated], command: .linked, app: new, lastShown: nil))
        #expect(!AgentUpdateNotice.shouldShow(skills: [current, outdated], command: .linked, app: new, lastShown: new.key))
        #expect(AgentUpdateNotice.shouldShow(skills: [current, outdated], command: .linked, app: new, lastShown: old.key))
        // 옛 링크(옮긴 앱)도 알린다
        #expect(AgentUpdateNotice.shouldShow(skills: [current], command: .staleLink(destination: "/old/DJCrate.app/Contents/Helpers/djc"), app: new,
                                             lastShown: nil))
        // 설치하지 않았거나 남이 둔 것은 알리지 않는다(사용자가 고른 일이 아니다)
        #expect(!AgentUpdateNotice.shouldShow(skills: [.notInstalled, .foreign(.folder), current], command: .foreign(.file), app: new, lastShown: nil))
    }

    @Test func 표시_파일은_JSON으로_오간다() throws {
        let manifest = AgentInstallManifest(app: new, files: ["SKILL.md": "abc"])
        let data = try manifest.encoded()
        #expect(try AgentInstallManifest.decode(data) == manifest)
        #expect(throws: (any Error).self) { try AgentInstallManifest.decode(Data("{}".utf8)) }
        #expect(AgentInstallManifest.fileName == ".djcrate-install.json")
    }
}
