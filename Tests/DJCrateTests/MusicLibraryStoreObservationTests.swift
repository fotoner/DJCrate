@testable import DJCrate
import DJCApplication
import DJCDomain
import Observation
import SwiftUI
import Testing

/// Music(iTunes) 조각(`MusicLibraryStore`, #253)의 값이 바뀔 때 다시 계산하는 범위. 그 값을 그리는 iTunes 절·작업 줄·동기화 창만
/// 다시 계산하고 사이드바 본문은 다시 계산하지 않는다(#141: 본문이 다시 계산되면 List가 재생 목록 수백 개를 모두 다시 비교한다).
/// 조각은 핵심의 `let` 속성이라, 조각으로 옮겨도 읽는 값의 수는 옛 `LibraryStore` 속성과 같다.
@MainActor
@Suite("Music 조각 — 다시 계산하는 범위")
struct MusicLibraryStoreObservationTests {
    private final class Flag: @unchecked Sendable { var fired = false }

    private func store() -> LibraryStore {
        LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
    }

    /// `body`를 한 번 계산하는 동안 읽은 값 중 `change`가 바꾸는 것이 있는지
    private func reads<Content: View>(_ view: (LibraryStore) -> Content, before: (LibraryStore) -> Void = { _ in },
                                      change: (LibraryStore) -> Void) -> Bool {
        let store = store()
        before(store)
        let flag = Flag()
        withObservationTracking { _ = view(store).body } onChange: { flag.fired = true }
        change(store)
        return flag.fired
    }

    /// 같은 값을 다시 넣으면 알림이 나가지 않으므로 값을 실제로 바꾼다
    private var snapshot: ITunesLibrarySnapshot { ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "합성 목록")]) }
    private var library: SyncedITunesLibrary { SyncedITunesLibrary(snapshot: snapshot, tracks: []) }

    @Test(.tags(.perfContract)) func 사이드바_본문은_Music_목록과_동기화_창을_읽지_않는다() {
        #expect(!reads({ Sidebar(store: $0) }) { $0.music.library = library })
        #expect(!reads({ Sidebar(store: $0) }) { $0.music.snapshot = snapshot })
        #expect(!reads({ Sidebar(store: $0) }) { $0.music.presentSyncWindow() })
    }

    @Test(.tags(.perfContract)) func iTunes_절은_Music_목록이_바뀌면_다시_계산한다() {
        #expect(reads({ ITunesPlaylistSection(store: $0) }) { $0.music.library = library })
        #expect(reads({ ITunesPlaylistSection(store: $0) }) { $0.music.library.status = .ready })
    }

    @Test(.tags(.perfContract)) func iTunes_절은_곡_선택과_Music_원문을_읽지_않는다() {
        #expect(!reads({ ITunesPlaylistSection(store: $0) }) { $0.selection = ["1"] })
        #expect(!reads({ ITunesPlaylistSection(store: $0) }) { $0.music.snapshot = snapshot })
    }

    @Test(.tags(.perfContract)) func 목록_위_작업_줄은_iTunes_목록을_볼_때만_Music_목록을_읽는다() {
        #expect(reads({ ListActionBar(store: $0) }, before: { $0.sidebar = .itunesPlaylist("itunes:A") }) { $0.music.library = library })
        #expect(!reads({ ListActionBar(store: $0) }) { $0.music.library = library })
    }

    @Test(.tags(.perfContract)) func 동기화_창은_사이드바_목록이_바뀌어도_다시_계산하지_않고_쓰기_잠금과_창_상태는_따른다() {
        let window: (LibraryStore) -> ITunesSyncView = { ITunesSyncView(model: $0.music.syncWindow) }
        // 목록을 다 읽은 창: 읽는 중이면 단추 막힘 식이 앞에서 끝나 잠금 값을 읽지 않는다
        let open: (LibraryStore) -> Void = { $0.music.presentSyncWindow(); $0.music.syncWindow.isLoading = false }
        #expect(!reads(window, before: open) { $0.music.library = library })
        #expect(!reads(window, before: open) { $0.music.snapshot = snapshot })
        #expect(reads(window, before: open) { $0.isWritingRekordbox = true })
        #expect(reads(window, before: open) { $0.music.syncWindow.isSyncing = true })
    }

    @Test func 조각은_핵심이_한_번_만들어_들고_창은_띄울_때마다_새_모델이다() {
        let store = store()
        #expect(store.music === store.music)
        store.music.presentSyncWindow()
        let first = store.music.syncWindow
        #expect(store.music.showingSyncWindow)
        store.music.showingSyncWindow = false
        store.music.presentSyncWindow()
        #expect(store.music.syncWindow !== first && store.music.showingSyncWindow)
    }
}
