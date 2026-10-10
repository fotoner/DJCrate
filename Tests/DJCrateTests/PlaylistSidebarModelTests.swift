import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 사이드바 재생 목록 칸의 화면 모델(#251): 폴더 펼침과 이름 바꾸기. 목록을 만들면(메뉴·곡 목록·사이드바 어디서든) 조상 폴더만 펼치고
/// 새 목록의 이름을 고치게 한다. 재생 목록 조각(`PlaylistEditStore`)은 시험 저장소의 것을 쓴다(초안 저장만 메모리로 받는다).
@MainActor
@Suite("사이드바 재생 목록 칸 화면 모델")
struct PlaylistSidebarModelTests {
    typealias Item = PlaylistLayout.Item
    let store: LibraryStore
    let model: PlaylistSidebarModel

    static func item(_ id: String, _ name: String, parent: String = PlaylistLayout.root, folder: Bool = false, tracks: [String] = []) -> Item {
        Item(id: id, name: name, parentID: parent, isFolder: folder,
             entries: tracks.enumerated().map { PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element) })
    }

    init() {
        store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("playlist-sidebar"), persist: false),
                                  resultHistory: WriteResultHistory(), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in })
        store.phase = .loaded
        for id in ["1", "2", "3"] { store.rowsByID[id] = PlaylistEditingTests.row(id) }
        // 맨 위: 폴더 F(접힌 자식 폴더 N · 목록 A[1,2]) · 펼친 다른 폴더 O · 접힌 다른 폴더 C
        store.playlists.rekordboxPlaylists = PlaylistLayout([
            (Self.item("F", "부모", folder: true), 1),
            (Self.item("N", "접힌 자식", parent: "F", folder: true), 1),
            (Self.item("A", "가", parent: "F", tracks: ["1", "2"]), 2),
            (Self.item("O", "펼친 다른 폴더", folder: true), 2),
            (Self.item("C", "접힌 다른 폴더", folder: true), 3),
        ])
        store.playlists.refreshPlaylists()
        model = PlaylistSidebarModel(playlists: store.playlists)
    }

    @Test func 접힌_폴더에_만들면_조상만_펼치고_다른_펼침과_선택은_유지한다() throws {
        model.expandedPlaylistIDs = ["O"]
        store.sidebar = .playlist("N")

        let id = try #require(store.playlists.createPlaylist(isFolder: false))

        #expect(model.expandedPlaylistIDs == ["O", "F", "N"])
        #expect(store.sidebar == .playlist(id) && model.renamingPlaylistID == id)
        #expect(store.playlists.playlistProjection.layout.childIDs(of: "N") == [id])
        model.finishRenaming(id, to: "자식 목록")
        #expect(model.expandedPlaylistIDs == ["O", "F", "N"])
    }

    @Test func 맨_위에_만들거나_만들지_못하면_폴더_펼침을_바꾸지_않는다() throws {
        model.expandedPlaylistIDs = ["F"]
        let id = try #require(store.playlists.createPlaylist(isFolder: true, in: PlaylistLayout.root))
        #expect(model.expandedPlaylistIDs == ["F"])
        #expect(!model.expandedPlaylistIDs.contains(id))
        model.cancelRenaming()
        #expect(store.playlists.createPlaylist(isFolder: false, in: "A") == nil)
        #expect(model.expandedPlaylistIDs == ["F"])
        #expect(model.renamingPlaylistID == nil, "만들지 못하면 이름 바꾸기를 시작하지 않는다")
    }

    @Test func 이름을_끝내면_편집을_닫고_다듬은_이름을_초안에_쓴다() throws {
        let id = try #require(store.playlists.createPlaylist(isFolder: false, in: "F"))
        #expect(model.renamingPlaylistID == id)
        model.finishRenaming(id, to: "  세트  ")
        #expect(model.renamingPlaylistID == nil && store.playlists.playlistItem(id)?.name == "세트")
        // 빈 이름이면 편집만 닫고 이름은 그대로다
        model.startRenaming(id)
        model.finishRenaming(id, to: "   ")
        #expect(model.renamingPlaylistID == nil && store.playlists.playlistItem(id)?.name == "세트")
    }

    @Test func 펼침은_폴더마다_켜고_끈다() {
        #expect(!model.isExpanded("F"))
        model.setExpanded("F", true)
        model.setExpanded("O", true)
        #expect(model.isExpanded("F") && model.expandedPlaylistIDs == ["F", "O"])
        model.setExpanded("F", false)
        #expect(!model.isExpanded("F") && model.expandedPlaylistIDs == ["O"])
    }

    @Test func 이름_바꾸기를_시작하고_취소한다() {
        model.startRenaming("A")
        #expect(model.renamingPlaylistID == "A")
        model.cancelRenaming()
        #expect(model.renamingPlaylistID == nil && store.playlists.playlistItem("A")?.name == "가")
    }
}
