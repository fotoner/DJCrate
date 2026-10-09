@testable import DJCrate
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import Testing

/// 사이드바 대상(전체·재생 기록·중복 후보)을 고를 때의 곡 목록. 읽기 규칙·JSON은 DJCStorageTests `LibraryReadTests`·`HistoryReadTests`·`DuplicateReadTests`.
@MainActor
@Suite("사이드바 대상별 곡 목록")
struct SidebarReadTests {
    private func fixture() throws -> RekordboxFixture { try duplicateLibraryFixture() }

    @Test func 사이드바_기본_선택은_전체다() {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        #expect(store.sidebar == .filter(.all))
        #expect(store.sidebarTitle == "전체")
    }

    @Test func 기록선택은_순번과_반복행을_보존하고_선택한곡은_한번만_편집한다() async throws {
        let fixture = try historyFixture()
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: fixture.root.appending(path: "result.json")), saveTagDrafts: { _ in })
        await store.load(snapshot: fixture.database)
        #expect(store.histories.map(\.id) == ["new-a", "new-b", "old", "undated"])
        store.sidebar = .history("new-a")
        #expect(store.sortOrder.isEmpty)
        #expect(store.sidebarTitle.contains("2025-02-03"))
        #expect(store.displayRows.map(\.track.id) == ["102", "101", "101"])
        #expect(store.displayRows.map(\.historyTrackNumber) == [1, 2, 3])
        #expect(Set(store.displayRows.map(\.id)).count == 3)
        store.selection = [store.displayRows[2].id]
        #expect(store.primaryRow?.id == "101")
        store.selection = Set(store.displayRows.map(\.id))
        #expect(store.selectedRows.map(\.id) == ["102", "101"])
        store.search = "Alpha"
        #expect(store.displayRows.map(\.historyTrackNumber) == [2, 3])
        store.search = ""
        store.sortOrder = [KeyPathComparator(\TrackRow.title)]
        #expect(store.displayRows.map(\.track.id) == ["101", "101", "102"])
        store.sortOrder = []
        #expect(store.displayRows.map(\.track.id) == ["102", "101", "101"])
        store.selection = [store.displayRows[2].id]
        await store.load(snapshot: fixture.database, quiet: true)
        #expect(store.selection == ["history:entry-3"])
        #expect(store.primaryRow?.id == "101")
        store.sidebar = .history("old")
        #expect(store.displayRows.isEmpty)
        store.sidebar = .filter(.all)
        #expect(!store.sortOrder.isEmpty)
        #expect(store.displayRows.allSatisfy { $0.historyTrackNumber == nil })
    }

    @Test func 후보_사이드바는_검색해도_비교곡을_함께_보이고_스냅샷_갱신을_따른다() async throws {
        let fixture = try fixture()
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: fixture.root.appending(path: "result.json")), saveTagDrafts: { _ in })
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
}
