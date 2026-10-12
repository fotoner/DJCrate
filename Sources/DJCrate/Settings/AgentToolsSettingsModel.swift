import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 설정 › AI 에이전트(#262): 앱에 든 DJCrate 스킬을 Claude Code·Codex 자리에 설치·갱신·제거하고, 번들 djc를 `~/.local/bin/djc` 링크로 둔다.
/// 상태와 할 일은 유스케이스 `AgentTools`가 정한다. 남의 것을 바꾸거나 고친 파일을 덮을 때는 확인 창(`confirm`)을 거친다.
/// 앱을 켤 때 옛 설치본이 있으면 앱 판마다 한 번 알린다(`launchNotice`). 모델은 조립 지점이 하나 만들어 설정 창과 알림이 함께 쓴다.
@MainActor @Observable
final class AgentToolsSettingsModel {
    /// 화면 한 줄(스킬 자리 하나)
    struct SkillRow: Identifiable, Equatable {
        let target: AgentTarget
        let state: AgentSkillState
        let title: String
        let location: String
        let status: String
        /// 상태 아래 한 줄(남의 것의 모양, 고친 파일)
        let detail: String?
        /// 설치·갱신 단추 이름. nil이면 단추가 없다(이미 같다)
        let installTitle: String?
        let canRemove: Bool

        var id: String { target.id }
    }

    struct CommandRow: Equatable {
        let location: String
        let status: String
        let detail: String?
        /// 링크 단추 이름. nil이면 단추가 없다
        let linkTitle: String?
        let canUnlink: Bool
    }

    private(set) var report: AgentToolsReport?
    private(set) var pathStatus: AgentPathStatus?
    private(set) var isWorking = false
    /// 마지막 결과 한 줄
    private(set) var message: String?
    /// 마지막 일이 실패했거나 할 수 없었는지(알림 색)
    private(set) var lastFailed = false

    @ObservationIgnored private let tools: AgentTools
    @ObservationIgnored private let settings: SettingsStore?
    @ObservationIgnored private let confirm: @MainActor (ReflectionPrompt) -> Bool
    /// 단추가 마지막으로 시작한 일. 설정 창을 닫아도 끝까지 간다. 시험은 이것을 기다린다
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    /// - Parameters:
    ///   - tools: 설치 유스케이스(홈은 조립 지점이 준다. 시험·자가 테스트는 임시 폴더)
    ///   - settings: 고른 자리와 알림 기록. 시험은 nil(저장하지 않는다)
    ///   - confirm: 바꾸기 전 확인 창. 확인이면 true
    init(tools: AgentTools, settings: SettingsStore?, confirm: @escaping @MainActor (ReflectionPrompt) -> Bool) {
        self.tools = tools
        self.settings = settings
        self.confirm = confirm
        customFolders = settings.map { $0.strings(SettingKeys.agentToolsClaudeFolders).sorted().map { URL(filePath: $0) } } ?? []
    }

    /// "다른 위치…"로 더한 Claude Code 스킬 자리
    private(set) var customFolders: [URL] {
        didSet { settings?.setStrings(SettingKeys.agentToolsClaudeFolders, Set(customFolders.map(\.path))) }
    }

    // MARK: - 읽기

    func refresh() async {
        let tools = tools, custom = customFolders
        report = await BlockingWork.run { tools.report(customClaudeFolders: custom) }
        // 로그인 셸은 느릴 수 있어 상태를 먼저 보인 뒤 읽는다
        pathStatus = await BlockingWork.run { tools.pathStatus() }
    }

    /// 앱을 켤 때: DJCrate가 설치한 것 가운데 이 앱과 다른 것이 있으면 앱 판마다 한 번 알린다.
    /// `present`가 실제로 보였을 때만(다른 알림이 없을 때) 알린 판을 남긴다. 보인 토스트를 돌려준다
    func launchNotice(present: (AppToast) -> Bool = { _ in true }) async -> AppToast? {
        let tools = tools, custom = customFolders
        let report = await BlockingWork.run { tools.report(customClaudeFolders: custom) }
        self.report = report
        guard let version = report.version,
              AgentUpdateNotice.shouldShow(skills: report.skills.map(\.state), command: report.command.state, app: version,
                                           lastShown: settings?.value(SettingKeys.agentToolsNotifiedVersion)) else { return nil }
        var toast = AppToast.notice(String(ui: "AI 에이전트 스킬이 옛 버전입니다"),
                                    String(ui: "Claude Code·Codex에 설치한 DJCrate 스킬·djc를 이 앱(\(version.version))에 맞춰 갱신하세요. 설정 › AI 에이전트에서도 할 수 있습니다."))
        toast.action = .updateAgentTools
        guard present(toast) else { return nil }
        settings?.set(SettingKeys.agentToolsNotifiedVersion, version.key)
        return toast
    }

    // MARK: - 단추

    func start(_ action: AgentToolsAction) { task = Task { _ = await perform(action) } }

    /// 다른 작업 중이면 하지 않고 false
    @discardableResult
    func perform(_ action: AgentToolsAction) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        let tools = tools, custom = customFolders
        var result = await BlockingWork.run { tools.perform(action, customClaudeFolders: custom) }
        if case let .needsConfirmation(confirmation) = result {
            guard confirm(Self.prompt(action, confirmation, home: tools.home)) else {
                message = String(ui: "바꾸지 않았습니다.")
                lastFailed = false
                return true
            }
            result = await BlockingWork.run { tools.perform(action, customClaudeFolders: custom, confirmed: confirmation) }
        }
        message = Self.summary(action, result, home: tools.home)
        lastFailed = switch result {
        case let .done(failures): !failures.isEmpty
        case .unavailable: true
        case .needsConfirmation: false
        }
        await refresh()
        return true
    }

    /// 켤 때 알림의 "모두 갱신": 결과를 알림으로 돌려준다(설정 창의 작업이 돌고 있으면 기다리라고 알린다)
    func updateAllFromNotice() async -> AppToast {
        guard await perform(.updateAll), let message else {
            return .notice(String(ui: "설정의 AI 에이전트 작업이 끝난 뒤 다시 하세요."), nil, kind: .warning)
        }
        return .notice(message, nil, kind: lastFailed ? .warning : .success)
    }

    /// "다른 위치…"에서 고른 폴더를 더한다(스킬 폴더·skills 폴더·설정 폴더 어느 것이든)
    func addCustomFolder(_ picked: URL) {
        let folder = AgentLocations.skillFolder(picked: picked)
        guard !customFolders.contains(folder) else { return }
        customFolders.append(folder)
        task = Task { await refresh() }
    }

    /// 목록에서만 뺀다(파일은 그대로)
    func removeCustomFolder(_ target: AgentTarget) {
        customFolders.removeAll { $0 == target.folder }
        task = Task { await refresh() }
    }

    // MARK: - 화면 값

    var versionText: String? {
        report?.version.map { String(ui: "이 앱의 스킬·djc: \($0.version) (빌드 \($0.build))") }
    }

    var noPayloadText: String? {
        report != nil && report?.version == nil ? String(ui: "이 빌드에는 설치할 스킬이 없습니다. 릴리스 앱(DJCrate.app)에서 설치하세요.") : nil
    }

    var needsUpdate: Bool { report?.needsUpdate ?? false }

    var legacyCodexText: String? {
        report?.legacyCodexCopy.map {
            String(ui: "\(Self.display($0, home: tools.home))에도 DJCrate 스킬이 있습니다. Codex가 같은 스킬을 두 번 보일 수 있으니 하나를 지우세요.")
        }
    }

    var skillRows: [SkillRow] {
        (report?.skills ?? []).map { Self.row($0, home: tools.home, hasPayload: report?.version != nil) }
    }

    var commandRow: CommandRow? { report.map { Self.row($0.command, home: tools.home) } }

    /// PATH 안내 한 줄과 더할 줄(PATH에 있으면 줄이 없다)
    var pathText: (text: String, line: String?)? {
        guard let pathStatus else { return nil }
        let folder = Self.display(tools.commandLink.deletingLastPathComponent(), home: tools.home)
        switch pathStatus.inPath {
        case true?: return (String(ui: "\(folder)가 셸 PATH에 있어 터미널과 에이전트가 djc를 바로 부릅니다."), nil)
        case false?:
            return (String(ui: "\(folder)가 셸 PATH에 없습니다. \(pathStatus.guide.file)에 아래 줄을 더한 뒤 새 터미널을 여세요."), pathStatus.guide.line)
        case nil:
            return (String(ui: "셸 PATH를 읽지 못했습니다. 터미널에서 which djc로 확인하고, 없으면 \(pathStatus.guide.file)에 아래 줄을 더하세요."),
                    pathStatus.guide.line)
        }
    }

    static func row(_ skill: AgentSkillReport, home: URL, hasPayload: Bool) -> SkillRow {
        let title = switch skill.target.kind {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
        var detail: String?
        var installTitle: String? = hasPayload ? String(ui: "설치") : nil
        let status: String
        switch skill.state {
        case .notInstalled:
            status = String(ui: "설치하지 않음")
        case let .foreign(kind):
            status = String(ui: "DJCrate가 설치하지 않음")
            detail = foreignText(kind, home: home)
            installTitle = hasPayload ? String(ui: "DJCrate 것으로 바꾸기…") : nil
        case let .installed(version, isCurrent, changes):
            switch skill.state.badge {
            case .modified: status = String(ui: "고친 파일 있음")
            case .outdated: status = String(ui: "옛 버전(\(version.version))")
            default: status = String(ui: "설치됨(\(version.version))")
            }
            let edited = changes.changed + changes.removed + changes.added
            if !edited.isEmpty { detail = String(ui: "설치한 뒤 바뀐 파일: \(edited.joined(separator: ", "))") }
            installTitle = !hasPayload ? nil : !isCurrent ? String(ui: "갱신") : changes.changed.isEmpty && changes.removed.isEmpty ? nil : String(ui: "다시 설치")
        }
        return SkillRow(target: skill.target, state: skill.state, title: title, location: display(skill.target.folder, home: home), status: status,
                        detail: detail, installTitle: installTitle, canRemove: { if case .installed = skill.state { true } else { false } }())
    }

    static func row(_ command: AgentCommandReport, home: URL) -> CommandRow {
        let location = display(command.link, home: home)
        if command.blocked == .translocated {
            return CommandRow(location: location, status: String(ui: "링크를 만들 수 없음"),
                              detail: String(ui: "DJCrate를 응용 프로그램 폴더로 옮긴 뒤 다시 열고 하세요."), linkTitle: nil, canUnlink: command.state.isOurs)
        }
        let canLink = command.bundled != nil
        switch command.state {
        case .missing:
            return CommandRow(location: location, status: String(ui: "없음"),
                              detail: canLink ? nil : String(ui: "이 빌드에는 djc가 없습니다. 릴리스 앱(DJCrate.app)에서 하세요."),
                              linkTitle: canLink ? String(ui: "링크 만들기") : nil, canUnlink: false)
        case .linked:
            return CommandRow(location: location, status: String(ui: "이 앱의 djc를 가리킴"), detail: nil, linkTitle: nil, canUnlink: true)
        case let .staleLink(destination):
            return CommandRow(location: location, status: String(ui: "옛 앱을 가리킴"), detail: display(URL(filePath: destination), home: home),
                              linkTitle: canLink ? String(ui: "갱신") : nil, canUnlink: true)
        case let .foreign(kind):
            return CommandRow(location: location, status: String(ui: "다른 djc가 있음"), detail: foreignText(kind, home: home),
                              linkTitle: canLink ? String(ui: "DJCrate 것으로 바꾸기…") : nil, canUnlink: false)
        }
    }

    static func foreignText(_ kind: AgentForeignKind, home: URL) -> String {
        switch kind {
        case let .link(destination): String(ui: "링크: \(display(URL(filePath: destination), home: home))")
        case .folder: String(ui: "직접 둔 폴더(설치 표시 없음)")
        case .file: String(ui: "직접 둔 파일")
        }
    }

    /// 홈 아래 경로는 `~`로 줄여 보인다
    static func display(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path, base = home.standardizedFileURL.path
        return path == base ? "~" : path.hasPrefix(base + "/") ? "~" + path.dropFirst(base.count) : path
    }

    static func prompt(_ action: AgentToolsAction, _ confirmation: AgentConfirmation, home: URL) -> ReflectionPrompt {
        let details = confirmation.items.map { item in
            switch item.reason {
            case .foreign: String(ui: "\(display(item.path, home: home)) — DJCrate가 설치하지 않음")
            case .modified: String(ui: "\(display(item.path, home: home)) — 설치한 뒤 고침")
            }
        }
        let title = switch action {
        case .remove: String(ui: "고친 파일도 휴지통으로 옮기고 제거할까요?")
        default: String(ui: "아래 항목을 휴지통으로 옮기고 바꿀까요?")
        }
        return ReflectionPrompt(title: title, text: String(ui: "DJCrate가 설치하지 않았거나 설치한 뒤 고친 것입니다. 휴지통에서 되살릴 수 있습니다."),
                                confirm: String(ui: "휴지통으로 옮기고 계속"), destructive: true, details: details)
    }

    static func summary(_ action: AgentToolsAction, _ result: AgentToolsResult, home: URL) -> String {
        switch result {
        case .needsConfirmation: return String(ui: "바꾸지 않았습니다.")
        case .unavailable(.translocated?): return String(ui: "DJCrate를 응용 프로그램 폴더로 옮긴 뒤 다시 열고 하세요.")
        case .unavailable(nil): return String(ui: "이 빌드에는 설치할 스킬·djc가 없습니다. 릴리스 앱(DJCrate.app)에서 하세요.")
        case let .done(failures) where !failures.isEmpty:
            let lines = failures.map { "\(display($0.path, home: home)): \($0.message)" }
            return String(ui: "\(failures.count)곳을 바꾸지 못했습니다. 권한을 확인한 뒤 다시 하세요.") + "\n" + lines.joined(separator: "\n")
        case .done:
            return switch action {
            case .install: String(ui: "스킬을 설치했습니다. 에이전트의 새 세션부터 읽습니다.")
            case .remove: String(ui: "스킬을 제거했습니다.")
            case .linkCommand: String(ui: "djc 링크를 만들었습니다.")
            case .unlinkCommand: String(ui: "djc 링크를 지웠습니다.")
            case .updateAll: String(ui: "모두 갱신했습니다. 에이전트의 새 세션부터 새 스킬을 읽습니다.")
            }
        }
    }
}
