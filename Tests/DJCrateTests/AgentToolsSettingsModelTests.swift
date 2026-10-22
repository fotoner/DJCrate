@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 설정 › AI 에이전트 화면 모델(#262). 실제 파일 구현을 임시 폴더(홈·앱 번들·휴지통)에 돌린다. 사용자 홈은 쓰지 않는다
@MainActor
@Suite("설정 AI 에이전트")
struct AgentToolsSettingsModelTests {
    let folder: TemporaryFolder
    let home: URL
    let app: URL
    let trash: URL
    let v1 = AgentPayloadVersion(version: "0.1.0", build: "100")
    let v2 = AgentPayloadVersion(version: "0.2.0", build: "120")
    /// 확인 창에 보인 것과 답
    final class Prompts {
        var shown: [ReflectionPrompt] = []
        var answer = true
        /// 확인 창이 떠 있는 동안 할 일(시험이 다른 입구를 부른다)
        var whileShown: (() -> Void)?
    }
    let prompts = Prompts()

    init() throws {
        folder = try TemporaryFolder(prefix: "djc-agent-model")
        let root = folder.url.resolvingSymlinksInPath()
        home = root.appending(path: "home")
        app = root.appending(path: "Applications/DJCrate.app")
        trash = root.appending(path: "trash")
        try write(app.appending(path: "Contents/Resources/skills/djcrate/SKILL.md"), "skill v1")
        try write(app.appending(path: "Contents/Helpers/djc"), "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appending(path: "Contents/Helpers/djc").path)
        try FileManager.default.createDirectory(at: home.appending(path: ".claude/projects"), withIntermediateDirectories: true)
    }

    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func model(_ version: AgentPayloadVersion? = nil, settings: SettingsStore? = nil, shellPath: String? = nil) -> AgentToolsSettingsModel {
        let layout = AgentBundleLayout.appBundle(app, info: ["CFBundleShortVersionString": (version ?? v1).version,
                                                             "CFBundleVersion": (version ?? v1).build])
        let prompts = prompts
        // 파일 일은 임시 폴더의 실제 구현, 로그인 셸은 정해 둔 값(이 Mac의 셸을 띄우지 않는다)
        var files = AgentToolFiles.live(layout: layout, trash: trash)
        files.shell = { _ in AgentShellInfo(shell: "/bin/zsh", path: shellPath) }
        return AgentToolsSettingsModel(tools: AgentTools(files: files, home: home), settings: settings) {
            prompts.shown.append($0)
            prompts.whileShown?()
            return prompts.answer
        }
    }

    func row(_ model: AgentToolsSettingsModel, _ relative: String) -> AgentToolsSettingsModel.SkillRow? {
        model.skillRows.first { $0.target.folder.standardizedFileURL == home.appending(path: relative).standardizedFileURL }
    }

    /// 이 Mac의 손 설치와 같은 꼴: 메인 체크아웃을 가리키는 링크, 복사본, 다른 djc를 부르는 스크립트
    func putHandInstalls() throws {
        try FileManager.default.createDirectory(at: home.appending(path: ".claude-goondori/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.appending(path: ".claude-goondori/skills/djcrate").path,
                                                   withDestinationPath: folder.url.appending(path: "repo/skills/djcrate").path)
        try write(home.appending(path: ".agents/skills/djcrate/SKILL.md"), "hand copy")
        try write(home.appending(path: ".local/bin/djc"), "#!/bin/sh\nexec ~/.local/lib/djcrate/djc \"$@\"\n")
    }

    @Test func 손_설치는_DJCrate가_설치하지_않은_것으로_보이고_바꾸기_전에_묻는다() async throws {
        try putHandInstalls()
        let model = model()
        await model.refresh()
        let goondori = try #require(row(model, ".claude-goondori/skills/djcrate"))
        #expect(goondori.status == String(ui: "DJCrate가 설치하지 않음"))
        #expect(goondori.installTitle == String(ui: "DJCrate 것으로 바꾸기…"))
        #expect(!goondori.canRemove)
        #expect(row(model, ".agents/skills/djcrate")?.detail == String(ui: "직접 둔 폴더(설치 표시 없음)"))
        #expect(model.commandRow?.status == String(ui: "다른 djc가 있음"))
        #expect(model.commandRow?.canUnlink == false)

        // 묻고, 거절하면 그대로 둔다
        prompts.answer = false
        model.start(.install(goondori.target))
        await model.task?.value
        #expect(prompts.shown.count == 1)
        #expect(prompts.shown.first?.details == [String(ui: "~/.claude-goondori/skills/djcrate — DJCrate가 설치하지 않음")])
        #expect(model.message == String(ui: "바꾸지 않았습니다."))
        #expect(row(model, ".claude-goondori/skills/djcrate")?.state == .foreign(.link(destination: folder.url.appending(path: "repo/skills/djcrate").path)))

        // 확인하면 링크만 휴지통으로 옮기고 복사로 설치한다
        prompts.answer = true
        model.start(.install(goondori.target))
        await model.task?.value
        #expect(row(model, ".claude-goondori/skills/djcrate")?.state.badge == .installed)
        #expect(read(home.appending(path: ".claude-goondori/skills/djcrate/SKILL.md")) == "skill v1")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) == ["djcrate"])
    }

    @Test func 설치하고_고친_파일은_갱신_때_묻고_제거한다() async throws {
        let first = model()
        await first.refresh()
        let claude = try #require(row(first, ".claude/skills/djcrate"))
        #expect(claude.status == String(ui: "설치하지 않음"))
        first.start(.install(claude.target))
        await first.task?.value
        #expect(prompts.shown.isEmpty)
        #expect(row(first, ".claude/skills/djcrate")?.status == String(ui: "설치됨(0.1.0)"))
        #expect(row(first, ".claude/skills/djcrate")?.installTitle == nil)

        // 사용자가 고친 뒤 앱이 바뀌었다
        try write(home.appending(path: ".claude/skills/djcrate/SKILL.md"), "my notes")
        try write(app.appending(path: "Contents/Resources/skills/djcrate/SKILL.md"), "skill v2")
        let second = model(v2)
        await second.refresh()
        #expect(second.needsUpdate)
        #expect(row(second, ".claude/skills/djcrate")?.status == String(ui: "고친 파일 있음"))
        #expect(row(second, ".claude/skills/djcrate")?.installTitle == String(ui: "갱신"))
        second.start(.updateAll)
        await second.task?.value
        #expect(prompts.shown.last?.details == [String(ui: "~/.claude/skills/djcrate/SKILL.md — 설치한 뒤 고침")])
        #expect(read(home.appending(path: ".claude/skills/djcrate/SKILL.md")) == "skill v2")
        #expect(!second.needsUpdate)

        second.start(.remove(claude.target))
        await second.task?.value
        #expect(row(second, ".claude/skills/djcrate")?.state == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/djcrate").path))
        #expect(second.message == String(ui: "스킬을 제거했습니다."))
    }

    @Test func djc_링크와_PATH_안내() async throws {
        let model = model()
        await model.refresh()
        #expect(model.commandRow?.linkTitle == String(ui: "링크 만들기"))
        model.start(.linkCommand)
        await model.task?.value
        #expect(model.commandRow?.status == String(ui: "이 앱의 djc를 가리킴"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.appending(path: ".local/bin/djc").path)
            == app.appending(path: "Contents/Helpers/djc").path)
        // PATH에 없으면 더할 줄을, 셸을 읽지 못하면 확인 방법과 줄을 보인다
        let path = try #require(model.pathText)
        #expect(path.text == String(ui: "셸 PATH를 읽지 못했습니다. 터미널에서 which djc로 확인하고, 없으면 ~/.zshrc에 아래 줄을 더하세요."))
        #expect(path.line == #"export PATH="$HOME/.local/bin:$PATH""#)
        let outside = self.model(shellPath: "/usr/bin:/bin")
        await outside.refresh()
        #expect(outside.pathText?.text == String(ui: "~/.local/bin가 셸 PATH에 없습니다. ~/.zshrc에 아래 줄을 더한 뒤 새 터미널을 여세요."))
        let inside = self.model(shellPath: "/usr/bin:\(home.path)/.local/bin")
        await inside.refresh()
        #expect(inside.pathText?.line == nil)
        model.start(.unlinkCommand)
        await model.task?.value
        #expect(model.commandRow?.status == String(ui: "없음"))
    }

    @Test func 켤_때_옛_설치본을_앱_판마다_한_번_알리고_알림에서_모두_갱신한다() async throws {
        let settings = SettingsStore(defaults: TestDefaults.make("agent-notice"), persist: true)
        let old = model(settings: settings)
        #expect(await old.launchNotice() == nil)
        old.start(.install(AgentTarget(kind: .codex, folder: home.appending(path: ".agents/skills/djcrate"))))
        await old.task?.value
        #expect(await old.launchNotice() == nil)

        // 판만 바뀐 앱은 스킬이 같아 알리지 않는다
        #expect(await model(v2, settings: settings).launchNotice() == nil)
        try write(app.appending(path: "Contents/Resources/skills/djcrate/SKILL.md"), "skill v2")
        let updated = model(v2, settings: settings)
        // 다른 알림이 떠 있어 보이지 못했으면 알린 것으로 치지 않는다
        #expect(await updated.launchNotice(present: { _ in false }) == nil)
        #expect(settings.value(SettingKeys.agentToolsNotifiedVersion) == "")
        let toast = try #require(await updated.launchNotice())
        #expect(toast.action == .updateAgentTools)
        #expect(toast.kind == .warning)
        #expect(await updated.launchNotice() == nil)
        #expect(settings.value(SettingKeys.agentToolsNotifiedVersion) == v2.key)

        // 알림의 "모두 갱신"(주 창 모델 입구)
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("agent-window"), persist: false))
        let window = LibraryWindowModel(store: store)
        window.agentTools = updated
        store.showToast(toast)
        await window.performToastAction(.updateAgentTools).value
        #expect(store.toast?.kind == .success)
        #expect(store.toast?.title == String(ui: "모두 갱신했습니다. 에이전트의 새 세션부터 새 스킬을 읽습니다."))
        #expect(row(updated, ".agents/skills/djcrate")?.state == .installed(v2, isCurrent: true, changes: AgentUserChanges()))
    }

    @Test func 다른_작업_중이면_알림의_모두_갱신은_기다리라고_알린다() async throws {
        let model = model()
        let codex = AgentTarget(kind: .codex, folder: home.appending(path: ".agents/skills/djcrate"))
        await model.perform(.install(codex))
        try write(codex.folder.appending(path: "SKILL.md"), "mine")
        // 제거가 확인 창을 띄운 사이(작업 중) 알림의 "모두 갱신"을 누른다
        var notice: Task<AppToast, Never>?
        prompts.whileShown = { notice = Task { await model.updateAllFromNotice() } }
        await model.perform(.remove(codex))
        let toast = try #require(await notice?.value)
        #expect(toast.title == String(ui: "설정의 AI 에이전트 작업이 끝난 뒤 다시 하세요."))
        #expect(toast.kind == .warning)
        #expect(model.message == String(ui: "스킬을 제거했습니다."))
    }

    @Test func 다른_위치를_더하고_목록에서만_뺀다() async throws {
        let settings = SettingsStore(defaults: TestDefaults.make("agent-custom"), persist: true)
        let model = model(settings: settings)
        let picked = folder.url.appending(path: "work-claude")
        model.addCustomFolder(picked)
        await model.task?.value
        let custom = try #require(model.skillRows.first { $0.target.isCustom })
        #expect(custom.target.folder == picked.appending(path: "skills/djcrate"))
        #expect(settings.strings(SettingKeys.agentToolsClaudeFolders) == [picked.appending(path: "skills/djcrate").path])
        // 다시 켜도 남는다
        let again = self.model(settings: settings)
        await again.refresh()
        #expect(again.skillRows.contains { $0.target.isCustom })
        again.removeCustomFolder(custom.target)
        await again.task?.value
        #expect(!again.skillRows.contains { $0.target.isCustom })
    }

    @Test func 홈_아래_경로는_물결표로_줄인다() {
        let home = URL(filePath: "/Users/me")
        #expect(AgentToolsSettingsModel.display(URL(filePath: "/Users/me/.claude/skills/djcrate"), home: home) == "~/.claude/skills/djcrate")
        #expect(AgentToolsSettingsModel.display(URL(filePath: "/Users/meow/x"), home: home) == "/Users/meow/x")
    }
}
