import DJCApplication
import DJCDomain
import Foundation

/// `djc xml-export`: 스냅샷 사본의 라이브러리 전체를 rekordbox XML 한 파일로 내보낸다(#72). rekordbox 라이브러리에는 쓰지 않고
/// 지정한 출력 파일만 쓴다. 쓰지 않은 초안은 넣지 않는다(rekordbox에 있는 그대로). 앱의 "라이브러리 XML 내보내기…"와 같은 유스케이스(`ExportXML`)다.
enum XMLExportCommand {
    static let command = Command("xml-export", "--db <사본.db> --out <파일.xml> [--share <폴더> | --no-analysis] [--overwrite] [--dry-run]",
                                 String(ui: "라이브러리 전체를 rekordbox XML 한 파일로 내보낸다(읽기만, 지정한 파일만 씀)")) { args in
        for line in try execute(try request(args)) { print(line) }
    }

    struct Request: Equatable {
        var database: URL
        var out: URL
        /// 분석 파일 뿌리. 없으면 사본 DB 옆 `share`(라이브 분석 파일로 대신하지 않는다)
        var share: URL?
        var overwrite: Bool
        var dryRun: Bool
        /// 분석 파일 없이(TEMPO 없이) 내보낸다. 이것을 주지 않으면 분석 파일 폴더가 있어야 한다.
        var noAnalysis = false
    }

    static func request(_ args: [String]) throws -> Request {
        var values: [String: String] = [:], flags: Set<String> = []
        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--db", "--out", "--share":
                guard values[arg] == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else { throw UsageError() }
                values[arg] = args[index + 1]
                index += 1
            case "--overwrite", "--dry-run", "--no-analysis":
                guard flags.insert(arg).inserted else { throw UsageError() }
            default:
                throw UsageError()
            }
            index += 1
        }
        guard let db = values["--db"], let out = values["--out"], !(flags.contains("--no-analysis") && values["--share"] != nil) else {
            throw UsageError()
        }
        return Request(database: URL(filePath: db), out: URL(filePath: out), share: values["--share"].map { URL(filePath: $0) },
                       overwrite: flags.contains("--overwrite"), dryRun: flags.contains("--dry-run"),
                       noAnalysis: flags.contains("--no-analysis"))
    }

    /// 출력 자리를 먼저 확인하고(DB를 열기 전) 내보낸다. 돌려주는 것은 출력할 줄이다.
    static func execute(_ request: Request) throws -> [String] {
        let library = CLIComposition.live.library()
        let export = library.exportXML
        try export.checkOutput(request.out, overwrite: request.overwrite, dryRun: request.dryRun)
        let snapshot = try library.queries.resolveCopy(request.database)
        let summary = try export.exportLibrary(snapshot: snapshot, share: try shareRoot(request, snapshot: snapshot), to: request.out,
                                               dryRun: request.dryRun)
        return summaryLines(summary, out: request.out, dryRun: request.dryRun)
    }

    /// 분석 파일 뿌리. `djc snapshot` 사본 옆에는 `share`가 없어서, 없는 폴더를 그대로 쓰면 모든 곡의 TEMPO가 조용히 빠진다.
    /// 그래서 폴더가 없으면 막고, 분석 없이 내보내는 것은 `--no-analysis`로 명시할 때만 한다(nil).
    static func shareRoot(_ request: Request, snapshot: URL) throws -> URL? {
        try CLIComposition.live.library().exportXML.analysisRoot(share: request.share, noAnalysis: request.noAnalysis, snapshot: snapshot)
    }

    static func summaryLines(_ summary: LibraryXMLSummary, out: URL, dryRun: Bool) -> [String] {
        var lines = [dryRun ? String(ui: "미리 보기(파일을 쓰지 않음): \(out.path)") : String(ui: "라이브러리 XML을 썼습니다: \(out.path)")]
        lines.append(String(ui: "곡 \(summary.tracks) · 큐·루프 \(summary.marks) · 그리드 있는 곡 \(summary.tracksWithGrid) · 분석 파일이 없거나 읽지 못한 곡 \(summary.tracksWithoutGrid)"))
        lines.append(String(ui: "재생 목록 \(summary.playlists) · 폴더 \(summary.folders) · 목록 항목 \(summary.playlistEntries)"))
        let omitted = summary.omitted
        lines.append(String(ui: "뺀 것: 스트리밍 곡 \(omitted.streamingTracks) · 인텔리전트 목록 \(omitted.intelligentPlaylists) · XML로 옮길 수 없는 큐 \(omitted.unknownCues) · 뺀 곡을 가리킨 목록 항목 \(omitted.playlistEntries) · 상위 폴더가 없는 목록 \(omitted.orphanedPlaylists)"))
        lines.append(String(ui: "쓰지 않은 초안은 넣지 않았습니다(rekordbox에 있는 그대로입니다)"))
        return lines
    }
}
