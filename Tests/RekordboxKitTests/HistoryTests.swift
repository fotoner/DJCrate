import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("재생 기록 읽기")
struct HistoryTests {
    @Test func 날짜_내림차순과_같은날_순서로_읽고_폴더와_삭제기록을_뺀다() throws {
        let fixture = try historyFixture()
        let before = try Data(contentsOf: fixture.database)
        let library = try RekordboxLibrary.load(snapshot: fixture.database)
        #expect(library.histories.map(\.id) == ["new-a", "new-b", "old", "undated"])
        #expect(library.histories.first?.dateCreated == "2025-02-03")
        #expect(library.histories.last?.dateCreated == nil)
        #expect(library.histories.last?.entries.isEmpty == true)
        #expect(try Data(contentsOf: fixture.database) == before)
    }

    @Test func 재생순번과_중복을_보존하고_삭제한_기록행을_뺀다() throws {
        let fixture = try historyFixture()
        let history = try #require(RekordboxLibrary.load(snapshot: fixture.database).histories.first)
        #expect(history.entries.map(\.id) == ["entry-1", "entry-2", "entry-3", "missing", "removed-track"])
        #expect(history.entries.map(\.contentID) == ["102", "101", "101", "missing", "103"])
        #expect(history.entries.map(\.trackNumber) == [1, 2, 3, 5, 6])
    }

    @Test func 빈_라이브러리는_빈_기록을_준다() throws {
        let fixture = try RekordboxFixture()
        #expect(try RekordboxLibrary.load(snapshot: fixture.database).histories.isEmpty)
    }
}
