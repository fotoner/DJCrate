import DJCDomain
import Foundation

/// 스킬 설치 자리 하나
public struct AgentTarget: Sendable, Hashable, Identifiable {
    public var kind: AgentKind
    /// 스킬 폴더(`…/skills/djcrate`)
    public var folder: URL
    /// "다른 위치…"로 고른 자리
    public var isCustom: Bool

    public init(kind: AgentKind, folder: URL, isCustom: Bool = false) {
        self.kind = kind
        self.folder = folder
        self.isCustom = isCustom
    }

    public var id: String { folder.path }
}

public struct AgentSkillReport: Sendable, Equatable, Identifiable {
    public var target: AgentTarget
    public var state: AgentSkillState

    public var id: String { target.id }
}

public struct AgentCommandReport: Sendable, Equatable {
    /// `~/.local/bin/djc`
    public var link: URL
    /// 번들 안 djc. 없으면 djc를 넣지 않은 빌드다
    public var bundled: URL?
    public var state: AgentCommandState
    /// 링크를 만들 수 없는 이유
    public var blocked: AgentLinkBlock?
}

/// 지금 설치 상태 전부(설정 칸과 켤 때 알림)
public struct AgentToolsReport: Sendable, Equatable {
    /// 앱 재료의 판. 재료가 없는 빌드면 nil
    public var version: AgentPayloadVersion?
    public var skills: [AgentSkillReport]
    public var command: AgentCommandReport
    /// Codex의 옛 사용자 스킬 자리(`~/.codex/skills/djcrate`)에 남은 것. Codex가 같은 스킬을 두 번 보일 수 있다
    public var legacyCodexCopy: URL?

    /// "모두 갱신"이 맞출 것이 있는지
    public var needsUpdate: Bool {
        skills.contains { $0.state.needsUpdate } || { if case .staleLink = command.state { true } else { false } }()
    }
}

/// PATH 안내
public struct AgentPathStatus: Sendable, Equatable {
    /// 링크 폴더가 로그인 셸 PATH에 있는지. 셸을 시간 안에 읽지 못하면 nil
    public var inPath: Bool?
    public var guide: AgentPathGuide

    public init(inPath: Bool?, guide: AgentPathGuide) {
        self.inPath = inPath
        self.guide = guide
    }
}

public enum AgentToolsAction: Sendable, Hashable {
    /// 설치·갱신
    case install(AgentTarget)
    case remove(AgentTarget)
    case linkCommand
    case unlinkCommand
    /// DJCrate가 설치한 것 가운데 이 앱과 다른 것을 모두 맞춘다
    case updateAll
}

/// 사용자에게 물을 것: 남의 것을 바꾸거나 사용자가 고친 파일을 덮거나 지운다. 둘 다 휴지통으로 옮긴다
public struct AgentConfirmation: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// DJCrate가 설치하지 않은 것
        case foreign
        /// 설치한 뒤 사용자가 고친 파일
        case modified
    }

    public struct Item: Sendable, Hashable {
        public var path: URL
        public var reason: Reason

        public init(path: URL, reason: Reason) {
            self.path = path
            self.reason = reason
        }
    }

    public var items: [Item]

    public init(items: [Item]) { self.items = items }

    public func covers(_ other: AgentConfirmation) -> Bool { Set(other.items).isSubset(of: Set(items)) }
}

public struct AgentToolsFailure: Sendable, Equatable {
    public var path: URL
    public var message: String
}

public enum AgentToolsResult: Sendable, Equatable {
    /// 묻지 않고는 할 수 없다. 아무것도 하지 않았다
    case needsConfirmation(AgentConfirmation)
    /// 재료가 없는 빌드이거나 링크를 만들 수 없는 자리에서 연 앱이다
    case unavailable(AgentLinkBlock?)
    /// 했다. 실패한 자리는 따로 알린다(나머지는 끝까지 한다)
    case done(failures: [AgentToolsFailure])
}

/// AI 에이전트 도구 설치(#262): 앱에 든 스킬을 Claude Code·Codex 자리에 복사하고, 번들 djc를 `~/.local/bin/djc` 링크로 둔다.
/// 상태와 할 일은 DJCDomain 규칙(`AgentSkillRules`·`AgentCommandRules`)이 정한다. 남의 것을 바꾸거나 사용자가 고친 파일을 덮을 때는
/// 확인(`AgentConfirmation`)을 받은 뒤에만 한다. 파일 일은 동기 포트라 부르는 쪽이 `BlockingWork.run`으로 메인 밖에서 부른다.
public struct AgentTools: Sendable {
    public let files: AgentToolFiles
    /// 설치 자리의 뿌리(사용자 홈). 시험·자가 테스트는 임시 폴더를 준다
    public let home: URL

    public init(files: AgentToolFiles, home: URL) {
        self.files = files
        self.home = home
    }

    public var commandLink: URL { AgentLocations.commandLink(home: home) }

    /// 설치 자리: Claude Code는 홈의 설정 폴더마다(`~/.claude`, `CLAUDE_CONFIG_DIR`로 둔 `~/.claude-…`)와 고른 자리, Codex는 `~/.agents/skills`
    public func targets(customClaudeFolders: [URL]) -> [AgentTarget] {
        let found = AgentLocations.claudeConfigFolders(in: files.homeEntries(home, AgentLocations.claudeDefault))
            .map { AgentTarget(kind: .claudeCode, folder: home.appending(path: "\($0)/skills/djcrate")) }
        let custom = customClaudeFolders.map { AgentTarget(kind: .claudeCode, folder: $0, isCustom: true) }
            .filter { target in !found.contains { $0.folder.standardizedFileURL == target.folder.standardizedFileURL } }
        return found + custom + [AgentTarget(kind: .codex, folder: AgentLocations.defaultSkillFolder(.codex, home: home))]
    }

    public func report(customClaudeFolders: [URL]) -> AgentToolsReport {
        let payload = files.payload()
        let skills = targets(customClaudeFolders: customClaudeFolders).map { target in
            AgentSkillReport(target: target, state: skillState(files.inspectSkill(target.folder), payload: payload))
        }
        let legacy = home.appending(path: ".codex/skills/djcrate")
        return AgentToolsReport(version: payload?.skill.version, skills: skills, command: commandReport(payload: payload),
                                legacyCodexCopy: files.inspectEntry(legacy) == .missing ? nil : legacy)
    }

    /// 로그인 셸을 띄워 PATH를 읽는다(느릴 수 있어 상태 읽기와 따로 부른다)
    public func pathStatus() -> AgentPathStatus {
        let shell = files.shell(home)
        let directory = commandLink.deletingLastPathComponent().path
        return AgentPathStatus(inPath: shell.path.map { AgentCommandRules.pathContains(directory, path: $0, home: home.path) },
                               guide: AgentCommandRules.pathGuide(shell: shell.shell))
    }

    /// 할 일을 한다. 물어야 할 것이 `confirmed`에 모두 들어 있지 않으면 아무것도 하지 않고 물을 것을 돌려준다.
    /// (확인 창을 띄운 사이 자리가 바뀌어도 사용자가 본 것만 바꾼다)
    public func perform(_ action: AgentToolsAction, customClaudeFolders: [URL] = [], confirmed: AgentConfirmation? = nil) -> AgentToolsResult {
        let steps: [Step]
        switch prepare(action, payload: files.payload(), customClaudeFolders: customClaudeFolders) {
        case let .blocked(block): return .unavailable(block)
        case let .ready(prepared): steps = prepared
        }
        let needed = AgentConfirmation(items: steps.flatMap(\.confirmation))
        if !needed.items.isEmpty, !(confirmed?.covers(needed) ?? false) { return .needsConfirmation(needed) }
        var failures: [AgentToolsFailure] = []
        for step in steps {
            do { try step.run(files) } catch { failures.append(AgentToolsFailure(path: step.path, message: error.localizedDescription)) }
        }
        return .done(failures: failures)
    }

    // MARK: - 안쪽

    func skillState(_ folder: AgentSkillFolder, payload: AgentToolsPayload?) -> AgentSkillState {
        // 재료가 없는 빌드도 남의 것·설치 표시는 읽어 보인다(판 비교만 못 한다)
        AgentSkillRules.state(of: folder, payload: payload?.skill ?? AgentSkillPayload(version: folder.manifest?.app ?? .init(version: "", build: ""),
                                                                                        files: folder.manifest?.files ?? [:]))
    }

    func commandReport(payload: AgentToolsPayload?) -> AgentCommandReport {
        let bundled = payload?.command
        let entry = files.inspectEntry(commandLink)
        return AgentCommandReport(link: commandLink, bundled: bundled, state: AgentCommandRules.state(of: entry, bundled: bundled?.path ?? ""),
                                  blocked: bundled.flatMap { AgentCommandRules.linkBlocked(bundled: $0.path) })
    }

    enum Prepared {
        case ready([Step])
        case blocked(AgentLinkBlock?)
    }

    enum Step {
        case skill(AgentSkillChange)
        case link(at: URL, destination: URL, replacing: AgentLinkReplace)
        case unlink(URL)

        var path: URL {
            switch self {
            case let .skill(change): change.folder
            case let .link(at, _, _): at
            case let .unlink(at): at
            }
        }

        var confirmation: [AgentConfirmation.Item] {
            switch self {
            case let .skill(change):
                (change.plan.replaces == nil ? [] : [.init(path: change.folder, reason: .foreign)])
                    + change.plan.trash.map { .init(path: change.folder.appending(path: $0), reason: .modified) }
            case let .link(at, _, replacing): replacing == .trash ? [.init(path: at, reason: .foreign)] : []
            case .unlink: []
            }
        }

        func run(_ files: AgentToolFiles) throws {
            switch self {
            case let .skill(change): try files.applySkill(change)
            case let .link(at, destination, replacing): try files.link(at, destination, replacing)
            case let .unlink(at): try files.unlink(at)
            }
        }
    }

    func prepare(_ action: AgentToolsAction, payload: AgentToolsPayload?, customClaudeFolders: [URL]) -> Prepared {
        switch action {
        case let .install(target):
            guard let payload else { return .blocked(nil) }
            return .ready([installStep(target.folder, payload: payload)].compactMap { $0 })
        case let .remove(target):
            // 제거는 재료가 없어도 한다(설치 표시만 본다)
            guard let plan = AgentSkillRules.removePlan(for: files.inspectSkill(target.folder)) else { return .ready([]) }
            return .ready([.skill(AgentSkillChange(folder: target.folder, source: payload?.skillSource ?? target.folder, plan: plan))])
        case .linkCommand:
            let report = commandReport(payload: payload)
            guard let bundled = report.bundled, report.blocked == nil else { return .blocked(report.blocked) }
            return .ready([linkStep(report.state, bundled: bundled)].compactMap { $0 })
        case .unlinkCommand:
            return .ready(commandReport(payload: payload).state.isOurs ? [.unlink(commandLink)] : [])
        case .updateAll:
            guard let payload else { return .blocked(nil) }
            let report = report(customClaudeFolders: customClaudeFolders)
            var steps = report.skills.filter { $0.state.needsUpdate }.compactMap { installStep($0.target.folder, payload: payload) }
            if case .staleLink = report.command.state, let bundled = report.command.bundled, report.command.blocked == nil,
               let step = linkStep(report.command.state, bundled: bundled) {
                steps.append(step)
            }
            return .ready(steps)
        }
    }

    func installStep(_ folder: URL, payload: AgentToolsPayload) -> Step? {
        let current = files.inspectSkill(folder)
        let plan = AgentSkillRules.installPlan(for: current, payload: payload.skill)
        // 이미 같으면 아무것도 쓰지 않는다(표시도 그대로)
        if plan.write.isEmpty, plan.delete.isEmpty, plan.trash.isEmpty, plan.replaces == nil, current.manifest == plan.manifest { return nil }
        return .skill(AgentSkillChange(folder: folder, source: payload.skillSource, plan: plan))
    }

    func linkStep(_ state: AgentCommandState, bundled: URL) -> Step? {
        switch state {
        case .linked: nil
        case .missing: .link(at: commandLink, destination: bundled, replacing: .none)
        case .staleLink: .link(at: commandLink, destination: bundled, replacing: .remove)
        case .foreign: .link(at: commandLink, destination: bundled, replacing: .trash)
        }
    }
}
