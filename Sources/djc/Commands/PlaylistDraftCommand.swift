import DJCApplication
import DJCDomain
import Foundation

/// `djc draft playlist …`(#260): 앱 사이드바와 같은 재생 목록 편집을 초안(`playlist-drafts.json`)으로 쌓는다. rekordbox는 스냅샷으로 읽기만 한다.
/// 편집 하나는 하위 명령으로, 여러 개는 편집 JSON 파일(`apply --file`)로 받는다. 계획 규칙은 유스케이스 `EditPlaylists.planning`이고,
/// 켜져 있는 앱은 저장한 파일을 다시 읽는다.
enum PlaylistDraftCommand {
    static let usage = "playlist apply --file <편집.json|-> | create <이름> | rename <목록> <이름> | move <목록> | delete <목록> | add|remove|order <목록> <ContentID…>"

    struct Result: Encodable {
        let kind = "playlist"
        let action: String
        let dryRun: Bool
        let hasChanges: Bool
        let stacked: Int
        let unchanged: Int
        let skipped: Int
        let results: [Item]
        /// 임시 이름(`@이름`) → 만든 목록 ID(`new:키`)
        let aliases: [String: String]
        /// 쌓은 뒤 재생 목록 초안 전체(앱 파일과 같다). 미리 보기면 저장하지 않은 값
        let playlist: PlaylistDraft
        var preserved: [String]?

        struct Item: Encodable {
            let index: Int
            let op: String
            let status: String
            let playlistID: String?
            let name: String?
            let reason: String?
            let ignored: [String]?
        }
    }

    static func run(_ args: [String]) throws {
        let options = try Options(args)
        let library = CLIComposition.live.library(home: try CLIComposition.checkedDraftHome())
        let read = try library.queries.open(database: options.values["--db"].map { URL(filePath: $0) })
        let batch = try library.draftEdits.stackPlaylistEdits(options.requests.map(\.request), rekordbox: read.playlistLayout(),
                                                              contentIDs: read.contentIDs(), allOrNothing: options.flags.contains("--all-or-nothing"),
                                                              dryRun: options.dryRun)
        let items = zip(options.requests, batch.outcomes).enumerated().map { index, pair in
            Result.Item(index: index, op: pair.0.op, status: pair.1.status.rawValue, playlistID: pair.1.playlistID, name: pair.1.name,
                        reason: pair.1.reason, ignored: pair.1.ignored.isEmpty ? nil : pair.1.ignored)
        }
        var result = Result(action: options.action, dryRun: options.dryRun, hasChanges: batch.hasChanges, stacked: batch.stackedCount,
                            unchanged: batch.outcomes.filter { $0.status == .unchanged }.count, skipped: batch.skippedCount, results: items,
                            aliases: Dictionary(uniqueKeysWithValues: batch.aliases.map { ("@\($0.key)", $0.value) }), playlist: batch.draft)
        let preserved = library.watch.takeMovedFiles().map(\.name)
        if !preserved.isEmpty { result.preserved = preserved }
        if options.flags.contains("--json") {
            print(String(decoding: try ReadJSON.encode(command: "draft", data: result), as: UTF8.self))
            return
        }
        for line in lines(result) { print(line) }
    }

    static func lines(_ result: Result) -> [String] {
        var lines = [String(ui: "\(result.dryRun ? String(ui: "미리 보기") : String(ui: "완료")) · 재생 목록 초안 · 쌓은 편집 \(result.stacked) · 바뀌지 않은 편집 \(result.unchanged) · 건너뛴 편집 \(result.skipped)")]
        for item in result.results {
            let mark = switch item.status { case "stacked": "✓"; case "skipped": "✗"; default: "·" }
            var line = "  \(mark) #\(item.index + 1) \(item.op)"
            if let name = item.name { line += " ‘\(name)’" }
            if let id = item.playlistID { line += " (\(id))" }
            if let reason = item.reason { line += " · \(reason)" }
            if let ignored = item.ignored { line += " · " + String(ui: "넣거나 빼지 않은 곡 \(ignored.joined(separator: ", "))") }
            lines.append(line)
        }
        if let preserved = result.preserved {
            lines.append(String(ui: "  읽지 못한 기존 초안 파일은 지우지 않고 damaged-drafts에 옮겨 두었습니다: \(preserved.joined(separator: ", "))"))
        }
        if result.hasChanges, !result.dryRun {
            lines.append(String(ui: "rekordbox에는 아직 쓰지 않았습니다. DJCrate의 rekordbox에 쓰기에서 미리 보고 쓰세요"))
        }
        return lines
    }

    static func invalid(_ message: String) -> ReadFailure {
        ReadFailure("invalid_arguments", String(ui: "\(message). docs/cli.md의 draft playlist 사용법을 확인하세요"))
    }

    /// 요청 하나와 그 이름(JSON `op`)
    struct Parsed {
        let op: String
        let request: PlaylistEditRequest
    }

    struct Options {
        let action: String
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var requests: [Parsed] = []
        var dryRun: Bool { flags.contains("--dry-run") }

        /// `args`: `draft playlist <하위 명령> …`
        init(_ args: [String], readFile: (String) throws -> Data = Options.readFile) throws {
            guard args.count >= 3 else { throw invalid(String(ui: "재생 목록 편집 종류를 지정하세요")) }
            action = args[2]
            let valued: Set<String>
            let boolean: Set<String>
            switch action {
            case "apply": valued = ["--file"]; boolean = []
            case "create": valued = ["--parent", "--before", "--index", "--tracks"]; boolean = ["--folder"]
            case "move": valued = ["--parent", "--before", "--index"]; boolean = []
            case "order": valued = ["--before"]; boolean = []
            case "rename", "delete", "add", "remove": valued = []; boolean = []
            default: throw invalid(String(ui: "재생 목록 편집 종류는 apply·create·rename·move·delete·add·remove·order입니다"))
            }
            var operands: [String] = [], positionalOnly = false, index = 3
            while index < args.count {
                let arg = args[index]
                if arg == "--", !positionalOnly { positionalOnly = true; index += 1; continue }
                if arg.hasPrefix("--"), !positionalOnly {
                    if boolean.union(["--json", "--dry-run", "--all-or-nothing"]).contains(arg) {
                        guard flags.insert(arg).inserted else { throw invalid(String(ui: "옵션이 중복되었습니다")) }
                    } else if valued.union(["--db"]).contains(arg) {
                        guard values[arg] == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                            throw invalid(String(ui: "옵션 값이 없거나 중복되었습니다"))
                        }
                        index += 1; values[arg] = args[index]
                    } else { throw invalid(String(ui: "알 수 없는 옵션입니다")) }
                } else { operands.append(arg) }
                index += 1
            }
            if action == "apply" {
                guard operands.isEmpty, let file = values["--file"] else { throw invalid(String(ui: "편집 JSON 파일을 --file로 지정하세요")) }
                requests = try EditFile.requests(try readFile(file))
            } else {
                requests = [try Self.single(action, operands: operands, values: values, folder: flags.contains("--folder"))]
            }
        }

        static func readFile(_ path: String) throws -> Data {
            do {
                return path == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(filePath: path))
            } catch {
                throw invalid(String(ui: "편집 JSON 파일을 읽지 못했습니다(\(path))"))
            }
        }

        static func single(_ action: String, operands: [String], values: [String: String], folder: Bool) throws -> Parsed {
            func target(_ index: Int) throws -> PlaylistTarget {
                guard operands.count > index, !operands[index].isEmpty else { throw invalid(String(ui: "목록을 지정하세요")) }
                return PlaylistTarget(operands[index])
            }
            func tracks() throws -> [String] {
                let ids = Array(operands.dropFirst())
                guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }) else { throw invalid(String(ui: "ContentID를 하나 이상 지정하세요")) }
                return ids
            }
            func count(_ expected: Int) throws {
                guard operands.count == expected else { throw invalid(String(ui: "인자 수가 맞지 않습니다")) }
            }
            let index = try values["--index"].map { raw in
                guard let value = Int(raw), value >= 0 else { throw invalid(String(ui: "--index는 0 이상의 정수입니다")) }
                return value
            }
            let position: PlaylistPosition?
            do { position = try EditFile.position(before: action == "order" ? nil : values["--before"], index: index) }
            catch let failure as ReadFailure { throw invalid(failure.message) }
            switch action {
            case "create":
                try count(1)
                let tracks = values["--tracks"].map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } } ?? []
                guard tracks.allSatisfy({ !$0.isEmpty }), !(folder && !tracks.isEmpty) else { throw invalid(String(ui: "--tracks는 쉼표로 나눈 ContentID이고 폴더에는 줄 수 없습니다")) }
                return Parsed(op: "create", request: .create(name: operands[0], isFolder: folder, parent: PlaylistTarget(values["--parent"] ?? "root"),
                                                             position: position, alias: nil, tracks: tracks))
            case "rename":
                try count(2)
                return Parsed(op: "rename", request: .rename(try target(0), name: operands[1]))
            case "move":
                try count(1)
                guard values["--parent"] != nil || position != nil else { throw invalid(String(ui: "--parent나 자리(--before·--index)를 지정하세요")) }
                return Parsed(op: "move", request: .move(try target(0), into: values["--parent"].map(PlaylistTarget.init), position: position))
            case "delete":
                try count(1)
                return Parsed(op: "delete", request: .delete(try target(0)))
            case "add": return Parsed(op: "add", request: .addTracks(try target(0), contentIDs: try tracks()))
            case "remove": return Parsed(op: "remove", request: .removeTracks(try target(0), contentIDs: try tracks()))
            default: return Parsed(op: "order", request: .moveTracks(try target(0), contentIDs: try tracks(), before: values["--before"]))
            }
        }
    }

    /// 편집 JSON 파일: `{"edits": [편집…]}` 또는 `[편집…]`. 편집 하나는 `{"op": "create"|"rename"|"move"|"delete"|"add"|"remove"|"order", …}`.
    /// 모르는 칸·잘못된 값은 쌓기 전에 모두 인자 오류로 거절한다(오타가 조용히 무시되지 않게).
    enum EditFile {
        static let keys: [String: (required: Set<String>, optional: Set<String>)] = [
            "create": (["name"], ["folder", "parent", "as", "before", "index", "tracks"]),
            "rename": (["playlist", "name"], []),
            "move": (["playlist"], ["parent", "before", "index"]),
            "delete": (["playlist"], []),
            "add": (["playlist", "tracks"], []),
            "remove": (["playlist", "tracks"], []),
            "order": (["playlist", "tracks"], ["before"]),
        ]

        static func requests(_ data: Data) throws -> [Parsed] {
            guard let root = try? JSONSerialization.jsonObject(with: data) else { throw invalid(String(ui: "편집 JSON을 읽지 못했습니다")) }
            let list: [Any]
            if let array = root as? [Any] { list = array }
            else if let object = root as? [String: Any], object.keys.sorted() == ["edits"], let array = object["edits"] as? [Any] { list = array }
            else { throw invalid(String(ui: "편집 JSON은 {\"edits\": [...]} 또는 배열입니다")) }
            guard !list.isEmpty else { throw invalid(String(ui: "편집이 하나도 없습니다")) }
            return try list.enumerated().map { index, value in
                do { return try parse(value) } catch let failure as ReadFailure {
                    throw invalid(String(ui: "#\(index + 1) 편집: \(failure.message)"))
                }
            }
        }

        private static func fail(_ message: String) -> ReadFailure { ReadFailure("invalid_arguments", message) }

        static func parse(_ value: Any) throws -> Parsed {
            guard let edit = value as? [String: Any], let op = edit["op"] as? String, let spec = keys[op] else {
                throw fail(String(ui: "op는 create·rename·move·delete·add·remove·order 가운데 하나입니다"))
            }
            let given = Set(edit.keys).subtracting(["op"])
            if let unknown = given.subtracting(spec.required).subtracting(spec.optional).sorted().first {
                throw fail(String(ui: "\(op)에는 \(unknown) 칸이 없습니다"))
            }
            if let missing = spec.required.subtracting(given).sorted().first { throw fail(String(ui: "\(op)에는 \(missing) 칸이 있어야 합니다")) }
            func text(_ key: String) throws -> String? {
                guard let raw = edit[key] else { return nil }
                guard let text = raw as? String, !text.isEmpty else { throw fail(String(ui: "\(key)는 빈칸이 아닌 문자열입니다")) }
                return text
            }
            func target(_ key: String) throws -> PlaylistTarget? { try text(key).map(PlaylistTarget.init) }
            func tracks() throws -> [String]? {
                guard let raw = edit["tracks"] else { return nil }
                guard let ids = raw as? [String], ids.allSatisfy({ !$0.isEmpty }) else { throw fail(String(ui: "tracks는 ContentID 문자열 배열입니다")) }
                return ids
            }
            func index() throws -> Int? {
                guard let raw = edit["index"] else { return nil }
                guard let number = raw as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(), let value = Int(exactly: number.doubleValue), value >= 0 else {
                    throw fail(String(ui: "index는 0 이상의 정수입니다"))
                }
                return value
            }
            let playlist = try target("playlist")
            switch op {
            case "create":
                let folder: Bool
                switch edit["folder"] {
                case nil: folder = false
                case let flag as NSNumber where CFGetTypeID(flag) == CFBooleanGetTypeID(): folder = flag.boolValue
                default: throw fail(String(ui: "folder는 true 또는 false입니다"))
                }
                var alias: String?
                if let raw = try text("as") {
                    guard raw.hasPrefix("@"), raw.count > 1 else { throw fail(String(ui: "as는 @로 시작하는 임시 이름입니다")) }
                    alias = String(raw.dropFirst())
                }
                let tracks = try tracks() ?? []
                guard !(folder && !tracks.isEmpty) else { throw fail(String(ui: "폴더에는 tracks를 줄 수 없습니다")) }
                return Parsed(op: op, request: .create(name: try text("name") ?? "", isFolder: folder, parent: try target("parent") ?? .ref(.root),
                                                       position: try position(before: try text("before"), index: try index()), alias: alias, tracks: tracks))
            case "rename": return Parsed(op: op, request: .rename(playlist!, name: try text("name") ?? ""))
            case "move":
                let position = try position(before: try text("before"), index: try index())
                guard edit["parent"] != nil || position != nil else { throw fail(String(ui: "move에는 parent나 자리(before·index)가 있어야 합니다")) }
                return Parsed(op: op, request: .move(playlist!, into: try target("parent"), position: position))
            case "delete": return Parsed(op: op, request: .delete(playlist!))
            case "add", "remove":
                guard let ids = try tracks(), !ids.isEmpty else { throw fail(String(ui: "tracks에 ContentID를 하나 이상 주세요")) }
                return Parsed(op: op, request: op == "add" ? .addTracks(playlist!, contentIDs: ids) : .removeTracks(playlist!, contentIDs: ids))
            default:
                guard let ids = try tracks(), !ids.isEmpty else { throw fail(String(ui: "tracks에 ContentID를 하나 이상 주세요")) }
                return Parsed(op: op, request: .moveTracks(playlist!, contentIDs: ids, before: try text("before")))
            }
        }

        /// 자리: `before`(이 항목 앞)와 `index`(부모 안 번호)는 하나만
        static func position(before: String?, index: Int?) throws -> PlaylistPosition? {
            switch (before, index) {
            case (nil, nil): return nil
            case let (before?, nil): return .before(PlaylistTarget(before))
            case let (nil, index?): return .index(index)
            default: throw fail(String(ui: "before와 index는 함께 줄 수 없습니다"))
            }
        }
    }
}
