import DJCApplication
import DJCDomain
import Foundation

/// `djc cache`: 캐시 종류별 용량 보기와 비우기(#215). 캐시는 다시 만들어지므로 따로 묻지 않는다(`--dry-run`으로 미리 본다).
/// 지우는 규칙은 캐시 포트의 실제 구현(`DJCCache`) 한 곳이다(초안·추가 목록·백업·USB 저널·준비 폴더는 종류에 없다).
enum CacheCommand {
    static let command = Command("cache", String(ui: "[--clear <종류…|all>] [--dry-run]"),
                                 String(ui: "캐시 종류별 용량 보기·비우기(초안·백업은 지우지 않음)")) { args in
        print(try run(args))
    }

    struct Request: Equatable {
        /// nil이면 용량만 본다
        var kinds: [DJCCacheKind]?
        var dryRun: Bool

        init(kinds: [DJCCacheKind]?, dryRun: Bool) { self.kinds = kinds; self.dryRun = dryRun }

        init(_ args: [String]) throws {
            var kinds: [DJCCacheKind]?, dryRun = false
            var rest = args.dropFirst()
            while let arg = rest.popFirst() {
                switch arg {
                case "--dry-run": dryRun = true
                case "--clear":
                    var names: [String] = []
                    while let next = rest.first, !next.hasPrefix("--") { names.append(next); rest.removeFirst() }
                    guard !names.isEmpty else { throw UsageError() }
                    kinds = try names.contains("all") ? DJCCacheKind.allCases : names.map { name in
                        guard let kind = DJCCacheKind(rawValue: name) else { throw Failure.unknownKind(name) }
                        return kind
                    }
                default: throw UsageError()
                }
            }
            if dryRun, kinds == nil { throw UsageError() }
            self.kinds = kinds
            self.dryRun = dryRun
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case unknownKind(String)
        var description: String {
            switch self {
            case .unknownKind(let name):
                String(ui: "모르는 캐시 종류입니다: \(name). \(DJCCacheKind.allCases.map(\.rawValue).joined(separator: ", ")), all 중에서 고르세요")
            }
        }
    }

    /// - Parameters:
    ///   - paths: 캐시 자리(nil이면 이 프로세스의 데이터 폴더, 시험은 임시 폴더)
    ///   - cache: 캐시 폴더(nil이면 조립 지점의 실제 구현)
    static func run(_ args: [String], paths: DJCCachePaths? = nil, cache: CacheFiles? = nil) throws -> String {
        let request = try Request(args)
        let paths = paths ?? CLIComposition.cachePaths, cache = cache ?? CLIComposition.cache
        guard let kinds = request.kinds else { return usageText(paths: paths, cache: cache) }
        let outcomes = cache.clear(kinds, paths, [], request.dryRun)
        var lines = [request.dryRun ? String(ui: "미리 보기(지우지 않음):") : String(ui: "비웠습니다:")]
        for outcome in outcomes {
            let head = "  \(outcome.kind.rawValue)  \(outcome.kind.title)"
            if let reason = outcome.skipped {
                lines.append(head + String(ui: ": 비우지 않음 — \(reason)"))
                continue
            }
            var line = head + String(ui: ": \(size(outcome.freedBytes)) · 파일 \(outcome.removedFiles)개")
            if outcome.keptItems > 0 { line += String(ui: " · 사본 \(outcome.keptItems)개 남김") }
            lines.append(line)
        }
        let total = outcomes.reduce(0) { $0 + $1.freedBytes }
        lines.append(String(ui: "합계 \(size(total))"))
        return lines.joined(separator: "\n")
    }

    static func usageText(paths: DJCCachePaths, cache: CacheFiles) -> String {
        let usage = cache.usage(paths)
        var lines = [String(ui: "데이터 폴더: \(paths.root.path)"), String(ui: "스냅샷 폴더: \(paths.snapshots.path)")]
        for item in usage {
            lines.append("  \(item.kind.rawValue)  \(item.kind.title): \(size(item.bytes)) · " + String(ui: "파일 \(item.files)개"))
        }
        lines.append(String(ui: "합계 \(size(usage.reduce(0) { $0 + $1.bytes }))"))
        lines.append(String(ui: "크기는 파일 크기의 합이라 실제 디스크 사용보다 클 수 있습니다. 비우려면 djc cache --clear <종류…|all>"))
        return lines.joined(separator: "\n")
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false  // "Zero KB" 대신 "0 바이트"
        return formatter.string(fromByteCount: bytes)
    }
}
