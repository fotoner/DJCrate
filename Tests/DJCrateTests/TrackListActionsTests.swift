import DJCAdapters
import DJCApplication
@testable import DJCrate
import AppKit
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Testing

/// 곡 목록 오른쪽 클릭 메뉴는 쓰기·추가 목록·XML 흐름을 직접 부르지 않고 동작 묶음(`TrackListActions`)으로 시작한다.
@Suite("곡 목록 메뉴의 동작 묶음")
@MainActor
struct TrackListActionsTests {
    private final class Calls {
        var log: [String] = []
        /// 추가한 곡 XML을 시작한 그 순간의 스토어 선택(추가 목록 창이 읽는 값)
        var selectionAtStagedXML: Set<TrackRow.ID>?
    }

    private final class MenuTable: NSTableView {
        var menuClickedRow = -1
        override var clickedRow: Int { menuClickedRow }
    }

    private func recording(_ calls: Calls, selection: @escaping @MainActor () -> Set<TrackRow.ID> = { [] }) -> TrackListActions {
        func ids(_ rows: [TrackRow]) -> String { rows.map(\.track.id).joined(separator: ",") }
        return TrackListActions(
            writeDrafts: { calls.log.append("쓰기 \(ids($0))") },
            exportDraftsXML: { calls.log.append("XML \(ids($0))") },
            addToRekordbox: { calls.log.append("넣기 \(ids($0))") },
            deleteFromRekordbox: { calls.log.append("빼기 \(ids($0))") },
            recoverDraft: { row, kind in calls.log.append("복구 \(row.track.id) \(kind)") },
            exportStagedXML: {
                calls.log.append("추가한 곡 XML")
                calls.selectionAtStagedXML = selection()
            },
            addToUsb: { rows, _ in calls.log.append("USB 넣기 \(ids(rows))") },
            removeFromUsb: { rows, _ in calls.log.append("USB 빼기 \(ids(rows))") },
            removeFromUsbPlaylist: { rows, _, _ in calls.log.append("USB 목록 빼기 \(ids(rows))") },
            refreshUsbTracks: { rows, _ in calls.log.append("USB 갱신 \(ids(rows))") })
    }

    @Test func 메뉴_항목은_고른_곡으로_동작_묶음을_부른다() throws {
        _ = NSApplication.shared
        let local = RatingColorEditingTests.row("1"), staged = RatingColorEditingTests.row("2", staged: true)
        let rows = [local, staged]
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        store.rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.track.id, $0) })
        store.rowsByUUID = Dictionary(uniqueKeysWithValues: rows.map { ($0.track.uuid, $0) })
        var draft = TagDraft(track: local.track)
        draft.fields.comment = "내 편집"
        store.tagDrafts[local.track.uuid] = draft
        let calls = Calls()
        let coordinator = TrackListCoordinator(store: store, actions: recording(calls, selection: { store.selection }))
        let table = MenuTable()
        table.allowsMultipleSelection = true
        table.dataSource = coordinator
        table.delegate = coordinator
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        coordinator.table = table
        coordinator.update(rows: rows, edited: [], selection: Set(rows.map(\.id)), sortOrder: [], snapshotURL: nil, previewRevision: 0)
        let menu = coordinator.makeMenu()
        coordinator.menuNeedsUpdate(menu)
        func press(_ title: String) throws {
            let item = try #require(menu.items.first { $0.title == title }, "\(title)")
            let action = try #require(item.action, "\(title)")
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        }
        try press("선택한 곡 rekordbox에 쓰기 (1곡)")
        try press("선택한 곡 XML 만들기 (1곡)")
        try press("rekordbox에 바로 넣기 (1곡)")
        try press("rekordbox 컬렉션에서 빼기 (1곡)…")
        #expect(calls.log == ["쓰기 1,djc-2", "XML 1,djc-2", "넣기 1,djc-2", "빼기 1,djc-2"])
        // 추가한 곡 XML은 추가한 곡만 고른 뒤 시작한다(추가 목록 창이 시작할 때 스토어 선택을 읽는다)
        #expect(store.selection != [staged.id])
        try press("추가한 곡 XML 만들기 (1곡)")
        #expect(calls.log.last == "추가한 곡 XML" && calls.selectionAtStagedXML == [staged.id])
    }

    /// 실제 묶음(`live`)의 USB 네 동작은 누를 때 스토어의 USB 편집(`usbEdits`)을 읽어 그 볼륨 초안에 쌓는다.
    /// USB 편집을 붙이지 않은 스토어(시험·캡처)에서는 아무것도 하지 않는다.
    @Test func USB_네_동작은_붙인_USB_편집의_초안에_쌓고_붙이지_않았으면_아무것도_하지_않는다() async throws {
        let image = FakeUsbVolume.diskImageFAT32(name: "B13T"), key = image.usbKey
        let drafts = FileManager.default.temporaryDirectory.appending(path: "djc-actions-usb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: drafts) }
        let host = FakeUsbHost([image])
        host.serve(image, library: UsbTestData.library())
        let service = FakeUsbWriteService()
        service.update {
            $0.base = UsbEditTestData.base
            $0.drafts = drafts
        }
        let usb = UsbTestData.store(host, local: UsbEditTestData.localNewerOne, service: service)
        usb.drafts = .live(directory: drafts)
        await usb.refresh()
        let library = try #require(usb.libraries[key])
        let collection = UsbLibraryRows.collection(library: library, volumeKey: key, mountPoint: image.mountPoint, badges: usb.syncBadges[key] ?? [:])
        let listed = UsbLibraryRows.playlist(10, library: library, volumeKey: key, mountPoint: image.mountPoint, badges: [:])
        let local = UsbEditTestData.localRow("11")

        let store = ListHarness.store()
        let actions = TrackListActions.live(store: store)
        #expect(store.usbEdits == nil)
        actions.addToUsb([local], .collection(volumeKey: key))
        actions.removeFromUsbPlaylist([listed[1]], key, 10)
        actions.removeFromUsb([collection[1]], key)
        actions.refreshUsbTracks([collection[0]], key)
        await drainMainActor()

        // 붙이면 같은 묶음이 누를 때마다 그 편집으로 초안에 하나씩 쌓는다(앞의 네 번은 남지 않았다)
        store.usb = usb
        let edits = try #require(store.usbEdits)
        let refresh = edits.refreshEdits(volumeKey: key, rows: [collection[0]])
        #expect(refresh.count == 1)
        actions.addToUsb([local], .collection(volumeKey: key))
        #expect(await waitForState { usb.draftCounts[key] == 1 })
        actions.removeFromUsbPlaylist([listed[1]], key, 10)
        #expect(await waitForState { usb.draftCounts[key] == 2 })
        actions.removeFromUsb([collection[1]], key)
        #expect(await waitForState { usb.draftCounts[key] == 3 })
        actions.refreshUsbTracks([collection[0]], key)
        #expect(await waitForState { usb.draftCounts[key] == 4 })
        let draft = try #require(try UsbDraftStore(directory: drafts).load(volumeKey: key))
        let add = try #require(UsbEditActions.addTracksEdit([local], target: .collection(volumeKey: key)))
        let removeFromList = try #require(UsbEditActions.removeFromPlaylistEdit([listed[1]], volumeKey: key, playlist: 10))
        #expect(draft.edits == [add, removeFromList, .removeTracks(usbContentIDs: [2])] + refresh)
    }
}
