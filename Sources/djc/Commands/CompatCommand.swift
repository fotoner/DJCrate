import DJCApplication
import DJCDomain
import Foundation

/// `djc compat`(글): 라이브 쓰기 전 확인(읽기 전용). 순서·판정은 유스케이스 `CompatibilityCheck`, 실제 구현은 조립 지점이 고른다.
/// `--json`은 읽기 명령(`ReadCommands`)이 맡는다.
enum CompatCommand {
    static let command = Command("compat", "[--db PATH] [--json]", String(ui: "쓰기 전 확인: rekordbox 버전·DB 구조가 확인한 모양인지")) { try run($0) }

    static func run(_ args: [String]) throws {
        try CLIComposition.compatibilityCheck.run(database: value(after: "--db", in: args).map { URL(filePath: $0) }) { print(line($0)) }
    }

    static func line(_ finding: CompatibilityCheck.Finding) -> String {
        switch finding {
        case let .app(installed, verified):
            String(ui: "rekordbox 앱: \(installed ?? String(ui: "찾지 못함")) · 확인한 버전 \(verified.map { "\($0).x" }.joined(separator: ", "))")
        case let .schema(databaseVersion, file):
            String(ui: "DB 구조: 확인한 모양과 같음(DBVersion \(databaseVersion)) · \(file)")
        case let .counters(local, cloud):
            String(ui: "변경 카운터: 로컬 \(local.map(String.init) ?? String(ui: "없음")) · 클라우드 동기화 \(cloud.map(String.init) ?? String(ui: "없음"))")
        }
    }
}
