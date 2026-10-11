import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 사용자가 rekordbox에서 바꾼 전후 사본으로만 실행한다. 원문·DB 내용은 로그와 저장소에 남기지 않는다.
struct ITunesSyncExperimentRepro {
    struct Source: Decodable { let id: String; let parentID: String?; let isFolder: Bool }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_ITUNES_SYNC_EXPERIMENT"] != nil),
          arguments: ["deselected", "reselected"])
    func 실제_추가와_해제_사본을_모든_칸과_순서까지_재현한다(stage: String) throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_ITUNES_SYNC_EXPERIMENT"] else { return }
        let root = URL(filePath: path)
        let previous = stage == "deselected" ? "before" : "deselected"
        let before = try Data(contentsOf: root.appending(path: "\(previous)-playlists3.sync"))
        let after = try Data(contentsOf: root.appending(path: "\(stage)-playlists3.sync"))
        try reproduce(before: before, after: after, root: root)
    }

    func reproduce(before: Data, after: Data, root: URL) throws {
        let source = try JSONDecoder().decode([Source].self, from: Data(contentsOf: root.appending(path: "source-playlists.json")))
            .map { ITunesSyncSelection.Node(id: $0.id, parentID: $0.parentID, isFolder: $0.isFolder) }
        let selection = ITunesSyncSelection(selectedIDs: try RekordboxITunesSelection.parse(after).selectedIDs)
        let change = RekordboxITunesSyncChange(base: before, source: source, selection: selection)
        func nodes(_ data: Data) throws -> [[String: String]] {
            try XMLDocument(data: data).rootElement()!.elements(forName: "PLAYLISTS")[0].elements(forName: "NODE").map { node in
                Dictionary(uniqueKeysWithValues: (node.attributes ?? []).map { ($0.name!, $0.stringValue!) })
            }
        }
        let expected = try nodes(after)
        let timestamps = Dictionary(uniqueKeysWithValues: expected.filter { $0["Lib_Type"] == "1" }.map { ($0["Id"]!, Int64($0["Timestamp"]!)!) })
        let generated = try change.render(timestamp: { timestamps[$0] ?? -1 })
        let matches = try nodes(generated) == expected
        #expect(matches, "노드 순서와 모든 속성(실험 시각 포함)이 같음")

        let copy = root.appending(path: "repro-\(UUID())")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: copy) }
        let database = copy.appending(path: "master.db"), sync = copy.appending(path: "playlists3.sync")
        try FileManager.default.copyItem(at: root.appending(path: "before.db"), to: database)
        try before.write(to: sync)
        let databaseBefore = try Data(contentsOf: database)
        _ = try RekordboxWriter.write(drafts: [], iTunesSync: change, to: database, dryRun: false, backups: copy.appending(path: "backups"))
        let written = try Data(contentsOf: sync)
        let selectedMatches = try RekordboxITunesSyncChange.state(of: written) == RekordboxITunesSyncChange.state(of: after)
        #expect(selectedMatches, "실제 쓰기 경로의 결과도 실행 시각을 제외한 모든 칸과 순서가 같음")
        let unchanged = try Data(contentsOf: database) == databaseBefore
        #expect(unchanged, "실험용 DB 사본은 바이트까지 그대로")
    }
}
