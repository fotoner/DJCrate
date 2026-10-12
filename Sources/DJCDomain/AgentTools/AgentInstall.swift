import Foundation

// AI 에이전트 도구(#262): 앱에 든 DJCrate 스킬과 djc를 Claude Code·Codex가 쓰는 자리에 설치·갱신·제거하는 규칙.
// 파일 일은 포트(DJCApplication `AgentToolFiles`)가 하고, 여기는 읽은 모양으로 상태와 할 일을 정한다.

/// 스킬을 설치할 에이전트
public enum AgentKind: String, Sendable, Hashable, CaseIterable, Codable {
    case claudeCode, codex
}

/// 설치 재료의 판: 앱 버전과 빌드
public struct AgentPayloadVersion: Codable, Sendable, Hashable {
    public var version: String
    public var build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    /// 알림을 한 번만 보이려고 저장하는 값
    public var key: String { "\(version)+\(build)" }
}

/// 스킬 설치 표시(설치 폴더의 `.djcrate-install.json`). 이 표시가 있는 폴더만 DJCrate가 설치한 것으로 본다.
/// 파일별 해시로 사용자가 고친 파일을 찾는다(덮거나 지우기 전에 묻는다).
public struct AgentInstallManifest: Codable, Sendable, Equatable {
    public static let fileName = ".djcrate-install.json"
    public static let currentFormat = 1
    /// 파일 목록에서 빼는 이름: 표시 파일과 Finder가 폴더를 열 때 만드는 파일(사용자가 고친 것으로 보지 않게)
    public static let ignoredNames: Set<String> = [fileName, ".DS_Store"]

    public var format: Int
    public var app: AgentPayloadVersion
    /// 설치한 파일(스킬 폴더 기준 상대 경로) → SHA-256(16진수)
    public var files: [String: String]

    public init(app: AgentPayloadVersion, files: [String: String]) {
        format = Self.currentFormat
        self.app = app
        self.files = files
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}

/// 설치 자리에 있는 것(링크는 따라가지 않는다)
public enum AgentPathEntry: Sendable, Equatable {
    case missing
    /// 링크. 대상은 링크 폴더 기준으로 푼 절대 경로다
    case link(destination: String)
    case file
    case folder
}

/// 스킬 설치 자리를 읽은 모양
public struct AgentSkillFolder: Sendable, Equatable {
    public var entry: AgentPathEntry
    /// 읽은 설치 표시. 없거나 읽지 못하면 nil
    public var manifest: AgentInstallManifest?
    /// 표시 파일을 뺀 파일(상대 경로 → 해시)
    public var files: [String: String]

    public init(entry: AgentPathEntry, manifest: AgentInstallManifest? = nil, files: [String: String] = [:]) {
        self.entry = entry
        self.manifest = manifest
        self.files = files
    }
}

/// 앱에 든 스킬 재료
public struct AgentSkillPayload: Sendable, Equatable {
    public var version: AgentPayloadVersion
    /// 상대 경로 → 해시
    public var files: [String: String]

    public init(version: AgentPayloadVersion, files: [String: String]) {
        self.version = version
        self.files = files
    }
}

/// DJCrate가 설치하지 않은 것의 모양
public enum AgentForeignKind: Sendable, Equatable {
    case link(destination: String)
    case folder
    case file
}

/// 설치한 뒤 사용자가 바꾼 파일
public struct AgentUserChanges: Sendable, Equatable {
    /// 내용이 바뀐 파일
    public var changed: [String]
    /// 지운 파일
    public var removed: [String]
    /// DJCrate가 넣지 않은 파일
    public var added: [String]

    public init(changed: [String] = [], removed: [String] = [], added: [String] = []) {
        self.changed = changed
        self.removed = removed
        self.added = added
    }

    public var isEmpty: Bool { changed.isEmpty && removed.isEmpty && added.isEmpty }
}

/// 화면에 보일 설치 상태 한 가지
public enum AgentInstallBadge: Sendable, Equatable {
    case notInstalled, installed, outdated, modified, foreign
}

/// 스킬 설치 자리 하나의 상태
public enum AgentSkillState: Sendable, Equatable {
    case notInstalled
    case foreign(AgentForeignKind)
    /// DJCrate가 설치했다. `isCurrent`는 설치한 내용이 이 앱의 재료와 같은지다(판은 보지 않는다)
    case installed(AgentPayloadVersion, isCurrent: Bool, changes: AgentUserChanges)

    /// "모두 갱신"이 맞출 것인지(DJCrate가 설치했고 이 앱과 다르다)
    public var needsUpdate: Bool {
        if case .installed(_, isCurrent: false, _) = self { return true }
        return false
    }

    public var badge: AgentInstallBadge {
        switch self {
        case .notInstalled: .notInstalled
        case .foreign: .foreign
        // 고친 파일이 있으면 옛 버전보다 먼저 알린다(덮기 전에 물어야 하므로)
        case let .installed(_, isCurrent, changes): !changes.isEmpty ? .modified : isCurrent ? .installed : .outdated
        }
    }
}

/// 설치·갱신·제거 때 할 파일 일
public struct AgentSkillPlan: Sendable, Equatable {
    /// 재료에서 복사할 파일
    public var write: [String] = []
    /// DJCrate가 넣은 그대로라 바로 지울 파일
    public var delete: [String] = []
    /// 사용자가 고쳐서 휴지통으로 옮길 파일(묻는다)
    public var trash: [String] = []
    /// 자리에 있던 남의 것을 통째로 휴지통으로 옮긴다(묻는다)
    public var replaces: AgentForeignKind?
    /// 끝에 남길 설치 표시. nil이면 표시를 지운다(제거)
    public var manifest: AgentInstallManifest?

    public init(write: [String] = [], delete: [String] = [], trash: [String] = [], replaces: AgentForeignKind? = nil,
                manifest: AgentInstallManifest? = nil) {
        self.write = write
        self.delete = delete
        self.trash = trash
        self.replaces = replaces
        self.manifest = manifest
    }

    public var needsConfirmation: Bool { !trash.isEmpty || replaces != nil }
}

public enum AgentSkillRules {
    public static func state(of folder: AgentSkillFolder, payload: AgentSkillPayload) -> AgentSkillState {
        switch folder.entry {
        case .missing: return .notInstalled
        case let .link(destination): return .foreign(.link(destination: destination))
        case .file: return .foreign(.file)
        case .folder:
            guard let manifest = folder.manifest else { return folder.files.isEmpty ? .notInstalled : .foreign(.folder) }
            let changes = changes(installed: manifest.files, disk: folder.files)
            // 내용(해시)으로만 판정한다. 개발 설치마다 빌드 번호가 바뀌므로 판만 다른 것은 이 앱의 설치본으로 본다
            let isCurrent = manifest.files == payload.files
            return .installed(isCurrent ? payload.version : manifest.app, isCurrent: isCurrent, changes: changes)
        }
    }

    static func changes(installed: [String: String], disk: [String: String]) -> AgentUserChanges {
        AgentUserChanges(changed: installed.keys.filter { disk[$0] != nil && disk[$0] != installed[$0] }.sorted(),
                         removed: installed.keys.filter { disk[$0] == nil }.sorted(),
                         added: disk.keys.filter { installed[$0] == nil }.sorted())
    }

    /// 설치·갱신: 처음이면 모두 쓰고, 남의 것이면 휴지통에 옮긴 뒤 쓴다. 갱신은 바뀐 파일만 쓰고 재료에서 빠진 파일은 지운다.
    /// 사용자가 고친 파일은 새 재료와 다를 때만 휴지통에 옮긴 뒤 덮고(묻는다), 재료에서 빠졌으면 지우지 않고 남긴다.
    public static func installPlan(for folder: AgentSkillFolder, payload: AgentSkillPayload) -> AgentSkillPlan {
        let manifest = AgentInstallManifest(app: payload.version, files: payload.files)
        let all = payload.files.keys.sorted()
        switch state(of: folder, payload: payload) {
        case .notInstalled:
            return AgentSkillPlan(write: all, manifest: manifest)
        case let .foreign(kind):
            return AgentSkillPlan(write: all, replaces: kind, manifest: manifest)
        case .installed:
            let installed = folder.manifest?.files ?? [:]
            var plan = AgentSkillPlan(manifest: manifest)
            for path in all {
                let disk = folder.files[path]
                guard disk != payload.files[path] else { continue }
                plan.write.append(path)
                if let disk, disk != installed[path] { plan.trash.append(path) }
            }
            plan.delete = installed.keys.filter { payload.files[$0] == nil && folder.files[$0] == installed[$0] }.sorted()
            return plan
        }
    }

    /// 제거: DJCrate가 설치한 자리만. 넣은 그대로인 파일은 지우고, 고친 파일은 휴지통에 옮긴다(묻는다). 사용자가 더한 파일은 남긴다.
    public static func removePlan(for folder: AgentSkillFolder) -> AgentSkillPlan? {
        guard folder.entry == .folder, let installed = folder.manifest?.files else { return nil }
        let present = installed.keys.filter { folder.files[$0] != nil }
        return AgentSkillPlan(delete: present.filter { folder.files[$0] == installed[$0] }.sorted(),
                              trash: present.filter { folder.files[$0] != installed[$0] }.sorted())
    }
}

// MARK: - djc 링크

/// `~/.local/bin/djc` 자리의 상태
public enum AgentCommandState: Sendable, Equatable {
    case missing
    /// 이 앱의 djc를 가리키는 링크
    case linked
    /// 다른 DJCrate 앱(옮기기 전 자리·옛 빌드)의 djc를 가리키는 링크. DJCrate가 만든 링크라 묻지 않고 바꾼다
    case staleLink(destination: String)
    /// 다른 djc(손으로 둔 스크립트·다른 곳을 가리키는 링크). 바꾸기 전에 묻는다
    case foreign(AgentForeignKind)

    public var isOurs: Bool {
        switch self {
        case .linked, .staleLink: true
        case .missing, .foreign: false
        }
    }
}

/// 링크를 만들 수 없는 이유
public enum AgentLinkBlock: Sendable, Equatable {
    /// macOS가 받은 앱을 임시 자리(App Translocation)에서 열었다. 링크가 곧 깨진다
    case translocated
}

/// PATH에 폴더를 더하는 안내
public struct AgentPathGuide: Sendable, Equatable {
    /// 더할 셸 설정 파일
    public var file: String
    /// 더할 줄
    public var line: String

    public init(file: String, line: String) {
        self.file = file
        self.line = line
    }
}

public enum AgentCommandRules {
    /// 앱 번들 안 djc 자리(번들 기준). 링크 대상이 이 꼴이면 DJCrate가 만든 링크다
    public static let bundleRelativePath = "Contents/Helpers/djc"

    public static func state(of entry: AgentPathEntry, bundled: String) -> AgentCommandState {
        switch entry {
        case .missing: return .missing
        case .file: return .foreign(.file)
        case .folder: return .foreign(.folder)
        case let .link(destination):
            let target = normalized(destination)
            if target == normalized(bundled) { return .linked }
            if target.hasSuffix(".app/" + bundleRelativePath) { return .staleLink(destination: destination) }
            return .foreign(.link(destination: destination))
        }
    }

    public static func linkBlocked(bundled: String) -> AgentLinkBlock? {
        bundled.contains("/AppTranslocation/") ? .translocated : nil
    }

    /// 로그인 셸의 PATH에 폴더가 있는지(`~`·`$HOME`으로 쓴 줄과 끝 `/`도 같게 본다)
    public static func pathContains(_ directory: String, path: String, home: String) -> Bool {
        let wanted = normalized(directory)
        return path.split(separator: ":").contains { item in
            var item = String(item)
            for prefix in ["~", "$HOME", "${HOME}"] where item == prefix || item.hasPrefix(prefix + "/") {
                item = home + item.dropFirst(prefix.count)
                break
            }
            return normalized(item) == wanted
        }
    }

    /// 사용자 셸(로그인 셸 경로)에 맞는 PATH 안내. 모르는 셸은 macOS 기본인 zsh로 본다
    public static func pathGuide(shell: String?) -> AgentPathGuide {
        switch shell.map({ ($0 as NSString).lastPathComponent }) {
        case "bash": AgentPathGuide(file: "~/.bash_profile", line: #"export PATH="$HOME/.local/bin:$PATH""#)
        case "fish": AgentPathGuide(file: "~/.config/fish/config.fish", line: "fish_add_path $HOME/.local/bin")
        default: AgentPathGuide(file: "~/.zshrc", line: #"export PATH="$HOME/.local/bin:$PATH""#)
        }
    }

    /// `.`·`..`·겹친 `/`·끝 `/`를 정리한다(파일 시스템을 보지 않는다). 상대 경로는 그대로 둔다
    static func normalized(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let standard = URL(filePath: path).standardized.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}

// MARK: - 위치

/// 홈 폴더의 항목 하나(Claude 설정 폴더 찾기)
public struct AgentHomeEntry: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    /// 폴더 안 항목 이름(설정 폴더인지 보려고 읽는다)
    public var children: Set<String>

    public init(name: String, isDirectory: Bool, children: Set<String> = []) {
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
    }
}

public enum AgentLocations {
    /// Claude Code 기본 설정 폴더(홈 기준)
    public static let claudeDefault = ".claude"
    /// Claude 설정 폴더에 있는 항목. 하나라도 있으면 설정 폴더로 본다(`CLAUDE_CONFIG_DIR`로 따로 둔 폴더)
    public static let claudeMarkers: Set<String> = ["settings.json", "projects", "skills", ".credentials.json", "CLAUDE.md", "plugins"]

    /// 홈에서 찾은 Claude 설정 폴더 이름. 기본 폴더는 없어도 맨 앞에 둔다
    public static func claudeConfigFolders(in entries: [AgentHomeEntry]) -> [String] {
        let others = entries.filter {
            $0.isDirectory && $0.name.hasPrefix(claudeDefault + "-") && !$0.children.isDisjoint(with: claudeMarkers)
        }
        return [claudeDefault] + others.map(\.name).sorted()
    }

    /// "다른 위치…"로 고른 폴더의 설치 자리: 스킬 폴더 자체(`…/djcrate`), 스킬 모음(`…/skills`), 그 밖은 설정 폴더로 본다
    public static func skillFolder(picked: URL) -> URL {
        switch picked.lastPathComponent {
        case "djcrate": picked
        case "skills": picked.appending(path: "djcrate")
        default: picked.appending(path: "skills/djcrate")
        }
    }

    /// 기본 자리: Claude Code는 `~/.claude/skills/djcrate`, Codex는 `~/.agents/skills/djcrate`(Codex가 읽는 사용자 스킬 폴더)
    public static func defaultSkillFolder(_ kind: AgentKind, home: URL) -> URL {
        switch kind {
        case .claudeCode: home.appending(path: "\(claudeDefault)/skills/djcrate")
        case .codex: home.appending(path: ".agents/skills/djcrate")
        }
    }

    public static func commandLink(home: URL) -> URL { home.appending(path: ".local/bin/djc") }
}

// MARK: - 켤 때 알림

public enum AgentUpdateNotice {
    /// DJCrate가 설치한 것 가운데 이 앱과 다른 것이 있고, 이 앱 판에서 아직 알리지 않았으면 알린다
    public static func shouldShow(skills: [AgentSkillState], command: AgentCommandState, app: AgentPayloadVersion, lastShown: String?) -> Bool {
        let stale: Bool = if case .staleLink = command { true } else { false }
        return (skills.contains(where: \.needsUpdate) || stale) && lastShown != app.key
    }
}
