import DJCApplication
@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestKit
import Foundation
import SwiftUI
import Testing

/// 곡 목록에서 곡을 끌어다 놓은 뒤에도 목록이 스크롤된다(#143).
/// 간격 표시(`.gap`)로 끌면 표가 끄는 줄을 숨긴다. 숨긴 채 덱에 곡을 올려 목록 높이가 바뀌면 표 높이를 줄 끝보다 짧게 잡고,
/// 끌기가 끝나 줄을 다시 보여도 높이를 다시 재지 않아 휠 스크롤이 짧은 높이에 막혔다.
@MainActor
@Suite("곡 목록 끌기 뒤 스크롤")
struct TrackListDragTests {
    /// 끌기 대리자 메서드에 넘길 빈 세션(AppKit은 세션을 만드는 공개 방법이 없다)
    static func session() -> NSDraggingSession {
        (NSDraggingSession.self as NSObject.Type).init() as! NSDraggingSession
    }

    static func rows(_ ids: [String]) -> [TrackRow] {
        ids.map { TrackListTagEditTests.row($0) }
    }

    @Test func 순서를_바꿀_수_없는_목록에서_끌면_줄을_숨기는_간격_표시를_쓰지_않는다() {
        let harness = ListHarness(rows: Self.rows((1...40).map(String.init)), selection: [])
        defer { harness.close() }
        harness.table.draggingDestinationFeedbackStyle = .gap
        #expect(!harness.store.playlists.canReorderDisplayedTracks)
        harness.coordinator.tableView(harness.table, draggingSession: Self.session(), willBeginAt: .zero, forRowIndexes: [3])
        #expect(harness.table.draggingDestinationFeedbackStyle == .regular)
    }

    @Test func 순서를_바꿀_수_있는_재생_목록에서는_간격_표시로_끈다() {
        let store = Self.playlistStore(count: 3)
        #expect(store.playlists.canReorderDisplayedTracks)
        let harness = ListHarness(rows: store.displayRows, selection: [], store: store)
        defer { harness.close() }
        harness.table.draggingDestinationFeedbackStyle = .regular
        harness.coordinator.tableView(harness.table, draggingSession: Self.session(), willBeginAt: .zero, forRowIndexes: [1])
        #expect(harness.table.draggingDestinationFeedbackStyle == .gap)
    }

    static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views(in:))
    }

    /// 순서를 바꿀 수 있는 재생 목록(# 순)
    static func playlistStore(count: Int) -> LibraryStore {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("drag"), persist: false),
                                 resultHistory: WriteResultHistory(), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in })
        store.phase = .loaded
        let ids = (1...count).map(String.init)
        for id in ids { store.rowsByID[id] = PlaylistEditingTests.row(id) }
        store.playlists.rekordboxPlaylists = PlaylistLayout([(PlaylistEditingTests.item("A", "가", tracks: ids), 1)])
        store.playlists.refreshPlaylists()
        store.sidebar = .playlist("A")
        return store
    }

    /// 재생 목록에서 덱으로 끌 때: 간격 표시라 끄는 줄을 숨기고, 덱에 곡이 올라가 목록 높이가 바뀐다.
    @Test func 끌기가_끝나면_표_높이를_줄_끝까지_다시_잰다() async throws {
        _ = NSApplication.shared
        let store = Self.playlistStore(count: 60)
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        let host = NSHostingView(rootView: TrackTable(source: store, deck: deck))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let table = try #require(Self.views(in: host).compactMap { $0 as? TrackListTableView }.first)
        // 이 시험의 칸 배치·정렬을 다른 시험에 남기지 않는다.
        table.autosaveTableColumns = false
        // 다른 시험이 자동 저장한 칸 배치의 정렬이 표에 되살아나 # 순이 아닐 수 있다. 정렬을 비우고 줄이 다 찰 때까지 기다린다.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !(store.playlists.canReorderDisplayedTracks && table.numberOfRows == 60), clock.now < deadline {
            store.sortOrder = []
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(store.playlists.canReorderDisplayedTracks && table.numberOfRows == 60)
        // 시험 프로세스가 막 떴을 때 AppKit이 한 번 보내는 스크롤 막대 모양 알림이 스크롤 뷰를 다시 배치해 표 높이를 고친다.
        // 그 알림이 지나간 뒤에 끈다(앱에서는 끌 때마다 오지 않는다).
        try await Task.sleep(for: .milliseconds(500))
        let bottom = table.rect(ofRow: table.numberOfRows - 1).maxY
        let session = Self.session()
        let source = table as NSDraggingSource
        source.draggingSession?(session, willBeginAt: .zero)
        #expect(table.draggingDestinationFeedbackStyle == .gap)
        // AppKit이 간격 표시 끌기를 시작할 때 끄는 줄을 숨기는 메서드(비공개). 공개 hideRows로는 이 높이 틀어짐이 생기지 않는다.
        let selector = NSSelectorFromString("_beginGapFeedbackDragIfNeededForRows:startRow:")
        try #require(table.responds(to: selector), "macOS가 바뀌었으면 이 재현 방법을 다시 확인한다")
        typealias BeginGapDrag = @convention(c) (AnyObject, Selector, NSIndexSet, Int) -> Void
        unsafeBitCast(table.method(for: selector), to: BeginGapDrag.self)(table, selector, IndexSet(integer: 5) as NSIndexSet, 5)
        try #require(table.hiddenRowIndexes == [5])
        // 숨긴 채 목록 높이가 바뀐다(덱에 곡이 올라감).
        window.setContentSize(NSSize(width: 900, height: 280))
        host.layoutSubtreeIfNeeded()
        // 표의 끌기 끝: 대리자를 부른 뒤 숨긴 줄을 다시 보인다. 높이는 짧은 채로 남는다.
        source.draggingSession?(session, endedAt: .zero, operation: .move)
        #expect(table.hiddenRowIndexes.isEmpty)
        try #require(table.frame.height < bottom, "재현 조건: 표 높이가 줄 끝보다 짧아야 한다")
        let settled = clock.now + .seconds(1)
        while table.frame.height < bottom, clock.now < settled { try await Task.sleep(for: .milliseconds(20)) }
        #expect(table.frame.height >= table.rect(ofRow: table.numberOfRows - 1).maxY)
    }
}
