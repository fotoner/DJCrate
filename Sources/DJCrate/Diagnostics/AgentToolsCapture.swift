#if DEBUG
import AppKit
import DJCApplication
import DJCDomain
import SwiftUI

/// 설정 › AI 에이전트(#262)의 전 과정을 실제 화면으로 캡처한다(`--agent-tools-capture=<폴더> --agent-home=<임시 홈>`).
/// 임시 홈에 이 Mac의 손 설치와 같은 꼴(메인 체크아웃을 가리키는 링크 둘, 복사본, 다른 djc 스크립트)을 만든 뒤
/// 손 설치 보기 → 빈 자리에 설치 → 다른 djc 바꾸기(확인 창) → 파일 고침 → 다시 설치(확인 창) → 제거 차례로 찍는다.
/// 확인 창은 답을 정해 두고(확인) 같은 창을 시트로 띄워 찍는다. 홈이 임시 폴더가 아니면 시작하지 않는다(종료 코드 2).
@MainActor
enum AgentToolsCapture {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let argument = arguments.first(where: { $0.hasPrefix("--agent-tools-capture=") }) else { return }
        let directory = URL(filePath: String(argument.dropFirst("--agent-tools-capture=".count)))
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard let home = arguments.first(where: { $0.hasPrefix("--agent-home=") }).map({ URL(filePath: String($0.dropFirst("--agent-home=".count))) }),
              home.resolvingSymlinksInPath().path.hasPrefix(temporary) else {
            log("미검증: --agent-home=<임시 폴더>를 주세요 · 종료 코드 2")
            exit(2)
        }
        Task {
            do {
                try await run(home: home, directory: directory, arguments: arguments)
                log("AI 에이전트 캡처 통과")
                exit(0)
            } catch {
                log("실패: \(error)")
                exit(1)
            }
        }
    }

    static func log(_ text: String) { FileHandle.standardError.write(Data("[AI 에이전트 캡처] \(text)\n".utf8)) }

    static func run(home: URL, directory: URL, arguments: [String]) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // 손 설치 꼴
        let repository = home.appending(path: "dev/DJCrate/skills/djcrate")
        try write(repository.appending(path: "SKILL.md"), "repo skill")
        for config in [".claude-goondori", ".claude-fotone"] {
            try fm.createDirectory(at: home.appending(path: "\(config)/skills"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: home.appending(path: "\(config)/skills/djcrate"), withDestinationURL: repository)
        }
        try write(home.appending(path: ".agents/skills/djcrate/SKILL.md"), "hand copy")
        try write(home.appending(path: ".local/bin/djc"), "#!/bin/sh\nexec ~/.local/lib/djcrate/djc \"$@\"\n")
        try fm.createDirectory(at: home.appending(path: ".claude/projects"), withIntermediateDirectories: true)

        let recorder = PromptRecorder()
        let model = AppComposition.agentTools(arguments: arguments, settings: nil) { recorder.prompts.append($0); return true }
        var prompts: [ReflectionPrompt] { recorder.prompts }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 560, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = String(ui: "AI 에이전트")
        window.contentView = NSHostingView(rootView: AgentToolsSettingsView(model: model))
        window.orderFrontRegardless()
        func settle() async { try? await Task.sleep(for: .seconds(1.5)) }
        func capture(_ name: String, _ target: NSWindow? = nil) throws {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String((target ?? window).windowNumber), directory.appending(path: "\(name).png").path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure("\(name) 캡처 실패") }
        }
        func confirmCapture(_ name: String) async throws {
            guard let prompt = prompts.last else { throw Failure("\(name): 확인 창이 없습니다") }
            let alert = AlertPrompter().makeAlert(prompt)
            alert.beginSheetModal(for: window, completionHandler: nil)
            await settle()
            try capture(name, alert.window)
            window.endSheet(alert.window)
        }
        func state(_ relative: String) -> AgentSkillState? {
            model.skillRows.first { $0.target.folder.standardizedFileURL == home.appending(path: relative).standardizedFileURL }?.state
        }

        await model.refresh()
        await settle()
        guard case .foreign(.link)? = state(".claude-goondori/skills/djcrate"), case .foreign(.folder)? = state(".agents/skills/djcrate"),
              model.commandRow?.status == String(ui: "다른 djc가 있음") else { throw Failure("손 설치를 남의 것으로 보지 않았습니다") }
        try capture("1-hand-installs")

        await model.perform(.install(AgentTarget(kind: .claudeCode, folder: home.appending(path: ".claude/skills/djcrate"))))
        await settle()
        guard prompts.isEmpty, state(".claude/skills/djcrate")?.badge == .installed else { throw Failure("빈 자리 설치: \(model.message ?? "")") }
        try capture("2-installed")

        await model.perform(.linkCommand)
        guard prompts.count == 1, model.commandRow?.status == String(ui: "이 앱의 djc를 가리킴") else { throw Failure("djc 바꾸기: \(model.message ?? "")") }
        try await confirmCapture("3-confirm-djc")
        await settle()
        try capture("4-djc-linked")

        try write(home.appending(path: ".claude/skills/djcrate/SKILL.md"), "my notes")
        await model.refresh()
        await settle()
        guard state(".claude/skills/djcrate")?.badge == .modified else { throw Failure("고친 파일을 찾지 못했습니다") }
        try capture("5-modified")
        await model.perform(.install(AgentTarget(kind: .claudeCode, folder: home.appending(path: ".claude/skills/djcrate"))))
        guard prompts.count == 2, prompts.last?.details.first?.contains("SKILL.md") == true else { throw Failure("고친 파일을 덮기 전에 묻지 않았습니다") }
        try await confirmCapture("6-confirm-modified")

        await model.perform(.remove(AgentTarget(kind: .claudeCode, folder: home.appending(path: ".claude/skills/djcrate"))))
        await settle()
        guard state(".claude/skills/djcrate") == .notInstalled,
              (try? fm.destinationOfSymbolicLink(atPath: home.appending(path: ".claude-goondori/skills/djcrate").path)) == repository.path
        else { throw Failure("제거 또는 손 설치 보존 실패") }
        try capture("7-removed")
        let trashed = (try? fm.contentsOfDirectory(atPath: home.appending(path: ".djc-test-trash").path)) ?? []
        log("휴지통(임시): \(trashed.sorted().joined(separator: ", "))")
        window.close()
    }

    /// 확인 창에 보인 것(답은 늘 확인)
    final class PromptRecorder {
        var prompts: [ReflectionPrompt] = []
    }

    static func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
#endif
