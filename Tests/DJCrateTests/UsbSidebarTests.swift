@testable import DJCrate
import AppKit
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@MainActor
@Suite("USB 사이드바와 읽기 전용 목록")
struct UsbSidebarTests {
    private func libraryStore() -> LibraryStore {
        LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("usb"), persist: false),
                     resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                     mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
    }

    /// 합성 USB 폴더(`UsbLibraryFixture`)를 사본으로 읽은 라이브러리
    private func fixtureLibrary() throws -> UsbLibrary {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        try UsbLibraryFixture().write(to: tree)
        let snapshots = FileManager.default.temporaryDirectory.appending(path: "djc-usbsidebar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: snapshots) }
        return try UsbRead.live.library(root: tree.base, snapshots: snapshots, volumeKey: "FIXTURE", volume: nil, now: Date()).library
    }

    private func physical(_ volume: UsbVolumeInfo, uuid: String) -> UsbVolumeInfo {
        var volume = volume
        volume.volumeUUID = uuid
        return volume
    }

    @Test("Device Library만 있는 USB는 OneLibrary 더하기 진입을 안내한다")
    func deviceLibraryMigrationEntry() async throws {
        let image = FakeUsbVolume.diskImageFAT32()
        let host = FakeUsbHost([image])
        host.serve(image, library: UsbTestData.library(formats: [.deviceLibrary]))
        let store = UsbTestData.store(host)
        await store.refresh()
        let row = try #require(UsbSidebarModel.volumes(store).first)
        #expect(row.help == "Device Library만 있습니다. OneLibrary를 더하려면 ‘OneLibrary 더하기…’를 누르세요")
    }

    @Test("OneLibrary 더하기는 Device Library 전용 USB에만 보인다", arguments: [Set<UsbFormat>(), [.deviceLibrary], [.oneLibrary], UsbFormat.defaultSet])
    func migrationVisibility(formats: Set<UsbFormat>) async throws {
        let image = FakeUsbVolume.diskImageFAT32()
        let host = FakeUsbHost([image])
        if formats.isEmpty { host.serveEmpty(image) } else { host.serve(image, library: UsbTestData.library(formats: formats)) }
        let store = UsbTestData.store(host)
        await store.refresh()
        let row = try #require(UsbSidebarModel.volumes(store).first)
        #expect(row.showsMigration == (formats == [.deviceLibrary]))
        #expect(row.canMigrate == row.showsMigration)
        _ = store.beginWrite(image, title: "시험")
        #expect(UsbSidebarModel.volumes(store).first?.canMigrate == false)
        store.endWrite(image.usbKey)
    }

    @Test("실물 Device Library에도 등록 없이 더하기를 연다(시험 실행처럼 동의가 없으면 닫고 이유를 보인다)")
    func physicalMigration() async throws {
        let volume = FakeUsbVolume.physicalFAT32()
        let host = FakeUsbHost([volume])
        host.serve(volume, library: UsbTestData.library(formats: [.deviceLibrary]))
        let store = UsbTestData.store(host)
        await store.refresh()
        let row = try #require(UsbSidebarModel.volumes(store).first)
        #expect(row.showsMigration && row.canMigrate)
        #expect(row.migrationHelp == "Device Library를 읽어 OneLibrary를 더합니다. 확인 창에서 CDJ에서 확인하지 않은 항목을 확인하세요")
        #expect(store.physicalWriteBlock(volume) == nil)
        #expect(UsbStore(host: host, readPolicy: .diskImagesOnly, writeService: FakeUsbWriteService(), localLibrary: { nil }).physicalWriteBlock(volume)
            == UsbTestData.physicalBlock.message)
    }

    @Test("빈 USB(FAT32·exFAT·GPT)는 내보내기, rekordbox USB는 컬렉션·목록, 쓸 수 없는 모양은 경고와 이유")
    func sidebarShapes() async throws {
        let empty = FakeUsbVolume.diskImageFAT32(name: "DJCEMPTY", uuid: "00000000-0000-0000-0000-000000000011")
        let rekordbox = FakeUsbVolume.diskImageFAT32(name: "DJCTEST", uuid: "00000000-0000-0000-0000-000000000012")
        let wider = [
            physical(FakeUsbVolume.gpt(), uuid: "00000000-0000-0000-0000-0000000000A2"),
            physical(FakeUsbVolume.exfat(), uuid: "00000000-0000-0000-0000-0000000000A3"),
        ]
        let unsupported = [
            physical(FakeUsbVolume.apfs(), uuid: "00000000-0000-0000-0000-0000000000A4"),
            physical(FakeUsbVolume.fat16(), uuid: "00000000-0000-0000-0000-0000000000A5"),
        ]
        let host = FakeUsbHost([empty, rekordbox] + wider + unsupported)
        host.serveEmpty(empty)
        for volume in wider { host.serveEmpty(volume) }
        host.serve(rekordbox, library: try fixtureLibrary())
        let store = UsbTestData.store(host)
        await store.refresh()
        let rows = Dictionary(uniqueKeysWithValues: UsbSidebarModel.volumes(store).map { ($0.id, $0) })

        let emptyRow = try #require(rows[empty.usbKey])
        #expect(emptyRow.showsExport && emptyRow.collection == nil && !emptyRow.isWarning && emptyRow.canEject)
        #expect(emptyRow.canExport)
        // 쓰는 동안은 내보내기·꺼내기를 막는다
        _ = store.beginWrite(empty, title: "시험")
        let busyRow = try #require(UsbSidebarModel.volumes(store).first { $0.id == empty.usbKey })
        #expect(busyRow.showsExport && !busyRow.canExport && !busyRow.canEject)
        store.endWrite(empty.usbKey)

        let rekordboxRow = try #require(rows[rekordbox.usbKey])
        #expect(rekordboxRow.collection == .collection(volumeKey: rekordbox.usbKey))
        #expect(rekordboxRow.collectionCount == 3)
        #expect(rekordboxRow.playlists.map(\.name) == ["시험 목록"])
        #expect(rekordboxRow.playlists.first?.count == 2)
        #expect(!rekordboxRow.showsExport && !rekordboxRow.isWarning)

        for volume in wider {
            let row = try #require(rows[volume.usbKey])
            #expect(row.showsExport && row.canExport && !row.isWarning)
            #expect(row.help == "rekordbox 라이브러리가 없는 USB입니다")
        }
        for volume in unsupported {
            let row = try #require(rows[volume.usbKey])
            let reformat = "이 USB 형식(\(volume.fileSystem.displayName))에는 rekordbox 라이브러리를 쓸 수 없습니다. FAT32나 exFAT로 포맷한 뒤 다시 시도하세요"
            #expect(row.isWarning && row.help == reformat && row.symbol == "exclamationmark.triangle")
            #expect(!row.showsExport && row.collection == nil && row.playlists.isEmpty)
            #expect(!host.infoCalls.contains(volume.usbKey) && !host.libraryCalls.contains(volume.usbKey))
        }
    }

    @Test("USB 목록은 읽기 전용: 쓰기·편집·끌기·재생 목록 메뉴가 없다")
    func readOnlyListBlocksWriteMenus() async throws {
        let fixture = try historyFixture()
        let store = libraryStore()
        await store.load(snapshot: fixture.database)
        let image = FakeUsbVolume.diskImageFAT32()
        let host = FakeUsbHost([image])
        host.serve(image, library: UsbTestData.library())
        let usb = UsbTestData.store(host)
        store.usb = usb
        await usb.refresh()

        store.sidebar = .usb(.collection(volumeKey: image.usbKey))
        #expect(store.isUsbSelection)
        #expect(store.displayRows.map(\.title) == ["시험 곡 1", "시험 곡 2", "시험 곡 3"])
        #expect(store.displayRows.allSatisfy { $0.isUsb })
        #expect(store.displayRows.first?.keyName == "8A" && store.displayRows.first?.artist == "시험 아티스트")
        #expect(store.displayRows.first?.track.folderPath == image.mountPoint + "/Contents/시험 아티스트/test1.mp3")
        // 로컬 share를 가리키지 않게 분석·아트워크 경로는 비운다
        #expect(store.displayRows.allSatisfy { $0.track.analysisDataPath == nil && $0.track.imagePath == nil })
        store.selection = Set(store.displayRows.map(\.id))
        #expect(store.selectedRows.isEmpty)
        // 덱 불러오기는 막지 않고 누르면 짝이 없다고 알린다(#255, 이 USB의 곡은 로컬에 없다)
        #expect(store.canLoadSelectionToDeck)
        #expect(!LibraryMenuAction.removeTracks.isEnabled(in: store))

        _ = NSApplication.shared
        let coordinator = TrackListCoordinator(store: store, actions: .live(store: store))
        let table = NSTableView()
        table.allowsMultipleSelection = true
        table.dataSource = coordinator
        table.delegate = coordinator
        let ids = ["index", "title", "artist", "album", "comment", "bpm", "key", "hotCues", "memoryCues", "tempo", "edited", "usbSync"]
        for id in ids { table.addTableColumn(NSTableColumn(identifier: .init(id))) }
        // 사용자가 숨겨 둔 칸(USB 목록에서 나오면 그대로 돌아와야 한다)
        table.tableColumns.first { $0.identifier.rawValue == "album" }?.isHidden = true
        coordinator.table = table
        coordinator.updateUsbMode(false)
        coordinator.update(rows: store.displayRows, edited: [], selection: store.selection, sortOrder: [], snapshotURL: store.snapshotURL,
                           previewRevision: 0)
        func visible() -> [String] { table.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue) }
        #expect(!visible().contains("usbSync"))
        // USB 목록도 컬렉션에서 고른 칸 배치를 그대로 쓰고 갱신 상태 칸만 더 보인다(#256)
        coordinator.updateUsbMode(true)
        #expect(visible() == ids.filter { $0 != "album" })
        // 읽지 않은 큐·그리드 값은 칸이 보이더라도 비운다(큐 없음 경고색 '없음'을 달지 않는다)
        func text(_ column: String) -> String? {
            let tableColumn = table.tableColumns.first { $0.identifier.rawValue == column }
            return (coordinator.tableView(table, viewFor: tableColumn, row: 0) as? TrackTextCell)?.text
        }
        #expect(text("memoryCues") == "" && text("hotCues") == "" && text("tempo") == "")
        #expect(text("key") == "8A")
        let menu = coordinator.makeMenu()
        coordinator.menuNeedsUpdate(menu)
        let actions = Set(menu.items.compactMap(\.action).map(NSStringFromSelector))
        let writes: Set<String> = ["reflectSelected", "exportReflectionXML", "addToRekordbox", "exportStaged", "deleteFromRekordbox",
                                   "pickPlaylist", "createPlaylistFromTracks", "removeFromPlaylist"]
        #expect(actions.isDisjoint(with: writes))
        #expect(!menu.items.contains { $0.title == "재생 목록에 넣기" })
        // 덱 불러오기는 누를 수 있다(#255, 짝이 없으면 누른 뒤 이유를 알린다)
        #expect(menu.items.first { $0.title == "덱에 불러오기" }?.action == #selector(TrackListCoordinator.loadMenuRow))
        // 끌기는 USB 곡 형식만 싣는다(덱에 놓기, #255). 로컬 목록·덱 ID 형식은 싣지 않는다
        let dragged = try #require(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        #expect(dragged.types == [PlaylistDragType.pasteboardUsbTracks])
        #expect(!coordinator.beginEditing(row: 0, column: "title"))
        store.tags.setTag(.title, "고친 제목", rows: store.displayRows)
        #expect(!store.tagDrafts.keys.contains { $0.hasPrefix(UsbLibraryRows.idPrefix) })
        store.loadToDeck(store.displayRows.first)
        #expect(store.deckTrackID == nil)
        #expect(store.staging.stagingMessage?.text == "로컬 rekordbox에 없는 USB 곡이라 덱에 올릴 수 없으니 rekordbox 컬렉션에 먼저 더하세요")
        // 로컬 목록으로 돌아오면 갱신 상태 칸만 숨긴다(사용자가 숨긴 칸은 그대로)
        coordinator.updateUsbMode(false)
        #expect(visible() == ids.filter { $0 != "album" && $0 != "usbSync" })
        withExtendedLifetime(table) {}

        // 재생 목록: 같은 곡이 두 번 들어 있어도 줄마다 따로 고르고 순번을 보인다
        store.sidebar = .usb(.playlist(volumeKey: image.usbKey, id: 10))
        #expect(store.displayRows.map(\.title) == ["시험 곡 2", "시험 곡 1", "시험 곡 2"])
        #expect(Set(store.displayRows.map(\.id)).count == 3)
        #expect(store.displayRows.map(\.playlistTrackNumber) == [1, 2, 3])
        #expect(store.sidebarTitle == "시험 목록")

        // 볼륨이 빠지면 라이브러리 목록으로 돌아간다
        host.mounted = []
        await usb.refresh()
        #expect(store.sidebar == .filter(.all))
    }

    @Test("한 형식에만 있는 목록은 표시를 달고, 두 형식의 항목이 다르면 경고한다")
    func playlistFormatMarkers() {
        let both = UsbFormat.defaultSet
        let library = UsbTestData.library(playlists: [
            UsbPlaylist(id: 1, name: "같음", presentIn: both, sortOrder: [.oneLibrary: 1, .deviceLibrary: 1],
                        entries: [.oneLibrary: [1, 2], .deviceLibrary: [1, 2]]),
            UsbPlaylist(id: 2, name: "OneLibrary 쪽", presentIn: [.oneLibrary], sortOrder: [.oneLibrary: 2], entries: [.oneLibrary: [1]]),
            UsbPlaylist(id: 3, name: "Device Library 쪽", presentIn: [.deviceLibrary], sortOrder: [.deviceLibrary: 3],
                        entries: [.deviceLibrary: [2]]),
            UsbPlaylist(id: 4, name: "다름", presentIn: both, sortOrder: [.oneLibrary: 4, .deviceLibrary: 4],
                        entries: [.oneLibrary: [1, 2, 3], .deviceLibrary: [3, 1, 2, 3]]),
            UsbPlaylist(id: 5, name: "폴더", attribute: 1, presentIn: both, sortOrder: [.oneLibrary: 0, .deviceLibrary: 0]),
            UsbPlaylist(id: 6, name: "폴더 안", parentID: 5, presentIn: both, sortOrder: [.oneLibrary: 0, .deviceLibrary: 0],
                        entries: [.oneLibrary: [3], .deviceLibrary: [3]]),
        ])
        let nodes = UsbPlaylistTree.build(library)
        #expect(nodes.map(\.name) == ["폴더", "같음", "OneLibrary 쪽", "Device Library 쪽", "다름"])
        let byName = Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, $0) })
        #expect(byName["같음"]?.marker == nil && byName["같음"]?.entriesDiffer == false)
        #expect(byName["OneLibrary 쪽"]?.marker == "OneLibrary만")
        #expect(byName["Device Library 쪽"]?.marker == "Device Library만")
        #expect(byName["다름"]?.entriesDiffer == true && byName["다름"]?.marker == nil)
        #expect(byName["다름"]?.count == 3)
        #expect(byName["폴더"]?.isFolder == true && byName["폴더"]?.children?.map(\.name) == ["폴더 안"])
        #expect(UsbPlaylistTree.mismatchHelp == "두 형식의 재생 목록 내용이 다릅니다")
        // 한 형식만 있는 USB에는 표시를 달지 않는다
        let single = UsbPlaylistTree.build(UsbTestData.library(formats: [.oneLibrary]))
        #expect(single.allSatisfy { $0.marker == nil && !$0.entriesDiffer })
        // Device Library에만 있는 목록은 그 형식의 항목을 보인다
        let rows = UsbLibraryRows.playlist(3, library: library, volumeKey: "K", mountPoint: "/Volumes/K", badges: [:])
        #expect(rows.map(\.title) == ["시험 곡 2"])
    }
}
