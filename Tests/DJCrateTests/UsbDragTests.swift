@testable import DJCrate
import AppKit
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Testing
import UniformTypeIdentifiers

/// 끌어 놓기 시험용 끌기 정보(창 서버 세션 없이 표의 놓기 대리자에 넘긴다)
@MainActor
final class TestDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingDestinationWindow: NSWindow? = nil
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move, .generic]
    let draggingLocation = NSPoint.zero
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(writers: [any NSPasteboardWriting], source: Any?) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("com.djcrate.test-drag.\(UUID().uuidString)"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(writers)
        draggingSource = source
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}

    func close() { draggingPasteboard.releaseGlobally() }
}

/// USB 목록 끌어 놓기(#240): USB 곡 줄 끌기, 같은 USB 목록에 넣기, USB 목록 안 순서 바꾸기, 초안을 얹은 목록, 실행 취소
@MainActor
@Suite("USB 끌어 놓기")
struct UsbDragTests {
    let image = FakeUsbVolume.diskImageFAT32(name: "B13T")
    let service = FakeUsbWriteService()
    let host = FakeUsbWriteHost()
    let drafts = FileManager.default.temporaryDirectory.appending(path: "djc-usbdrag-\(UUID().uuidString)")

    var key: String { image.usbKey }

    /// 목록 10 '시험 목록'(곡 2·1·2), 목록 20 '둘째 목록'(곡 3), 폴더 30 '폴더'와 그 안 목록 40 '폴더 안'(곡 1)
    static func library() -> UsbLibrary {
        let both = UsbFormat.defaultSet
        func list(_ id: Int, _ name: String, _ order: Int, parent: Int = 0, entries: [Int]? = nil) -> UsbPlaylist {
            UsbPlaylist(id: id, name: name, parentID: parent, attribute: entries == nil ? 1 : 0, presentIn: both,
                        sortOrder: [.oneLibrary: order, .deviceLibrary: order],
                        entries: entries.map { [.oneLibrary: $0, .deviceLibrary: $0] } ?? [:])
        }
        return UsbTestData.library(playlists: [list(10, "시험 목록", 0, entries: [2, 1, 2]), list(20, "둘째 목록", 1, entries: [3]),
                                               list(30, "폴더", 2), list(40, "폴더 안", 0, parent: 30, entries: [1])])
    }

    func setUp(undo: UndoManager? = nil) async -> (UsbStore, UsbEditActions) {
        let usbHost = FakeUsbHost([image])
        usbHost.serve(image, library: Self.library())
        let usb = UsbTestData.store(usbHost, service: service)
        usb.drafts = .live(directory: drafts)
        service.update {
            $0.base = UsbEditTestData.base
            $0.drafts = drafts
        }
        await usb.refresh()
        var actions = UsbEditActions(usb: usb, host: host, prompter: ScriptedPrompter(), namePrompter: ScriptedNamePrompter())
        actions.undoManager = { undo }
        return (usb, actions)
    }

    func draft() throws -> UsbDraft? { try UsbDraftStore(directory: drafts).load(volumeKey: key) }
    func cleanUp() { try? FileManager.default.removeItem(at: drafts) }

    /// USB 목록을 보는 곡 목록(앱처럼 store.usb를 붙인다)
    func store(_ usb: UsbStore, showing target: UsbSidebarTarget) -> LibraryStore {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("usbdrag"), persist: false),
                                      resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                                      mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        store.phase = .loaded
        store.usb = usb
        store.sidebar = .usb(target)
        return store
    }

    func contentIDs(_ rows: [TrackRow]) -> [Int] { rows.compactMap { UsbEditActions.usbContentID($0, volumeKey: key) } }

    // MARK: - 형식 선언

    @Test("곡 끌기 형식(로컬 곡·USB 곡)을 페이스트보드와 연결해 macOS에 선언한다")
    func dragTypesAreDeclared() throws {
        // 선언이 없으면 표(AppKit)가 실은 곡 ID를 SwiftUI 사이드바가 받지 못한다(#93의 덱 형식과 같다). 로컬 곡은 파일 URL로만 들어갔고
        // 파일 URL을 받지 않는 USB 줄에는 놓을 수 없었다
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/DJCrate/Info.plist")
        let info = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let declarations = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        for (type, pasteboard) in [(PlaylistDragType.tracks, PlaylistDragType.pasteboardTracks),
                                   (PlaylistDragType.usbTracks, PlaylistDragType.pasteboardUsbTracks)] {
            let declared = try #require(declarations.first { $0["UTTypeIdentifier"] as? String == type.identifier }, "\(type.identifier)")
            #expect((declared["UTTypeConformsTo"] as? [String])?.contains("public.data") == true)
            let tags = try #require(declared["UTTypeTagSpecification"] as? [String: [String]])
            #expect(tags["com.apple.nspboard-type"]?.contains(pasteboard.rawValue) == true)
        }
    }

    // MARK: - 끌기

    @Test("USB 곡 줄은 USB 곡 형식(볼륨·곡·목록 자리)만 싣는다. 덱·로컬 목록·앱 밖으로는 끌리지 않는다")
    func usbRowsWriteOnlyUsbTrackType() async throws {
        defer { cleanUp() }
        let (usb, _) = await setUp()
        let playlist = store(usb, showing: .playlist(volumeKey: key, id: 10))
        #expect(contentIDs(playlist.displayRows) == [2, 1, 2])
        let harness = ListHarness(rows: playlist.displayRows, selection: [], store: playlist)
        defer { harness.close() }
        let item = try #require(harness.coordinator.tableView(harness.table, pasteboardWriterForRow: 2) as? NSPasteboardItem)
        #expect(item.types == [PlaylistDragType.pasteboardUsbTracks])
        #expect(UsbTrackDrag.read([item]) == [UsbTrackDrag(volumeKey: key, contentID: 2, playlist: 10, trackNo: 3)])

        // 컬렉션 줄은 목록 자리가 없다
        let collection = store(usb, showing: .collection(volumeKey: key))
        let other = ListHarness(rows: collection.displayRows, selection: [], store: collection)
        defer { other.close() }
        let first = try #require(other.coordinator.tableView(other.table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        #expect(UsbTrackDrag.read([first]) == [UsbTrackDrag(volumeKey: key, contentID: 1, playlist: nil, trackNo: nil)])

        // 로컬 곡 줄은 그대로(덱·로컬 목록 형식)
        let local = ListHarness(rows: [UsbEditTestData.localRow("11")], selection: [])
        defer { local.close() }
        let localItem = try #require(local.coordinator.tableView(local.table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        #expect(localItem.types.contains(PlaylistDragType.pasteboardTracks))
        #expect(!localItem.types.contains(PlaylistDragType.pasteboardUsbTracks))
    }

    @Test("USB 곡을 끄는 동안만 끄는 볼륨을 기억해, 사이드바는 같은 USB의 일반 재생 목록에서만 받는다")
    func sidebarAcceptsUsbTracksOnSameVolumePlaylists() async throws {
        defer { cleanUp() }
        let (usb, actions) = await setUp()
        let playlist = store(usb, showing: .playlist(volumeKey: key, id: 10))
        let harness = ListHarness(rows: playlist.displayRows, selection: [], store: playlist)
        defer { harness.close() }
        harness.coordinator.tableView(harness.table, draggingSession: TrackListDragTests.session(), willBeginAt: .zero, forRowIndexes: [0, 2])
        #expect(playlist.usbDragVolume == key)
        #expect(UsbDrop.accepts(local: false, usb: true, on: .playlist(volumeKey: key, id: 20), store: playlist))
        #expect(!UsbDrop.accepts(local: false, usb: true, on: .collection(volumeKey: key), store: playlist))
        #expect(!UsbDrop.accepts(local: false, usb: true, on: .playlist(volumeKey: key, id: 30), store: playlist))
        #expect(!actions.acceptsUsbDrop(from: "다른 USB", on: .playlist(volumeKey: key, id: 20)))
        // 로컬 곡은 컬렉션·일반 목록 모두
        #expect(UsbDrop.accepts(local: true, usb: false, on: .collection(volumeKey: key), store: playlist))
        harness.coordinator.tableView(harness.table, draggingSession: TrackListDragTests.session(), endedAt: .zero, operation: [])
        #expect(playlist.usbDragVolume == nil)
        #expect(!UsbDrop.accepts(local: false, usb: true, on: .playlist(volumeKey: key, id: 20), store: playlist))
    }

    @Test("끌어서 순서를 바꿀 수 없는 목록이면 누를 때 간격 표시를 끈다(끌기가 시작되지 않으면 숨긴 줄이 돌아오지 않아 고른 줄이 사라졌다)")
    func dragFeedbackFollowsReorderability() async throws {
        defer { cleanUp() }
        let (usb, _) = await setUp()
        let playlist = store(usb, showing: .playlist(volumeKey: key, id: 10))
        let harness = ListHarness(rows: playlist.displayRows, selection: [], store: playlist)
        defer { harness.close() }
        #expect(harness.coordinator.dragFeedbackStyle == .gap)
        harness.table.draggingDestinationFeedbackStyle = .regular
        harness.table.prepareDragFeedback()
        #expect(harness.table.draggingDestinationFeedbackStyle == .gap)
        // 초안을 받지 않는 볼륨(USB 줄을 끌 수 없음)·USB 컬렉션은 간격 표시를 쓰지 않는다
        usb.drafts = nil
        #expect(harness.coordinator.dragFeedbackStyle == .regular)
        harness.table.prepareDragFeedback()
        #expect(harness.table.draggingDestinationFeedbackStyle == .regular)
        usb.drafts = .live(directory: drafts)
        playlist.sidebar = .usb(.collection(volumeKey: key))
        #expect(harness.coordinator.dragFeedbackStyle == .regular)
    }

    // MARK: - 다른 목록에 넣기

    @Test("USB 곡을 같은 USB의 다른 목록에 놓으면 끈 차례대로 넣는 초안을 쌓고, 이미 든 곡은 넣지 않는다")
    func dropUsbTracksOnPlaylist() async throws {
        defer { cleanUp() }
        let (usb, actions) = await setUp()
        let dragged = [UsbTrackDrag(volumeKey: key, contentID: 1, playlist: 10, trackNo: 2), UsbTrackDrag(volumeKey: key, contentID: 3),
                       UsbTrackDrag(volumeKey: key, contentID: 2, playlist: 10, trackNo: 1), UsbTrackDrag(volumeKey: key, contentID: 2, playlist: 10, trackNo: 3)]
        #expect(await actions.dropUsbTracks(dragged, on: .playlist(volumeKey: key, id: 20)))
        // 3은 이미 들어 있고, 같은 곡(2)은 한 번만
        #expect(try draft()?.edits == [.playlist(edit: .addTracks(playlist: .id("20"), contentIDs: ["1", "2"]))])
        #expect(host.toast?.title == "USB 쓰기 대기에 더했습니다")
        #expect(host.toast?.detail == "B13T · ‘둘째 목록’에 곡 2개 넣기 · 이미 들어 있는 1곡은 넣지 않았습니다")
        // 목록은 초안을 얹은 모양으로 보인다
        let rows = usb.rows(for: .playlist(volumeKey: key, id: 20))
        #expect(contentIDs(rows) == [3, 1, 2])
        #expect(rows.map(\.playlistTrackNumber) == [1, 2, 3])

        // 초안을 얹은 목록에 이미 든 곡만 끌면 더하지 않고 알린다
        #expect(!(await actions.dropUsbTracks([UsbTrackDrag(volumeKey: key, contentID: 1)], on: .playlist(volumeKey: key, id: 20))))
        #expect(host.toast?.title == "USB 쓰기 대기에 더하지 않았습니다")
        #expect(host.toast?.detail == "이미 들어 있는 곡이라 넣지 않았습니다")
        // 다른 USB의 곡·폴더·컬렉션은 받지 않는다
        #expect(!(await actions.dropUsbTracks([UsbTrackDrag(volumeKey: "다른 USB", contentID: 1)], on: .playlist(volumeKey: key, id: 20))))
        #expect(!(await actions.dropUsbTracks([UsbTrackDrag(volumeKey: key, contentID: 1)], on: .playlist(volumeKey: key, id: 30))))
        #expect(!(await actions.dropUsbTracks([UsbTrackDrag(volumeKey: key, contentID: 1)], on: .collection(volumeKey: key))))
        #expect(try draft()?.edits.count == 1)
    }

    @Test("사이드바 USB 줄은 USB 곡 형식을 읽어 넣기 초안을 만든다(SwiftUI 놓기 항목)")
    func sidebarDropLoadsUsbTrackProviders() async throws {
        defer { cleanUp() }
        let (usb, _) = await setUp()
        let playlist = store(usb, showing: .playlist(volumeKey: key, id: 10))
        playlist.usbDragVolume = key
        let providers = [UsbTrackDrag(volumeKey: key, contentID: 1, playlist: 10, trackNo: 2)].map { drag in
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: PlaylistDragType.usbTracks.identifier, visibility: .ownProcess) { done in
                done(Data(drag.pasteboardString.utf8), nil)
                return nil
            }
            return provider
        }
        #expect(UsbDrop.perform(providers, on: .playlist(volumeKey: key, id: 20), store: playlist))
        #expect(await waitUntil { usb.draftCounts[key] == 1 })
        #expect(try draft()?.edits == [.playlist(edit: .addTracks(playlist: .id("20"), contentIDs: ["1"]))])
    }

    // MARK: - 목록 안 순서 바꾸기

    @Test("USB 목록 표 안에 놓으면 순서 바꾸기 초안이 생기고, 표는 초안을 얹은 순서라 이어서 옮겨도 자리가 맞는다")
    func reorderInsideUsbPlaylist() async throws {
        defer { cleanUp() }
        let (usb, _) = await setUp()
        let playlist = store(usb, showing: .playlist(volumeKey: key, id: 10))
        #expect(playlist.usbReorderPlaylist?.id == 10)
        let harness = ListHarness(rows: playlist.displayRows, selection: [], store: playlist)
        defer { harness.close() }
        func drop(row source: Int, above target: Int) throws -> Bool {
            let writer = try #require(harness.coordinator.tableView(harness.table, pasteboardWriterForRow: source))
            let info = TestDraggingInfo(writers: [writer], source: harness.table)
            defer { info.close() }
            guard harness.coordinator.tableView(harness.table, validateDrop: info, proposedRow: target, proposedDropOperation: .above) == .move
            else { return false }
            return harness.coordinator.tableView(harness.table, acceptDrop: info, row: target, dropOperation: .above)
        }
        // 셋째 줄(곡 2)을 골라 맨 위로. 줄 ID는 곡과 그 곡의 몇 번째 출현이라 순서를 바꿔도 고른 곡을 따라간다(로컬 목록과 같다)
        let moved = playlist.displayRows[2].id
        #expect(playlist.displayRows.map(\.id) == ["usb:\(key):pl10:2:0", "usb:\(key):pl10:1:0", "usb:\(key):pl10:2:1"])
        #expect(try drop(row: 2, above: 0))
        #expect(await waitUntil { usb.draftCounts[key] == 1 })
        #expect(try draft()?.edits == [.playlist(edit: .moveTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 3, contentID: "2")], to: 1))])
        #expect(contentIDs(playlist.displayRows) == [2, 2, 1])
        #expect(playlist.displayRows.map(\.id) == ["usb:\(key):pl10:2:0", "usb:\(key):pl10:2:1", "usb:\(key):pl10:1:0"])
        #expect(playlist.displayRows.map(\.playlistTrackNumber) == [1, 2, 3])
        #expect(moved == "usb:\(key):pl10:2:1")
        // 알림은 초안 수가 바뀐 바로 뒤에 붙는다
        #expect(await waitUntil { playlist.toast?.detail == "B13T · ‘시험 목록’ 곡 순서 바꾸기" })

        // 초안을 얹은 표에서 다시 옮긴다(셋째 줄 곡 1을 맨 위로): 자리는 앞 편집을 적용한 목록 기준
        harness.coordinator.update(rows: playlist.displayRows, edited: [], selection: [], sortOrder: [], snapshotURL: nil, previewRevision: 0)
        #expect(try drop(row: 2, above: 0))
        #expect(await waitUntil { usb.draftCounts[key] == 2 })
        #expect(try draft()?.edits.last == .playlist(edit: .moveTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 3, contentID: "1")], to: 1)))
        #expect(contentIDs(playlist.displayRows) == [1, 2, 2])

        // 다른 곳에서 끈 곡·정렬·검색으로 거른 목록에는 놓지 않는다
        let other = TestDraggingInfo(writers: [try #require(harness.coordinator.tableView(harness.table, pasteboardWriterForRow: 0))], source: nil)
        defer { other.close() }
        #expect(harness.coordinator.tableView(harness.table, validateDrop: other, proposedRow: 1, proposedDropOperation: .above) == [])
        playlist.search = "시험"
        #expect(playlist.usbReorderPlaylist == nil)
    }

    @Test("곡 번호를 쓰기 전에는 알 수 없는 초안(로컬 곡 넣기)이 있는 목록은 끌어서 순서를 바꾸지 않는다")
    func reorderNeedsKnownEntries() async throws {
        defer { cleanUp() }
        let (usb, actions) = await setUp()
        await actions.addTracks([UsbEditTestData.localRow("11")], to: .playlist(volumeKey: key, id: 10))
        #expect(usb.draftCounts[key] == 1)
        let playlist = store(usb, showing: .playlist(volumeKey: key, id: 10))
        #expect(playlist.usbReorderPlaylist == nil)
        #expect(contentIDs(playlist.displayRows) == [2, 1, 2])
    }

    // MARK: - 초안을 얹은 항목

    @Test("목록에서 빼기 메뉴도 초안을 얹은 자리로 판정한다(앞 초안이 자리를 바꾼 뒤)")
    func blockReasonUsesProjectedEntries() async throws {
        defer { cleanUp() }
        let (usb, actions) = await setUp()
        #expect(await actions.moveEntries([UsbTrackDrag(volumeKey: key, contentID: 1, playlist: 10, trackNo: 2)], before: 1, volumeKey: key, playlist: 10))
        // 얹은 목록 [1, 2, 2]의 첫 곡(1)
        let rows = usb.rows(for: .playlist(volumeKey: key, id: 10))
        #expect(contentIDs(rows) == [1, 2, 2])
        let edit = try #require(UsbEditActions.removeFromPlaylistEdit([rows[0]], volumeKey: key, playlist: 10))
        #expect(actions.blockReason(edit, volumeKey: key) == nil)
        // 읽은 그대로의 자리(1번째 = 곡 2)는 이제 어긋난다
        #expect(actions.blockReason(.playlist(edit: .removeTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 1, contentID: "2")])),
                                    volumeKey: key) == "1번째 곡이 편집을 만들 때와 다릅니다. USB를 다시 읽은 뒤 고치세요")
    }

    @Test("쓰기 대기 목록은 편집마다 그 앞 편집까지 얹은 목록으로 판정한다(이미 더한 순서 바꾸기를 막힐 수 있다고 하지 않는다)")
    func pendingJudgesEachEditAfterEarlierOnes() async throws {
        defer { cleanUp() }
        let (usb, actions) = await setUp()
        #expect(await actions.moveEntries([UsbTrackDrag(volumeKey: key, contentID: 2, playlist: 10, trackNo: 1)], before: nil, volumeKey: key, playlist: 10))
        // 얹은 목록 [1, 2, 2]의 첫 곡(1)을 맨 끝으로. 읽은 목록 [2, 1, 2]의 첫 자리는 곡 2다
        #expect(await actions.moveEntries([UsbTrackDrag(volumeKey: key, contentID: 1, playlist: 10, trackNo: 1)], before: nil, volumeKey: key, playlist: 10))
        let edits = try #require(try draft()).edits
        #expect(edits.count == 2)
        let model = UsbPendingList(volumeName: "B13T", isConnected: true, edits: edits, library: usb.editLibrary(key), summary: nil, busy: false,
                                    blockReason: { actions.blockReason($0, volumeKey: key, after: $1) })
        #expect(model.rows.map(\.status) == [.waiting, .waiting])
        // 앞 편집을 빼면 뒤 편집의 자리가 어긋난다
        let alone = UsbPendingList(volumeName: "B13T", isConnected: true, edits: [edits[1]], library: usb.editLibrary(key), summary: nil, busy: false,
                                    blockReason: { actions.blockReason($0, volumeKey: key, after: $1) })
        #expect(alone.rows.map(\.status) == [.expectedBlock("1번째 곡이 편집을 만들 때와 다릅니다. USB를 다시 읽은 뒤 고치세요")])
    }

    // MARK: - 실행 취소

    @Test("끌어 놓아 더한 USB 편집은 편집 › 실행 취소로 빼고 실행 복귀로 다시 더한다(로컬 재생 목록 끌어 놓기와 같다)")
    func dropUndo() async throws {
        defer { cleanUp() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        let (usb, actions) = await setUp(undo: undo)
        // 묶음 없이 불러도 끌어 놓기 한 번이 실행 취소 한 단계다(초안을 고친 뒤 비동기로 건다)
        #expect(await actions.dropUsbTracks([UsbTrackDrag(volumeKey: key, contentID: 1)], on: .playlist(volumeKey: key, id: 20)))
        #expect(undo.groupingLevel == 0)
        #expect(undo.undoActionName == "USB 재생 목록에 넣기")
        undo.undo()
        #expect(await waitUntil { (usb.draftCounts[key] ?? 0) == 0 })
        #expect(try draft() == nil)
        #expect(undo.canRedo)
        undo.redo()
        #expect(await waitUntil { usb.draftCounts[key] == 1 })
        #expect(try draft()?.edits == [.playlist(edit: .addTracks(playlist: .id("20"), contentIDs: ["1"]))])

        // 순서 바꾸기·로컬 곡 놓기도 같다
        #expect(await actions.moveEntries([UsbTrackDrag(volumeKey: key, contentID: 2, playlist: 10, trackNo: 3)], before: 1, volumeKey: key, playlist: 10))
        #expect(undo.undoActionName == "USB 곡 순서 바꾸기")
        #expect(await actions.drop(["11"], on: .collection(volumeKey: key), rows: ["11": UsbEditTestData.localRow("11")]))
        #expect(undo.undoActionName == "USB 컬렉션에 더하기")
        #expect(usb.draftCounts[key] == 3)
        undo.undo()
        #expect(await waitUntil { usb.draftCounts[key] == 2 })
        undo.undo()
        #expect(await waitUntil { usb.draftCounts[key] == 1 })

        // 그 사이 뒤에 다른 편집이 쌓였으면 빼지 않고 알린다
        #expect(await actions.dropUsbTracks([UsbTrackDrag(volumeKey: key, contentID: 2)], on: .playlist(volumeKey: key, id: 20)))
        await actions.removeTracks([usb.rows(for: .collection(volumeKey: key))[2]], volumeKey: key)
        #expect(usb.draftCounts[key] == 3)
        undo.undo()
        #expect(await waitUntil { host.toast?.title == "실행 취소하지 않았습니다" })
        #expect(usb.draftCounts[key] == 3)
    }
}
