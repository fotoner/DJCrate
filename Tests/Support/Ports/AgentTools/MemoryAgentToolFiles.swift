import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 계약 함수가 자리를 꾸미고 결과를 들여다보는 손(가짜는 메모리, 실제 구현 시험은 임시 폴더)
public protocol AgentToolFilesBench {
    func put(_ url: URL, _ content: String) throws
    func putLink(_ url: URL, to destination: String) throws
    func content(_ url: URL) -> String?
    /// 휴지통에 옮긴 항목 이름
    func trashed() -> [String]
}

/// AI 에이전트 설치 자리의 메모리 구현(`AgentToolFiles`, #262). 실제(`AgentToolFiles.live`)와 같은 약속인지는 `agentToolFilesContract`가 본다.
/// 재료는 `source` 폴더 아래 파일에서 그때그때 셈한다. `failing`에 든 폴더는 `applySkill`이 던진다
public final class MemoryAgentToolFiles: AgentToolFilesBench, Sendable {
    public struct Failure: Error, Equatable {}

    enum Node: Equatable {
        case file(String)
        case link(String)
        case folder
    }

    private struct State {
        var nodes: [String: Node] = [:]
        var trashed: [String] = []
        var version = AgentPayloadVersion(version: "1.0.0", build: "10")
        var source: URL?
        var command: URL?
        var shell = AgentShellInfo(shell: "/bin/zsh", path: nil)
        var failing: Set<String> = []
        var applied: [AgentSkillChange] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// 재료: `source` 폴더 아래 파일(이 가짜에 `put`으로 둔다)과 판, 번들 djc
    public func setPayload(source: URL?, version: AgentPayloadVersion = AgentPayloadVersion(version: "1.0.0", build: "10"), command: URL? = nil) {
        state.withLock {
            $0.source = source
            $0.version = version
            $0.command = command
        }
    }

    public func setShell(_ shell: AgentShellInfo) { state.withLock { $0.shell = shell } }

    public func fail(_ folders: Set<URL>) { state.withLock { $0.failing = Set(folders.map(Self.key)) } }

    /// `applySkill`을 부른 차례
    public var applied: [AgentSkillChange] { state.withLock { $0.applied } }

    // MARK: - 손

    public func put(_ url: URL, _ content: String) throws {
        state.withLock { state in
            Self.makeParents(of: Self.key(url), in: &state.nodes)
            state.nodes[Self.key(url)] = .file(content)
        }
    }

    public func putLink(_ url: URL, to destination: String) throws {
        state.withLock { state in
            Self.makeParents(of: Self.key(url), in: &state.nodes)
            state.nodes[Self.key(url)] = .link(destination)
        }
    }

    public func putFolder(_ url: URL) {
        state.withLock { state in
            Self.makeParents(of: Self.key(url), in: &state.nodes)
            state.nodes[Self.key(url)] = .folder
        }
    }

    public func content(_ url: URL) -> String? {
        state.withLock { if case let .file(text)? = $0.nodes[Self.key(url)] { text } else { nil } }
    }

    public func trashed() -> [String] { state.withLock { $0.trashed } }

    // MARK: - 포트

    public var port: AgentToolFiles {
        AgentToolFiles(
            payload: {
                self.state.withLock { state in
                    guard let source = state.source else { return nil }
                    return AgentToolsPayload(skill: AgentSkillPayload(version: state.version, files: Self.files(under: Self.key(source), state.nodes)),
                                             skillSource: source, command: state.command)
                }
            },
            inspectSkill: { url in
                self.state.withLock { state in
                    let key = Self.key(url)
                    let entry = Self.entry(key, state.nodes)
                    guard entry == .folder else { return AgentSkillFolder(entry: entry) }
                    var files = Self.files(under: key, state.nodes)
                    files[AgentInstallManifest.fileName] = nil
                    let manifestKey = key + "/" + AgentInstallManifest.fileName
                    let manifest: AgentInstallManifest? = if case let .file(text)? = state.nodes[manifestKey] {
                        try? AgentInstallManifest.decode(Data(text.utf8))
                    } else { nil }
                    return AgentSkillFolder(entry: entry, manifest: manifest, files: files)
                }
            },
            inspectEntry: { url in self.state.withLock { Self.entry(Self.key(url), $0.nodes) } },
            homeEntries: { home, prefix in
                self.state.withLock { state in
                    let base = Self.key(home) + "/"
                    return state.nodes.keys.filter { $0.hasPrefix(base) && !$0.dropFirst(base.count).contains("/") }
                        .compactMap { key -> AgentHomeEntry? in
                            let name = String(key.dropFirst(base.count))
                            guard name.hasPrefix(prefix) else { return nil }
                            let children = Set(state.nodes.keys.filter { $0.hasPrefix(key + "/") && !$0.dropFirst(key.count + 1).contains("/") }
                                .map { String($0.dropFirst(key.count + 1)) })
                            return AgentHomeEntry(name: name, isDirectory: state.nodes[key] == .folder, children: children)
                        }
                        .sorted { $0.name < $1.name }
                }
            },
            applySkill: { change in
                try self.state.withLock { state in
                    state.applied.append(change)
                    let folder = Self.key(change.folder), source = Self.key(change.source)
                    if state.failing.contains(folder) { throw Failure() }
                    if change.plan.replaces != nil { Self.moveToTrash(folder, &state) }
                    Self.makeParents(of: folder + "/x", in: &state.nodes)
                    for path in change.plan.trash { Self.moveToTrash(folder + "/" + path, &state) }
                    for path in change.plan.delete { state.nodes[folder + "/" + path] = nil }
                    for path in change.plan.write {
                        guard case let .file(text)? = state.nodes[source + "/" + path] else { throw Failure() }
                        Self.makeParents(of: folder + "/" + path, in: &state.nodes)
                        state.nodes[folder + "/" + path] = .file(text)
                    }
                    let manifestKey = folder + "/" + AgentInstallManifest.fileName
                    if let manifest = change.plan.manifest {
                        state.nodes[manifestKey] = .file(String(decoding: try manifest.encoded(), as: UTF8.self))
                    } else {
                        state.nodes[manifestKey] = nil
                        Self.removeEmptyFolders(under: folder, &state.nodes)
                    }
                }
            },
            link: { at, destination, replacing in
                try self.state.withLock { state in
                    let key = Self.key(at)
                    switch (Self.entry(key, state.nodes), replacing) {
                    case (.missing, _): break
                    case (.link, .remove): state.nodes[key] = nil
                    case (_, .trash): Self.moveToTrash(key, &state)
                    default: throw Failure()
                    }
                    Self.makeParents(of: key, in: &state.nodes)
                    state.nodes[key] = .link(destination.path)
                }
            },
            unlink: { at in
                try self.state.withLock { state in
                    guard case .link = state.nodes[Self.key(at)] else { throw Failure() }
                    state.nodes[Self.key(at)] = nil
                }
            },
            shell: { _ in self.state.withLock { $0.shell } })
    }

    // MARK: - 안쪽

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private static func entry(_ key: String, _ nodes: [String: Node]) -> AgentPathEntry {
        switch nodes[key] {
        case nil: .missing
        case .file: .file
        case let .link(destination): .link(destination: destination)
        case .folder: .folder
        }
    }

    private static func files(under key: String, _ nodes: [String: Node]) -> [String: String] {
        var files: [String: String] = [:]
        for (path, node) in nodes where path.hasPrefix(key + "/") {
            if case let .file(text) = node { files[String(path.dropFirst(key.count + 1))] = "h:" + text }
        }
        return files
    }

    private static func makeParents(of key: String, in nodes: inout [String: Node]) {
        var parent = (key as NSString).deletingLastPathComponent
        while parent != "/", !parent.isEmpty {
            if nodes[parent] == nil { nodes[parent] = .folder }
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    private static func moveToTrash(_ key: String, _ state: inout State) {
        guard state.nodes[key] != nil else { return }
        state.trashed.append((key as NSString).lastPathComponent)
        // 링크는 링크만 옮긴다(대상은 그대로)
        let isFolder = state.nodes[key] == .folder
        state.nodes[key] = nil
        if isFolder { state.nodes = state.nodes.filter { !$0.key.hasPrefix(key + "/") } }
    }

    private static func removeEmptyFolders(under key: String, _ nodes: inout [String: Node]) {
        let folders = nodes.filter { ($0.key == key || $0.key.hasPrefix(key + "/")) && $0.value == .folder }.keys.sorted { $0.count > $1.count }
        for folder in folders where !nodes.keys.contains(where: { $0.hasPrefix(folder + "/") }) { nodes[folder] = nil }
    }
}

/// AI 에이전트 설치 자리(`AgentToolFiles`, #262): 재료 해시는 같은 폴더를 읽은 해시와 같고, 계획대로 쓰고 지우며,
/// 고친 파일·남의 것은 휴지통으로 옮긴다(링크는 링크만). 제거 뒤 빈 폴더는 지우고 사용자가 더한 파일은 남긴다.
/// 링크는 비어 있지 않은 자리를 덮지 않는다(치우는 방법을 받았을 때만). `root`는 비어 있는 시험 폴더다
public func agentToolFilesContract(_ files: AgentToolFiles, bench: some AgentToolFilesBench, root: URL) throws {
    let source = root.appending(path: "payload/skills/djcrate"), home = root.appending(path: "home")
    try bench.put(source.appending(path: "SKILL.md"), "v1")
    try bench.put(source.appending(path: "ref/a.md"), "r1")
    let payload = try #require(files.payload())
    #expect(Set(payload.skill.files.keys) == ["SKILL.md", "ref/a.md"])
    #expect(files.inspectSkill(source).files == payload.skill.files)
    #expect(samePath(payload.skillSource, source))

    // 설치
    let target = home.appending(path: ".claude/skills/djcrate")
    #expect(files.inspectSkill(target) == AgentSkillFolder(entry: .missing))
    let install = AgentSkillRules.installPlan(for: files.inspectSkill(target), payload: payload.skill)
    try files.applySkill(AgentSkillChange(folder: target, source: source, plan: install))
    let installed = files.inspectSkill(target)
    #expect(installed.entry == .folder)
    #expect(installed.manifest == install.manifest)
    #expect(installed.files == payload.skill.files)
    #expect(bench.content(target.appending(path: "ref/a.md")) == "r1")
    #expect(files.homeEntries(home, ".claude").map(\.name) == [".claude"])
    #expect(files.homeEntries(home, ".claude").first?.children == ["skills"])
    #expect(files.homeEntries(home, ".claude").first?.isDirectory == true)

    // 사용자가 고치고 더한 뒤 제거: 넣은 그대로는 지우고, 고친 것은 휴지통, 더한 것은 남는다
    try bench.put(target.appending(path: "SKILL.md"), "mine")
    try bench.put(target.appending(path: "notes.md"), "n")
    #expect(files.inspectSkill(target).files["SKILL.md"] != payload.skill.files["SKILL.md"])
    let remove = try #require(AgentSkillRules.removePlan(for: files.inspectSkill(target)))
    try files.applySkill(AgentSkillChange(folder: target, source: source, plan: remove))
    #expect(bench.content(target.appending(path: "SKILL.md")) == nil)
    #expect(bench.content(target.appending(path: "ref/a.md")) == nil)
    #expect(bench.content(target.appending(path: "notes.md")) == "n")
    #expect(files.inspectSkill(target).manifest == nil)
    #expect(bench.trashed().contains("SKILL.md"))

    // 고치지 않은 설치본을 제거하면 빈 폴더까지 지운다
    let clean = home.appending(path: ".claude-work/skills/djcrate")
    try files.applySkill(AgentSkillChange(folder: clean, source: source, plan: AgentSkillRules.installPlan(for: files.inspectSkill(clean),
                                                                                                          payload: payload.skill)))
    try files.applySkill(AgentSkillChange(folder: clean, source: source, plan: try #require(AgentSkillRules.removePlan(for: files.inspectSkill(clean)))))
    #expect(files.inspectEntry(clean) == .missing)

    // 남이 둔 링크 자리에 설치: 링크만 휴지통으로(대상은 그대로)
    let linked = home.appending(path: ".agents/skills/djcrate")
    let elsewhere = root.appending(path: "repo/skills/djcrate")
    try bench.put(elsewhere.appending(path: "SKILL.md"), "repo")
    try bench.putLink(linked, to: elsewhere.path)
    #expect(files.inspectEntry(linked) == .link(destination: elsewhere.path))
    #expect(files.inspectSkill(linked).entry == .link(destination: elsewhere.path))
    let replace = AgentSkillRules.installPlan(for: files.inspectSkill(linked), payload: payload.skill)
    #expect(replace.replaces == .link(destination: elsewhere.path))
    try files.applySkill(AgentSkillChange(folder: linked, source: source, plan: replace))
    #expect(files.inspectSkill(linked).manifest == replace.manifest)
    #expect(bench.content(elsewhere.appending(path: "SKILL.md")) == "repo")
    #expect(bench.trashed().contains("djcrate"))

    // djc 링크
    let command = home.appending(path: ".local/bin/djc")
    let app = root.appending(path: "Apps/DJCrate.app/Contents/Helpers/djc"), moved = root.appending(path: "New/DJCrate.app/Contents/Helpers/djc")
    #expect(files.inspectEntry(command) == .missing)
    try files.link(command, app, .none)
    #expect(files.inspectEntry(command) == .link(destination: app.path))
    #expect(throws: (any Error).self) { try files.link(command, moved, .none) }
    try files.link(command, moved, .remove)
    #expect(files.inspectEntry(command) == .link(destination: moved.path))
    try files.unlink(command)
    #expect(files.inspectEntry(command) == .missing)
    try bench.put(command, "#!/bin/sh\nexec ~/.local/lib/djcrate/djc \"$@\"\n")
    #expect(files.inspectEntry(command) == .file)
    #expect(throws: (any Error).self) { try files.unlink(command) }
    try files.link(command, app, .trash)
    #expect(files.inspectEntry(command) == .link(destination: app.path))
    #expect(bench.trashed().contains("djc"))
}
