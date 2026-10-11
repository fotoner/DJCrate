import DJCApplication
import DJCDomain
import Foundation

/// `djc xml-diff`: 다른 도구·rekordbox가 만든 rekordbox XML을 스냅샷 사본과 비교한다(#72 가져오기). 읽기만 한다.
/// 곡은 파일 경로로 맞추고, 큐·그리드·태그·재생 목록의 차이를 종류별로 센다(규칙은 `XMLLibraryDiff`). 비교·초안 만들기는 앱의
/// "rekordbox XML 가져오기…"와 같은 유스케이스(`ImportXML`)다.
enum XMLDiffCommand {
    static let command = Command("xml-diff", "--db <사본.db> --xml <파일.xml> [--share <폴더> | --no-analysis] [--limit N] [--json] [--draft [--only cue,grid,tag,playlist]]",
                                 String(ui: "rekordbox XML과 라이브러리의 차이를 본다(읽기만, --draft면 고른 차이를 초안으로)")) { args in
        let request = try request(args)
        let report = try report(request)
        if request.json {
            FileHandle.standardOutput.write(try json(report) + Data("\n".utf8))
        } else {
            for line in lines(report, limit: request.limit) { print(line) }
        }
        if request.draft {
            for line in try makeDrafts(report, request: request, home: try CLIComposition.checkedDraftHome(), appRunning: isAppRunning()) {
                print(line)
            }
        }
    }

    struct Request: Equatable {
        var database: URL
        var xml: URL
        /// 분석 파일 뿌리. 없으면 사본 DB 옆 `share`(라이브 분석 파일로 대신하지 않는다)
        var share: URL?
        /// 그리드를 읽지 않고 비교하지도 않는다
        var noAnalysis = false
        var json = false
        /// 글 출력에서 곡·재생 목록을 몇 개까지 적을지
        var limit = 50
        /// 차이를 DJCrate 초안으로 만든다(DJC_HOME 아래 초안 폴더에만 쓴다)
        var draft = false
        /// 초안으로 만들 종류(`--only`)
        var kinds: Set<XMLImportDrafts.Kind> = Set(XMLImportDrafts.Kind.allCases)
    }

    typealias Report = XMLImportComparison

    static func request(_ args: [String]) throws -> Request {
        var values: [String: String] = [:], flags: Set<String> = []
        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--db", "--xml", "--share", "--limit", "--only":
                guard values[arg] == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else { throw UsageError() }
                values[arg] = args[index + 1]
                index += 1
            case "--json", "--no-analysis", "--draft":
                guard flags.insert(arg).inserted else { throw UsageError() }
            default:
                throw UsageError()
            }
            index += 1
        }
        guard let db = values["--db"], let xml = values["--xml"], !(flags.contains("--no-analysis") && values["--share"] != nil) else {
            throw UsageError()
        }
        var limit = 50
        if let text = values["--limit"] {
            guard let value = Int(text), value >= 0 else { throw UsageError() }
            limit = value
        }
        // JSON 출력에 초안 결과 줄이 섞이지 않게 함께 받지 않는다
        guard !(flags.contains("--json") && flags.contains("--draft")) else { throw UsageError() }
        var kinds = Set(XMLImportDrafts.Kind.allCases)
        if let text = values["--only"] {
            // 종류를 고르는 것은 초안을 만들 때만 뜻이 있다
            guard flags.contains("--draft") else { throw UsageError() }
            let parsed = text.split(separator: ",").map { XMLImportDrafts.Kind(rawValue: String($0)) }
            guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else { throw UsageError() }
            kinds = Set(parsed.compactMap { $0 })
        }
        return Request(database: URL(filePath: db), xml: URL(filePath: xml), share: values["--share"].map { URL(filePath: $0) },
                       noAnalysis: flags.contains("--no-analysis"), json: flags.contains("--json"), limit: limit,
                       draft: flags.contains("--draft"), kinds: kinds)
    }

    /// 라이브 DB를 먼저 거부하고(DB·XML을 열기 전), XML과 사본을 읽어 비교한다.
    static func report(_ request: Request) throws -> Report {
        let library = CLIComposition.live.library()
        let snapshot = try library.queries.resolveCopy(request.database)
        try library.importXML.requireXMLFile(request.xml)
        let share = try library.exportXML.analysisRoot(share: request.share, noAnalysis: request.noAnalysis, snapshot: snapshot)
        return try library.importXML.compare(xml: request.xml, snapshot: snapshot, share: share)
    }

    // MARK: - 글

    static func lines(_ report: Report, limit: Int) -> [String] {
        let diff = report.diff, matching = diff.matching, counts = diff.counts
        var lines = [
            String(ui: "XML 곡 \(matching.xmlTracks) · 맞춘 곡 \(matching.matched) · 라이브러리에 없는 곡 \(matching.unmatched) · 여러 곡에 맞는 곡 \(matching.ambiguous)"),
            String(ui: "큐가 다른 곡 \(counts.cueTracks) · 그리드가 다른 곡 \(counts.gridTracks) · 태그가 다른 곡 \(counts.tagTracks)"),
            String(ui: "없는 재생 목록 \(counts.missingPlaylists) · 곡이 다른 재생 목록 \(counts.changedPlaylists) · 이름이 겹쳐 비교하지 않은 목록 \(counts.ambiguousPlaylists)"),
        ]
        if !report.library.hasGrids { lines.append(String(ui: "그리드는 비교하지 않았습니다(분석 파일을 읽지 않음)")) }
        if counts.xmlWithoutGrid > 0 { lines.append(String(ui: "XML에 그리드가 없어 비교하지 않은 곡 \(counts.xmlWithoutGrid)")) }
        if counts.xmlWithoutCues > 0 { lines.append(String(ui: "XML에 큐가 없어 비교하지 않은 곡 \(counts.xmlWithoutCues)")) }
        if counts.xmlUnreadableCues > 0 { lines.append(String(ui: "읽지 못한 큐가 있어 큐를 비교하지 않은 곡 \(counts.xmlUnreadableCues)")) }
        let skipped = report.xml.skipped.sorted { $0.key < $1.key }.map { "\($0.key.label) \($0.value)" }
        if !skipped.isEmpty { lines.append(String(ui: "읽지 않고 건너뛴 것: \(skipped.joined(separator: " · "))")) }
        if diff.isEmpty {
            lines.append(String(ui: "차이가 없습니다"))
            return lines
        }
        for track in diff.tracks.prefix(limit) { lines.append("• " + summary(track)) }
        if diff.tracks.count > limit {
            lines.append(String(ui: "곡 \(diff.tracks.count - limit)개는 줄였습니다. --limit으로 늘리거나 --json으로 모두 보세요"))
        }
        for change in diff.playlists.prefix(limit) {
            let path = change.path.joined(separator: " / ")
            switch change.kind {
            case .missing: lines.append("• " + String(ui: "없는 재생 목록: \(path) (곡 \(change.xmlEntries.count))"))
            case .changed:
                lines.append("• " + String(ui: "곡이 다른 재생 목록: \(path) (XML \(change.xmlEntries.count)곡 · 라이브러리 \(change.libraryEntries.count)곡)"))
            }
            if change.unmatchedEntries > 0 {
                lines.append("  " + String(ui: "라이브러리에서 맞추지 못한 곡 \(change.unmatchedEntries)"))
            }
        }
        if diff.playlists.count > limit {
            lines.append(String(ui: "재생 목록 \(diff.playlists.count - limit)개는 줄였습니다. --limit으로 늘리거나 --json으로 모두 보세요"))
        }
        return lines
    }

    /// 곡 한 줄: 경로 — 제목: 큐 +더할 것 −뺄 것 · 그리드 · 태그 칸
    static func summary(_ track: XMLLibraryDiff.TrackDiff) -> String {
        var parts: [String] = []
        if let cues = track.cues { parts.append(String(ui: "큐 +\(cues.added.count) ~\(cues.modified.count) −\(cues.removed.count)")) }
        if track.grid != nil { parts.append(String(ui: "그리드")) }
        if !track.tags.isEmpty {
            parts.append(String(ui: "태그 \(track.tags.map(\.key.label).joined(separator: "·"))"))
        }
        return "\(track.path) — \(track.title): \(parts.joined(separator: " · "))"
    }

    // MARK: - 초안

    /// DJCrate 앱이 켜져 있는지 프로세스 이름으로 본다(확인하지 못하면 켜진 것으로 본다: 재생 목록 초안을 덮지 않게).
    static func isAppRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-x", DJCIdentity.name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return true
        }
    }

    /// 차이를 초안으로 만들어 `home` 아래 초안 폴더에만 쓴다. 기존 초안은 덮지 않고, 초안이 담지 못한 차이는 손실로 알린다.
    /// - Parameter appRunning: DJCrate 앱이 켜져 있다. 앱은 재생 목록 초안 파일을 다시 읽지 않고 메모리 초안을 저장하므로
    ///   재생 목록 초안은 만들지 않는다. 큐·태그·그리드 파일은 앱이 다시 읽지만 덱에 올린 곡의 그리드는 덱 편집이 덮을 수 있어 알린다.
    static func makeDrafts(_ report: Report, request: Request, home: URL, appRunning: Bool = false) throws -> [String] {
        var kinds = request.kinds
        if appRunning { kinds.remove(.playlist) }
        // 재생 목록 초안은 초안 파일에서 읽고, 계획하는 동안 파일이 바뀌지 않았을 때만 저장한다(앱은 화면이 든 초안으로 같은 규칙).
        let result = try CLIComposition.live.library(home: home).importXML
            .makeDraftsNow(report, selection: XMLImportDrafts.Selection(kinds: kinds))
        let saved: [XMLImportDrafts.Kind: Int] = [.cue: result.cues, .grid: result.grids, .tag: result.tags, .playlist: result.playlists]
        var lines = [String(ui: "초안을 만들었습니다: 큐 \(saved[.cue, default: 0]) · 그리드 \(saved[.grid, default: 0]) · 태그 \(saved[.tag, default: 0]) · 재생 목록 \(saved[.playlist, default: 0])")]
        if appRunning, request.kinds.contains(.playlist), !report.diff.playlists.isEmpty {
            lines.append(String(ui: "DJCrate가 켜져 있어 재생 목록 초안은 만들지 않았습니다(앱이 자기 초안으로 덮습니다). DJCrate를 끈 뒤 다시 실행하거나 앱의 rekordbox XML 가져오기를 쓰세요"))
        }
        if appRunning, request.kinds.contains(.grid) {
            lines.append(String(ui: "DJCrate가 켜져 있습니다: 덱에 올린 곡의 그리드 초안은 덱 편집이 덮을 수 있으니 그 곡을 덱에 다시 불러오세요"))
        }
        let skipped = result.skipped
        if !skipped.isEmpty { lines.append(String(ui: "기존 초안이 있어 건너뛴 것 \(skipped.count)")) }
        for note in skipped.prefix(request.limit) { lines.append("• \(note.kind.label) · \(note.subject): \(note.reason)") }
        if !result.losses.isEmpty { lines.append(String(ui: "초안에 담지 못한 차이 \(result.losses.count)")) }
        for note in result.losses.prefix(request.limit) { lines.append("• \(note.kind.label) · \(note.subject): \(note.reason)") }
        if skipped.count > request.limit || result.losses.count > request.limit {
            lines.append(String(ui: "일부 줄은 줄였습니다. --limit으로 늘려 보세요"))
        }
        lines.append(String(ui: "rekordbox에는 아직 쓰지 않았습니다. DJCrate의 rekordbox에 쓰기에서 미리 보고 쓰세요"))
        return lines
    }

    // MARK: - JSON

    struct JSONMark: Encodable {
        var kind: String
        var slot: String?
        var start: Double
        var end: Double?
        var name: String

        init(_ mark: XMLLibrary.Mark) {
            kind = mark.kind == .memory ? "memory" : "hot"
            slot = mark.kind.slotLetter
            start = mark.start; end = mark.end; name = mark.name
        }
    }

    struct JSONTag: Encodable {
        var key: String
        var library: String
        var xml: String
    }

    struct JSONCueEdit: Encodable {
        var library: JSONMark
        var xml: JSONMark
    }

    struct JSONCues: Encodable {
        var added: [JSONMark]
        var removed: [JSONMark]
        var modified: [JSONCueEdit]
    }

    struct JSONTrack: Encodable {
        var xmlID: String
        var libraryID: String
        var path: String
        var title: String
        var cues: JSONCues?
        var grid: XMLLibraryDiff.GridChange?
        var tags: [JSONTag]
    }

    struct JSONUnmatched: Encodable {
        var xmlID: String
        var path: String?
        var title: String
    }

    struct JSONPlaylist: Encodable {
        var kind: String
        var path: [String]
        var libraryID: String?
        var xmlEntries: [String]
        var libraryEntries: [String]
        var unmatchedEntries: Int
    }

    struct JSONReport: Encodable {
        var gridsCompared: Bool
        var matching: XMLLibraryDiff.Matching
        var counts: XMLLibraryDiff.Counts
        var skipped: [String: Int]
        var tracks: [JSONTrack]
        var unmatched: [JSONUnmatched]
        var ambiguous: [JSONUnmatched]
        var playlists: [JSONPlaylist]
    }

    static func json(_ report: Report) throws -> Data {
        let diff = report.diff
        let byKey = Dictionary(report.xml.tracks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        func records(_ keys: [String]) -> [JSONUnmatched] {
            keys.map { JSONUnmatched(xmlID: $0, path: byKey[$0]?.path, title: byKey[$0]?.title ?? "") }
        }
        let body = JSONReport(
            gridsCompared: report.library.hasGrids, matching: diff.matching, counts: diff.counts,
            skipped: Dictionary(uniqueKeysWithValues: report.xml.skipped.map { ($0.key.rawValue, $0.value) }),
            tracks: diff.tracks.map { track in
                JSONTrack(xmlID: track.xmlKey, libraryID: track.libraryKey, path: track.path, title: track.title,
                          cues: track.cues.map { cues in
                              JSONCues(added: cues.added.map(JSONMark.init), removed: cues.removed.map(JSONMark.init),
                                       modified: cues.modified.map { JSONCueEdit(library: JSONMark($0.library), xml: JSONMark($0.xml)) })
                          },
                          grid: track.grid, tags: track.tags.map { JSONTag(key: $0.key.rawValue, library: $0.library, xml: $0.xml) })
            },
            unmatched: records(diff.matches.unmatched), ambiguous: records(diff.matches.ambiguous),
            playlists: diff.playlists.map {
                JSONPlaylist(kind: $0.kind.rawValue, path: $0.path, libraryID: $0.libraryID, xmlEntries: $0.xmlEntries,
                             libraryEntries: $0.libraryEntries, unmatchedEntries: $0.unmatchedEntries)
            })
        return try ReadJSON.encode(command: "xml-diff", data: body)
    }
}
