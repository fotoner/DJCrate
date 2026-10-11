import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 사용자가 rekordbox에서 편집한 전후 사본을 대조한다. DB·분석 파일은 저장소에 넣지 않는다.
struct GridTempoExperimentRepro {
    struct Edit: Decodable {
        var before: String
        var after: String
        var title: String
        var segment: Int
        var bpm: Double
        var truncateFollowing: Bool
        var segments: [GridSegment]?
    }

    struct Track: Decodable {
        var id: String
        var uuid: String
        var title: String
        var audio: String
        var analysis: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_GRID_EXPERIMENT"] != nil))
    func 변속곡_편집을_사본에_써서_모든_박과_DB_칸을_대조한다() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_GRID_EXPERIMENT"] else { return }
        let root = URL(filePath: path)
        let edits = try JSONDecoder().decode([Edit].self, from: Data(contentsOf: root.appending(path: "edits.json")))
        for edit in edits { try reproduce(edit, root: root) }
    }

    private func reproduce(_ edit: Edit, root: URL) throws {
        let fm = FileManager.default
        let before = root.appending(path: edit.before), after = root.appending(path: edit.after)
        let tracks = try JSONDecoder().decode([Track].self, from: Data(contentsOf: before.appending(path: "tracks.json")))
        let track = try #require(tracks.first { $0.title == edit.title })
        let work = root.appending(path: "repro-\(UUID())")
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        try fm.copyItem(at: before.appending(path: "master.db"), to: work.appending(path: "master.db"))
        try fm.copyItem(at: before.appending(path: "share"), to: work.appending(path: "share"))
        let relative = "share/" + track.analysis.drop(while: { $0 == "/" })
        let dat = work.appending(path: relative)
        var draft = GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: dat))
        let time = draft.segments[edit.segment].start
        if edit.truncateFollowing { draft.segments = Array(draft.segments.prefix(edit.segment + 1)) }
        draft.setBPM(edit.bpm, at: time)
        if let segments = edit.segments { draft.segments = segments }
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: work.appending(path: "master.db"),
                                               dryRun: false, backups: work.appending(path: "backups"), shareRoot: work.appending(path: "share"))
        try #require(report.gridWritten.count == 1, "실험 편집 쓰기: \(report.gridBlocked.compactMap(\.reason))")
        for ext in ["DAT", "EXT", "2EX", "3EX"] {
            let generated = dat.deletingPathExtension().appendingPathExtension(ext)
            let expected = after.appending(path: relative).deletingPathExtension().appendingPathExtension(ext)
            let same = try Data(contentsOf: generated) == Data(contentsOf: expected)
            #expect(same, "\(edit.title): .\(ext) 전체 바이트 일치")
        }

        let key = try RekordboxKey.derive()
        let source = try CipherDatabase.diagnostic(path: before.appending(path: "master.db").path, key: key)
        let ours = try CipherDatabase.diagnostic(path: work.appending(path: "master.db").path, key: key)
        let theirs = try CipherDatabase.diagnostic(path: after.appending(path: "master.db").path, key: key)
        defer { source.close(); ours.close(); theirs.close() }
        for table in ["djmdContent", "contentFile", "djmdCue", "contentCue", "djmdMixerParam"] {
            let column = table == "djmdContent" ? "ID" : "ContentID"
            let sql = "SELECT * FROM \(table) WHERE \(column) = ? ORDER BY ID"
            func rows(_ db: CipherDatabase) throws -> [[String: String]] {
                var result: [[String: String]] = []
                try db.query(sql, [.text(track.id)]) { row in
                    result.append(Dictionary(uniqueKeysWithValues: (0..<row.count).map {
                        (row.name(Int32($0)), row.string(Int32($0)) ?? "NULL")
                    }))
                }
                return result
            }
            let original = try rows(source), actual = try rows(ours), expected = try rows(theirs)
            try #require(original.count == expected.count && actual.count == expected.count, "\(table) 행 구성")
            for (index, pair) in zip(actual, expected).enumerated() {
                let differences = Set(pair.0.keys).union(pair.1.keys).filter { column in
                    // 번호 값·시각은 실행마다 다르므로 변경 여부를 비교한다. 칸 값은 로그에 내보내지 않는다.
                    if ["rb_local_usn", "updated_at"].contains(column) {
                        return (pair.0[column] != original[index][column]) != (pair.1[column] != original[index][column])
                    }
                    return pair.0[column] != pair.1[column]
                }
                #expect(differences.isEmpty, "\(edit.title): \(table) 다른 칸 \(differences.sorted())")
            }
        }
    }
}
