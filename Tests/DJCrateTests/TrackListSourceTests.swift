@testable import DJCrate
import AppKit
import DJCDomain
import DJCTestKit
import Foundation
import Observation
import SwiftUI
import Testing

/// 곡 목록 표와 덱 묶음은 라이브러리 저장소를 통째로 받지 않고 좁은 입력만 받는다(#254, D7).
/// 표는 `TrackListSource`의 값만 읽고, 덱의 이전·다음 단추와 덱에 놓기는 `DeckLibrarySource`만 부른다.
@MainActor
@Suite("곡 목록·덱 묶음 좁은 입력")
struct TrackListSourceTests {
    /// 표가 읽는 값만 든 가짜 출처. 메뉴·칸 편집을 맡는 조정자는 시험 저장소로 만든다(표 본문은 그 저장소를 읽지 않는다)
    @MainActor @Observable
    final class FakeSource: TrackListSource {
        var isWritingRekordbox = false
        var isUsbSelection = false
        var commentPreset = CommentPreset.none
        var displayRows: [TrackRow] = []
        var listMarkedUUIDs: Set<String> = []
        var selection: Set<TrackRow.ID> = []
        var sortOrder: [KeyPathComparator<TrackRow>] = []
        var snapshotURL: URL?
        var previewRevision = 0
        var tagRevision = 0
        var draftCueCounts: [String: CueCounts] = [:]
        var draftPreviewCues: [String: [PreviewCueMark]] = [:]
        var deckTrackID: String?
        @ObservationIgnored let library = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("track-list-source"), persist: false),
                                                            resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
        @ObservationIgnored private(set) var madeCoordinators = 0

        func makeTrackListCoordinator(actions: TrackListActions?, reflection: ReflectionCoordinator?) -> TrackListCoordinator {
            madeCoordinators += 1
            return TrackListCoordinator(store: library, actions: actions ?? .live(store: library, reflection: reflection))
        }
    }

    @MainActor @Observable
    final class FakeDeck: TrackListDeckStatus {
        var waveformColorMode = WaveformColorMode.threeBand
        var isPlaying = false
    }

    /// 상태를 기다린다(걸린 시간으로 판정하지 않는다, TEST-30·31). 기다리는 동안 표를 다시 배치해 SwiftUI 갱신을 받는다
    private func settle(_ host: NSView, until done: () -> Bool) async -> Bool {
        await waitForState {
            host.layoutSubtreeIfNeeded()
            return done()
        }
    }

    @Test func 표는_가짜_출처의_줄·선택·덱_곡을_따르고_조정자는_한_번_만든다() async throws {
        _ = NSApplication.shared
        let source = FakeSource()
        let host = NSHostingView(rootView: TrackTable(source: source, deck: FakeDeck()))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let table = try #require(TrackListDragTests.views(in: host).compactMap { $0 as? TrackListTableView }.first)
        // 이 시험의 칸 배치를 다른 시험에 남기지 않는다.
        table.autosaveTableColumns = false
        let coordinator = try #require(table.coordinator)

        let rows = TrackListDragTests.rows(["1", "2", "3"])
        source.displayRows = rows
        #expect(await settle(host) { table.numberOfRows == 3 })

        source.selection = [rows[1].id]
        #expect(await settle(host) { table.selectedRowIndexes == [1] })

        source.deckTrackID = rows[2].track.id
        #expect(await settle(host) { coordinator.deckTrackID == rows[2].track.id })

        source.isUsbSelection = true
        #expect(await settle(host) { coordinator.usbMode == true })
        #expect(source.madeCoordinators == 1, "값이 바뀌어도 조정자는 처음 한 번만 만든다")
    }

    @Test func 라이브러리_저장소는_표가_읽는_값을_그대로_내준다() {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("track-list-source-store"), persist: false),
                                      resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
        let source: any TrackListSource = store
        store.sidebar = .usb(.collection(volumeKey: "합성"))
        #expect(source.isUsbSelection)
        let coordinator = source.makeTrackListCoordinator(actions: nil, reflection: nil)
        #expect(coordinator.store === store)
    }

    @Test func 덱의_이전·다음_단추는_곡을_고르고_덱에_올린다() {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("deck-library-source"), persist: false),
                                      resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
        let row = TrackListTagEditTests.row("7")
        store.rowsByID[row.id] = row
        var loaded: [String?] = []
        store.onLoadToDeck = { loaded.append($0?.track.id) }
        let library: any DeckLibrarySource = store
        #expect(library.allowsLibraryInteraction)
        library.selectAndLoadToDeck(row)
        #expect(store.selection == [row.id])
        #expect(loaded == ["7"])
        // 쓰는 동안은 단추가 막히고, 눌러도 덱은 바꾸지 않는다
        store.isWritingRekordbox = true
        #expect(!library.allowsLibraryInteraction)
        library.selectAndLoadToDeck(row)
        #expect(loaded == ["7"])
    }
}
