@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestKit
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("코멘트 프리셋 화면 상태")
@MainActor
struct CommentPresetAppTests {
    private struct OtherRule: CommentRule {
        func evaluate(normalized text: String) -> CommentEvaluation {
            CommentEvaluation(classification: "custom", displayName: "별도 분류", tone: .info,
                              isMatch: text == "별도 규칙", isEmpty: text.isEmpty, summary: text)
        }
    }

    @Test func 다른_규칙도_같은_행과_집계를_쓴다() throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        try fixture.execute("UPDATE djmdContent SET Commnt = '  별도  규칙  ' WHERE ID = '1'")
        let library = try RekordboxLibrary.load(snapshot: fixture.database)
        let row = TrackRow(track: try #require(library.tracks.first), cues: [], playCount: 0, commentRule: OtherRule())
        #expect(row.commentClassName == "별도 분류")
        #expect(!LibraryFilter.offConvention.includes(row))
        let report = LibraryReport(library: library, commentRule: OtherRule())
        #expect(report.commentClasses == ["custom": 1])
        #expect(report.matchingComments == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_COMMENT_FIXTURE"] != nil))
    func 화면_확인용_합성_사본() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_COMMENT_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        let audio = try AudioFixture.wav(seconds: 10, in: fixture.audio)
        for (index, comment) in ["TVA 시험 작품(시험) 2기 OP 1 TVSIZE", "자유 코멘트", ""].enumerated() {
            var track = TrackSpec(id: String(index + 1))
            track.title = "프리셋 시험 \(index + 1)"
            track.folderPath = root.appending(path: "audio/\(audio.lastPathComponent)").path
            track.fileType = 11
            try fixture.add(track)
            try fixture.execute("UPDATE djmdContent SET Commnt = '\(comment)' WHERE ID = '\(track.id)'")
        }
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }

    @Test func 저장한_프리셋을_다시_읽고_자가테스트는_무시한다() {
        let defaults = SettingsStoreTests.freshDefaults()
        let settings = SettingsStore(defaults: defaults, persist: true)
        #expect(settings.commentPreset == .none)
        settings.commentPreset = .anisong
        #expect(SettingsStore(defaults: defaults, persist: true).commentPreset == .anisong)
        #expect(SettingsStore(defaults: defaults, persist: false).commentPreset == .none)
        settings.commentPreset = .none
        #expect(SettingsStore(defaults: defaults, persist: true).commentPreset == .none)
    }

    @Test func 프리셋_전환은_메모리에서_다시_분류하고_필터와_정렬을_해제한다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        try fixture.add(TrackSpec(id: "2"))
        try fixture.execute("UPDATE djmdContent SET Commnt = 'TVA 시험 OP 1' WHERE ID = '1'")
        let settings = SettingsStore(defaults: SettingsStoreTests.freshDefaults(), persist: true)
        let store = LibraryStore.test(settings: settings, saveTagDrafts: { _ in })
        await store.load(snapshot: fixture.database)
        #expect(store.rows.allSatisfy { $0.commentEvaluation == nil })
        #expect(store.report?.hasCommentRule == false)
        #expect(!store.commentRuleEnabled)
        let snapshot = store.snapshotURL
        store.selection = ["1"]
        store.commentPreset = .anisong
        #expect(store.rowsByID["1"]?.commentEvaluation?.isMatch == true)
        #expect(store.report?.matchingComments == 1)
        #expect(store.count(.emptyComment) == 1)
        store.sidebar = .filter(.emptyComment)
        store.sortOrder = [KeyPathComparator(\TrackRow.commentClassName)]
        store.commentPreset = .none
        #expect(store.sidebar == .filter(.all))
        #expect(store.sortOrder.allSatisfy { $0.keyPath != \TrackRow.commentClassName })
        #expect(store.rows.allSatisfy { $0.commentEvaluation == nil })
        #expect(store.report?.commentClasses.isEmpty == true)
        #expect(store.displayRows.count == 2)
        #expect(store.selection == ["1"])
        #expect(store.snapshotURL == snapshot)
        #expect(settings.commentPreset == .none)
    }

    @Test func 꺼진_분류_열은_메뉴에도_없고_모두_보이기로_살아나지_않는다() {
        let store = LibraryStore.test(settings: SettingsStore(defaults: SettingsStoreTests.freshDefaults(), persist: false), saveTagDrafts: { _ in })
        let coordinator = TrackListCoordinator(store: store, actions: .live(store: store))
        let table = NSTableView()
        for id in ["title", "class", "comment"] { table.addTableColumn(NSTableColumn(identifier: .init(id))) }
        coordinator.table = table
        coordinator.updateCommentPreset(.none)
        #expect(table.tableColumns.first { $0.identifier.rawValue == "class" }?.isHidden == true)
        let menu = coordinator.makeColumnMenu(table)
        coordinator.menuNeedsUpdate(menu)
        #expect(!menu.items.contains { $0.representedObject as? String == "class" })
        coordinator.showAllColumns()
        #expect(table.tableColumns.first { $0.identifier.rawValue == "class" }?.isHidden == true)
        coordinator.updateCommentPreset(.anisong)
        #expect(table.tableColumns.first { $0.identifier.rawValue == "class" }?.isHidden == false)
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.contains { $0.representedObject as? String == "class" })
        table.tableColumns.first { $0.identifier.rawValue == "class" }?.isHidden = true
        coordinator.updateCommentPreset(.none)
        coordinator.updateCommentPreset(.anisong)
        #expect(table.tableColumns.first { $0.identifier.rawValue == "class" }?.isHidden == true)
    }

    @Test func 프리셋을_바꿔도_재생_기록의_반복행과_선택을_보존한다() async throws {
        let fixture = try historyFixture()
        try fixture.execute("UPDATE djmdContent SET Commnt = 'TVA 시험 OP' WHERE ID = '101'")
        let settings = SettingsStore(defaults: SettingsStoreTests.freshDefaults(), persist: true)
        let store = LibraryStore.test(settings: settings, saveTagDrafts: { _ in })
        await store.load(snapshot: fixture.database)
        store.sidebar = .history("new-a")
        store.selection = ["history:entry-3"]
        for preset in [CommentPreset.anisong, .none, .anisong] {
            store.commentPreset = preset
            #expect(store.sidebar == .history("new-a"))
            #expect(store.displayRows.map(\.id) == ["history:entry-1", "history:entry-2", "history:entry-3"])
            #expect(store.selection == ["history:entry-3"])
            #expect(store.primaryRow?.track.id == "101")
            #expect(store.displayRows.last?.commentEvaluation?.isMatch == (preset == .none ? nil : true))
        }
    }
}
