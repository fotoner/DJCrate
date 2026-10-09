@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import Testing
import UniformTypeIdentifiers

/// 목록 한 번 클릭은 선택만, 덱에 올리기는 불러오기 명령(더블클릭·⌘→·오른쪽 클릭·끌어다 놓기)으로만 한다(#93).
@Suite("목록 선택과 덱 불러오기")
@MainActor
struct DeckLoadTests {
    /// 덱에 올린 곡(불러오기 명령마다 한 줄, 내리면 nil)
    final class LoadLog {
        var rows: [TrackRow?] = []
        var ids: [String?] { rows.map { $0?.id } }
    }

    func loadedStore(_ fixture: RekordboxFixture) async -> (LibraryStore, LoadLog) {
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: fixture.root.appending(path: "result.json")), saveTagDrafts: { _ in })
        let log = LoadLog()
        store.onLoadToDeck = { log.rows.append($0) }
        await store.load(snapshot: fixture.database)
        return (store, log)
    }

    /// 선택이 덱에 닿는 길은 없다(덱은 불러오기 명령으로만, #93). 그래도 선택 변경이 메인 액터에 일을 남겼다면 그 일까지 돌린 뒤 본다.
    /// 시간을 기다리지 않는다: 메인 액터 큐를 여러 번 양보해 비운다.
    func settle() async { await drainMainActor() }

    // MARK: - 스토어

    @Test func 선택만_바꾸면_덱은_그대로다() async throws {
        let fixture = try historyFixture()
        let (store, log) = await loadedStore(fixture)
        #expect(log.rows.isEmpty && store.deckTrackID == nil)
        store.selection = ["101"]
        await settle()
        store.selection = ["101", "102"]
        await settle()
        store.selection = []
        await settle()
        #expect(log.rows.isEmpty)
        #expect(store.deckTrackID == nil)
    }

    @Test func 덱이_곡을_바꾸지_말라고_하면_올리지_않는다() async throws {
        // Flip 기록 중 곡을 바꾸기 전에 묻고, 취소하면 덱도 덱 곡 ID도 그대로다.
        let fixture = try historyFixture()
        let (store, log) = await loadedStore(fixture)
        var asked: [String] = []
        var allow = true
        store.confirmDeckReplacement = { row in asked.append(row.id); return allow }
        store.loadToDeck(store.rowsByID["101"])
        #expect(log.ids == ["101"] && asked == ["101"])
        allow = false
        store.loadToDeck(store.rowsByID["102"])
        #expect(log.ids == ["101"])
        #expect(store.deckTrackID == "101")
        // 같은 곡을 다시 올리는 것은 묻지 않는다(곡이 바뀌지 않는다)
        store.loadToDeck(store.rowsByID["101"])
        #expect(asked == ["101", "102"])
        #expect(log.ids == ["101", "101"])
    }

    @Test func 불러오기_명령은_고른_곡_중_표_순서로_첫_곡을_올린다() async throws {
        let fixture = try historyFixture()
        let (store, log) = await loadedStore(fixture)
        #expect(!store.canLoadSelectionToDeck)
        store.loadSelectionToDeck()
        #expect(log.rows.isEmpty)
        store.sortOrder = [KeyPathComparator(\TrackRow.title, order: .reverse)]
        store.selection = ["101", "102"]
        #expect(store.canLoadSelectionToDeck)
        store.loadSelectionToDeck()
        #expect(log.ids == ["102"])
        #expect(store.deckTrackID == "102")
        // 쓰는 동안은 덱을 바꾸지 않는다
        store.isWritingRekordbox = true
        #expect(!store.canLoadSelectionToDeck)
        store.loadSelectionToDeck()
        store.loadToDeck(store.rowsByID["101"])
        store.loadDroppedTracks(["101"])
        #expect(log.ids == ["102"])
    }

    @Test func 재생_기록의_반복_행을_불러와도_컬렉션_곡으로_올린다() async throws {
        let fixture = try historyFixture()
        let (store, log) = await loadedStore(fixture)
        store.sidebar = .history("new-a")
        let repeated = try #require(store.displayRows.last)
        #expect(repeated.id == "history:entry-3")
        store.loadToDeck(repeated)
        #expect(log.ids == ["101"])
        #expect(log.rows.last??.historyEntry == nil)
        #expect(store.deckTrackID == "101")
    }

    @Test func 끌어다_놓은_곡은_있는_첫_곡을_올린다() async throws {
        let fixture = try historyFixture()
        let (store, log) = await loadedStore(fixture)
        store.loadDroppedTracks([])
        store.loadDroppedTracks(["없는 곡"])
        #expect(log.rows.isEmpty)
        store.loadDroppedTracks(["없는 곡", "102", "101"])
        #expect(log.ids == ["102"])
    }

    @Test func 새로_읽으면_덱의_곡은_새_값으로_맞추고_지워진_곡은_내리고_선택은_따라가지_않는다() async throws {
        let fixture = try historyFixture()
        let (store, log) = await loadedStore(fixture)
        store.loadToDeck(store.rowsByID["101"])
        store.selection = ["102"]
        try fixture.execute("UPDATE djmdContent SET Title = '고친 제목' WHERE ID = '101'")
        // 덱 맞추기는 다시 읽기(`load`) 안에서 끝난다(`refreshDeckTrack`)
        await store.load(snapshot: fixture.database, quiet: true)
        #expect(log.ids == ["101", "101"])
        #expect(log.rows.last??.title == "고친 제목")
        // rekordbox에서 덱의 곡을 지우면 덱에서 내린다(지워진 곡을 붙들지 않게)
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '101'")
        await store.load(snapshot: fixture.database, quiet: true)
        #expect(log.ids == ["101", "101", nil])
        #expect(store.deckTrackID == nil)
        #expect(store.selection == ["102"])
        // 덱이 비어 있으면 새로 읽어도 올리지 않는다
        await store.load(snapshot: fixture.database, quiet: true)
        #expect(log.ids == ["101", "101", nil])
    }

    @Test func 추가한_곡의_ID를_옮긴_뒤_새로_읽으면_덱은_등록된_곡을_유지한다() async throws {
        let fixture = try historyFixture()
        let (store, log) = await loadedStore(fixture)
        let staged = TrackListTagEditTests.row("djc-test")
        store.loadToDeck(staged)
        store.selection = ["102"]
        store.moveDeckTrack(to: "101")
        // 다시 읽기 전에는 기존 오디오를 내리지 않는다.
        #expect(log.ids == [staged.id])
        await store.load(snapshot: fixture.database, quiet: true)
        #expect(log.ids == [staged.id, "101"])
        #expect(store.deckTrackID == "101")
        #expect(store.selection == ["102"])
        #expect(log.rows.last??.isStaged == false)
    }
}

/// 곡 목록 표(#93): 한 번 클릭은 고르기만, 더블클릭·⌘→·오른쪽 클릭·끌어다 놓기로 덱에 올린다.
/// 태그 칸 바로 편집(#88)은 이미 고른 줄의 칸을 다시 누르거나(잠깐 뒤, Finder처럼) Return으로 시작한다.
@Suite("곡 목록에서 덱 불러오기")
@MainActor
struct TrackListDeckLoadTests {
    let a = TrackListTagEditTests.row("1"), b = TrackListTagEditTests.row("2")

    @Test func 덱_드래그_형식은_페이스트보드와_연결해_선언한다() throws {
        // 선언이 없으면 AppKit 드래그를 SwiftUI가 받지 못하고, 데이터를 읽어도 -1000으로 실패한다.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/DJCrate/Info.plist")
        let info = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let declarations = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let track = try #require(declarations.first { $0["UTTypeIdentifier"] as? String == DeckDragType.track.identifier })
        #expect((track["UTTypeConformsTo"] as? [String])?.contains("public.data") == true)
        let tags = try #require(track["UTTypeTagSpecification"] as? [String: [String]])
        #expect(tags["com.apple.nspboard-type"]?.contains(DeckDragType.pasteboard.rawValue) == true)
    }

    func harness(_ rows: [TrackRow], selection: Set<TrackRow.ID>) -> (ListHarness, DeckLoadTests.LoadLog) {
        let h = ListHarness(rows: rows, selection: selection)
        let log = DeckLoadTests.LoadLog()
        h.store.onLoadToDeck = { log.rows.append($0) }
        return (h, log)
    }

    func settle() async { await drainMainActor() }

    @Test func 한_번_클릭은_고르기만_하고_덱은_그대로다() async {
        let (h, log) = harness([a, b], selection: [a.id])
        defer { h.close() }
        h.table.selectRowIndexes([1], byExtendingSelection: false)
        #expect(h.store.selection == [b.id])
        await settle()
        #expect(log.rows.isEmpty)
    }

    @Test func 더블클릭은_누른_줄을_덱에_올리고_칸을_고치지_않는다() {
        let (h, log) = harness([a, b], selection: [a.id])
        defer { h.close() }
        #expect(h.table.doubleAction == #selector(TrackListCoordinator.doubleClicked(_:)))
        #expect(h.table.target === h.coordinator)
        h.coordinator.loadRow(at: 1)
        #expect(log.ids == ["2"])
        #expect(!h.coordinator.isEditing)
        // 머리글·빈 곳 더블클릭은 아무것도 하지 않는다
        h.coordinator.loadRow(at: -1)
        h.coordinator.loadRow(at: 5)
        #expect(log.ids == ["2"])
    }

    @Test func 명령_오른쪽_화살표는_고른_곡_중_첫_곡을_올리고_화살표만으로는_올리지_않는다() {
        let (h, log) = harness([a, b], selection: [b.id, a.id])
        defer { h.close() }
        h.press(keyCode: 124, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        #expect(log.rows.isEmpty)
        h.press(keyCode: 124, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: .command)
        #expect(log.ids == ["1"])
        #expect(!h.coordinator.isEditing)
        // 목록에서 ⌘ 조합은 덱 단축키가 아니라 표로 간다
        #expect(!KeyRoutingPolicy.accepts(124, in: .init(hasShortcutModifiers: true, focus: .trackList)))
    }

    /// 덱을 보고 있을 때도 메뉴에 적힌 ⌘→가 고른 곡을 올린다. 목록·시트는 표가, 글자 칸은 커서 이동으로 받는다.
    @Test func 명령_오른쪽_화살표는_덱_포커스에서도_고른_곡을_올리고_글자_입력은_건드리지_않는다() {
        #expect(KeyRoutingPolicy.loadsSelection(124, modifiers: .command, focus: .deck))
        #expect(KeyRoutingPolicy.loadsSelection(124, modifiers: [.command, .numericPad, .function], focus: .deck))
        #expect(!KeyRoutingPolicy.loadsSelection(124, modifiers: [], focus: .deck))
        #expect(!KeyRoutingPolicy.loadsSelection(124, modifiers: [.command, .shift], focus: .deck))
        #expect(!KeyRoutingPolicy.loadsSelection(123, modifiers: .command, focus: .deck))
        for focus in [KeyRoutingPolicy.Focus.trackList, .sheet, .textInput, .control, .table] {
            #expect(!KeyRoutingPolicy.loadsSelection(124, modifiers: .command, focus: focus))
        }
    }

    @Test func 오른쪽_클릭_메뉴_맨_위에서_덱에_불러온다() throws {
        let (h, log) = harness([a, b], selection: [b.id])
        defer { h.close() }
        let menu = h.coordinator.makeMenu()
        h.coordinator.menuNeedsUpdate(menu)
        let item = try #require(menu.items.first)
        #expect(item.title == "덱에 불러오기")
        #expect(item.keyEquivalent == String(UnicodeScalar(NSRightArrowFunctionKey)!) && item.keyEquivalentModifierMask == .command)
        let action = try #require(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
        #expect(log.ids == ["2"])
    }

    @Test func 이미_혼자_고른_줄을_다시_한_번_누를_때만_잠깐_뒤_고친다() {
        #expect(TrackListTagEditing.startsSlowEdit(clickCount: 1, row: 0, selected: [0], modifiers: []))
        #expect(!TrackListTagEditing.startsSlowEdit(clickCount: 2, row: 0, selected: [0], modifiers: []))
        #expect(!TrackListTagEditing.startsSlowEdit(clickCount: 1, row: 0, selected: [1], modifiers: []))
        #expect(!TrackListTagEditing.startsSlowEdit(clickCount: 1, row: 0, selected: [0, 1], modifiers: []))
        #expect(!TrackListTagEditing.startsSlowEdit(clickCount: 1, row: 0, selected: [0], modifiers: .shift))
        #expect(!TrackListTagEditing.startsSlowEdit(clickCount: 1, row: 0, selected: [0], modifiers: .command))
        #expect(!TrackListTagEditing.startsSlowEdit(clickCount: 1, row: -1, selected: [0], modifiers: []))
    }

    /// 기다리던 칸 편집이 끝날 때까지(고쳤거나 취소). 다른 시험이 메인 스레드를 쓰는 동안은 늦게 깨므로 시간이 아니라 상태로 기다린다.
    func finishPendingEdit(_ h: ListHarness) async {
        let finished = await waitForState(until: { !h.coordinator.hasPendingEdit })
        #expect(finished)
    }

    /// 다시 누른 칸은 마우스를 놓은 뒤에야 고친다. 실제 마우스 상태는 시험이 정한다(시험 중에 사용자가 마우스를 누르고 있어도 같은 결과).
    @Test func 다시_누른_태그_칸은_마우스를_아직_누르고_있으면_고치지_않고_놓으면_고친다() async {
        let (h, _) = harness([a, b], selection: [a.id])
        defer { h.close() }
        h.coordinator.isMouseDown = { true }
        h.coordinator.scheduleEdit(row: 0, column: "title", after: .milliseconds(20))
        await finishPendingEdit(h)
        #expect(!h.coordinator.isEditing)
        h.coordinator.isMouseDown = { false }
        h.coordinator.scheduleEdit(row: 0, column: "title", after: .milliseconds(20))
        await finishPendingEdit(h)
        #expect(h.coordinator.editingColumn == "title")
    }

    @Test func 다시_누른_태그_칸은_잠깐_뒤_고치고_그_사이_더블클릭_선택_변경이면_취소한다() async {
        let (h, log) = harness([a, b], selection: [a.id])
        defer { h.close() }
        h.coordinator.scheduleEdit(row: 0, column: "title", after: .milliseconds(20))
        #expect(!h.coordinator.isEditing)
        await finishPendingEdit(h)
        #expect(h.coordinator.editingColumn == "title")
        h.coordinator.cancelEditing()
        // 태그 칸이 아니면 기다리지도 않는다
        h.coordinator.scheduleEdit(row: 0, column: "bpm", after: .milliseconds(20))
        #expect(!h.coordinator.hasPendingEdit)
        // 기다리는 사이 두 번째 클릭(더블클릭)이 오면 덱에 올리고 고치지 않는다
        h.coordinator.scheduleEdit(row: 0, column: "title", after: .milliseconds(100))
        h.coordinator.loadRow(at: 0)
        #expect(!h.coordinator.hasPendingEdit)
        #expect(log.ids == ["1"])
        // 기다리는 사이 다른 줄을 고르면 고치지 않는다
        h.coordinator.scheduleEdit(row: 0, column: "title", after: .milliseconds(50))
        h.table.selectRowIndexes([1], byExtendingSelection: false)
        await finishPendingEdit(h)
        #expect(!h.coordinator.isEditing)
        // 기다리는 사이 줄을 끌기 시작하면(덱에 놓기 등) 고치지 않는다. 끌기가 먼저 시작돼도 예약하지 않는다.
        h.table.selectRowIndexes([0], byExtendingSelection: false)
        h.coordinator.scheduleEdit(row: 0, column: "title", after: .milliseconds(50))
        let drags = h.coordinator.dragGeneration
        h.coordinator.tableView(h.table, draggingSession: NSDraggingSession(), willBeginAt: .zero, forRowIndexes: [0])
        #expect(!h.coordinator.hasPendingEdit)
        #expect(h.coordinator.dragGeneration == drags + 1)
        // 키를 누르면 취소한다(Return·⌘→ 등은 그 키 몫)
        h.table.selectRowIndexes([0], byExtendingSelection: false)
        h.coordinator.scheduleEdit(row: 0, column: "title", after: .milliseconds(50))
        h.press(keyCode: 125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        #expect(!h.coordinator.hasPendingEdit)
    }

    @Test func 덱에_올린_곡은_번호_칸에_스피커로_보이고_VoiceOver로_알린다() throws {
        let (h, _) = harness([a, b], selection: [a.id])
        defer { h.close() }
        let first = try #require(h.view(row: 0, column: "index") as? TrackIndexCell)
        #expect(first.text == "1" && first.deckSymbol == nil)
        h.coordinator.updateDeck(trackID: b.track.id, playing: false)
        let loaded = try #require(h.view(row: 1, column: "index") as? TrackIndexCell)
        #expect(loaded.deckSymbol == "speaker.fill")
        #expect(loaded.spokenDeckState == "덱에 올린 곡")
        h.coordinator.updateDeck(trackID: b.track.id, playing: true)
        #expect((h.view(row: 1, column: "index") as? TrackIndexCell)?.deckSymbol == "speaker.wave.2.fill")
        #expect((h.view(row: 1, column: "index") as? TrackIndexCell)?.spokenDeckState == "덱에 올린 곡, 재생 중")
        h.coordinator.updateDeck(trackID: nil, playing: false)
        let cleared = try #require(h.view(row: 1, column: "index") as? TrackIndexCell)
        #expect(cleared.text == "2" && cleared.deckSymbol == nil && cleared.spokenDeckState == nil)
    }

    @Test func 끌면_덱에_올릴_곡을_싣고_추가한_곡은_재생_목록용으로는_싣지_않는다() throws {
        let staged = TrackListTagEditTests.row("djc-9")
        let (h, _) = harness([a, staged], selection: [a.id])
        defer { h.close() }
        let library = try #require(h.coordinator.tableView(h.table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        #expect(library.string(forType: DeckDragType.pasteboard) == "1")
        #expect(library.string(forType: PlaylistDragType.pasteboardTracks) == "1")
        let added = try #require(h.coordinator.tableView(h.table, pasteboardWriterForRow: 1) as? NSPasteboardItem)
        #expect(added.string(forType: DeckDragType.pasteboard) == "djc-9")
        #expect(added.string(forType: PlaylistDragType.pasteboardTracks) == nil)
    }
}

/// 태그 시트(#93): 커서 이동은 고르기만, ⌘→·오른쪽 클릭으로 덱에 올린다. 더블클릭은 칸 편집 그대로.
@Suite("태그 시트에서 덱 불러오기")
@MainActor
struct TagSheetDeckLoadTests {
    @Test func 커서를_옮겨도_덱은_그대로고_명령_오른쪽_화살표와_메뉴로_올린다() async throws {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let log = DeckLoadTests.LoadLog()
        store.onLoadToDeck = { log.rows.append($0) }
        let coordinator = SheetCoordinator(store: store)
        let table = SheetTableView()
        table.coordinator = coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        coordinator.update(rows: [TrackListTagEditTests.row("1"), TrackListTagEditTests.row("2")], revision: 0)
        coordinator.select(CellPosition(row: 1, column: 1), extend: false)
        #expect(store.selection == ["2"])
        await drainMainActor()
        #expect(log.rows.isEmpty)
        let arrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        func press(_ modifiers: NSEvent.ModifierFlags) {
            table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                                 context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
                                                 isARepeat: false, keyCode: 124)!)
        }
        press(.command)
        #expect(log.ids == ["2"])
        #expect(coordinator.cursor == CellPosition(row: 1, column: 1))
        press([])
        #expect(coordinator.cursor == CellPosition(row: 1, column: 2))
        #expect(log.ids == ["2"])
        // 오른쪽 클릭한 줄을 올린다(커서가 다른 줄에 있어도)
        let menu = coordinator.contextMenu(forRow: 0)
        let item = try #require(menu.items.first)
        #expect(item.title == "덱에 불러오기")
        let action = try #require(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
        #expect(log.ids == ["2", "1"])
    }
}
