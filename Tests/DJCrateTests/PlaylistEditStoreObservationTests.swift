@testable import DJCrate
import DJCApplication
import DJCDomain
import Observation
import SwiftUI
import Testing

/// 재생 목록 조각(`PlaylistEditStore`, #251)의 값이 바뀔 때 다시 계산하는 범위. 트리 구조는 재생 목록 구역만 읽고, 사이드바 본문은
/// 재생 목록 값을 읽지 않는다(#141: 본문이 다시 계산되면 List가 재생 목록 수백 개를 모두 다시 비교한다. `SidebarObservationTests`).
/// 조각은 핵심이 관찰하지 않는 속성이라, 조각으로 옮겨도 읽는 값의 수는 옛 `LibraryStore` 속성과 같다.
@MainActor
@Suite("재생 목록 조각 — 다시 계산하는 범위")
struct PlaylistEditStoreObservationTests {
    private final class Flag: @unchecked Sendable { var fired = false }

    /// 사이드바는 읽은 뒤에만 재생 목록 구역을 그리므로 읽은 상태로 둔다
    private func store() -> LibraryStore {
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in })
        store.phase = .loaded
        return store
    }

    /// `body`를 한 번 계산하는 동안 읽은 값 중 `change`가 바꾸는 것이 있는지
    private func reads<Content: View>(_ view: (LibraryStore) -> Content, change: (LibraryStore) -> Void) -> Bool {
        let store = store()
        let flag = Flag()
        withObservationTracking { _ = view(store).body } onChange: { flag.fired = true }
        change(store)
        return flag.fired
    }

    private func sidebar(_ store: LibraryStore) -> Sidebar {
        Sidebar(store: store, playlistSidebar: PlaylistSidebarModel(playlists: store.playlists))
    }

    private func section(_ store: LibraryStore) -> PlaylistSection {
        PlaylistSection(store: store, sidebar: PlaylistSidebarModel(playlists: store.playlists))
    }

    private var layout: PlaylistLayout { PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "합성 목록"), 1)]) }

    @Test(.tags(.perfContract)) func 재생_목록_구역은_트리와_초안이_바뀔_때만_다시_계산한다() {
        #expect(reads(section) {
            $0.playlists.rekordboxPlaylists = layout
            $0.playlists.refreshPlaylists()
        })
        #expect(reads(section) {
            var draft = PlaylistDraft()
            _ = try? draft.append(.create(key: "k", name: "새 목록", isFolder: false, parent: PlaylistRef(PlaylistLayout.root)), rekordbox: PlaylistLayout())
            $0.playlists.playlistDraft = draft
        })
        #expect(!reads(section) { $0.playlists.playlistMessage = AppMessage(text: "합성 안내") })
        #expect(!reads(section) { $0.playlists.recentPlaylistIDs = ["A"] })
    }

    @Test(.tags(.perfContract)) func 고르기_시트를_열어도_사이드바와_재생_목록_구역은_다시_계산하지_않는다() {
        let row = TrackRow(track: Track(id: "1", uuid: "u1", title: "합성", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                                        releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180, folderPath: "/x/1.wav",
                                        comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false),
                           cues: [], playCount: 0)
        #expect(!reads(sidebar) { $0.playlists.openPlaylistPicker(tracks: [row]) })
        #expect(!reads(section) { $0.playlists.openPlaylistPicker(tracks: [row]) })
    }
}
