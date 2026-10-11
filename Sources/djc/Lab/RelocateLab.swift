import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 파일 없는 곡의 새 위치 후보 맞추기(#62). 사본 DB와 폴더를 읽기만 하고 rekordbox·음원에는 쓰지 않는다.
/// lab 명령이라 문구는 번역하지 않는다.
enum RelocateLab {
    static let all: [Command] = [
        Command("relocate-candidates", "--db <사본.db> --folder <폴더>",
                "파일 없는 곡의 새 위치 후보를 폴더에서 맞춰 확실·애매·없음 개수만 찍는다(읽기 전용, 곡 제목·경로는 찍지 않는다)",
                RelocateLab.candidates),
    ]

    static func candidates(_ args: [String]) async throws {
        guard let db = value(after: "--db", in: args), let folder = value(after: "--folder", in: args) else { throw UsageError() }
        // 라이브 master.db·그 링크는 열지 않는다(사본만).
        let snapshot = try LibraryRead.resolve(database: URL(filePath: db))
        let library = try RekordboxLibrary.load(snapshot: snapshot)
        let local = library.tracks.filter { !$0.isStreaming }
        let missing = MissingFiles.scan(local, exists: { FileManager.default.fileExists(atPath: $0) }).trackIDs
        let targets = try RelocateScanner.targets(for: local.filter { missing.contains($0.id) }, snapshot: snapshot)
        FileHandle.standardError.write(Data("파일 없는 곡 \(targets.count)곡의 후보를 폴더에서 찾는 중…\n".utf8))
        let output = try await RelocateScanner.scan(targets: targets, folder: URL(filePath: folder))
        for line in summaryLines(targets: targets.count, output: output) { print(line) }
    }

    /// 곡 제목·경로 없이 개수만. 분류별 개수와 애매한 이유별 개수.
    static func summaryLines(targets: Int, output: RelocateScanner.Output) -> [String] {
        let report = output.report
        var reasons: [RelocateOutcome.AmbiguityReason: Int] = [:]
        for result in report.results {
            if case let .ambiguous(reason, _) = result.outcome { reasons[reason, default: 0] += 1 }
        }
        func count(_ reason: RelocateOutcome.AmbiguityReason) -> Int { reasons[reason, default: 0] }
        return [
            "파일 없는 곡 \(targets)곡 · 폴더의 음원 파일 \(output.summary.audioFiles)개(이름·크기가 맞아 태그까지 읽은 파일 \(output.summary.comparedFiles)개)",
            "확실 \(report.confidentCount) · 애매 \(report.ambiguousCount) · 없음 \(report.noneCount)",
            "애매한 이유: 후보 여럿 \(count(.severalCandidates)) · 다른 곡도 같은 파일을 후보로 삼음 \(count(.sharedFile))"
                + " · 확장자가 다름 \(count(.differentExtension)) · 근거 부족 \(count(.weakEvidence))",
        ]
    }
}
