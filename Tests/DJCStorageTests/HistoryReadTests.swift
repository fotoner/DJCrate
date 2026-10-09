import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import Testing

@Suite("재생 기록 JSON")
struct HistoryReadTests {
    @Test func JSON은_날짜와_재생순번을_보존하고_없는곡은_뺀다() throws {
        let fixture = try historyFixture()
        let read = try LibraryRead(snapshot: fixture.database, home: fixture.root.appending(path: "home"))
        #expect(read.histories().histories.map(\.id) == ["new-a", "new-b", "old", "undated"])
        #expect(read.histories().histories.first?.trackCount == 3)
        let result = try read.history(id: "new-a")
        #expect(result.entries.map(\.track.id) == ["102", "101", "101"])
        #expect(result.entries.map(\.trackNumber) == [1, 2, 3])
        let data = try LibraryReadTests().json("history", result)
        #expect(Set(data.keys) == ["history", "entries"])
        let history = try #require(data["history"] as? [String: Any])
        #expect(Set(history.keys) == ["id", "name", "dateCreated", "trackCount"])
        let entry = try #require((data["entries"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["id", "trackNumber", "track"])
        #expect(try read.history(id: "old").entries.isEmpty)
        #expect(throws: ReadFailure.self) { try read.history(id: "deleted") }
        #expect(throws: ReadFailure.self) { try read.history(id: "unknown") }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_HISTORY_FIXTURE"] != nil))
    func 화면확인용_합성_사본() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_HISTORY_FIXTURE"] else { return }
        let fixture = try historyFixture()
        try FileManager.default.copyItem(at: fixture.root, to: URL(filePath: path))
    }
}
