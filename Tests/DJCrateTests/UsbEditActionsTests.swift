@testable import DJCrate
import AppKit
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 이름 창: 정해 둔 이름을 차례로 돌려준다(비면 취소)
@MainActor
final class ScriptedNamePrompter: UsbNamePrompter {
    var answers: [String?] = []
    private(set) var asked: [(title: String, initial: String)] = []

    func askName(title: String, text: String, initial: String, confirm: String) -> String? {
        asked.append((title, initial))
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

/// 메인 액터 밖의 가짜 창구를 멈춰 두는 문. 시험이 열 때까지 기다린다. 시험이 열지 못하고 끝나도 쓰레드가 남지 않게
/// 아주 늦으면(2분) 스스로 열고 `timedOut`을 남긴다 — 순서를 시간에 맡기지 않으므로 시험은 그것이 거짓인지 본다
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var arrived = 0
    private var expired = false

    /// 문 앞에 온 수
    var arrivals: Int { lock.withLock { arrived } }
    /// 시험이 열기 전에 스스로 열렸는지
    var timedOut: Bool { lock.withLock { expired } }
    func open() { lock.withLock { opened = true } }

    /// 메인 액터 밖에서만 부른다
    func pass() {
        lock.withLock { arrived += 1 }
        expectBlockingOffPool()
        let deadline = Date().addingTimeInterval(120)
        while !lock.withLock({ opened }) {
            if Date() >= deadline {
                lock.withLock { expired = true }
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

/// 메인 액터 밖의 가짜 창구가 받은 편집 묶음을 차례로 적는다
final class EditLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[UsbLibraryEdit]] = []

    var all: [[UsbLibraryEdit]] { lock.withLock { entries } }
    func append(_ edits: [UsbLibraryEdit]) { lock.withLock { entries.append(edits) } }
}

/// 조건이 참이 될 때까지 기다린다. 참이 되면 true, 아주 늦도록(기본 2분) 거짓이면 false — 부르는 쪽은 false를 실패로 본다
/// (시간이 다 됐다고 다음 단계로 넘어가면 부하에서 단계 순서가 바뀐다, #184)
@MainActor
func waitUntil(timeout: Duration = .seconds(120), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// USB 편집 시험 자료(곡 제목·ID는 지어낸 값)
enum UsbEditTestData {
    static func localRow(_ id: String, folder: String = "/x") -> TrackRow {
        TrackRow(track: Track(id: id, uuid: "uuid-\(id)", title: "로컬 곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil,
                              composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180,
                              folderPath: "\(folder)/\(id).mp3", comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil,
                              isDeleted: false),
                 cues: [], playCount: 0)
    }

    /// 지어낸 USB DB 지문
    static let base = UsbFingerprint(files: ["PIONEER/rekordbox/exportLibrary.db": .init(size: 10, mtime: Date(timeIntervalSince1970: 0), sha256: "aa")])

    /// 로컬 곡 11이 USB 곡 1과 짝이고 곡 정보가 더 새롭다(갱신 가능)
    static let localNewerOne = LocalLibraryKeys(localDBID: UsbTestData.localDBID,
                                                tracks: [UsbLocalTrackKey(contentID: "11", masterSongID: "501", fileNameL: "test1.mp3")],
                                                counters: ["11": LocalTrackCounters(information: "4", analysis: "2", cue: "1")])

    /// 맨 위에 A(1)·B(2)·C(3)·폴더 F(7)가 이 순서로 있는 라이브러리
    static func siblingLibrary() -> UsbLibrary {
        let both = UsbFormat.defaultSet
        func list(_ id: Int, _ name: String, _ order: Int, folder: Bool = false) -> UsbPlaylist {
            UsbPlaylist(id: id, name: name, attribute: folder ? 1 : 0, presentIn: both, sortOrder: [.oneLibrary: order, .deviceLibrary: order],
                        entries: folder ? [:] : [.oneLibrary: [], .deviceLibrary: []])
        }
        return UsbTestData.library(playlists: [list(1, "A", 0), list(2, "B", 1), list(3, "C", 2), list(7, "F", 3, folder: true)])
    }

    /// 두 형식의 항목이 다른 목록(4)·폴더(5)·폴더 안 목록(6)을 더한 라이브러리
    static func mixedLibrary() -> UsbLibrary {
        let both = UsbFormat.defaultSet
        return UsbTestData.library(playlists: [
            UsbPlaylist(id: 10, name: "시험 목록", presentIn: both, sortOrder: [.oneLibrary: 0, .deviceLibrary: 0],
                        entries: [.oneLibrary: [2, 1, 2], .deviceLibrary: [2, 1, 2]]),
            UsbPlaylist(id: 4, name: "다름", presentIn: both, sortOrder: [.oneLibrary: 1, .deviceLibrary: 1],
                        entries: [.oneLibrary: [1, 2, 3], .deviceLibrary: [3, 1, 2, 3]]),
            UsbPlaylist(id: 5, name: "폴더", attribute: 1, presentIn: both, sortOrder: [.oneLibrary: 2, .deviceLibrary: 2]),
            UsbPlaylist(id: 6, name: "폴더 안", parentID: 5, presentIn: both, sortOrder: [.oneLibrary: 0, .deviceLibrary: 0],
                        entries: [.oneLibrary: [3], .deviceLibrary: [3]]),
        ])
    }
}

@MainActor
@Suite("USB 편집 동작(UsbEditActions)")
struct UsbEditActionsTests {
    let image = FakeUsbVolume.diskImageFAT32(name: "B13T")
    let service = FakeUsbWriteService()
    let host = FakeUsbWriteHost()
    let prompter = ScriptedPrompter()
    let names = ScriptedNamePrompter()
    let drafts = FileManager.default.temporaryDirectory.appending(path: "djc-usbdrafts-\(UUID().uuidString)")

    var key: String { image.usbKey }

    func setUp(_ library: UsbLibrary = UsbTestData.library(), volumes: [UsbVolumeInfo]? = nil,
               local: LocalLibraryKeys? = nil) async -> (UsbStore, FakeUsbHost, UsbEditActions) {
        let usbHost = FakeUsbHost(volumes ?? [image])
        for volume in volumes ?? [image] { usbHost.serve(volume, library: library) }
        let usb = UsbTestData.store(usbHost, local: local, service: service)
        usb.drafts = .live(directory: drafts)
        service.update {
            $0.base = UsbEditTestData.base
            $0.drafts = drafts
        }
        await usb.refresh()
        var counter = 0
        let actions = UsbEditActions(usb: usb, host: host, prompter: prompter, namePrompter: names, newKey: {
            counter += 1
            return "k\(counter)"
        })
        return (usb, usbHost, actions)
    }

    func draft() throws -> UsbDraft? { try UsbDraftStore(directory: drafts).load(volumeKey: key) }

    func cleanUp() { try? FileManager.default.removeItem(at: drafts) }

    // MARK: - 초안 쌓기·빼기·버리기

    @Test("편집을 볼륨 초안에 차례로 쌓고(처음 편집 때 USB DB 지문이 base), 하나 빼기·초안 버리기를 한다")
    func draftAppendDiscard() async throws {
        defer { cleanUp() }
        let (usb, _, actions) = await setUp()
        let staged = UsbEditTestData.localRow("djc-1")
        let streaming = UsbEditTestData.localRow("77", folder: "spotify:x")
        await actions.addTracks([UsbEditTestData.localRow("11"), staged, streaming, UsbEditTestData.localRow("12")], to: .collection(volumeKey: key))
        #expect(host.toast?.title == UsbEditActions.Text.appendedTitle)
        #expect(host.toast?.detail == "\(image.name) · " + UsbEditText.describe(.addTracks(localContentIDs: ["11", "12"], playlist: nil), library: nil))
        let usbRows = UsbLibraryRows.collection(library: try #require(usb.libraries[key]), volumeKey: key, mountPoint: image.mountPoint, badges: [:])
        await actions.removeTracks([usbRows[1]], volumeKey: key)
        names.answers = ["새 목록"]
        await actions.createPlaylist(isFolder: false, parent: nil, volumeKey: key)
        #expect(names.asked.first?.title == "B13T에 새 재생 목록")

        let saved = try #require(try draft())
        #expect(saved.edits == [.addTracks(localContentIDs: ["11", "12"], playlist: nil), .removeTracks(usbContentIDs: [2]),
                                .playlist(edit: .create(key: "k1", name: "새 목록", isFolder: false, parent: .root))])
        #expect(saved.base == UsbEditTestData.base)
        // 지문은 처음 편집 때만 뜬다(메인 액터 밖, USB 쓰기 창구)
        #expect(service.current.calls == ["draftBase"])
        #expect(usb.draftCounts[key] == 3)
        #expect(UsbSidebarModel.volumes(usb).first { $0.id == key }?.pendingCount == 3)
        #expect(UsbSidebarModel.volumes(usb).first { $0.id == key }?.pending == .pending(volumeKey: key))

        // 이름 창을 취소하면 더하지 않는다
        names.answers = []
        await actions.createPlaylist(isFolder: true, parent: nil, volumeKey: key)
        #expect(usb.draftCounts[key] == 3)

        // 보고 있던 편집과 그 자리의 편집이 다르면(그 사이 초안이 바뀜) 빼지 않는다
        await actions.removeEdit(2, volumeKey: key, matching: .removeTracks(usbContentIDs: [3]))
        #expect(try draft()?.edits.count == 3)
        // 편집 하나 빼기(편집 번호 1부터)
        await actions.removeEdit(2, volumeKey: key, matching: .removeTracks(usbContentIDs: [2]))
        #expect(try draft()?.edits.count == 2)
        #expect(try draft()?.edits.last == .playlist(edit: .create(key: "k1", name: "새 목록", isFolder: false, parent: .root)))
        #expect(usb.draftCounts[key] == 2)

        // 초안 버리기는 묻지 않고 바로 버린다(실행 취소로 되살린다)
        prompter.answer = false
        let shown = prompter.shown.count
        await actions.discardDraft(volumeKey: key)
        #expect(prompter.shown.count == shown)
        #expect(try draft() == nil)
        #expect((usb.draftCounts[key] ?? 0) == 0)
    }

    @Test("USB 초안 버리기는 편집 › 실행 취소로 되살리고(처음 base 그대로, 그 뒤 더한 편집은 뒤에), 실행 복귀로 다시 버린다")
    func discardDraftUndo() async throws {
        defer { cleanUp() }
        let (usb, _, base) = await setUp()
        let undo = UndoManager()
        undo.groupsByEvent = false
        var actions = base
        actions.undoManager = { undo }
        await actions.addTracks([UsbEditTestData.localRow("11")], to: .collection(volumeKey: key))
        await actions.removeTracks([UsbLibraryRows.collection(library: try #require(usb.libraries[key]), volumeKey: key,
                                                              mountPoint: image.mountPoint, badges: [:])[1]], volumeKey: key)
        let before = try #require(try draft())
        #expect(before.edits.count == 2)

        undo.beginUndoGrouping()
        await actions.discardDraft(volumeKey: key)
        undo.endUndoGrouping()
        #expect(try draft() == nil)
        #expect(undo.canUndo)
        #expect(undo.undoActionName == UsbEditActions.Text.discardActionName)

        // 버린 뒤 더한 편집은 되살린 편집 뒤에 남는다
        service.update { $0.base = UsbFingerprint(files: [:]) }
        await actions.addTracks([UsbEditTestData.localRow("12")], to: .collection(volumeKey: key))
        undo.undo()
        #expect(await waitUntil { usb.draftCounts[key] == 3 })
        let restored = try #require(try draft())
        #expect(restored.edits == before.edits + [.addTracks(localContentIDs: ["12"], playlist: nil)])
        #expect(restored.base == before.base)
        #expect(restored.createdAt == before.createdAt)
        #expect(prompter.shown.isEmpty)

        #expect(undo.canRedo)
        undo.redo()
        #expect(await waitUntil { (usb.draftCounts[key] ?? 0) == 0 })
        #expect(try draft() == nil)
        #expect(undo.canUndo)
    }

    // MARK: - 막힘 미리 판정

    /// 판정표(실물·임시 폴더 밖·목록 모양·곡 수)는 `UsbEditRulesTests`(DJCApplicationTests)가 본다. 여기서는 메뉴가 그 판정을 잇는지만 본다
    @Test("막힐 편집은 메뉴 옆에 이유를 보인다(동의 없는 실물은 막힘). 앱의 실물 USB는 막지 않는다")
    func blockedEditHelpText() async throws {
        defer { cleanUp() }
        let physical = FakeUsbVolume.physicalFAT32()
        let library = UsbEditTestData.mixedLibrary()
        let differ = UsbEditRules.Reason.entriesDiffer

        // 곡 목록 메뉴 'USB에 넣기 ▸': 앱에서는 실물 볼륨의 항목도 누를 수 있다(쓰기 확인 창이 동의를 받는다)
        let fixture = try historyFixture()
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("usbedit"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in })
        await store.load(snapshot: fixture.database)
        let (usb, _, actions) = await setUp(library, volumes: [image, physical], local: UsbEditTestData.localNewerOne)
        store.usb = usb
        store.selection = ["101"]
        _ = NSApplication.shared
        let coordinator = TrackListCoordinator(store: store, actions: .live(store: store))
        let table = NSTableView()
        table.dataSource = coordinator
        table.delegate = coordinator
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        coordinator.table = table
        coordinator.update(rows: store.displayRows, edited: [], selection: store.selection, sortOrder: [], snapshotURL: store.snapshotURL,
                           previewRevision: 0)
        table.selectRowIndexes(IndexSet(integer: try #require(store.displayRows.firstIndex { $0.track.id == "101" })), byExtendingSelection: false)
        let menu = coordinator.makeMenu()
        coordinator.menuNeedsUpdate(menu)
        let usbMenu = try #require(menu.items.first { $0.title == "USB에 넣기" }?.submenu)
        let imageMenu = try #require(usbMenu.items.first { $0.title == "B13T" }?.submenu)
        let physicalMenu = try #require(usbMenu.items.first { $0.title == physical.name }?.submenu)
        let imageCollection = try #require(imageMenu.items.first { $0.title == "컬렉션" })
        #expect(imageCollection.action != nil && imageCollection.toolTip == nil)
        #expect(imageMenu.items.first { $0.title == "다름" }?.toolTip == differ)
        #expect(imageMenu.items.first { $0.title == "다름" }?.action == nil)
        // 폴더는 하위 메뉴로, 그 안의 목록은 누를 수 있다
        #expect(imageMenu.items.first { $0.title == "폴더" }?.submenu?.items.first { $0.title == "폴더 안" }?.action != nil)
        let physicalCollection = try #require(physicalMenu.items.first { $0.title == "컬렉션" })
        #expect(physicalCollection.action != nil && physicalCollection.toolTip == nil)

        // 순서 바꾸기·로컬 변경 반영도 같은 판정: 앱에서는 실물 볼륨도 막지 않는다
        let physicalKey = physical.usbKey
        #expect(actions.moveBlockReason(4, by: -1, volumeKey: physicalKey) == nil)
        #expect(actions.moveBlockReason(4, by: -1, volumeKey: key) == nil)
        #expect(actions.updatableTracks(volumeKey: physicalKey) == [1])
        #expect(actions.refreshBlockReason(volumeKey: physicalKey) == nil)
        #expect(actions.refreshBlockReason(volumeKey: key) == nil)
        // 곡 목록의 USB 곡 메뉴(실물 볼륨 컬렉션)
        store.sidebar = .usb(.collection(volumeKey: physicalKey))
        coordinator.update(rows: store.displayRows, edited: [], selection: [], sortOrder: [], snapshotURL: store.snapshotURL, previewRevision: 0)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let usbTrackMenu = coordinator.makeMenu()
        coordinator.menuNeedsUpdate(usbTrackMenu)
        let refreshItem = try #require(usbTrackMenu.items.first { $0.title == "로컬 변경을 USB에 반영 (1곡)" })
        #expect(refreshItem.action != nil && refreshItem.toolTip == nil)
        store.sidebar = .usb(.collection(volumeKey: key))
        coordinator.update(rows: store.displayRows, edited: [], selection: [], sortOrder: [], snapshotURL: store.snapshotURL, previewRevision: 0)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let imageTrackMenu = coordinator.makeMenu()
        coordinator.menuNeedsUpdate(imageTrackMenu)
        let imageRefresh = try #require(imageTrackMenu.items.first { $0.title == "로컬 변경을 USB에 반영 (1곡)" })
        #expect(imageRefresh.action != nil && imageRefresh.toolTip == nil)
        store.sidebar = .filter(.all)
        withExtendedLifetime(table) {}
    }

    // MARK: - 볼륨이 빠져도 초안

    @Test("볼륨이 빠져 있어도 초안은 쌓이고 대기 목록이 남는다. 쓰기만 막힌다")
    func volumeAbsentStillDrafts() async throws {
        defer { cleanUp() }
        let (usb, usbHost, actions) = await setUp()
        await actions.addTracks([UsbEditTestData.localRow("11")], to: .playlist(volumeKey: key, id: 10))
        #expect(usb.draftCounts[key] == 1)
        usbHost.mounted = []
        await usb.refresh()
        #expect(usb.volume(key) == nil)
        #expect(usb.contains(.pending(volumeKey: key)))
        #expect(!usb.contains(.collection(volumeKey: key)))
        #expect(usb.title(for: .pending(volumeKey: key)) == "B13T · USB 쓰기 대기")

        // USB를 읽지 않고(지문도 뜨지 않고) 초안에 더한다
        await actions.append(.removeTracks(usbContentIDs: [3]), to: key)
        #expect(try draft()?.edits == [.addTracks(localContentIDs: ["11"], playlist: .id("10")), .removeTracks(usbContentIDs: [3])])
        #expect(service.current.calls == ["draftBase"])
        #expect(usb.draftCounts[key] == 2)
        // 사이드바: 연결 안 됨 + 대기 목록, 편집 대상에도 남는다(연결 안 됨)
        let row = try #require(UsbSidebarModel.volumes(usb).first { $0.id == key })
        #expect(row.status != nil)
        #expect(row.pending == .pending(volumeKey: key) && row.pendingCount == 2)
        #expect(row.collection == nil && !row.canEject)
        #expect(actions.targets.map(\.volumeKey) == [key])
        #expect(actions.targets.first?.isConnected == false)
        #expect(actions.blockReason(.removeTracks(usbContentIDs: [1]), volumeKey: key) == nil)

        // 쓰기만 막힌다: 미리 보기·쓰기를 부르지 않고 연결하라고 알린다
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { false })
        await coordinator.writeDraft(volumeKey: key, database: nil, share: nil)
        #expect(await coordinator.previewDraft(volumeKey: key, database: nil, share: nil) == nil)
        #expect(service.current.calls == ["draftBase"])
        #expect(prompter.shown.isEmpty && host.toast?.title == UsbWriteFlow.Text.notWrittenTitle
            && host.toast?.detail == UsbWriteFlow.Text.connectFirstDetail)
        let model = UsbPendingModel(volumeName: "B13T", isConnected: false, edits: try #require(try draft()).edits,
                                    library: usb.editLibrary(key), summary: nil, busy: false, blockReason: { _, _ in nil })
        #expect(!model.canWrite)
        #expect(model.writeHelp == UsbWriteFlow.Text.connectFirstDetail)

        // 다시 붙으면 대기 목록이 그 볼륨 아래로 돌아간다
        usbHost.mounted = [image]
        await usb.refresh()
        #expect(usb.volume(key) != nil)
        #expect(UsbSidebarModel.volumes(usb).filter { $0.id == key }.count == 1)
        #expect(UsbSidebarModel.volumes(usb).first { $0.id == key }?.status == nil)
        #expect(usb.draftCounts[key] == 2)
    }

    // MARK: - 끌어다 놓기

    @Test("로컬 곡을 USB 목록에 끌어다 놓으면 그 목록 끝에 넣는 곡 더하기 편집이 된다")
    func dragToUsbPlaylistCreatesAddTracksEdit() async throws {
        defer { cleanUp() }
        let (_, _, actions) = await setUp(UsbEditTestData.mixedLibrary())
        let rows = ["11": UsbEditTestData.localRow("11"), "12": UsbEditTestData.localRow("12"), "djc-9": UsbEditTestData.localRow("djc-9")]
        #expect(actions.acceptsDrop(on: .playlist(volumeKey: key, id: 10)))
        #expect(actions.acceptsDrop(on: .collection(volumeKey: key)))
        // 폴더·대기 목록·없는 목록에는 놓지 않는다
        #expect(!actions.acceptsDrop(on: .playlist(volumeKey: key, id: 5)))
        #expect(!actions.acceptsDrop(on: .pending(volumeKey: key)))
        #expect(!actions.acceptsDrop(on: .playlist(volumeKey: key, id: 99)))

        #expect(await actions.drop(["11", "djc-9", "12", "11", "usb:\(key):1", "없음"], on: .playlist(volumeKey: key, id: 10), rows: rows))
        #expect(try draft()?.edits == [.addTracks(localContentIDs: ["11", "12"], playlist: .id("10"))])
        #expect(host.toast?.detail == "\(image.name) · " + UsbEditText.describe(.addTracks(localContentIDs: ["11", "12"], playlist: .id("10")), library: UsbEditTestData.mixedLibrary()))
        #expect(await actions.drop(["12"], on: .collection(volumeKey: key), rows: rows))
        #expect(try draft()?.edits.last == .addTracks(localContentIDs: ["12"], playlist: nil))
        // 막힐 목록(두 형식의 항목이 다름)이나 넣을 곡이 없으면 초안에 더하지 않는다
        #expect(await actions.drop(["11"], on: .playlist(volumeKey: key, id: 4), rows: rows) == false)
        #expect(host.toast?.kind == .warning)
        #expect(host.toast?.detail == UsbEditRules.Reason.entriesDiffer)
        #expect(await actions.drop(["djc-9"], on: .playlist(volumeKey: key, id: 10), rows: rows) == false)
        #expect(try draft()?.edits.count == 2)
    }

    // MARK: - 로컬 변경 반영

    @Test("로컬 변경을 USB에 반영: 로컬이 더 새로운 곡만, 바뀐 부분만 갱신한다")
    func refreshLocalChangesOnlyUpdatable() async throws {
        defer { cleanUp() }
        let tracks = [
            UsbTestData.track(1, info: "3", analysis: "2", cue: "1"),
            UsbTestData.track(2, hasModified: 1),
            UsbTestData.track(3, masterContentId: 999),
            UsbTestData.track(4, info: "5", analysis: "5", cue: "5"),
            UsbTestData.track(5, info: "3", analysis: "2", cue: "1"),
        ]
        let local = LocalLibraryKeys(localDBID: UsbTestData.localDBID, tracks: [
            UsbLocalTrackKey(contentID: "11", masterSongID: "501", fileNameL: "test1.mp3"),
            UsbLocalTrackKey(contentID: "12", masterSongID: "502", fileNameL: "test2.mp3"),
            UsbLocalTrackKey(contentID: "14", masterSongID: "504", fileNameL: "test4.mp3"),
            UsbLocalTrackKey(contentID: "15", masterSongID: "505", fileNameL: "test5.mp3"),
        ], counters: [
            "11": LocalTrackCounters(information: "4", analysis: "2", cue: "1"),
            "12": LocalTrackCounters(information: "3", analysis: "2", cue: "1"),
            "14": LocalTrackCounters(information: "5", analysis: "5", cue: "5"),
            "15": LocalTrackCounters(information: "3", analysis: "3", cue: "2"),
        ])
        let (usb, _, actions) = await setUp(UsbTestData.library(tracks: tracks), local: local)
        #expect(actions.updatableTracks(volumeKey: key) == [1, 5])

        await actions.refreshLocalChanges(volumeKey: key)
        // 곡 1은 곡 정보만, 곡 5는 분석·큐만 바뀌었다: 바뀐 부분이 같은 곡끼리 한 편집(목록 순서)
        #expect(try draft()?.edits == [.refreshTracks(usbContentIDs: [1], parts: [.info, .artwork]),
                                       .refreshTracks(usbContentIDs: [5], parts: [.grid, .cues])])
        #expect(actions.refreshEdits(volumeKey: key) == [.refreshTracks(usbContentIDs: [1], parts: [.info, .artwork]),
                                                         .refreshTracks(usbContentIDs: [5], parts: [.grid, .cues])])
        #expect(host.toast?.detail == "\(image.name) · " + UsbEditText.describe(.refreshTracks(usbContentIDs: [1, 5], parts: []), library: nil))
        #expect(usb.draftCounts[key] == 2)

        // 고른 곡만: 갱신할 곡이 없으면 더하지 않고 알린다
        let rows = UsbLibraryRows.collection(library: try #require(usb.libraries[key]), volumeKey: key, mountPoint: image.mountPoint,
                                             badges: usb.syncBadges[key] ?? [:])
        await actions.refreshLocalChanges(volumeKey: key, rows: [rows[1], rows[2], rows[3]])
        #expect(try draft()?.edits.count == 2)
        #expect(host.toast?.title == UsbEditActions.Text.nothingNewerTitle)
        await actions.refreshLocalChanges(volumeKey: key, rows: [rows[0], rows[1]])
        #expect(try draft()?.edits.last == .refreshTracks(usbContentIDs: [1], parts: [.info, .artwork]))
    }

    // MARK: - 재생 목록 순서

    @Test("위로·아래로 옮기기는 초안의 순서 편집을 따른다: 이어 누르면 한 편집으로 고치고, 제자리로 돌아오면 뺀다")
    func movePlaylistFollowsDraft() async throws {
        defer { cleanUp() }
        let library = UsbEditTestData.siblingLibrary()
        let (usb, _, actions) = await setUp(library)
        func order(_ id: Int) -> [PlaylistRef]? {
            UsbEditRules.siblingOrder(of: .id(String(id)), library: library, edits: usb.draftEdits[key] ?? [])
        }
        func reorder(_ id: Int, _ index: Int) -> UsbLibraryEdit { .playlist(edit: .reorder(playlist: .id(String(id)), index: index)) }
        #expect(actions.siblingPosition(2, volumeKey: key)! == (1, 4))
        #expect(actions.canMovePlaylist(2, by: -1, volumeKey: key))
        #expect(!actions.canMovePlaylist(1, by: -1, volumeKey: key))
        #expect(!actions.canMovePlaylist(7, by: 1, volumeKey: key))

        // B↑: 맨 앞으로. 한 번 더 누를 수 없다(초안의 자리를 본다)
        await actions.movePlaylist(2, by: -1, volumeKey: key)
        #expect(try draft()?.edits == [reorder(2, 0)])
        #expect(host.toast?.detail == "\(image.name) · " + UsbEditText.describe(reorder(2, 0), library: library))
        #expect(actions.siblingPosition(2, volumeKey: key)! == (0, 4))
        #expect(!actions.canMovePlaylist(2, by: -1, volumeKey: key))
        await actions.movePlaylist(2, by: -1, volumeKey: key)
        #expect(try draft()?.edits == [reorder(2, 0)])

        // B↓: 제자리로 돌아와 순서 편집을 뺀다(초안이 비면 지운다)
        await actions.movePlaylist(2, by: 1, volumeKey: key)
        #expect(try draft() == nil)
        #expect(usb.draftCounts[key] == nil)
        #expect(actions.siblingPosition(2, volumeKey: key)! == (1, 4))

        // C↑↑: 한 편집으로 고친다
        await actions.movePlaylist(3, by: -1, volumeKey: key)
        await actions.movePlaylist(3, by: -1, volumeKey: key)
        #expect(try draft()?.edits == [reorder(3, 0)])
        #expect(host.toast?.title == UsbEditActions.Text.changedQueueTitle)
        #expect(order(3) == [.id("3"), .id("1"), .id("2"), .id("7")])

        // 다른 목록은 앞 편집을 적용한 자리에서 옮긴다: A(지금 2번째) ↓ → 3번째
        await actions.movePlaylist(1, by: 1, volumeKey: key)
        #expect(try draft()?.edits == [reorder(3, 0), reorder(1, 2)])
        #expect(order(1) == [.id("3"), .id("2"), .id("1"), .id("7")])

        // 초안에서 만들기는 끝에 붙고, 다른 폴더로 옮기면 그 폴더 끝으로 간다(계획과 같은 규칙)
        await actions.append(.playlist(edit: .create(key: "n1", name: "새 목록", isFolder: false, parent: .root)), to: key)
        await actions.append(.playlist(edit: .move(playlist: .id("2"), into: .id("7"))), to: key)
        #expect(order(1) == [.id("3"), .id("1"), .id("7"), .new("n1")])
        #expect(actions.siblingPosition(1, volumeKey: key)! == (1, 4))
        #expect(actions.siblingPosition(2, volumeKey: key)! == (0, 1))
        #expect(!actions.canMovePlaylist(2, by: 1, volumeKey: key))
        // 초안에서 지운 목록은 옮길 수 없다
        await actions.append(.playlist(edit: .delete(playlist: .id("3"))), to: key)
        #expect(actions.siblingPosition(3, volumeKey: key) == nil)
        #expect(!actions.canMovePlaylist(3, by: 1, volumeKey: key))
        #expect(order(1) == [.id("1"), .id("7"), .new("n1")])
    }

    // MARK: - 목록에서 빼기

    @Test("USB 목록에서 고른 줄 → 그 목록에서 빼기 편집: 줄의 자리(1부터)와 그 자리의 곡, 같은 자리는 한 번")
    func removeFromPlaylistMapsOccurrences() async throws {
        defer { cleanUp() }
        let (usb, _, actions) = await setUp()
        let library = try #require(usb.libraries[key])
        // 목록 10: 1번째 곡 2, 2번째 곡 1, 3번째 곡 2
        let rows = UsbLibraryRows.playlist(10, library: library, volumeKey: key, mountPoint: image.mountPoint, badges: [:])
        let other = UsbLibraryRows.playlist(10, library: library, volumeKey: "OTHER", mountPoint: "/Volumes/OTHER", badges: [:])
        let collection = UsbLibraryRows.collection(library: library, volumeKey: key, mountPoint: image.mountPoint, badges: [:])
        let edit = UsbEditActions.removeFromPlaylistEdit([rows[2], rows[0], rows[2], other[1], UsbEditTestData.localRow("11")],
                                                         volumeKey: key, playlist: 10)
        #expect(edit == .playlist(edit: .removeTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 1, contentID: "2"), PlaylistEntry(trackNo: 3, contentID: "2")])))
        // 자리가 없는 줄(컬렉션·다른 볼륨·로컬 곡)만이면 편집이 없다
        #expect(UsbEditActions.removeFromPlaylistEdit(collection + other + [UsbEditTestData.localRow("11")], volumeKey: key, playlist: 10) == nil)

        await actions.removeFromPlaylist([rows[1]], volumeKey: key, playlist: 10)
        #expect(try draft()?.edits == [.playlist(edit: .removeTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 2, contentID: "1")]))])
        let removal = try #require(try draft()?.edits.first)
        #expect(host.toast?.detail == "\(image.name) · " + UsbEditText.describe(removal, library: library))
        // 고를 때의 자리와 곡이 USB와 다르면(다시 읽기 전 줄) 더하지 않는다. 자리는 앞 초안을 얹은 목록([2, 2])으로 본다(#240)
        let stale = UsbLibraryEdit.playlist(edit: .removeTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 3, contentID: "2")]))
        #expect(actions.blockReason(stale, volumeKey: key) == UsbEditRules.Reason.entryChanged(3))
        let projected = UsbLibraryEdit.playlist(edit: .removeTracks(playlist: .id("10"), entries: [PlaylistEntry(trackNo: 2, contentID: "2")]))
        #expect(actions.blockReason(projected, volumeKey: key) == nil)
    }

    // MARK: - 초안 한 줄로

    @Test("초안 고치기는 볼륨마다 한 줄로 선다: 처음 지문을 뜨는 동안 더한 편집도 차례대로, 쓰는 동안 더한 편집은 쓰기 뒤에 더한다")
    func draftMutationsAreSerialized() async throws {
        defer { cleanUp() }
        let (usb, _, actions) = await setUp()
        let gate = TestGate()
        defer { gate.open() }
        service.update { $0.onDraftBase = { gate.pass() } }
        let first = UsbLibraryEdit.removeTracks(usbContentIDs: [1]), second = UsbLibraryEdit.removeTracks(usbContentIDs: [2])
        let firstTask = Task { await actions.append(first, to: key) }
        try #require(await waitUntil { gate.arrivals == 1 })
        let queuedBeforeSecond = usb.draftQueueLength(key)
        let secondTask = Task { await actions.append(second, to: key) }
        // 앞 편집이 지문을 뜨는 동안 뒤 편집은 줄에 서서 기다린다(줄 밖에서 돌면 지문을 다시 뜨러 문에 온다)
        try #require(await waitUntil { usb.draftQueueLength(key) > queuedBeforeSecond || gate.arrivals > 1 })
        gate.open()
        let added = await (firstTask.value, secondTask.value)
        #expect(added.0 && added.1)
        #expect(try draft()?.edits == [first, second])
        #expect(service.current.calls == ["draftBase"])
        #expect(usb.draftCounts[key] == 2)
        #expect(!gate.timedOut)

        // 쓰는 동안 더한 편집: 쓰기가 초안을 다시 저장한 뒤에 더한다(잃지 않는다)
        let writing = TestGate()
        defer { writing.open() }
        let drafts = drafts, key = key
        service.update {
            $0.editSummary = UsbTestData.editSummary(editCount: 2)
            // 실제 세션처럼 처음 읽은 초안에서 막힌 편집만 남긴다(여기서는 모두 씀 → 초안 지움)
            $0.onWriteEdit = {
                let store = UsbDraftStore(directory: drafts)
                let loaded = try? store.load(volumeKey: key)
                writing.pass()
                if loaded != nil { try? store.discard(volumeKey: key) }
            }
        }
        prompter.answer = true
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { false })
        let write = Task { await coordinator.writeDraft(volumeKey: key, database: nil, share: nil) }
        // 쓰기가 줄 안에서 초안을 읽고 문에 멈출 때까지 기다린다(그 전에 더한 편집은 다시 미리 보기로 간다 — 다음 시험)
        try #require(await waitUntil { writing.arrivals == 1 })
        let queuedBeforeDuring = usb.draftQueueLength(key)
        let during = UsbLibraryEdit.playlist(edit: .rename(playlist: .id("10"), name: "새 이름"))
        let duringTask = Task { await actions.append(during, to: key) }
        // 줄에 서서 쓰기를 기다린다(줄 밖에서 돌면 초안에 바로 나타나고, 쓰기가 그것까지 지운다)
        try #require(await waitUntil { usb.draftQueueLength(key) > queuedBeforeDuring || ((try? draft()) ?? nil)?.edits.contains(during) == true })
        writing.open()
        let (_, appended) = await (write.value, duringTask.value)
        #expect(appended)
        #expect(try draft()?.edits == [during])
        #expect(usb.draftCounts[key] == 1)
        #expect(!writing.timedOut)
    }

    // MARK: - 확인한 것만 쓴다

    @Test("미리 보기(초안 줄 밖) 뒤 더한 편집은 확인 없이 쓰지 않는다: 쓰기 줄에서 초안이 확인한 것과 다르면 지금 초안으로 다시 미리 보고 묻는다")
    func draftChangedAfterPreviewIsConfirmedAgain() async throws {
        defer { cleanUp() }
        let (usb, _, actions) = await setUp()
        let first = UsbLibraryEdit.removeTracks(usbContentIDs: [1])
        #expect(await actions.append(first, to: key))
        let written = EditLog()
        let drafts = drafts, key = key
        service.update {
            // 실제 세션처럼 그때 초안을 읽어 모두 쓴다(→ 초안 지움)
            $0.onWriteEdit = {
                let store = UsbDraftStore(directory: drafts)
                let loaded = try? store.load(volumeKey: key)
                written.append(loaded?.edits ?? [])
                if loaded != nil { try? store.discard(volumeKey: key) }
            }
        }
        let coordinator = UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { false })
        let changed = UsbWriteFlow.draftChangedText

        // 미리 보는 동안 편집을 더하고 다시 묻는 확인 창에서 취소하면 아무것도 쓰지 않는다(초안은 그대로)
        let previewing = TestGate()
        defer { previewing.open() }
        service.update { $0.onPreviewEdit = { previewing.pass() } }
        prompter.answers = [true, false]
        let write = Task { await coordinator.writeDraft(volumeKey: key, database: nil, share: nil) }
        try #require(await waitUntil { previewing.arrivals == 1 })
        let during = UsbLibraryEdit.playlist(edit: .rename(playlist: .id("10"), name: "새 이름"))
        #expect(await actions.append(during, to: key))
        previewing.open()
        await write.value
        #expect(written.all.isEmpty && !service.current.wrote)
        #expect(prompter.shown.count == 2)
        #expect(prompter.shown.first?.text.hasPrefix(changed) == false)
        #expect(prompter.shown.last?.text.hasPrefix(changed) == true)
        #expect(try draft()?.edits == [first, during])
        #expect(usb.draftCounts[key] == 2)
        #expect(!previewing.timedOut)

        // 다시 확인하면 다시 미리 본 초안(그 사이 더한 편집 포함)을 쓴다
        let again = TestGate()
        defer { again.open() }
        service.update { $0.onPreviewEdit = { again.pass() } }
        prompter.answers = [true, true]
        service.update { $0.calls = [] }
        let rewrite = Task { await coordinator.writeDraft(volumeKey: key, database: nil, share: nil) }
        try #require(await waitUntil { again.arrivals == 1 })
        let later = UsbLibraryEdit.playlist(edit: .rename(playlist: .id("10"), name: "나중 이름"))
        #expect(await actions.append(later, to: key))
        again.open()
        await rewrite.value
        #expect(written.all == [[first, during, later]])
        #expect(service.current.previewedBeforeWrite)
        #expect(prompter.shown.count == 4)
        #expect(prompter.shown.last?.text.hasPrefix(changed) == true)
        #expect(try draft() == nil)
        #expect(usb.draftCounts[key] == nil)
        #expect(!again.timedOut)
    }

    // MARK: - 초안 base

    @Test("초안 base는 그 자리의 볼륨을 다시 본 뒤에만 뜬다: 다른 볼륨이면 USB 파일을 읽지 않고, 초안은 빈 base로 쌓인다")
    func draftBaseRechecksVolume() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-usbbase-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            cleanUp()
        }
        try FileManager.default.createDirectory(at: root.appending(path: "usb/PIONEER/rekordbox"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: root.appending(path: "usb/PIONEER/rekordbox/exportLibrary.db"))
        var volume = image
        volume.mountPoint = root.appending(path: "usb").path
        let fileSystem = FaultyUsbFileSystem(root: root.appending(path: "usb"))
        func service(recheck: @escaping @Sendable (UsbVolumeInfo) throws -> UsbVolumeInfo) -> UsbWriteService {
            var service = UsbAppComposition.writeService(policy: .diskImagesOnly,
                                                         paths: UsbWritePaths(backups: root.appending(path: "b"), sessions: root.appending(path: "s"),
                                                                              staging: root.appending(path: "t")),
                                                         localCopies: root.appending(path: "c"), drafts: root.appending(path: "d"), fileSystem: fileSystem)
            service.recheck = recheck
            return service
        }
        // 같은 자리에 다른 볼륨이 붙었다
        let changed = #expect(throws: UsbError.self) {
            try service { _ in throw UsbError.readFailed(detail: "volumeChanged") }.draftBase(volume)
        }
        #expect(changed.map { if case .readFailed("volumeChanged") = $0 { true } else { false } } == true)
        #expect(fileSystem.calls.isEmpty)
        // 같은 볼륨이면 DB 파일 지문을 뜬다
        let base = try service { $0 }.draftBase(volume)
        #expect(base.files.keys.contains("PIONEER/rekordbox/exportLibrary.db"))
        #expect(!fileSystem.calls.isEmpty)

        // 지문을 뜨지 못하면 초안은 빈 base로 쌓인다(쓸 때 지금 USB 상태로 다시 계획한다)
        let (_, _, actions) = await setUp()
        self.service.update { $0.baseError = .readFailed(detail: "volumeChanged") }
        #expect(await actions.append(.removeTracks(usbContentIDs: [1]), to: key))
        #expect(try draft()?.base == UsbFingerprint(files: [:]))
    }
}
