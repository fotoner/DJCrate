import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
@testable import RekordboxKit
import Testing

/// 곡 목록·사이드바에서 재생 목록을 고치면 초안으로 쌓이고(#39·#40), 반영·되돌리기 뒤 초안이 정리된다.
@MainActor
@Suite("재생 목록 편집(앱)")
struct PlaylistEditingTests {
    typealias Item = PlaylistLayout.Item
    let store: LibraryStore
    let undo = UndoManager()
    let saved = SavedDrafts()

    final class SavedDrafts: @unchecked Sendable { var last: PlaylistDraft? }

    /// 추가한 곡(아직 rekordbox에 없음)은 ID가 djc-로 시작한다.
    static func row(_ id: String, staged: Bool = false) -> TrackRow {
        ReflectionPresenterTests.row(staged ? "djc-\(id)" : id)
    }

    static func item(_ id: String, _ name: String, parent: String = PlaylistLayout.root, folder: Bool = false, tracks: [String] = []) -> Item {
        Item(id: id, name: name, parentID: parent, isFolder: folder,
             entries: tracks.enumerated().map { PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element) })
    }

    /// 맨 위: 폴더 F(목록 A[1,2]) · 목록 B[3]
    static let rekordbox = PlaylistLayout([
        (item("F", "폴더", folder: true), 1), (item("A", "가", parent: "F", tracks: ["1", "2"]), 1), (item("B", "나", tracks: ["3"]), 2),
    ])

    init() {
        let saved = saved
        store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("playlists"), persist: false),
                             resultHistory: WriteResultHistory(), saveTagDrafts: { _ in }, playlistDraftSaver: { saved.last = $0 })
        store.undoManager = undo
        store.phase = .loaded
        for id in ["1", "2", "3", "4"] { store.rowsByID[id] = Self.row(id) }
        store.playlists.rekordboxPlaylists = Self.rekordbox
        store.playlists.refreshPlaylists()
    }

    @Test func 곡을_넣으면_초안이_되고_이미_든_곡과_추가한_곡은_알린다() throws {
        store.playlists.addTracks([Self.row("2"), Self.row("4"), Self.row("x", staged: true)], toPlaylist: "A")
        #expect(store.playlists.playlistDraft.edits == [.addTracks(playlist: .id("A"), contentIDs: ["4"])])
        #expect(saved.last == store.playlists.playlistDraft)
        #expect(store.playlists.playlistIndex["A"]?.trackIDs == ["1", "2", "4"] && store.playlists.playlistIndex["A"]?.isDraft == true)
        #expect(store.count(playlist: try #require(store.playlists.playlistIndex["A"])) == 3)
        #expect(store.playlists.playlistMessage?.kind == .warning)
        #expect(store.playlists.playlistMessage?.text == "‘가’에 1곡을 넣었습니다(쓰기 대기). 이미 들어 있는 1곡은 넣지 않았습니다. 추가한 곡 1곡은 rekordbox 컬렉션에 넣은 뒤 목록에 넣을 수 있습니다.")
        #expect(store.playlists.lastUsedPlaylist?.id == "A")
        // 목록을 보면 초안으로 넣은 곡에 초안 표식
        store.sidebar = .playlist("A")
        #expect(store.displayRows.map(\.track.id) == ["1", "2", "4"])
        #expect(store.listMarkedUUIDs == ["4"])
        // ⌘Z 한 번에 되돌린다
        #expect(undo.undoActionName == "재생 목록에 넣기")
        undo.undo()
        #expect(store.playlists.playlistDraft.isEmpty && store.displayRows.map(\.track.id) == ["1", "2"])
        undo.redo()
        #expect(store.playlists.playlistDraft.edits.count == 1)
    }

    @Test func 목록에서_빼고_끌어_순서를_바꾼다() {
        store.sidebar = .playlist("A")
        store.playlists.addTracks([Self.row("3"), Self.row("4")], toPlaylist: "A")
        store.selection = ["1"]
        store.playlists.removeSelectedFromPlaylist()
        #expect(store.displayRows.map(\.track.id) == ["2", "3", "4"])
        // 4를 2 앞으로
        #expect(store.playlists.canReorderDisplayedTracks)
        store.playlists.moveTracks(["4"], inPlaylist: "A", before: "2")
        #expect(store.displayRows.map(\.track.id) == ["4", "2", "3"])
        #expect(store.playlists.playlistDraft.edits.last == .moveTracks(playlist: .id("A"), entries: [.init(trackNo: 3, contentID: "4")], to: 1))
        // 제자리에 놓으면 편집이 없다
        let count = store.playlists.playlistDraft.edits.count
        store.playlists.moveTracks(["4"], inPlaylist: "A", before: "2")
        #expect(store.playlists.playlistDraft.edits.count == count)
        // 정렬하거나 검색하면 끌어 옮기지 않는다
        store.search = "곡"
        #expect(!store.playlists.canReorderDisplayedTracks)
    }

    @Test func 새_목록은_고른_폴더_맨_위에_생기고_이름을_고치게_한다() throws {
        // 이름 바꾸기는 사이드바 화면 모델이 든다(#251, 펼침과 함께 `PlaylistSidebarModelTests`)
        let sidebar = PlaylistSidebarModel(playlists: store.playlists)
        store.sidebar = .playlist("A")
        let id = try #require(store.playlists.createPlaylist(isFolder: false, tracks: [Self.row("3")]))
        #expect(store.playlists.playlistProjection.layout.childIDs(of: "F") == [id, "A"])
        #expect(store.sidebar == .playlist(id) && sidebar.renamingPlaylistID == id)
        sidebar.finishRenaming(id, to: "  세트  ")
        #expect(sidebar.renamingPlaylistID == nil && store.playlists.playlistItem(id)?.name == "세트")
        // 새 목록의 이름은 만들기에 합친다
        #expect(store.playlists.playlistDraft.edits.first == .create(key: String(id.dropFirst(4)), name: "세트", isFolder: false, parent: .id("F")))
        // 폴더를 고르고 만들면 그 안
        store.sidebar = .playlist("F")
        #expect(store.playlists.newPlaylistParent == "F")
        store.sidebar = .filter(.all)
        #expect(store.playlists.newPlaylistParent == PlaylistLayout.root)
    }

    @Test func 지우면_보던_목록에서_나오고_폴더는_안까지_지운다() throws {
        store.sidebar = .playlist("A")
        store.playlists.deletePlaylist("F")
        #expect(store.sidebar == .filter(.all) && store.playlists.playlistIndex["A"] == nil)
        #expect(store.playlists.playlistTree.map(\.id) == ["B"])
    }

    /// 재생 목록 지우기·초안 모두 버리기는 초안 편집이라 묻지 않고, ⌘Z로 되돌린다(#212). 쓸 때 한 번만 확인한다.
    @Test func 지우기와_초안_모두_버리기는_묻지_않고_실행_취소로_되돌린다() {
        // 메뉴 동작 하나가 실행 취소 하나가 되게 묶는다(시험에는 이벤트 루프가 없다)
        undo.groupsByEvent = false
        func step(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }
        step { PlaylistPanels.delete(store: store, id: "F") }
        #expect(store.playlists.playlistIndex["F"] == nil && store.playlists.playlistDraft.edits.count == 1)
        #expect(undo.undoMenuItemTitle.contains("재생 목록 지우기"))
        undo.undo()
        #expect(store.playlists.playlistIndex["F"] != nil && store.playlists.playlistDraft.edits.isEmpty)
        step { store.playlists.deletePlaylist("B") }
        step { PlaylistPanels.discardAll(store: store) }
        #expect(store.playlists.playlistDraft.edits.isEmpty && store.playlists.playlistIndex["B"] != nil)
        undo.undo()
        #expect(store.playlists.playlistIndex["B"] == nil && store.playlists.playlistDraft.edits.count == 1)
    }

    @Test func 옮기기와_순서_바꾸기() {
        store.playlists.movePlaylist("B", into: "F")
        #expect(store.playlists.playlistProjection.layout.childIDs(of: "F") == ["A", "B"])
        store.playlists.movePlaylist("B", into: "F", before: "A")
        #expect(store.playlists.playlistProjection.layout.childIDs(of: "F") == ["B", "A"])
        store.playlists.movePlaylist("A", into: PlaylistLayout.root, before: "F")
        #expect(store.playlists.playlistProjection.layout.childIDs(of: PlaylistLayout.root) == ["A", "F"])
        #expect(store.playlists.playlistDraft.edits == [
            .move(playlist: .id("B"), into: .id("F")), .reorder(playlist: .id("B"), index: 0),
            .move(playlist: .id("A"), into: .root), .reorder(playlist: .id("A"), index: 0),
        ])
        // 폴더를 제 안으로는 옮기지 않고 알린다
        store.playlists.movePlaylist("F", into: "F")
        #expect(store.playlists.playlistMessage?.text == "재생 목록을 고치지 않았습니다: 폴더를 제 안으로 옮길 수 없습니다")
    }

    @Test func 목록의_초안만_버린다() {
        store.playlists.addTracks([Self.row("4")], toPlaylist: "A")
        store.playlists.renamePlaylist("B", to: "새 이름")
        store.playlists.discardPlaylistDraft("A")
        #expect(store.playlists.playlistDraft.edits == [.rename(playlist: .id("B"), name: "새 이름")])
        store.playlists.discardPlaylistDraft()
        #expect(store.playlists.playlistDraft.isEmpty && saved.last?.isEmpty == true)
    }

    @Test func 반영하면_쓴_편집을_빼고_새_ID로_바꾼다() throws {
        let id = try #require(store.playlists.createPlaylist(isFolder: false, in: PlaylistLayout.root, tracks: [Self.row("1")]))
        store.playlists.renamePlaylist("B", to: "새 이름")
        let written = store.playlists.playlistDraft
        store.sidebar = .playlist(id)
        let outcomes = [
            PlaylistOutcome(edit: written.edits[0], playlistID: "777", name: "새 재생 목록", status: .written),
            PlaylistOutcome(edit: written.edits[1], playlistID: "777", name: "새 재생 목록", status: .written),
            PlaylistOutcome(edit: written.edits[2], playlistID: nil, name: "나", status: .blocked, reason: "바뀜"),
        ]
        store.finishPlaylistWrite(written, outcomes: outcomes)
        #expect(store.playlists.playlistDraft.edits == [.rename(playlist: .id("B"), name: "새 이름")])
        #expect(store.playlists.recentPlaylistIDs == ["777"] && store.sidebar == .playlist("777"))
        #expect(saved.last == store.playlists.playlistDraft)
    }

    @Test func 되돌리면_그때_쓴_편집을_다시_쌓고_그_뒤_초안을_잇는다() {
        store.playlists.renamePlaylist("B", to: "나중")
        let failed = store.playlists.restorePlaylistEdits([.addTracks(playlist: .id("A"), contentIDs: ["4"]), .delete(playlist: .id("없음"))])
        #expect(failed == 1)
        #expect(store.playlists.playlistDraft.edits == [.addTracks(playlist: .id("A"), contentIDs: ["4"]), .rename(playlist: .id("B"), name: "나중")])
    }

    @Test func 재생_기록으로_재생_목록을_만든다() throws {
        store.history.histories = [RekordboxHistory(id: "h", name: "", dateCreated: "2026-09-20 21:00:00",
                                            entries: [.init(id: "e2", contentID: "3", trackNumber: 2), .init(id: "e1", contentID: "1", trackNumber: 1),
                                                      .init(id: "e3", contentID: "1", trackNumber: 3), .init(id: "e4", contentID: "없는 곡", trackNumber: 4)])]
        store.playlists.createPlaylist(fromHistory: "h")
        let id = try #require(store.playlists.playlistTree.first?.id)
        #expect(store.playlists.playlistItem(id)?.name == "2026-09-20" && store.playlists.playlistItem(id)?.trackIDs == ["1", "3"])
        #expect(store.playlists.playlistProjection.layout.childIDs(of: PlaylistLayout.root).first == id)
    }

    @Test func 쓰는_동안에는_고치지_않는다() {
        store.isWritingRekordbox = true
        store.playlists.addTracks([Self.row("4")], toPlaylist: "A")
        #expect(store.playlists.playlistDraft.isEmpty)
    }

    @Test func 초안_파일은_비면_지운다() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-playlist-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("B"), name: "x"), rekordbox: Self.rekordbox)
        try PlaylistDraftStore.save(draft, url: url)
        #expect(PlaylistDraftStore.load(url: url) == draft)
        try PlaylistDraftStore.save(PlaylistDraft(), url: url)
        #expect(!FileManager.default.fileExists(atPath: url.path) && PlaylistDraftStore.load(url: url).isEmpty)
    }
}
