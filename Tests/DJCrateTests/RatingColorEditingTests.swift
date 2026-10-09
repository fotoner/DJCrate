@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 평점·곡 색 편집(#65): 곡 목록 칸(초안 표시·메뉴로 고르기), 태그 시트, 쓰기를 확인한 곡에만 초안 만들기, 목록 거르기.
/// 쓰기 규칙은 rekordbox 7.2.18 실험(2026-10-04 묶음 2·#173 S1 T11·T12)에서 상태 0·256·257 곡을, R65(2026-10-09)에서 재생 목록에 든 곡을
/// 확인했다(`TagWriteScope`). 그 밖의 상태(258 등)는 막는다.
@Suite("평점·곡 색 편집")
@MainActor
struct RatingColorEditingTests {
    static func row(_ id: String, rating: Int = 0, color: String? = nil, state: Int? = 0, inPlaylist: Bool = false,
                    staged: Bool = false, streaming: Bool = false) -> TrackRow {
        var row = TrackRow(track: Track(id: staged ? "djc-\(id)" : id, uuid: "uuid-\(id)", title: "곡 \(id)", artist: "가수", album: nil,
                                        albumArtist: nil, genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120,
                                        lengthSeconds: 30, folderPath: streaming ? "spotify:track:\(id)" : "/x/\(id).mp3", comment: "",
                                        importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false,
                                        rating: rating, colorID: color, dataStatus: staged ? nil : state),
                           cues: [], playCount: 0)
        row.inPlaylist = inPlaylist
        return row
    }

    func store() -> LibraryStore { LibraryStore.test(saveTagDrafts: { _ in }) }

    // MARK: 고칠 수 있는 곡

    @Test func 고칠_수_없는_곡이나_고를_수_없는_값은_초안을_만들지_않는다() {
        // 곡 상태·재생 목록별 범위(`TagWriteScope`)와 값 다듬기·거절은 Domain `RatingColorTagTests`. 여기서는 저장소가 그 규칙을 거치는지만 본다.
        let store = store()
        let ok = Self.row("1"), staged = Self.row("4", staged: true), unverified = Self.row("5", state: 258)
        store.setTag(.rating, "4", rows: [ok, staged, unverified])
        #expect(store.tagDrafts.keys.sorted() == [ok.track.uuid])
        #expect(store.tagCell(ok, .rating) == "4" && store.tagCell(unverified, .rating) == "")
        // 시트 붙여넣기의 별·색 이름도 다듬어 받는다. 고를 수 없는 값은 건너뛴다.
        store.applyTagEdits([(row: ok, key: .rating, value: "★★"), (row: ok, key: .color, value: "blue")])
        #expect(store.tagCell(ok, .rating) == "2" && store.tagCell(ok, .color) == "7")
        store.applyTagEdits([(row: ok, key: .color, value: "빨강")])
        #expect(store.tagCell(ok, .color) == "7")
        // 되돌리기(기준 값)는 받는다
        store.revertTags(rows: [ok])
        #expect(store.tagDrafts.isEmpty)
    }

    @Test func 칸이_없던_옛_초안은_지금_평점과_색을_보이고_초안으로_세지_않는다() throws {
        let store = store()
        let row = Self.row("1", rating: 3, color: "2")
        let json = #"{"trackUUID":"uuid-1","base":{"title":"곡 1","artist":"가수","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":"","musicalKey":""},"fields":{"title":"새 제목","artist":"가수","album":"","albumArtist":"","genre":"","composer":"","year":"","trackNumber":"","comment":"","musicalKey":""}}"#
        store.tagDrafts[row.track.uuid] = try JSONDecoder().decode(TagDraft.self, from: Data(json.utf8))
        #expect(store.tagCell(row, .rating) == "3" && store.tagCell(row, .color) == "2")
        #expect(!store.isTagEdited(row, .rating) && !store.isTagEdited(row, .color))
        #expect(TrackListTagEditing.text(row, .rating, draft: store.tagDrafts[row.track.uuid]) == ("3", false))
        store.setTag(.rating, "5", rows: [row])
        let draft = try #require(store.tagDrafts[row.track.uuid])
        #expect(draft.base.rating == "3" && draft.fields.rating == "5" && draft.fields.title == "새 제목" && draft.base.color == "2")
    }

    // MARK: 곡 목록

    @Test func 목록의_평점과_곡_색_칸은_초안을_값과_표식으로_보인다() throws {
        let row = Self.row("1", rating: 2, color: "2")
        let h = ListHarness(rows: [row], selection: [row.id], extra: ["rating", "color"])
        defer { h.close() }
        let rating = try #require(h.cell(row: 0, column: "rating")), color = try #require(h.cell(row: 0, column: "color"))
        #expect(rating.text == "★★☆☆☆" && !rating.showsDraftMark && rating.label.accessibilityValue() == "별 2개")
        #expect(color.text == "Red" && color.swatchShown && !color.showsDraftMark)
        h.store.setTag(.rating, "5", rows: [row])
        h.store.setTag(.color, "7", rows: [row])
        h.coordinator.updateTagRevision(h.store.tagRevision)
        #expect(rating.text == "★★★★★" && rating.showsDraftMark && rating.label.accessibilityValue() == "별 5개, 초안")
        #expect(color.text == "Blue" && color.showsDraftMark)
        h.store.setTag(.color, "", rows: [row])
        h.coordinator.updateTagRevision(h.store.tagRevision)
        #expect(color.text.isEmpty && !color.swatchShown && color.showsDraftMark)
    }

    @Test func 평점과_곡_색_칸은_메뉴로_고르고_고른_곡_모두에_넣는다() throws {
        let rows = [Self.row("1", rating: 3), Self.row("2", rating: 1, state: 257), Self.row("3", state: 258)]
        let h = ListHarness(rows: rows, selection: Set(rows.map(\.id)), extra: ["rating", "color"])
        defer { h.close() }
        let menu = try #require(h.coordinator.choiceMenu(.rating, row: 0))
        #expect(menu.items.map(\.title) == ["없음", "★☆☆☆☆", "★★☆☆☆", "★★★☆☆", "★★★★☆", "★★★★★"])
        #expect(menu.items.allSatisfy { $0.state == .off }, "값이 서로 다르면 체크하지 않는다")
        try choose("★★★★☆", menu: menu)
        #expect(h.store.tagCell(rows[0], .rating) == "4" && h.store.tagCell(rows[1], .rating) == "4")
        #expect(h.store.tagDrafts[rows[2].track.uuid] == nil, "쓰기를 확인하지 않은 상태(258)의 곡은 빼고 쓴다")
        let colors = try #require(h.coordinator.choiceMenu(.color, row: 1))
        #expect(colors.items.map(\.title) == ["없음"] + TrackColor.rekordboxDefaults.map(\.name))
        #expect(colors.items.dropFirst().allSatisfy { $0.image != nil })
        try choose("Aqua", menu: colors)
        #expect(h.store.tagCell(rows[0], .color) == "6" && h.store.tagCell(rows[1], .color) == "6")
        // 고칠 수 없는 곡에서는 메뉴를 열지 않는다
        #expect(h.coordinator.choiceMenu(.rating, row: 2) == nil)
    }

    @Test func 평점_칸을_누른_뒤_Return은_평점_메뉴를_연다() throws {
        let row = Self.row("1", rating: 2)
        let h = ListHarness(rows: [row], selection: [row.id], extra: ["rating", "color"])
        defer { h.close() }
        var opened: NSMenu?
        h.coordinator.presentKeyMenu = { menu, _, _ in opened = menu }
        h.click(row: 0, column: "rating")
        h.pressReturn()
        let menu = try #require(opened)
        #expect(menu.items.first { $0.state == .on }?.title == "★★☆☆☆" && h.store.tagDrafts.isEmpty)
        opened = nil
        h.click(row: 0, column: "color")
        h.pressReturn()
        #expect(opened?.items.first { $0.state == .on }?.title == "없음")
    }

    @Test func 고칠_수_없는_곡의_평점_칸_더블클릭은_덱에_올린다() {
        let row = Self.row("1", state: 258)
        let h = ListHarness(rows: [row], selection: [row.id], extra: ["rating"])
        defer { h.close() }
        var loaded: [String?] = []
        h.store.onLoadToDeck = { loaded.append($0?.track.id) }
        var opened = 0
        h.coordinator.presentKeyMenu = { _, _, _ in opened += 1 }
        h.coordinator.doubleClicked(row: 0, column: "rating")
        #expect(opened == 0 && loaded == ["1"])
    }

    @Test func 목록_칸_정의와_정렬() {
        let ids = TrackColumn.all.map(\.id)
        let key = ids.firstIndex(of: "key")!
        #expect(Array(ids[key...key + 2]) == ["key", "rating", "color"])
        let rows = [Self.row("1", rating: 2, color: "7"), Self.row("2", rating: 5, color: "1"), Self.row("3")]
        let byRating = rows.sorted(using: TrackColumn.comparator(key: "rating", ascending: false)!)
        #expect(byRating.map(\.track.id) == ["2", "1", "3"])
        let byColor = rows.sorted(using: TrackColumn.comparator(key: "color", ascending: true)!)
        #expect(byColor.map(\.track.id) == ["3", "2", "1"], "rekordbox 색 순서(없음 먼저)")
        #expect(TrackColumn.sortKey(of: \TrackRow.ratingValue) == "rating" && TrackColumn.sortKey(of: \TrackRow.colorSortKey) == "color")
    }

    // MARK: 태그 시트

    @Test func 시트는_평점을_별로_곡_색을_이름으로_보이고_붙여넣기는_다듬어_받는다() throws {
        let rows = [Self.row("1", rating: 3, color: "2"), Self.row("2", state: 256, inPlaylist: true), Self.row("3", state: 258)]
        let h = SheetColumnLookupTests.Harness(rows: rows, moved: false)
        defer { h.window.close() }
        let rating = h.column("rating"), color = h.column("color")
        #expect(h.coordinator.text(row: 0, column: rating) == "★★★☆☆" && h.coordinator.text(row: 0, column: color) == "Red")
        #expect(h.coordinator.editableKey(row: 0, column: rating) == .rating && h.coordinator.editableKey(row: 2, column: rating) == nil)
        var messages: [String] = []
        h.coordinator.announce = { messages.append($0) }
        // 한 값을 고른 칸 전체에: 재생 목록에 든 곡(줄 2)은 넣고, 쓰기를 확인하지 않은 상태의 곡(줄 3)은 건너뛴다
        h.coordinator.select(CellPosition(row: 0, column: rating), extend: false)
        h.coordinator.select(CellPosition(row: 2, column: color), extend: true)
        h.coordinator.paste(string: "★★★★★")
        #expect(h.store.tagCell(rows[0], .rating) == "5" && h.store.tagCell(rows[1], .rating) == "5")
        #expect(h.store.tagCell(rows[0], .color) == "2", "★는 색이 아니라 건너뛴다")
        #expect(h.store.tagDrafts[rows[2].track.uuid] == nil)
        #expect(messages.last?.contains("곡 색 칸 2칸은 rekordbox 색이 아니어서 건너뜀") == true)
        // 두 칸 블록 붙여넣기
        h.coordinator.select(CellPosition(row: 1, column: rating), extend: false)
        h.coordinator.paste(string: "2\tPurple")
        #expect(h.store.tagCell(rows[1], .rating) == "2" && h.store.tagCell(rows[1], .color) == "8")
        // 메뉴로 고르기
        let menu = try #require(h.coordinator.choiceMenu(.color, row: 0))
        #expect(menu.items.first { $0.state == .on }?.title == "Red")
        let blue = try #require(menu.items.first { $0.title == "Blue" })
        h.coordinator.pickKey(blue)
        #expect(h.store.tagCell(rows[0], .color) == "7")
        #expect(h.coordinator.choiceMenu(.rating, row: 2) == nil)
    }

    // MARK: 거르기

    @Test func 읽은_라이브러리의_평점과_곡_색으로_목록을_거른다() async throws {
        // 101 평점 2·Red, 102 평점 4·Blue(재생 목록에 듦), 103 평점 5, 104 없음. 색 목록은 이름을 바꾼 rekordbox 여덟 색.
        let fixture = try RekordboxFixture()
        for id in ["101", "102", "103", "104"] { try fixture.add(TrackSpec(id: id)) }
        for color in TrackColor.rekordboxDefaults {
            try fixture.insert("djmdColor", ["ID": .text(color.id), "SortKey": .int(Int(color.id) ?? 0),
                                             "Commnt": .text(color.id == "2" ? "Opener" : color.name), "rb_local_deleted": .int(0)])
        }
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0, Rating = 0, ColorID = '0'")
        try fixture.execute("UPDATE djmdContent SET Rating = 2, ColorID = '2' WHERE ID = '101'")
        try fixture.execute("UPDATE djmdContent SET Rating = 4, ColorID = '7' WHERE ID = '102'")
        try fixture.execute("UPDATE djmdContent SET Rating = 5 WHERE ID = '103'")
        try fixture.add(PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["102"]))
        // 초안은 이 시험의 폴더에서만 읽는다(함께 도는 시험의 초안이 섞이지 않게, `LibraryDraftFolderTests`)
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: fixture.root.appending(path: "result.json")), saveTagDrafts: { _ in },
                                 draftHome: fixture.root.appending(path: "drafts"))
        await store.load(snapshot: fixture.database)
        #expect(store.trackColors.first { $0.id == "2" }?.name == "Opener")
        #expect(store.rowsByID["102"]?.inPlaylist == true && store.rowsByID["101"]?.inPlaylist == false)
        #expect(store.rowsByID["101"]?.track.dataStatus == 0)
        store.sidebar = .filter(.all)
        #expect(Set(store.displayRows.map(\.track.id)) == ["101", "102", "103", "104"] && !store.isAttributeFiltered)
        store.minimumRating = 4
        #expect(Set(store.displayRows.map(\.track.id)) == ["102", "103"] && store.isAttributeFiltered)
        store.colorFilter = "7"
        #expect(store.displayRows.map(\.track.id) == ["102"])
        store.minimumRating = 0
        store.colorFilter = "2"
        #expect(store.displayRows.map(\.track.id) == ["101"])
        // 초안 값이 아니라 rekordbox 값으로 거른다(정렬과 같다)
        store.colorFilter = nil
        store.minimumRating = 2
        let first = try #require(store.rowsByID["101"])
        store.setTag(.rating, "1", rows: [first])
        #expect(store.tagCell(first, .rating) == "1")
        #expect(Set(store.displayRows.map(\.track.id)) == ["101", "102", "103"])
        // 재생 목록에 든 곡도 평점·곡 색 초안을 만든다(R65, 2026-10-09)
        let listed = try #require(store.rowsByID["102"])
        store.setTag(.rating, "1", rows: [listed])
        store.setTag(.color, "", rows: [listed])
        #expect(store.tagDrafts[listed.track.uuid]?.changedKeys == [.rating, .color] && store.tagDrafts.count == 2)
    }

    @Test func 인스펙터는_재생_목록에_든_곡의_평점과_곡_색을_막지_않는다() {
        // 인스펙터 고르기(`TagChoiceField`)와 키 고르기가 쓰는 판단: 재생 목록에 든 곡도 고를 수 있고 이유를 보이지 않는다(R65)
        let listed = Self.row("1", inPlaylist: true), synced = Self.row("2", state: 257, inPlaylist: true), unverified = Self.row("3", state: 258)
        for key in [TagFields.Key.rating, .color] {
            #expect(TagChoice.targets(key, [listed, synced, unverified]).map(\.track.id) == ["1", "2"], "\(key)")
            #expect([listed, synced].compactMap { TrackListTagEditing.unavailableReason($0, key: key) }.isEmpty)
        }
        let store = store()
        store.setTag(.rating, "5", rows: TagChoice.targets(.rating, [listed]))
        #expect(store.tagCell(listed, .rating) == "5" && store.isTagEdited(listed, .rating))
    }

    private func choose(_ title: String, menu: NSMenu) throws {
        let item = try #require(menu.items.first { $0.title == title && $0.isEnabled })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }
}
