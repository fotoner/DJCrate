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

    // 폴더 모양은 실제 rekordbox 7 라이브러리에서 읽기만 해 확인했다(연 폴더 "2026" › 월 폴더 "202608"(이름 "8") › 기록).
    @Test func 연_월_폴더_아래_기록은_폴더이름과_같은폴더_순서를_준다() throws {
        let fixture = try historyFolderFixture()
        let before = try Data(contentsOf: fixture.database)
        let histories = try RekordboxLibrary.load(snapshot: fixture.database).histories
        // 폴더 행은 기록 목록에 없고, 순서는 지금처럼 만든 시각 내림차순이다
        #expect(histories.map(\.id) == ["1002", "1001", "1004", "1003", "1005", "1006", "1007"])
        let month = histories.filter { $0.folderNames == ["2026", "8"] }
        #expect(month.map(\.id) == ["1002", "1001"])
        #expect(month.sorted { $0.seq < $1.seq }.map(\.name) == ["HISTORY 2026-08-01", "HISTORY 2026-08-01 (1)"])
        #expect(month.map(\.seq) == [2, 1])
        let root = try #require(histories.first { $0.id == "1003" })
        #expect(root.folderNames.isEmpty)
        #expect(root.seq == 3)
        #expect(try Data(contentsOf: fixture.database) == before)
    }

    @Test func 폴더_사슬은_삭제된_폴더_빈_부모_순환_지나친_깊이에서_멈춘다() throws {
        let fixture = try historyFolderFixture()
        let histories = try RekordboxLibrary.load(snapshot: fixture.database).histories
        let byID = Dictionary(uniqueKeysWithValues: histories.map { ($0.id, $0) })
        // 삭제된 월 폴더 아래: 바로 위 폴더가 없으니 연 폴더까지 가지 않는다
        let underDeleted = try #require(byID["1004"])
        #expect(underDeleted.folderNames.isEmpty)
        // 부모가 빈 값이고 Seq가 NULL
        let orphan = try #require(byID["1006"])
        #expect(orphan.folderNames.isEmpty)
        #expect(orphan.seq == 0)
        // A의 부모 B, B의 부모 A: 다시 만난 A에서 멈추고 그때까지 모은 것만
        let looped = try #require(byID["1005"])
        #expect(looped.folderNames == ["순환 B", "순환 A"])
        // 40단계 사슬은 바로 위부터 32단계까지만
        let deep: [String] = (1...32).reversed().map { "깊이 \($0)" }
        let tooDeep = try #require(byID["1007"])
        #expect(tooDeep.folderNames == deep)
    }

    @Test func 폴더와_순서를_주지_않으면_빈_폴더와_순서0이다() {
        let history = RekordboxHistory(id: "h", name: "기록", dateCreated: nil,
                                       entries: [.init(id: "e", contentID: "1", trackNumber: 1)])
        #expect(history.folderNames.isEmpty)
        #expect(history.seq == 0)
        #expect(history.entries.map(\.contentID) == ["1"])
    }
}
