import CryptoKit
import DJCApplication
import DJCDomain
import DJCEnvironment
import Foundation

/// 앱에 든 설치 재료의 자리와 판
public struct AgentBundleLayout: Sendable, Equatable {
    /// 재료 스킬 폴더. 없으면 재료를 넣지 않은 빌드다
    public var skillSource: URL?
    /// 번들 안 djc
    public var command: URL?
    public var version: AgentPayloadVersion

    public init(skillSource: URL?, command: URL?, version: AgentPayloadVersion) {
        self.skillSource = skillSource
        self.command = command
        self.version = version
    }

    /// 앱 번들 안 자리(`scripts/build-app.sh`가 넣는다): 스킬은 `Contents/Resources/skills/djcrate`, djc는 `Contents/Helpers/djc`.
    /// djc를 `Contents/MacOS`에 두지 않는 까닭: 거기서 직접 부르면 `Bundle.main`이 앱 번들이 되어 djc가 앱의 번들 ID·실행 파일을 본다
    public static func appBundle(_ app: URL, info: [String: Any]) -> AgentBundleLayout {
        let skill = app.appending(path: "Contents/Resources/skills/djcrate"), command = app.appending(path: AgentCommandRules.bundleRelativePath)
        let fm = FileManager.default
        return AgentBundleLayout(skillSource: fm.fileExists(atPath: skill.appending(path: "SKILL.md").path) ? skill : nil,
                                 command: fm.isExecutableFile(atPath: command.path) ? command : nil,
                                 version: AgentPayloadVersion(version: info["CFBundleShortVersionString"] as? String ?? "dev",
                                                              build: info["CFBundleVersion"] as? String ?? "0"))
    }
}

enum AgentToolFilesError: LocalizedError {
    case occupied(String)
    case notLink(String)
    case missingSource(String)
    case outsideSandbox(String)
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case let .occupied(path): String(ui: "\(path)에 다른 파일이 있어 링크를 만들지 않았습니다. 그 파일을 옮긴 뒤 다시 하세요.")
        case let .notLink(path): String(ui: "\(path)는 링크가 아니라 지우지 않았습니다. 직접 확인한 뒤 지우세요.")
        case let .missingSource(path): String(ui: "앱 안 재료 \(path)를 찾지 못했습니다. DJCrate를 다시 받아 설치하세요.")
        case let .outsideSandbox(path): "시험 프로세스는 임시 폴더 밖(\(path))에 쓰지 않습니다"
        case let .blocked(path): String(ui: "\(path)에 DJCrate가 넣지 않은 폴더나 링크가 있어 바꾸지 않았습니다. 그 항목을 옮긴 뒤 다시 하세요.")
        }
    }
}

extension AgentToolFiles {
    /// 실제 파일 시스템. 남의 것·고친 파일은 `trash` 폴더로 옮긴다(nil이면 macOS 휴지통).
    /// 시험 프로세스는 임시 폴더 밖에 쓰지 않고 macOS 휴지통도 쓰지 않는다(사용자 홈의 `~/.claude*`·`~/.agents`·`~/.local/bin`을 지킨다)
    public static func live(layout: AgentBundleLayout, trash: URL? = nil, shellTimeout: Duration = .seconds(3)) -> AgentToolFiles {
        AgentToolFiles(
            payload: {
                guard let source = layout.skillSource else { return nil }
                return AgentToolsPayload(skill: AgentSkillPayload(version: layout.version, files: hashes(under: source)), skillSource: source,
                                         command: layout.command)
            },
            inspectSkill: { inspectSkill($0) },
            inspectEntry: { entry($0) },
            homeEntries: { homeEntries($0, prefix: $1) },
            applySkill: { try applySkill($0, trash: trash) },
            link: { try link(at: $0, to: $1, replacing: $2, trash: trash) },
            unlink: { at in
                try guardWritable(at)
                guard case .link = entry(at) else { throw AgentToolFilesError.notLink(at.path) }
                try FileManager.default.removeItem(at: at)
            },
            shell: { home in
                let shell = loginShell()
                // 시험 프로세스는 사용자 셸 설정(~/.zshrc 등)을 돌리지 않는다. 임시 홈일 때만 띄운다
                guard !TestProcess.isRunning || isTemporary(home) else { return AgentShellInfo(shell: shell, path: nil) }
                return AgentShellInfo(shell: shell, path: shell.flatMap { readPath(shell: $0, arguments: ["-l", "-i", "-c"], home: home,
                                                                                    timeout: shellTimeout) })
            })
    }

    // MARK: - 읽기

    static func entry(_ url: URL) -> AgentPathEntry {
        let fm = FileManager.default
        guard let type = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { return .missing }
        switch type {
        case .typeSymbolicLink:
            let raw = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            let absolute = raw.hasPrefix("/") ? raw : url.deletingLastPathComponent().appending(path: raw).path
            // standardizingPath는 있는 경로의 /private를 떼어 내므로 URL로만 정리한다
            return .link(destination: URL(filePath: absolute).standardized.path)
        case .typeDirectory: return .folder
        default: return .file
        }
    }

    static func inspectSkill(_ folder: URL) -> AgentSkillFolder {
        let entry = entry(folder)
        guard entry == .folder else { return AgentSkillFolder(entry: entry) }
        let manifest = (try? Data(contentsOf: folder.appending(path: AgentInstallManifest.fileName))).flatMap { try? AgentInstallManifest.decode($0) }
        return AgentSkillFolder(entry: entry, manifest: manifest, files: hashes(under: folder))
    }

    /// 폴더 아래 파일의 SHA-256(상대 경로 → 16진수). 안의 링크는 따라가지 않고 대상 경로로 센다
    static func hashes(under folder: URL) -> [String: String] {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder.resolvingSymlinksInPath(),
                                                          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [:] }
        var files: [String: String] = [:]
        for case let url as URL in walker {
            guard !AgentInstallManifest.ignoredNames.contains(url.lastPathComponent) else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let relative = String(url.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.hasPrefix(base) ? base.count + 1 : 0))
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                files[relative] = "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "")
            } else if values?.isRegularFile == true, let data = try? Data(contentsOf: URL(filePath: path)) {
                files[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return files
    }

    static func homeEntries(_ home: URL, prefix: String) -> [AgentHomeEntry] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: home.path)) ?? []).filter { $0.hasPrefix(prefix) }
        return names.sorted().map { name in
            var isDirectory: ObjCBool = false
            let path = home.appending(path: name).path
            _ = fm.fileExists(atPath: path, isDirectory: &isDirectory)
            let children = isDirectory.boolValue ? Set((try? fm.contentsOfDirectory(atPath: path)) ?? []) : []
            return AgentHomeEntry(name: name, isDirectory: isDirectory.boolValue, children: children)
        }
    }

    // MARK: - 쓰기

    static func applySkill(_ change: AgentSkillChange, trash: URL?) throws {
        let fm = FileManager.default, folder = change.folder, plan = change.plan
        try guardWritable(folder)
        if plan.replaces != nil, entry(folder) != .missing { try moveToTrash(folder, trash: trash) }
        if plan.replaces == nil { try preflight(plan, folder: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for path in plan.trash where entry(folder.appending(path: path)) != .missing { try moveToTrash(folder.appending(path: path), trash: trash) }
        for path in plan.delete where entry(folder.appending(path: path)) != .missing { try fm.removeItem(at: folder.appending(path: path)) }
        for path in plan.write {
            let source = change.source.appending(path: path), target = folder.appending(path: path)
            guard let data = try? Data(contentsOf: source) else { throw AgentToolFilesError.missingSource(path) }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        // 표시는 마지막에 쓴다: 중간에 실패하면 옛 표시가 남아 다시 갱신할 때 같은 계획이 나온다
        let manifestURL = folder.appending(path: AgentInstallManifest.fileName)
        if let manifest = plan.manifest {
            try manifest.encoded().write(to: manifestURL, options: .atomic)
        } else {
            if entry(manifestURL) != .missing { try fm.removeItem(at: manifestURL) }
            removeEmptyFolders(folder)
        }
    }

    /// 바꾸기 전에 모든 자리를 본다(반쯤 바꾸고 멈추지 않게). 링크를 따라 스킬 폴더 밖으로 나가지 않고,
    /// 쓸 자리에 폴더·링크가 남아 있으면(해시에 잡히지 않아 계획이 몰랐던 것) 지우거나 덮지 않는다
    static func preflight(_ plan: AgentSkillPlan, folder: URL) throws {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        for path in plan.trash + plan.delete + plan.write {
            let parent = folder.appending(path: path).deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            guard parent == base || parent.hasPrefix(base + "/") else { throw AgentToolFilesError.blocked(path) }
        }
        for path in plan.delete where entry(folder.appending(path: path)) == .folder { throw AgentToolFilesError.blocked(path) }
        for path in plan.write where !plan.trash.contains(path) {
            switch entry(folder.appending(path: path)) {
            case .missing, .file: continue
            case .folder, .link: throw AgentToolFilesError.blocked(path)
            }
        }
    }

    static func link(at: URL, to destination: URL, replacing: AgentLinkReplace, trash: URL?) throws {
        let fm = FileManager.default
        try guardWritable(at)
        switch (entry(at), replacing) {
        case (.missing, _): break
        case (.link, .remove): try fm.removeItem(at: at)
        case (_, .trash): try moveToTrash(at, trash: trash)
        default: throw AgentToolFilesError.occupied(at.path)
        }
        try fm.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: at.path, withDestinationPath: destination.path)
    }

    /// 제거 뒤 빈 폴더를 아래부터 지운다(Finder 파일만 남은 폴더도 빈 것으로 본다). 사용자가 더한 파일이 있는 폴더는 남는다
    static func removeEmptyFolders(_ folder: URL) {
        let fm = FileManager.default
        let folders = (fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])?.compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path.count > $1.path.count } + [folder]
        for url in folders {
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            guard names.allSatisfy({ $0 == ".DS_Store" }) else { continue }
            try? fm.removeItem(at: url)
        }
    }

    static func moveToTrash(_ url: URL, trash: URL?) throws {
        let fm = FileManager.default
        guard let trash else {
            if TestProcess.isRunning { throw AgentToolFilesError.outsideSandbox("Trash") }
            try fm.trashItem(at: url, resultingItemURL: nil)
            return
        }
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        var target = trash.appending(path: url.lastPathComponent), number = 2
        while entry(target) != .missing {
            target = trash.appending(path: "\(url.lastPathComponent) \(number)")
            number += 1
        }
        try fm.moveItem(at: url, to: target)
    }

    /// 시험 프로세스는 임시 폴더 밖에 쓰지 않는다(주입을 빠뜨려도 사용자 홈을 고치지 않게)
    static func guardWritable(_ url: URL) throws {
        guard !TestProcess.isRunning || isTemporary(url.deletingLastPathComponent()) else { throw AgentToolFilesError.outsideSandbox(url.path) }
    }

    static func isTemporary(_ url: URL) -> Bool {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(temporary)
    }

    // MARK: - 셸

    /// 사용자 계정의 로그인 셸(launchd가 띄운 앱의 환경 변수가 아니라 계정 정보에서 읽는다)
    static func loginShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }

    static let pathMarker = "__DJC_PATH__"

    /// 셸을 띄워 PATH를 읽는다. 시간 안에 끝나지 않거나 표시 줄이 없으면 nil.
    /// 출력은 파일로 받는다(셸이 띄운 다른 프로세스가 파이프를 붙잡아도 기다리지 않게)
    static func readPath(shell: String, arguments: [String], home: URL, timeout: Duration, launched: ((pid_t) -> Void)? = nil) -> String? {
        let output = FileManager.default.temporaryDirectory.appending(path: "djc-shell-path-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil), let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = arguments + [#"printf '\n\#(pathMarker)%s\n' "$PATH""#]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let environment = ProcessInfo.processInfo.environment
        process.environment = ["USER", "LOGNAME", "LANG", "TMPDIR"].reduce(into: ["TERM": "dumb", "SHELL": shell, "HOME": home.path]) { result, key in
            if let value = environment[key] { result[key] = value }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        launched?(process.processIdentifier)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        guard finished.wait(timeout: .now() + seconds) == .success else {
            // 대화형 셸은 SIGTERM을 무시한다. 이 프로세스가 띄운 셸 PID에만 SIGKILL을 보내고 거둘 때까지 기다린다
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 5)
            return nil
        }
        guard let text = try? String(contentsOf: output, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last { $0.hasPrefix(pathMarker) }.map { String($0.dropFirst(pathMarker.count)) }
    }
}
