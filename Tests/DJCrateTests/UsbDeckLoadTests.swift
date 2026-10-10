@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import Testing

/// USB 목록의 곡을 덱에 불러오기(#255): 짝이 있는 USB 곡은 그 로컬 곡 줄을 올리고, 짝이 없으면 덱을 바꾸지 않고 이유를 알린다.
/// 짝 판정 규칙은 DJCDomainTests `UsbDeckLoadTests`가 본다. 여기서는 스토어·목록·끌기의 연결만 본다.
/// 재료는 `UsbHistoryAppTests`와 같다: 합성 기록 사본(곡 101·102)과 USB 곡 1 ↔ 101, 2 ↔ 102, 곡 3은 짝 없음.
@MainActor
@Suite("USB 곡 덱 불러오기")
struct UsbDeckLoadTests {
    @MainActor
    struct Setup {
        let fixture: RekordboxFixture
        let store: LibraryStore
        let usb: UsbStore
        let key: String
        let log = DeckLoadTests.LoadLog()

        func row(_ contentID: Int) -> TrackRow? {
            store.displayRows.first { $0.track.id == UsbLibraryRows.trackID(volumeKey: key, contentID: contentID) }
        }
    }

    func setUp(showing target: (String) -> UsbSidebarTarget = { .collection(volumeKey: $0) }) async throws -> Setup {
        let fixture = try historyFixture()
        let store = try await UsbHistoryAppTests.libraryStore(fixture)
        let (host, volume) = UsbHistoryAppTests.host()
        let usb = UsbTestData.store(host, local: UsbHistoryAppTests.localKeys())
        store.usb = usb
        await usb.refresh()
        #expect(usb.localMatches[volume.usbKey] == [1: "101", 2: "102"])
        store.sidebar = .usb(target(volume.usbKey))
        let setup = Setup(fixture: fixture, store: store, usb: usb, key: volume.usbKey)
        store.onLoadToDeck = { [log = setup.log] in log.rows.append($0) }
        return setup
    }

    static let notLocal = "로컬 rekordbox에 없는 USB 곡이라 덱에 올릴 수 없으니 rekordbox 컬렉션에 먼저 더하세요"

    @Test("짝이 있는 USB 컬렉션 곡은 그 로컬 곡 줄을 덱에 올린다")
    func loadsLocalMatch() async throws {
        let s = try await setUp()
        s.store.loadToDeck(try #require(s.row(1)))
        #expect(s.store.deckTrackID == "101")
        #expect(s.log.ids == ["101"])
        #expect(s.log.rows.last??.isUsb == false)
        #expect(s.store.staging.stagingMessage == nil)
    }

    @Test("USB 재생 목록에서 고른 곡도 ⌘→·덱 메뉴로 로컬 곡을 올린다")
    func loadsSelectionFromUsbPlaylist() async throws {
        let s = try await setUp { .playlist(volumeKey: $0, id: 10) }
        let first = try #require(s.store.displayRows.first)
        #expect(first.playlistOccurrence != nil)
        s.store.selection = [first.id]
        #expect(s.store.canLoadSelectionToDeck)
        s.store.loadSelectionToDeck()
        #expect(s.store.deckTrackID == "102")
        #expect(s.log.ids == ["102"])
    }

    @Test("짝이 없는 USB 곡은 덱을 바꾸지 않고 rekordbox 컬렉션에 먼저 더하라고 알린다")
    func unmatchedExplains() async throws {
        let s = try await setUp()
        s.store.loadToDeck(try #require(s.row(1)))
        let unmatched = try #require(s.row(3))
        // 메뉴를 막지 않는다: 눌렀을 때 이유를 보인다
        s.store.selection = [unmatched.id]
        #expect(s.store.canLoadSelectionToDeck)
        s.store.loadSelectionToDeck()
        #expect(s.store.staging.stagingMessage?.text == Self.notLocal)
        #expect(s.store.staging.stagingMessage?.kind == .warning)
        s.store.staging.stagingMessage = nil
        s.store.loadToDeck(unmatched)
        #expect(s.store.staging.stagingMessage?.text == Self.notLocal)
        #expect(s.store.deckTrackID == "101")
        #expect(s.log.ids == ["101"])
    }

    @Test("재생 기록 보존 줄(usb:history:)은 USB 볼륨 곡으로 풀지 않고 같은 안내를 한다")
    func archivedHistoryRowIsNotUsbVolumeTrack() async throws {
        let s = try await setUp()
        let archived = TrackListTagEditTests.row(HistoryStore.archivedTrackIDPrefix + "\(s.key):1")
        #expect(archived.isUsb)
        s.store.loadToDeck(archived)
        #expect(s.store.deckTrackID == nil)
        #expect(s.log.rows.isEmpty)
        #expect(s.store.staging.stagingMessage?.text == Self.notLocal)
    }

    @Test("짝 로컬 곡이 목록에 없으면 덱을 바꾸지 않고 다시 읽으라고 알린다")
    func missingLocalRowExplains() async throws {
        let s = try await setUp()
        let row = try #require(s.row(1))
        // 짝을 계산한 뒤 rekordbox에서 곡을 지웠다(짝 정보는 아직 옛 값)
        try s.fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '101'")
        await s.store.load(snapshot: s.fixture.database, quiet: true)
        #expect(s.store.rowsByID["101"] == nil)
        #expect(s.usb.localMatches[s.key]?[1] == "101")
        s.store.loadToDeck(row)
        #expect(s.store.deckTrackID == nil)
        #expect(s.log.rows.isEmpty)
        #expect(s.store.staging.stagingMessage?.text == "USB 곡과 짝인 로컬 곡을 찾을 수 없으니 라이브러리를 다시 읽은 뒤 덱에 불러오세요")
    }

    @Test("덱에 끌어 놓은 USB 곡은 첫 곡의 로컬 짝을 올리고, 짝이 없으면 알린다")
    func droppedUsbTracks() async throws {
        let s = try await setUp()
        s.store.loadDroppedUsbTracks([])
        #expect(s.log.rows.isEmpty && s.store.staging.stagingMessage == nil)
        s.store.loadDroppedUsbTracks([UsbTrackDrag(volumeKey: s.key, contentID: 3), UsbTrackDrag(volumeKey: s.key, contentID: 1)])
        #expect(s.log.rows.isEmpty)
        #expect(s.store.staging.stagingMessage?.text == Self.notLocal)
        s.store.loadDroppedUsbTracks([UsbTrackDrag(volumeKey: s.key, contentID: 2, playlist: 10, trackNo: 1)])
        #expect(s.log.ids == ["102"])
        #expect(s.store.deckTrackID == "102")
        // 쓰는 동안은 덱을 바꾸지 않는다
        s.store.isWritingRekordbox = true
        s.store.loadDroppedUsbTracks([UsbTrackDrag(volumeKey: s.key, contentID: 1)])
        #expect(s.log.ids == ["102"])
    }

    @Test("USB 목록의 더블클릭·오른쪽 클릭 메뉴·끌기가 덱 불러오기로 이어지고, 덱의 로컬 곡은 USB 줄 # 칸에도 보인다")
    func trackListConnections() async throws {
        let s = try await setUp()
        let rows = s.store.displayRows
        let h = ListHarness(rows: rows, selection: [], store: s.store)
        defer { h.close() }
        let one = try #require(rows.firstIndex { $0.track.id == s.row(1)?.track.id })
        let three = try #require(rows.firstIndex { $0.track.id == s.row(3)?.track.id })

        // # 칸: 덱의 로컬 곡(101)과 짝인 USB 줄에도 덱 표시가 나오고, 덱이 바뀌면 다시 그린다
        #expect((h.view(row: one, column: "index") as? TrackIndexCell)?.deckSymbol == nil)
        h.coordinator.updateDeck(trackID: "101", playing: false)
        #expect((h.view(row: one, column: "index") as? TrackIndexCell)?.deckSymbol == "speaker.fill")
        #expect((h.view(row: three, column: "index") as? TrackIndexCell)?.deckSymbol == nil)
        h.coordinator.updateDeck(trackID: nil, playing: false)
        #expect((h.view(row: one, column: "index") as? TrackIndexCell)?.deckSymbol == nil)

        // 더블클릭
        h.coordinator.doubleClicked(row: one, column: "title")
        #expect(s.log.ids == ["101"])

        // 오른쪽 클릭 메뉴의 '덱에 불러오기'는 눌린다(짝이 없으면 누른 뒤 이유를 보인다)
        h.table.selectRowIndexes([three], byExtendingSelection: false)
        let menu = h.coordinator.makeMenu()
        h.coordinator.menuNeedsUpdate(menu)
        let item = try #require(menu.items.first { $0.title == "덱에 불러오기" })
        let action = try #require(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
        #expect(s.log.ids == ["101"])
        #expect(s.store.staging.stagingMessage?.text == Self.notLocal)

        // 쓰기를 받지 않는 USB여도 덱에 놓을 수 있게 USB 곡 형식을 싣는다(덱·로컬 목록 형식은 싣지 않는다)
        #expect(s.usb.acceptsEdits(s.key) == false)
        let dragged = try #require(h.coordinator.tableView(h.table, pasteboardWriterForRow: one) as? NSPasteboardItem)
        #expect(dragged.types == [PlaylistDragType.pasteboardUsbTracks])
        #expect(UsbTrackDrag.read([dragged]) == [UsbTrackDrag(volumeKey: s.key, contentID: 1)])
    }
}
