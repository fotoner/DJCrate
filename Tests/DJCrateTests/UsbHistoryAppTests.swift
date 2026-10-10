@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import RekordboxFixtures
import Foundation
import RekordboxKit
import Testing

/// USB 기기 재생 기록 보존(#43): USB를 읽으면 새 기록을 보존하고 사이드바 트리·곡 목록에 rekordbox 기록과 섞는다.
/// 보존 유스케이스(`ArchiveUsbHistories`)의 파일은 임시 폴더로 주입하고(사용자 폴더를 쓰지 않는다), 시계는 고정한다. USB는 가짜 호스트의 합성 라이브러리다.
@MainActor
@Suite("USB 재생 기록 보존과 재생 기록 트리(앱)")
struct UsbHistoryAppTests {
    /// 초 단위로 떨어지는 고정 시각(보존 파일의 날짜는 초 아래를 버린다). 어느 시간대에서도 2026년 9월이다
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "djc-usbhistory-app-\(UUID().uuidString)")
    }

    static func historiesFolder(_ scratch: URL) -> URL { scratch.appending(path: "usb-histories") }

    /// 합성 기록 사본(`historyFixture`, 곡 101·102)과 짝짓는 로컬 키: USB 곡 1 ↔ 101, 2 ↔ 102. 곡 3은 짝이 없다
    static func localKeys() -> LocalLibraryKeys {
        LocalLibraryKeys(localDBID: UsbTestData.localDBID, tracks: [
            UsbLocalTrackKey(contentID: "101", masterSongID: "501", fileNameL: "test1.mp3"),
            UsbLocalTrackKey(contentID: "102", masterSongID: "502", fileNameL: "test2.mp3"),
        ], counters: [:])
    }

    /// OneLibrary만 있는 USB: 기기 기록 하나(2 → 1 → 3 → 1, 같은 곡을 다시 튼 줄 포함). 곡 3은 로컬에 없다
    static func usbLibrary() -> UsbLibrary {
        let formats: Set<UsbFormat> = [.oneLibrary]
        var library = UsbTestData.library(formats: formats, tracks: [
            UsbTestData.track(1, formats: formats), UsbTestData.track(2, formats: formats),
            UsbTestData.track(3, formats: formats, masterContentId: 999),
        ])
        library.histories = [UsbHistory(format: .oneLibrary, id: 1, name: "HISTORY 001", entries: [2, 1, 3, 1])]
        return library
    }

    /// rekordbox처럼 가져온 날로 지은 이름(이 Mac의 달력)
    static func expectedName() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return String(format: "HISTORY %04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 읽지 않은 시험 저장소(설정·초안 폴더는 저장소마다 새 시험 영역). `histories`는 보존 파일이다(주지 않으면 시험 기본처럼 보존하지 않는다).
    /// 시계는 고정한다
    static func newStore(_ fixture: RekordboxFixture, histories: UsbHistoryFiles? = nil) -> LibraryStore {
        let fixed = now
        return LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("usbhistory"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 ports: { ports in
                                     ports.usbHistories = histories
                                     ports.now = { fixed }
                                 })
    }

    static func libraryStore(_ fixture: RekordboxFixture, histories: UsbHistoryFiles? = nil) async throws -> LibraryStore {
        // 보존본은 주입한 짝만 믿지 않고 실제로 연 사본의 키로 다시 검증한다.
        try fixture.execute("UPDATE djmdProperty SET DBID = '424242'")
        try fixture.execute("UPDATE djmdContent SET MasterDBID = '424242' WHERE ID IN ('101', '102')")
        try fixture.execute("UPDATE djmdContent SET MasterSongID = '501', FileNameL = 'test1.mp3' WHERE ID = '101'")
        try fixture.execute("UPDATE djmdContent SET MasterSongID = '502', FileNameL = 'test2.mp3' WHERE ID = '102'")
        let store = newStore(fixture, histories: histories)
        await store.load(snapshot: fixture.database)
        return store
    }

    /// 임시 폴더의 보존 파일(조립 지점과 같은 실제 파일 구현). 저장소를 만들 때 라이브러리 포트로 준다. `fileSystem`으로 저장 실패를 만든다
    static func histories(_ scratch: URL, home: URL? = nil, fileSystem: any UsbFileSystem = PosixUsbFileSystem()) -> UsbHistoryFiles {
        .live(directory: historiesFolder(scratch), home: home ?? scratch.appending(path: "home"), fileSystem: fileSystem)
    }

    /// 앱과 같은 연결(`UsbAppSetup.connectHistories`)을 붙이고, 보존한 기록을 다 읽을 때까지 기다린다(보존 파일은 저장소를 만들 때 준다)
    static func connect(_ store: LibraryStore, _ usb: UsbStore) async {
        store.usb = usb
        UsbAppSetup.connectHistories(store: store, usb: usb)
        await store.history.waitForHistoryImports()
    }

    /// 기록 하나가 든 USB를 읽을 수 있게 둔 가짜 호스트
    static func host() -> (FakeUsbHost, UsbVolumeInfo) {
        let volume = FakeUsbVolume.diskImageFAT32()
        let host = FakeUsbHost([volume])
        host.serve(volume, library: usbLibrary())
        return (host, volume)
    }

    @Test("USB 기록을 보존해 가져온 날의 연·월에 넣고, 고르면 짝 있는 곡은 컬렉션 줄·짝 없는 곡은 읽기 전용 줄로 재생 순서대로 보인다")
    func importsAndShowsArchivedHistory() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let store = try await Self.libraryStore(fixture, histories: Self.histories(scratch))
        let (host, volume) = Self.host()
        let usb = UsbTestData.store(host, local: Self.localKeys())
        await Self.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()

        #expect(store.history.archivedHistories.count == 1)
        let archived = try #require(store.history.archivedHistories.first)
        #expect(archived.name == Self.expectedName())
        #expect(archived.source.volumeKey == volume.usbKey && archived.source.historyName == "HISTORY 001")
        #expect(archived.entries.map(\.contentID) == ["102", "101", nil, "101"])
        #expect(archived.entries.map(\.trackNumber) == [1, 2, 3, 4])
        #expect(FileManager.default.fileExists(atPath: Self.historiesFolder(scratch).appending(path: "\(archived.id).json").path))
        #expect(store.toast?.kind == .success)
        #expect(store.toast?.title == "USB에서 재생 기록 1개를 가져왔습니다")
        // 같은 곡(101)이 두 번 든 기록이고 앱의 쓰기 관문도 닫혀 있어 쓰기 대기에는 올리지 않는다
        #expect(store.toast?.detail == volume.name)
        #expect(store.history.pendingHistories.isEmpty && store.history.pendingHistoryIDs.isEmpty)

        // 트리: rekordbox 기록(2025년)과 섞어 오래된 것부터, 보존 기록은 가져온 날의 연·월 아래
        let parts = Calendar.current.dateComponents([.year, .month], from: Self.now)
        let year = try #require(parts.year), month = try #require(parts.month)
        let folders = [HistoryTree.yearID(year), HistoryTree.monthID(year: year, month: month)]
        #expect(store.history.historyTree.years.map(\.year) == [2025, year])
        #expect(store.history.historyTree.folderIDs(containing: archived.id) == folders)
        #expect(store.history.historyTree.folderIDs(containing: "new-a") == [HistoryTree.yearID(2025), HistoryTree.monthID(year: 2025, month: 2)])
        #expect(store.history.historyTree.undated.map(\.id) == ["undated"])
        // 새로 가져온 기록이 보이게 그 연·월을 펼친다
        #expect(store.history.expandedHistoryFolders.isSuperset(of: folders))
        // 곡 수는 보일 줄 수(컬렉션에 없는 곡도 읽기 전용 줄로 센다)
        #expect(store.history.historyCount(archived.id) == 4)

        store.sidebar = .history(archived.id)
        #expect(store.sidebarTitle == archived.name)
        #expect(store.sortOrder.isEmpty)
        let rows = store.displayRows
        #expect(rows.map(\.track.id) == ["102", "101", "\(HistoryStore.archivedTrackIDPrefix)\(archived.id):3", "101"])
        #expect(rows.map(\.historyTrackNumber) == [1, 2, 3, 4])
        #expect(rows.map(\.isUsb) == [false, false, true, false])
        #expect(Set(rows.map(\.id)).count == 4)
        let unmatched = try #require(rows.dropFirst(2).first)
        #expect(unmatched.title == "시험 곡 3" && unmatched.artist == "시험 아티스트")
        // 로컬 share를 가리키지 않게 분석·아트워크 경로는 비운다
        #expect(unmatched.track.analysisDataPath == nil && unmatched.track.imagePath == nil)
        // 읽기 전용 줄은 편집·덱 대상이 아니다. 반복 재생 줄을 함께 골라도 컬렉션 곡은 한 번만
        store.selection = Set(rows.map(\.id))
        #expect(store.selectedRows.map(\.id) == ["102", "101"])
        // 덱 불러오기는 막지 않고 누르면 짝이 없다고 알린다(#255, 보존 기록 줄은 USB 볼륨 곡으로 풀지 않는다)
        store.selection = [unmatched.id]
        #expect(store.canLoadSelectionToDeck)
        store.loadSelectionToDeck()
        #expect(store.deckTrackID == nil)
        #expect(store.staging.stagingMessage?.text == "로컬 rekordbox에 없는 USB 곡이라 덱에 올릴 수 없으니 rekordbox 컬렉션에 먼저 더하세요")

        // 재생 목록으로 만들기: 짝 있는 곡만 튼 순서대로(같은 곡은 처음 한 번), 이름은 기록 이름
        store.playlists.createPlaylist(fromHistory: archived.id)
        let created = try #require(store.playlists.playlistTree.first?.id)
        #expect(store.playlists.playlistItem(created)?.name == archived.name)
        #expect(store.playlists.playlistItem(created)?.trackIDs == ["102", "101"])
    }

    @Test("같은 USB를 다시 읽거나 앱을 다시 켜도 보존 기록이 늘지 않고 알리지 않는다")
    func rereadDoesNotDuplicate() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let store = try await Self.libraryStore(fixture, histories: Self.histories(scratch))
        let (host, _) = Self.host()
        let usb = UsbTestData.store(host, local: Self.localKeys())
        await Self.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()
        let first = store.history.archivedHistories
        #expect(first.count == 1)

        store.toast = nil
        await usb.refresh()
        await store.history.waitForHistoryImports()
        await usb.localLibraryChanged()
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistories == first)
        #expect(store.toast == nil)

        // 앱을 다시 켠 것처럼: 새 스토어가 보존 폴더에서 읽고, 같은 USB를 읽어도 더하지 않는다
        let reopened = try await Self.libraryStore(fixture, histories: Self.histories(scratch))
        let usbAgain = UsbTestData.store(host, local: Self.localKeys())
        await Self.connect(reopened, usbAgain)
        #expect(reopened.history.archivedHistories == first)
        await usbAgain.refresh()
        await reopened.history.waitForHistoryImports()
        #expect(reopened.history.archivedHistories == first)
        #expect(reopened.toast == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.historiesFolder(scratch).path).filter { $0.hasSuffix(".json") }
        #expect(files.count == 1)
    }

    @Test("시작 중 로컬 키를 몰라도 먼저 보존하고 USB를 뺀 뒤 사본을 읽으면 보존본의 짝을 채운다")
    func preservesBeforeLocalKeysAndRematchesAfterDisconnect() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let store = Self.newStore(fixture, histories: Self.histories(scratch))
        let (host, volume) = Self.host()
        let keys = LocalLibraryKeysCache()
        let usb = UsbStore(host: host, readPolicy: .all, writeService: FakeUsbWriteService(), localLibrary: { keys.current })
        usb.isScratchMount = { _ in true }
        await Self.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()
        #expect(usb.libraries[volume.usbKey] != nil)
        let original = try #require(store.history.archivedHistories.first)
        #expect(original.entries.allSatisfy { $0.contentID == nil })
        #expect(FileManager.default.fileExists(atPath: Self.historiesFolder(scratch).appending(path: "\(original.id).json").path))

        host.mounted = []
        await usb.refresh()
        #expect(usb.libraries.isEmpty)
        try fixture.execute("UPDATE djmdProperty SET DBID = '424242'")
        try fixture.execute("UPDATE djmdContent SET MasterDBID = '424242' WHERE ID IN ('101', '102')")
        try fixture.execute("UPDATE djmdContent SET MasterSongID = '501', FileNameL = 'test1.mp3' WHERE ID = '101'")
        try fixture.execute("UPDATE djmdContent SET MasterSongID = '502', FileNameL = 'test2.mp3' WHERE ID = '102'")
        await store.load(snapshot: fixture.database)

        keys.set(Self.localKeys())
        await usb.localLibraryChanged()
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistories.map(\.id) == [original.id])
        #expect(store.history.archivedHistories.first?.entries.map(\.contentID) == ["102", "101", nil, "101"])
        #expect(UsbHistoryStore(directory: Self.historiesFolder(scratch), home: scratch).load().histories.first?.entries.map(\.contentID)
                == ["102", "101", nil, "101"])
    }

    /// 숨김 판정(다른 날·짝 없는 항목은 남김, rekordbox 기록 하나에 보존본 하나)은 DJCDomainTests `UsbHistoryImportTests`·`UsbHistoryRulesTests`가 본다
    @Test("rekordbox도 같은 날 가져온 짝이 모두 있는 기록은 보존하되 트리에서 숨기고 알리지 않는다")
    func shadowedByRekordboxHistory() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let store = try await Self.libraryStore(fixture, histories: Self.histories(scratch))
        // rekordbox가 같은 USB 기록을 가져온 모양: 컬렉션에 있는 곡만 재생 순서대로, 연 › 월 폴더 아래
        store.history.histories.append(RekordboxHistory(id: "rb-usb", name: Self.expectedName(), dateCreated: String(Self.expectedName().dropFirst(8)) + " 23:00:00",
                                                folderNames: ["2026", "9"], seq: 1, entries: [
                                                    .init(id: "rb-1", contentID: "102", trackNumber: 1),
                                                    .init(id: "rb-2", contentID: "101", trackNumber: 2),
                                                    .init(id: "rb-3", contentID: "101", trackNumber: 3),
                                                ]))
        let (host, volume) = Self.host()
        var library = Self.usbLibrary()
        library.histories[0].entries = [2, 1, 1]
        host.serve(volume, library: library)
        let usb = UsbTestData.store(host, local: Self.localKeys())
        await Self.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()

        let archived = try #require(store.history.archivedHistories.first)
        #expect(store.history.shadowedArchiveIDs == [archived.id])
        #expect(store.history.historyTree.folderIDs(containing: archived.id).isEmpty)
        #expect(!store.history.historyTree.undated.contains { $0.id == archived.id })
        #expect(store.history.historyTree.folderIDs(containing: "rb-usb") == [HistoryTree.yearID(2026), HistoryTree.monthID(year: 2026, month: 9)])
        #expect(store.toast == nil)
        // 보존 파일은 남는다. rekordbox 기록이 없어지면 다시 보인다
        #expect(FileManager.default.fileExists(atPath: Self.historiesFolder(scratch).appending(path: "\(archived.id).json").path))
        store.history.histories.removeAll { $0.id == "rb-usb" }
        #expect(store.history.shadowedArchiveIDs.isEmpty)
        #expect(!store.history.historyTree.folderIDs(containing: archived.id).isEmpty)
    }

    @Test("USB가 빠져도 새 사본에서 원본 키로 다시 짝지어 같은 contentID의 다른 곡을 잇지 않고 새 ID로 갱신한다")
    func disconnectedArchiveRematchesOnSnapshotChange() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let store = try await Self.libraryStore(fixture, histories: Self.histories(scratch))
        let (host, _) = Self.host()
        let usb = UsbTestData.store(host, local: Self.localKeys())
        await Self.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()
        let id = try #require(store.history.archivedHistories.first?.id)
        host.mounted = []
        await usb.refresh()
        store.sidebar = .history(id)

        try fixture.execute("UPDATE djmdContent SET MasterSongID = '9001', FileNameL = 'different.mp3' WHERE ID = '101'")
        try fixture.add(TrackSpec(id: "201", uuid: "history-replacement"))
        try fixture.execute("UPDATE djmdContent SET MasterSongID = '501', FileNameL = 'test1.mp3' WHERE ID = '201'")
        try fixture.execute("UPDATE djmdContent SET MasterDBID = '424242' WHERE ID = '201'")
        await store.load(snapshot: fixture.database)
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistory(id)?.entries.map(\.contentID) == ["102", "201", nil, "201"])
        #expect(store.displayRows.filter { !$0.isUsb }.map(\.track.id) == ["102", "201", "201"])

        // 다른 라이브러리가 같은 ContentID·MasterSongID·파일 이름을 써도 곡의 원본 DBID가 다르면 짝이 없다.
        try fixture.execute("UPDATE djmdProperty SET DBID = '9002'")
        try fixture.execute("UPDATE djmdContent SET MasterDBID = '9002' WHERE ID IN ('101', '102', '201')")
        await store.load(snapshot: fixture.database)
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistory(id)?.entries.allSatisfy { $0.contentID == nil } == true)
        #expect(store.displayRows.allSatisfy { $0.isUsb })
        let saved = UsbHistoryStore(directory: Self.historiesFolder(scratch), home: scratch).load()
        #expect(saved.histories.first?.entries.allSatisfy { $0.contentID == nil } == true)
    }

    @Test("다른 라이브러리에서 가져온 곡은 현재 DBID가 달라도 원본 MasterDBID·MasterSongID·파일 이름으로 다시 짝지어진다")
    func importedTrackRematchesUsingSourceDatabaseFamily() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let store = try await Self.libraryStore(fixture, histories: Self.histories(scratch))
        let (host, _) = Self.host()
        let usb = UsbTestData.store(host, local: Self.localKeys())
        await Self.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()
        let id = try #require(store.history.archivedHistories.first?.id)
        host.mounted = []
        await usb.refresh()

        // 새 현재 라이브러리에도 같은 원본 곡이 있다. 현재 ContentID만 바뀌었다.
        try fixture.execute("UPDATE djmdProperty SET DBID = '9002'")
        try fixture.execute("UPDATE djmdContent SET ID = '201' WHERE ID = '101'")
        await store.load(snapshot: fixture.database)
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistory(id)?.entries.map(\.contentID) == ["102", "201", nil, "201"])
        // 같은 원본 곡 ID·파일 이름이어도 MasterDBID가 다르면 그 항목의 짝은 끊는다.
        try fixture.execute("UPDATE djmdContent SET MasterDBID = '9003' WHERE ID = '201'")
        await store.load(snapshot: fixture.database)
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistory(id)?.entries.map(\.contentID) == ["102", nil, nil, nil])
    }

    @Test("읽지 못한 보존 파일이 남으면 경고하고 새 ID 보존을 막으며 읽기 실패가 해소된 뒤 다시 시도한다")
    func unreadableArchiveBlocksDuplicateImportAndRetries() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let blocked = Self.historiesFolder(scratch).appending(path: "\(ArchivedHistory.idPrefix)blocked.json")
        // 권한 시험은 실행 계정에 따라 달라서 JSON 이름의 폴더로 읽기 실패를 만든다.
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let fixture = try historyFixture()
        let store = try await Self.libraryStore(fixture, histories: Self.histories(scratch))
        let (host, _) = Self.host()
        let usb = UsbTestData.store(host, local: Self.localKeys())
        await Self.connect(store, usb)
        #expect(store.toast?.kind == .warning)
        #expect(store.history.unreadableHistoryFiles == [blocked.lastPathComponent])
        await usb.refresh()
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistories.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: Self.historiesFolder(scratch).path) == [blocked.lastPathComponent])

        try FileManager.default.removeItem(at: blocked)
        await usb.refresh()
        await store.history.waitForHistoryImports()
        #expect(store.history.unreadableHistoryFiles.isEmpty)
        #expect(store.history.archivedHistories.count == 1)
    }

    @Test("보존 저장소를 붙이지 않으면(시험 기본) 아무것도 보존하지 않는다")
    func noStoreNoImport() async throws {
        let fixture = try historyFixture()
        let store = try await Self.libraryStore(fixture)
        let (host, volume) = Self.host()
        let usb = UsbTestData.store(host, local: Self.localKeys())
        await Self.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistories.isEmpty)
        #expect(store.toast == nil)
        #expect(store.history.historyTree.years.map(\.year) == [2025])
        store.history.importUsbHistories(volume: volume, library: Self.usbLibrary(), matches: [1: "101", 2: "102"])
        #expect(store.history.archivedHistories.isEmpty)
        #expect(store.toast == nil)
    }

    @Test("보존하지 못하면 경고만 하고 기록을 더하지 않는다")
    func saveFailureKeepsState() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // 보존 폴더 자리에 파일이 있어 쓸 수 없다
        try Data().write(to: Self.historiesFolder(scratch))
        let fixture = try historyFixture()
        let store = try await Self.libraryStore(fixture, histories: Self.histories(scratch))
        let (host, _) = Self.host()
        let usb = UsbTestData.store(host, local: Self.localKeys())
        await Self.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistories.isEmpty)
        #expect(store.toast?.kind == .warning)
        #expect(store.toast?.title == "USB 재생 기록 파일을 읽지 못했습니다. usb-histories 읽기 권한을 확인한 뒤 USB를 다시 연결하세요")
        #expect(store.history.historyTree.years.map(\.year) == [2025])
    }

    @Test("rename 전에 저장이 실패하면 현재 파일이 일치하지 않아 보존본을 채택하지 않는다",
          arguments: [FaultyUsbFileSystem.Op.fullSync, .rename])
    func archiveFailureBeforeRenameDoesNotAdopt(operation: FaultyUsbFileSystem.Op) async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let fileSystem = FaultyUsbFileSystem(root: scratch)
        fileSystem.failWhen = { actual, _ in actual == operation }
        let store = try await Self.libraryStore(fixture, histories: Self.histories(scratch, home: scratch, fileSystem: fileSystem))
        let (host, _) = Self.host()
        let usb = UsbTestData.store(host, local: Self.localKeys())
        let saved = UsbHistoryStore(directory: Self.historiesFolder(scratch), home: scratch, fileSystem: fileSystem)
        await Self.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistories.isEmpty && saved.load().histories.isEmpty)
        #expect(store.toast?.kind == .warning)
        #expect(try FileManager.default.contentsOfDirectory(atPath: Self.historiesFolder(scratch).path).isEmpty)
    }

    @Test("rename 뒤 폴더 fsync가 실패해도 같은 파일 내용이면 같은 ID를 채택하고 경고를 남겨 다시 읽을 때 중복을 만들지 않는다")
    func archiveRenameThenSyncFailureKeepsIdentity() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try historyFixture()
        let fileSystem = FaultyUsbFileSystem(root: scratch)
        fileSystem.failAt = (.syncDirectory, 1, .error)
        let store = try await Self.libraryStore(fixture, histories: Self.histories(scratch, home: scratch, fileSystem: fileSystem))
        let (host, _) = Self.host()
        let usb = UsbTestData.store(host, local: Self.localKeys())
        let historyStore = UsbHistoryStore(directory: Self.historiesFolder(scratch), home: scratch, fileSystem: fileSystem)
        await Self.connect(store, usb)
        await usb.refresh()
        await store.history.waitForHistoryImports()
        let archived = try #require(store.history.archivedHistories.first)
        #expect(historyStore.containsExact(archived))
        #expect(store.toast?.title == "USB 재생 기록을 보존하지 못했습니다" && store.toast?.kind == .warning)

        await usb.refresh()
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistories.map(\.id) == [archived.id])
        #expect(historyStore.load().histories.map(\.id) == [archived.id])
        #expect(store.toast?.kind == .warning)
        #expect(try FileManager.default.contentsOfDirectory(atPath: Self.historiesFolder(scratch).path)
            .filter { $0.hasSuffix(".json") }.count == 1)
    }

    @Test("읽지 못한 보존 파일은 옮겼다고 알리고 나머지는 그대로 읽는다")
    func damagedArchiveIsReported() async throws {
        let scratch = Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = Self.historiesFolder(scratch)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let broken = folder.appending(path: "\(ArchivedHistory.idPrefix)broken.json")
        try Data("{".utf8).write(to: broken)
        let fixture = try historyFixture()
        let store = try await Self.libraryStore(fixture, histories: Self.histories(scratch))
        let (host, _) = Self.host()
        let usb = UsbTestData.store(host, local: Self.localKeys())
        await Self.connect(store, usb)
        #expect(store.history.archivedHistories.isEmpty)
        #expect(store.toast?.kind == .warning)
        #expect(store.toast?.detail == broken.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: broken.path))
        // 옮긴 뒤에도 USB 기록은 새로 가져온다
        await usb.refresh()
        await store.history.waitForHistoryImports()
        #expect(store.history.archivedHistories.count == 1)
    }

    @Test("rekordbox 기록 트리: 연 › 월(오래된 것부터)·날짜 없는 기록은 아래, 처음엔 가장 최근 연·월을 펼치고 고른 기록의 폴더를 펼친다")
    func rekordboxTree() async throws {
        let fixture = try historyFixture()
        let store = try await Self.libraryStore(fixture)
        let tree = store.history.historyTree
        #expect(tree.years.map(\.year) == [2025])
        #expect(tree.years.first?.months.map(\.month) == [1, 2])
        #expect(tree.years.first?.months.last?.items.map(\.id) == ["new-a", "new-b"])
        #expect(tree.years.first?.months.last?.items.map(\.name) == ["합성 오전 기록", "합성 저녁 기록"])
        #expect(tree.undated.map(\.id) == ["undated"])
        #expect(store.history.expandedHistoryFolders == [HistoryTree.yearID(2025), HistoryTree.monthID(year: 2025, month: 2)])
        // 접은 폴더 안 기록을 고르면 그 폴더를 펼친다
        store.history.expandedHistoryFolders = []
        store.sidebar = .history("old")
        #expect(store.history.expandedHistoryFolders == [HistoryTree.yearID(2025), HistoryTree.monthID(year: 2025, month: 1)])
        // 기록 보기(순번·반복 행)와 곡 수는 트리로 바뀐 뒤에도 같다
        store.sidebar = .history("new-a")
        #expect(store.displayRows.map(\.track.id) == ["102", "101", "101"])
        #expect(store.displayRows.map(\.historyTrackNumber) == [1, 2, 3])
        #expect(store.history.historyCount("new-a") == 3)
        #expect(store.sidebarTitle.contains("2025-02-03"))
        // 이름 없는 rekordbox 기록은 날짜, 날짜도 없으면 "날짜 없음"
        #expect(HistoryTree.rowName(RekordboxHistory(id: "x", name: "", dateCreated: "2026-08-01 23:12:27", entries: [])) == "2026-08-01")
        #expect(HistoryTree.rowName(RekordboxHistory(id: "y", name: "", dateCreated: nil, entries: [])) == "날짜 없음")
    }
}
