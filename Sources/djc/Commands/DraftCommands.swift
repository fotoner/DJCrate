import DJCApplication
import DJCDomain
import Foundation

/// rekordbox는 스냅샷으로 읽고, 앱이 읽는 초안 파일만 고친다.
enum DraftCommands {
    static let command = Command("draft", "cue|tag|rm … <ContentID> [--db PATH] [--dry-run] [--json]", String(ui: "큐·태그 초안 만들기·지우기(docs/cli.md)")) { args in try run(args) }

    struct Result: Encodable {
        let kind: String
        let action: String
        let contentID: String
        let trackUUID: String
        let dryRun: Bool
        var hasChanges = false
        var cue: CueDraft?
        var tag: TagDraft?
        /// 지우지 않고 damaged-drafts에 옮긴 읽지 못한 기존 초안 파일(데이터 폴더 기준, #174)
        var preserved: [String]?
    }

    static func run(_ args: [String]) throws {
        let options = try Options(args)
        // 초안은 데이터 폴더의 실제 경로 아래 곡별 파일에 바로 쓴다(유스케이스 `EditDraftFiles`, 앱은 바깥 변경 확인으로 받는다)
        let library = CLIComposition.live.library(home: CLIComposition.resolvedDraftHome)
        let read = try library.queries.open(database: options.values["--db"].map { URL(filePath: $0) })
        let (track, cues) = try read.draftSource(options.id)
        let edits = library.draftEdits
        let kind: EditDraftFiles.Kind = options.kind == "cue" ? .cue : .tag
        try edits.checkTarget(kind, uuid: track.uuid)
        var result = Result(kind: options.kind, action: options.remove ? "remove" : "save", contentID: track.id,
                            trackUUID: track.uuid, dryRun: options.dryRun)
        if options.remove {
            try edits.remove(kind, uuid: track.uuid, dryRun: options.dryRun)
        } else if kind == .cue {
            let draft = try edits.addCue({
                EditDraftFiles.CueRequest(time: try options.number("--time"),
                                          loopEnd: try options.values["--loop-end"].map { _ in try options.number("--loop-end") },
                                          beats: try options.values["--beats"].map { _ in try options.number("--beats") },
                                          slot: options.slot, name: options.values["--name"], active: options.flags.contains("--active"))
            }, track: track, rekordboxCues: cues, dryRun: options.dryRun)
            result.cue = draft; result.hasChanges = draft.hasChanges
        } else {
            var values: [TagFields.Key: String] = [:]
            for key in TagFields.Key.allCases { values[key] = options.values[Options.flag(key)] }
            let draft = try edits.setTags(values, track: track, colors: read.colors, inPlaylist: read.isInPlaylist(track.id),
                                          dryRun: options.dryRun)
            result.tag = draft; result.hasChanges = draft.hasChanges
        }
        let preserved = library.watch.takeMovedFiles().map(\.name)
        if !preserved.isEmpty { result.preserved = preserved }
        if options.flags.contains("--json") {
            print(String(decoding: try ReadJSON.encode(command: "draft", data: result), as: UTF8.self))
        } else {
            print(String(ui: "\(options.dryRun ? String(ui: "미리 보기") : String(ui: "완료")) · \(options.kind == "cue" ? String(ui: "큐") : String(ui: "태그")) 초안 \(options.remove ? String(ui: "삭제") : String(ui: "저장")) · \(track.id)"))
            if let draft = result.cue {
                for cue in draft.cues {
                    let loop = cue.loop.map { String(ui: " · 루프 끝 ") + String(ui: "\($0.end, specifier: "%.3f")초") + ($0.active ? String(ui: " (활성)") : "") } ?? ""
                    print("  \(cue.kind.slotLetter ?? String(ui: "메모리")) · \(String(ui: "\(cue.time, specifier: "%.3f")초")) · \(cue.name)\(loop)")
                }
            }
            if let draft = result.tag {
                for key in draft.changedKeys { print("  \(key.label): \(draft.base[key]) → \(draft.fields[key])") }
            }
            if !preserved.isEmpty {
                print(String(ui: "  읽지 못한 기존 초안 파일은 지우지 않고 damaged-drafts에 옮겨 두었습니다: \(preserved.joined(separator: ", "))"))
            }
        }
    }

    private static func invalid(_ message: String) -> ReadFailure {
        ReadFailure("invalid_arguments", String(ui: "\(message). docs/cli.md의 draft 사용법을 확인하세요"))
    }

    private struct Options {
        let kind: String
        let remove: Bool
        let id: String
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var slot: Int?
        var dryRun: Bool { flags.contains("--dry-run") }

        static func flag(_ key: TagFields.Key) -> String {
            switch key {
            case .albumArtist: "--album-artist"
            case .trackNumber: "--track-number"
            case .musicalKey: "--musical-key"
            default: "--" + key.rawValue
            }
        }

        init(_ args: [String]) throws {
            guard args.count >= 2 else { throw invalid(String(ui: "초안 종류를 지정하세요")) }
            remove = args[1] == "rm"
            let start = remove ? 3 : 2
            guard args.count >= start else { throw invalid(String(ui: "지울 초안 종류를 지정하세요")) }
            kind = args[remove ? 2 : 1]
            guard ["cue", "tag"].contains(kind) else { throw invalid(String(ui: "초안 종류는 cue 또는 tag입니다")) }
            var valued: Set<String> = ["--db"]
            var boolean: Set<String> = ["--json", "--dry-run"]
            if !remove {
                if kind == "cue" {
                    valued.formUnion(["--time", "--slot", "--name", "--loop-end", "--beats"]); boolean.insert("--active")
                } else { valued.formUnion(TagFields.Key.allCases.map(Self.flag)) }
            }
            var index = start, operands: [String] = [], positionalOnly = false
            while index < args.count {
                let arg = args[index]
                if arg == "--", !positionalOnly { positionalOnly = true; index += 1; continue }
                if arg.hasPrefix("--"), !positionalOnly {
                    if boolean.contains(arg) {
                        guard flags.insert(arg).inserted else { throw invalid(String(ui: "옵션이 중복되었습니다")) }
                    } else if valued.contains(arg) {
                        guard values[arg] == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                            throw invalid(String(ui: "옵션 값이 없거나 중복되었습니다"))
                        }
                        index += 1; values[arg] = args[index]
                    } else { throw invalid(String(ui: "알 수 없는 옵션입니다")) }
                } else { operands.append(arg) }
                index += 1
            }
            guard operands.count == 1, !operands[0].isEmpty else { throw invalid(String(ui: "ContentID 하나를 지정하세요")) }
            id = operands[0]
            if !remove, kind == "cue" {
                _ = try number("--time")
                if let raw = values["--slot"] {
                    guard raw.uppercased().utf8.count == 1, let ascii = raw.uppercased().utf8.first, (65...72).contains(ascii) else { throw invalid(String(ui: "핫큐 슬롯은 A~H입니다")) }
                    slot = Int(ascii - 65)
                }
                if values["--loop-end"] == nil, values["--beats"] != nil || flags.contains("--active") { throw invalid(String(ui: "루프 끝을 --loop-end로 지정하세요")) }
            }
            if !remove, kind == "tag", !TagFields.Key.allCases.contains(where: { values[Self.flag($0)] != nil }) { throw invalid(String(ui: "바꿀 태그를 하나 이상 지정하세요")) }
        }

        func number(_ flag: String) throws -> Double {
            guard let raw = values[flag], let number = Double(raw), number.isFinite else { throw invalid(String(ui: "\(flag)에 유한한 숫자를 지정하세요")) }
            return number
        }
    }
}
