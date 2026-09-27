@testable import DJCrate
import DJCStorage
import DJCTestSupport
import Foundation
import Testing

@Suite("중복 후보 읽기와 JSON")
struct DuplicateReadTests {
    private func fixture() throws -> RekordboxFixture {
        let fixture = try LibraryReadTests().fixture()
        return try fixture.withConnection {
            try fixture.execute("UPDATE djmdContent SET Title = '시험 alpha', ArtistID = 'a1', Length = 202, BitRate = 0, FolderPath = '/synthetic/copy.flac' WHERE ID = '102'")
            try fixture.execute("UPDATE djmdCue SET Comment = 'CUE(Auto)' WHERE ID = 'memory'")
            try fixture.insert("djmdSongPlaylist", ["ID": .text("second-list"), "PlaylistID": .text("p2"), "ContentID": .text("101"), "TrackNo": .int(1)])
            try fixture.insert("djmdSongPlaylist", ["ID": .text("deleted-entry"), "PlaylistID": .text("p2"), "ContentID": .text("102"), "TrackNo": .int(2), "rb_local_deleted": .int(1)])
            for index in 0..<3 {
                try fixture.insert("djmdSongHistory", ["ID": .text("play-\(index)"), "ContentID": .text("101"), "rb_local_deleted": .int(index == 2 ? 1 : 0)])
            }
            return fixture
        }
    }

    @Test func 후보_JSON은_원본_큐와_직접_소속과_재생수와_음질을_비교한다() throws {
        let fixture = try fixture()
        let before = try Data(contentsOf: fixture.database)
        let read = try LibraryReadTests().reader(fixture)
        let result = read.duplicates()
        #expect(result.lengthToleranceSeconds == 2)
        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1)
        #expect(group.tracks.map(\.id) == ["101", "102"])
        #expect(group.tracks.map(\.cueCount) == [2, 0])
        #expect(group.tracks.map(\.manualCueCount) == [1, 0])
        #expect(group.tracks.map(\.playlistCount) == [2, 1])
        #expect(group.tracks.map(\.playCount) == [2, 0])
        #expect(group.tracks.map(\.format) == ["MP3", "FLAC"])
        #expect(group.tracks.map(\.bitrateKbps) == [320, nil])
        let data = try LibraryReadTests().json("duplicates", result)
        #expect(Set(data.keys) == ["lengthToleranceSeconds", "groups"])
        let groups = try #require(data["groups"] as? [[String: Any]])
        let members = try #require(groups.first?["tracks"] as? [[String: Any]])
        #expect(Set(try #require(members.first).keys) == ["track", "cueCount", "manualCueCount", "playlistCount", "playCount", "format", "bitrateKbps"])
        #expect(members.last?["bitrateKbps"] == nil)
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "home").path))
    }

    @Test func CLI는_후보와_빈목록과_잘못된_인자를_JSON으로_출력한다() throws {
        let fixture = try fixture()
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        for invalid in [false, true] {
            let process = Process(), out = Pipe(), err = Pipe()
            process.executableURL = executable
            process.arguments = ["duplicates", "--db", fixture.database.path, "--json"] + (invalid ? ["--merge"] : [])
            process.environment = ProcessInfo.processInfo.environment.merging([
                "DJC_HOME": fixture.root.appending(path: "home").path,
                "DJC_REKORDBOX_DIR": fixture.root.path,
            ]) { _, new in new }
            process.standardOutput = out; process.standardError = err
            try process.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == (invalid ? 1 : 0))
            #expect(invalid ? stdout.isEmpty : stderr.isEmpty)
            let envelope = try #require(JSONSerialization.jsonObject(with: invalid ? stderr : stdout) as? [String: Any])
            #expect(envelope["schemaVersion"] as? Int == 1)
            #expect(envelope["command"] as? String == "duplicates")
            if invalid {
                #expect((envelope["error"] as? [String: String])?["code"] == "invalid_arguments")
            } else {
                let data = try #require(envelope["data"] as? [String: Any])
                #expect((data["groups"] as? [Any])?.count == 1)
            }
        }
        let empty = try RekordboxFixture()
        #expect(try LibraryReadTests().reader(empty).duplicates().groups.isEmpty)
    }

    @Test @MainActor func 후보_사이드바는_검색해도_비교곡을_함께_보이고_스냅샷_갱신을_따른다() async throws {
        let fixture = try fixture()
        let store = LibraryStore(resultHistory: WriteResultHistory(url: fixture.root.appending(path: "result.json")), saveTagDrafts: { _ in })
        await store.load(snapshot: fixture.database)
        store.sidebar = .duplicates
        #expect(store.sidebarTitle == "중복 후보")
        #expect(store.sortOrder.isEmpty)
        #expect(store.duplicateGroups.count == 1)
        #expect(store.displayRows.map(\.id) == ["101", "102"])
        // 한 곡에만 있는 코멘트로 검색해도 비교할 상대를 남긴다.
        store.search = "TVA"
        #expect(store.displayRows.map(\.id) == ["101", "102"])
        #expect(store.displayDuplicateGroups.count == 1)
        store.selection = ["102"]
        #expect(store.primaryRow?.id == "102")
        #expect(store.selectedRows.map(\.id) == ["102"])
        store.search = "없는 검색어"
        #expect(store.displayRows.isEmpty && store.displayDuplicateGroups.isEmpty)
        store.search = ""
        try fixture.execute("UPDATE djmdContent SET Title = '다른 곡' WHERE ID = '102'")
        await store.load(snapshot: fixture.database, quiet: true)
        #expect(store.duplicateGroups.isEmpty && store.displayRows.isEmpty)
        store.sidebar = .filter(.all)
        #expect(!store.sortOrder.isEmpty && store.displayRows.count == 2)
    }

    @Test(arguments: ["0", "-1", "NULL"])
    func 비트레이트가_없거나_양수가_아니면_알수없음이다(value: String) throws {
        let fixture = try fixture()
        try fixture.execute("UPDATE djmdContent SET BitRate = \(value)")
        let members = try LibraryReadTests().reader(fixture).duplicates().groups.flatMap(\.tracks)
        #expect(members.count == 2 && members.allSatisfy { $0.bitrateKbps == nil })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_DUPLICATES_FIXTURE"] != nil))
    func 화면확인용_합성_사본() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_DUPLICATES_FIXTURE"] else { return }
        let fixture = try fixture()
        try FileManager.default.copyItem(at: fixture.root, to: URL(filePath: path))
    }
}
