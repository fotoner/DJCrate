import DJCDomain
import Foundation

/// 명령 하나. `run`은 명령 이름이 `args[0]`인 인자를 받는다.
struct Command: Sendable {
    let name: String
    let arguments: String?
    let summary: String
    let run: @Sendable ([String]) async throws -> Void

    init(_ name: String, _ arguments: String?, _ summary: String, _ run: @escaping @Sendable ([String]) async throws -> Void) {
        self.name = name
        self.arguments = arguments
        self.summary = summary
        self.run = run
    }

    func line(prefix: String = "djc") -> String {
        let head = "  \(prefix) \(name)" + (arguments.map { " \($0)" } ?? "")
        // 한글·가나는 터미널에서 두 칸
        let width = head.unicodeScalars.reduce(0) { $0 + ((0x1100...0xFFDC).contains($1.value) ? 2 : 1) }
        return width < 46 ? head + String(repeating: " ", count: 46 - width) + summary
            : head + "\n" + String(repeating: " ", count: 46) + summary
    }
}

/// 명령에 인자가 모자라면 던진다. 그 명령의 사용법을 보여 준다.
struct UsageError: Error {}

enum CLI {
    static let lab = CueLab.all + GridLab.all + AudioLab.all + TrackLab.all + EditLab.all + PlaylistLab.all + HistoryLab.all + CipherLab.all + UsbLab.all
        + UsbReadLab.all + UsbFieldsLab.all + UsbAnlzLab.all + UsbPlanLab.all + UsbImageLab.all + UsbExportLab.all + UsbSettingLab.all
        + UsbSyncSelectionLab.all
        + RelocateLab.all

    static let usage = String(ui: """
        DJCrate(djc) — rekordbox DJ 라이브러리 관리 도구

        사용법:
        \((MainCommands.all + [DraftCommands.command]).map { $0.line() }.joined(separator: "\n"))
        \(CompatCommand.command.line())
        \(Command("lab", String(ui: "<명령>"), String(ui: "규칙을 알아낼 때 쓴 실험 명령(목록: djc lab)"), { _ in }).line())
        """)

    static var labUsage: String {
        "djc lab — 실험 명령(읽기 전용이거나 사본에만 쓴다)\n\n" + lab.map { $0.line(prefix: "djc lab") }.joined(separator: "\n")
    }

    static func run(_ args: [String]) async throws {
        if ReadCommands.handlesJSON(args) { try await ReadCommands.run(args); return }
        if args.first == "draft" { try DraftCommands.run(args); return }
        switch args.first {
        case "lab"?:
            try await dispatch(Array(args.dropFirst()), in: lab, usage: labUsage)
        case "compat"?:
            try CompatCommand.run(args)
        default:
            try await dispatch(args, in: MainCommands.all, usage: usage)
        }
    }

    static func dispatch(_ args: [String], in commands: [Command], usage: String) async throws {
        guard let name = args.first, let command = commands.first(where: { $0.name == name }) else {
            print(usage)
            return
        }
        do {
            try await command.run(args)
        } catch is UsageError {
            print(String(ui: "사용법:\n") + command.line(prefix: commands.first?.name == lab.first?.name ? "djc lab" : "djc"))
        }
    }
}

/// 실행 파일(`djcExecutable/main.swift`)의 진입점. 본체를 라이브러리로 두어 실행 파일과 테스트가 컴파일 결과를 함께 쓴다.
@MainActor
package func runDJC() async {
    // 새 읽기 명령(JSON 조회·XML 내보내기)은 옛 데이터 폴더를 옮기지도 않는다.
    let arguments = Array(CommandLine.arguments.dropFirst())
    CLILocalization.configure(lab: arguments.first == "lab")
    if arguments.first != "draft", arguments.first != "usb-info", arguments.first != "xml-export", arguments.first != "xml-diff",
       !ReadCommands.names.contains(arguments.first ?? ""),
       !ReadCommands.handlesJSON(arguments) {
        CLIComposition.migrateLegacyData()
    }

    do {
        try await CLI.run(arguments)
    } catch {
        if (ReadCommands.handlesJSON(arguments) || (["draft", "xml-diff"].contains(arguments.first ?? "") && arguments.contains("--json"))), let data = try? ReadJSON.error(command: arguments.first ?? "", error: error) {
            FileHandle.standardError.write(data + Data("\n".utf8))
        } else {
            FileHandle.standardError.write(Data(String(ui: "오류: \(String(describing: error))\n").utf8))
        }
        exit(1)
    }
}
