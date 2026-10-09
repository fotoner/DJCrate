import DJCApplication
import DJCDomain
import Foundation

/// 인자와 출력만 맡는다. 조회는 유스케이스 `QueryLibrary`(사본 정하기·라이브 DB 거부), JSON 계약 값은 `LibraryRecords`다.
enum ReadCommands {
    static let names: Set<String> = ["search", "track", "playlists", "playlist", "histories", "history", "drafts", "duplicates"]
    static let jsonNames = names.union(["report", "path", "parse", "compat", "usb-info"])
    static let all: [Command] = [
        Command("search", String(ui: "<검색어> [--bpm 최소-최대] [--key 키] [--playlist ID] [--filter 필터] [--comment-preset none|anisong] [--db PATH] [--json]"), String(ui: "곡 찾기"), run),
        Command("track", "<ContentID> [--db PATH] [--json]", String(ui: "곡 정보·큐·그리드·게인·초안 보기"), run),
        Command("playlists", "[--tree] [--db PATH] [--json]", String(ui: "재생 목록·폴더 보기"), run),
        Command("playlist", "<ID> [--db PATH] [--json]", String(ui: "재생 목록의 곡을 순서대로 보기"), run),
        Command("histories", "[--db PATH] [--json]", String(ui: "재생 기록을 날짜순으로 보기"), run),
        Command("history", "<ID> [--db PATH] [--json]", String(ui: "기록의 곡을 재생 순서대로 보기"), run),
        Command("drafts", "[--db PATH] [--json]", String(ui: "반영 대기 초안 보기"), run),
        Command("duplicates", "[--db PATH] [--json]", String(ui: "중복 후보 묶음과 큐·재생 목록·음질 비교"), run),
    ]

    static func handlesJSON(_ args: [String]) -> Bool {
        args.contains("--json") && jsonNames.contains(args.first ?? "")
    }

    static func run(_ args: [String]) async throws {
        // USB 읽기는 인자·출력이 달라 따로 맡긴다(JSON 계약만 같다)
        if args.first == "usb-info" { try await UsbCommands.info(args); return }
        let options = try Options(args)
        let name = args[0]
        let queries = CLIComposition.live.library().queries
        if name == "parse" {
            try output(queries.parse(comment: options.operands[0]), name: name, json: true) { _ in "" }
            return
        }
        let explicit = options.values["--db"].map { URL(filePath: $0) }
        if name == "compat" {
            try output(queries.compatibility(database: explicit), name: name, json: true) { _ in "" }
            return
        }
        let read = try queries.open(database: explicit, commentPreset: options.commentPreset)
        let json = options.flags.contains("--json")
        switch name {
        case "search":
            let result = try read.search(options.operands[0], options.bpm, options.values["--key"], options.values["--playlist"], options.filter)
            try output(result, name: name, json: json) { tracksText($0.tracks) }
        case "track":
            try output(read.track(options.operands[0]), name: name, json: json, text: trackText)
        case "duplicates":
            try output(read.duplicates(), name: name, json: json) { result in
                result.groups.isEmpty ? String(ui: "중복 후보가 없습니다") : result.groups.map { group in
                    String(ui: "후보 묶음 \(group.id) · 길이 차이 2초 이내\n") + group.tracks.map { member in
                        let bitrate = member.bitrateKbps.map { "\($0) kbps" } ?? String(ui: "비트레이트 알 수 없음")
                        return String(ui: "\(member.id) · \(member.track.title) · \(member.track.artist ?? "") · \(member.track.lengthSeconds)초")
                            + String(ui: " · 큐 \(member.cueCount)(수동 \(member.manualCueCount)) · 재생 목록 \(member.playlistCount) · 재생 \(member.playCount)")
                            + " · \(member.format) · \(bitrate)\n  \(member.track.path)"
                    }.joined(separator: "\n")
                }.joined(separator: "\n\n")
            }
        case "playlists":
            try output(read.playlists(options.flags.contains("--tree")), name: name, json: json) {
                playlistsText($0.playlists)
            }
        case "playlist":
            try output(read.playlist(options.operands[0]), name: name, json: json) {
                "\($0.playlist.name) · \($0.playlist.id)\n" + tracksText($0.tracks)
            }
        case "histories":
            try output(read.histories(), name: name, json: json) {
                $0.histories.isEmpty ? String(ui: "재생 기록이 없습니다") : $0.histories.map {
                    String(ui: "\($0.id) · \($0.dateCreated ?? String(ui: "날짜 없음")) · \($0.name) · \($0.trackCount)곡")
                }.joined(separator: "\n")
            }
        case "history":
            try output(read.history(options.operands[0]), name: name, json: json) {
                "\($0.history.dateCreated ?? String(ui: "날짜 없음")) · \($0.history.name)\n"
                    + ($0.entries.isEmpty ? String(ui: "곡이 없습니다") : $0.entries.map {
                        "\($0.trackNumber). " + tracksText([$0.track])
                    }.joined(separator: "\n"))
            }
        case "drafts":
            try output(read.drafts(), name: name, json: json) { result in
                result.drafts.isEmpty ? String(ui: "반영 대기 초안이 없습니다") : result.drafts.map {
                    "\($0.contentID ?? String(ui: "컬렉션에 없음")) · \($0.title ?? $0.trackUUID) · \(draftNames($0.kinds))"
                }.joined(separator: "\n")
            }
        case "report":
            try output(LibraryRecords.Report(read.report(options.flags.contains("--files"))), name: name, json: true) { _ in "" }
        case "path":
            try output(read.paths(options.operands[0]), name: name, json: true) { _ in "" }
        default: throw ReadFailure("invalid_arguments", String(ui: "알 수 없는 명령입니다. djc로 명령 목록을 확인하세요"))
        }
    }

    private static func output<T: Encodable>(_ result: T, name: String, json: Bool, text: (T) -> String) throws {
        if json { print(String(decoding: try ReadJSON.encode(command: name, data: result), as: UTF8.self)) }
        else { print(text(result)) }
    }

    private static func tracksText(_ tracks: [LibraryRecords.TrackRecord]) -> String {
        tracks.isEmpty ? String(ui: "곡이 없습니다") : tracks.map {
            "\($0.id) · \($0.title) · \($0.artist ?? String(ui: "아티스트 없음")) · \($0.bpm.map { String(format: "%.2f BPM", $0) } ?? String(ui: "BPM 없음")) · \($0.key ?? String(ui: "키 없음"))"
        }.joined(separator: "\n")
    }

    private static func playlistsText(_ playlists: [LibraryRecords.PlaylistRecord], depth: Int = 0) -> String {
        playlists.map {
            String(repeating: "  ", count: depth) + String(ui: "\($0.id) · \($0.name) · \($0.isFolder ? String(ui: "폴더") : String(ui: "재생 목록")) · \($0.trackCount)곡")
                + ($0.children.map { $0.isEmpty ? "" : "\n" + playlistsText($0, depth: depth + 1) } ?? "")
        }.joined(separator: "\n")
    }

    private static func draftNames(_ kinds: [String]) -> String {
        kinds.map { ["cue": String(ui: "큐"), "grid": String(ui: "그리드"), "gain": String(ui: "게인"), "tag": String(ui: "태그")][$0] ?? $0 }.joined(separator: ", ")
    }

    private static func trackText(_ result: LibraryRecords.TrackInfo) -> String {
        let track = result.track
        var lines = [tracksText([track]), "UUID: \(track.uuid)", String(ui: "파일: \(track.path)"), String(ui: "길이: \(track.lengthSeconds)초"),
                     String(ui: "앨범: \(track.album ?? String(ui: "없음")) · 앨범 아티스트: \(track.albumArtist ?? String(ui: "없음"))"),
                     String(ui: "장르: \(track.genre ?? String(ui: "없음")) · 작곡가: \(track.composer ?? String(ui: "없음"))"),
                     String(ui: "연도: \(track.releaseYear.map(String.init) ?? String(ui: "없음")) · 트랙 번호: \(track.trackNumber.map(String.init) ?? String(ui: "없음"))"),
                     String(ui: "코멘트: \(track.comment)")]
        lines += result.cues.map {
            String(ui: "큐 \($0.kind == 0 ? String(ui: "메모리") : ($0.hotCueSlot ?? String(ui: "슬롯 \($0.kind)"))) · \($0.inMsec)ms · \($0.name)")
                + ($0.isLoop ? String(ui: " · 루프 끝 \($0.outMsec)ms\($0.activeLoop ? String(ui: " (활성)") : "")") : "")
        }
        lines.append(String(ui: "그리드: \(result.grid.status == "available" ? String(ui: "\(result.grid.beatCount)박 · \(result.grid.segments.count)구간") : String(ui: "분석 파일 없음 또는 읽기 실패"))"))
        lines += result.grid.segments.map { String(ui: "  \($0.start, specifier: "%.3f")초 · \($0.bpm, specifier: "%.2f") BPM · \($0.firstBeatNumber)박") }
        lines.append(String(ui: "게인: \(result.gain.map { String(format: "%.2f dB", $0.decibels) } ?? String(ui: "없음"))"))
        lines.append(String(ui: "재생 목록: \(result.playlists.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))"))
        lines.append(String(ui: "초안: \(result.drafts.kinds.isEmpty ? String(ui: "없음") : draftNames(result.drafts.kinds))"))
        return lines.joined(separator: "\n")
    }

    private struct Options {
        var operands: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var bpm: ClosedRange<Double>?
        var filter: LibraryFilter = .all
        var commentPreset: CommentPreset = .none

        init(_ args: [String]) throws {
            let command = args.first ?? ""
            var valued: Set<String> = command == "parse" ? [] : ["--db"]
            var boolean: Set<String> = ["--json"]
            if command == "search" { valued.formUnion(["--bpm", "--key", "--playlist", "--filter"]) }
            if command == "search" || command == "report" { valued.insert("--comment-preset") }
            if command == "playlists" { boolean.insert("--tree") }
            if command == "report" { boolean.insert("--files") }
            var index = 1, positionalOnly = false
            func invalid(_ message: String) -> ReadFailure {
                ReadFailure("invalid_arguments", String(ui: "\(message). djc로 사용법을 확인하세요"))
            }
            while index < args.count {
                let arg = args[index]
                if arg == "--", !positionalOnly { positionalOnly = true; index += 1; continue }
                if !positionalOnly && arg.hasPrefix("--") {
                    if boolean.contains(arg) {
                        guard flags.insert(arg).inserted else { throw invalid(String(ui: "옵션이 중복되었습니다")) }
                    } else if valued.contains(arg) {
                        guard values[arg] == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else {
                            throw invalid(String(ui: "옵션 값이 없거나 중복되었습니다"))
                        }
                        index += 1; values[arg] = args[index]
                    } else { throw invalid(String(ui: "알 수 없는 옵션입니다")) }
                } else { operands.append(arg) }
                index += 1
            }
            let expected = ["search", "track", "playlist", "history", "path", "parse"].contains(command) ? 1 : 0
            guard operands.count == expected else { throw invalid(String(ui: "명령 인자 수가 맞지 않습니다")) }
            if let raw = values["--bpm"] {
                let pieces = raw.split(separator: "-", omittingEmptySubsequences: false)
                guard pieces.count == 2, let lower = Double(pieces[0]), let upper = Double(pieces[1]),
                      lower.isFinite, upper.isFinite, lower > 0, lower <= upper else { throw invalid(String(ui: "BPM은 120-130처럼 양수 범위로 쓰세요")) }
                bpm = lower...upper
            }
            if let raw = values["--comment-preset"] {
                guard let preset = CommentPreset(rawValue: raw) else {
                    throw invalid(String(ui: "코멘트 프리셋은 none 또는 anisong으로 쓰세요"))
                }
                commentPreset = preset
            }
            if let raw = values["--filter"] {
                if raw == "backlog" {
                    throw invalid(String(ui: "backlog 필터는 삭제되었습니다. 빈 코멘트는 --filter empty-comment로 찾으세요"))
                }
                guard let matched = LibraryFilter.allCases.first(where: { $0.cliName == raw }) else {
                    throw invalid(String(ui: "필터는 \(LibraryFilter.allCases.map(\.cliName).joined(separator: ", ")) 중 하나로 쓰세요"))
                }
                guard !matched.requiresCommentRule || commentPreset.rule != nil else {
                    throw invalid(String(ui: "코멘트 규칙 필터는 --comment-preset anisong을 지정한 뒤 쓰세요"))
                }
                filter = matched
            }
        }
    }
}
