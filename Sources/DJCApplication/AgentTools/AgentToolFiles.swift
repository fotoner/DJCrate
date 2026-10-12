import DJCDomain
import Foundation

/// 앱에 든 AI 에이전트 설치 재료(#262): 스킬 폴더와 번들 안 djc
public struct AgentToolsPayload: Sendable, Equatable {
    public var skill: AgentSkillPayload
    /// 재료 스킬 폴더(복사할 원본)
    public var skillSource: URL
    /// 번들 안 djc. 없으면 djc를 넣지 않은 빌드다
    public var command: URL?

    public init(skill: AgentSkillPayload, skillSource: URL, command: URL?) {
        self.skill = skill
        self.skillSource = skillSource
        self.command = command
    }
}

/// 사용자 로그인 셸에서 읽은 값
public struct AgentShellInfo: Sendable, Equatable {
    /// 로그인 셸 경로(예: `/bin/zsh`)
    public var shell: String?
    /// 그 셸의 PATH. 시간 안에 읽지 못하면 nil
    public var path: String?

    public init(shell: String?, path: String?) {
        self.shell = shell
        self.path = path
    }
}

/// 스킬 폴더 하나에 할 파일 일(계획 `AgentSkillPlan`을 그대로 옮긴다)
public struct AgentSkillChange: Sendable, Equatable {
    public var folder: URL
    /// 쓸 파일의 원본 폴더
    public var source: URL
    public var plan: AgentSkillPlan

    public init(folder: URL, source: URL, plan: AgentSkillPlan) {
        self.folder = folder
        self.source = source
        self.plan = plan
    }
}

/// 링크 자리에 이미 있는 것을 어떻게 치울지
public enum AgentLinkReplace: Sendable, Equatable {
    /// 자리가 비었다
    case none
    /// DJCrate가 만든 옛 링크라 그냥 지운다
    case remove
    /// 남의 것이라 휴지통으로 옮긴다(사용자가 확인했다)
    case trash
}

/// AI 에이전트 설치 자리의 파일 일(피동 포트, #262). 실제 구현은 DJCAdapters `AgentToolFiles.live`(조립 지점이 고른다).
/// 사용자 홈 폴더(`~/.claude*`·`~/.agents`·`~/.local/bin`)에 쓰므로 시험은 임시 폴더를 홈으로 주고 휴지통도 임시 폴더로 바꾼다.
public struct AgentToolFiles: Sendable {
    /// 앱에 든 재료. 재료가 없는 빌드면 nil
    public var payload: @Sendable () -> AgentToolsPayload?
    /// 스킬 설치 자리를 읽는다(링크는 따라가지 않는다)
    public var inspectSkill: @Sendable (URL) -> AgentSkillFolder
    /// 자리 하나를 읽는다(링크는 따라가지 않는다)
    public var inspectEntry: @Sendable (URL) -> AgentPathEntry
    /// 홈에서 이름이 접두로 시작하는 항목과 그 안 항목 이름
    public var homeEntries: @Sendable (_ home: URL, _ prefix: String) -> [AgentHomeEntry]
    /// 계획대로 스킬 폴더를 고친다. 남의 것·고친 파일은 휴지통으로 옮기고, 표시 파일은 마지막에 쓴다.
    /// 제거(표시 nil) 뒤 빈 폴더는 지운다
    public var applySkill: @Sendable (AgentSkillChange) throws -> Void
    /// `at`에 `destination`을 가리키는 링크를 만든다(폴더가 없으면 만든다)
    public var link: @Sendable (_ at: URL, _ destination: URL, _ replacing: AgentLinkReplace) throws -> Void
    /// 링크를 지운다(링크 대상은 건드리지 않는다)
    public var unlink: @Sendable (URL) throws -> Void
    /// 사용자 로그인 셸과 그 PATH(짧은 시간 제한). 셸은 `home`을 홈으로 띄운다(설치 자리와 같은 셸 설정을 읽는다)
    public var shell: @Sendable (_ home: URL) -> AgentShellInfo

    public init(payload: @escaping @Sendable () -> AgentToolsPayload?, inspectSkill: @escaping @Sendable (URL) -> AgentSkillFolder,
                inspectEntry: @escaping @Sendable (URL) -> AgentPathEntry, homeEntries: @escaping @Sendable (URL, String) -> [AgentHomeEntry],
                applySkill: @escaping @Sendable (AgentSkillChange) throws -> Void,
                link: @escaping @Sendable (URL, URL, AgentLinkReplace) throws -> Void, unlink: @escaping @Sendable (URL) throws -> Void,
                shell: @escaping @Sendable (URL) -> AgentShellInfo) {
        self.payload = payload
        self.inspectSkill = inspectSkill
        self.inspectEntry = inspectEntry
        self.homeEntries = homeEntries
        self.applySkill = applySkill
        self.link = link
        self.unlink = unlink
        self.shell = shell
    }
}
