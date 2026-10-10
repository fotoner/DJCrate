import DJCApplication
@testable import DJCrate
import DJCDomain
@testable import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

struct ITunesSyncTests {
    /// 명시한 사본(`--db`)으로 연 창. 쓰기 대상은 그 사본과 같은 DB(앱을 `DJC_REKORDBOX_DIR`·`--db`로 같은 사본에 띄운 것과 같다)
    @MainActor private func store(_ fixture: RekordboxFixture) -> LibraryStore { store(root: fixture.root) }
    /// 쓰기 대상은 `root`의 master.db(앱의 라이브 또는 `DJC_REKORDBOX_DIR`), 읽기 출처는 명시한 사본 `opened`(주지 않으면 쓰기 대상).
    /// DB를 열지 않는 시험(`withoutDatabase`)은 임시 폴더만 준다
    @MainActor private func store(root: URL, opened: URL? = nil, withoutDatabase: Bool = false) -> LibraryStore {
        let ports: ((inout LibraryPorts) -> Void)? = withoutDatabase ? { $0.source = .withoutDatabase } : nil
        let database = root.appending(path: "master.db")
        return LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("itunes.sync"), persist: false),
                          resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                          backupDirectory: root.appending(path: "backups"),
                          playlistDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                          rekordboxDatabase: database,
                          arguments: ["DJCrate", "--db", (opened ?? database).path], environment: [:],
                          ports: ports)
    }
    let source: [ITunesLibrarySnapshot.Playlist] = [
        .init(id: "F", name: "폴더", isFolder: true),
        .init(id: "A", name: "동명", parentID: "F", paths: ["/b", "/a", "/b", nil]),
        .init(id: "B", name: "동명"),
    ]
    let base = Data("""
        <SYNC_ITUNES_PLAYLIST Version="3.0.0"><PLAYLISTS>
        <NODE Id="0" ParentId="0" Attribute="1" Timestamp="0" Lib_Type="1" CheckType="2"/>
        <NODE Id="B" ParentId="0" Attribute="0" Timestamp="100" Lib_Type="1" CheckType="1"/>
        </PLAYLISTS></SYNC_ITUNES_PLAYLIST>
        """.utf8)

    func snapshot() throws -> ITunesLibrarySnapshot {
        try ITunesLibrarySnapshot(playlists: [source[2]], sourcePlaylists: source).applyingRekordboxSelection(base)
    }

    @Test func 전체_원본을_보존하고_사용자_선택으로_교체한다() throws {
        let snapshot = try snapshot()
        let selected = try snapshot.applying(ITunesSyncSelection(selectedIDs: ["F"]))
        #expect(selected.playlists.map(\.id) == ["F", "A"])
        #expect(selected.playlists.last?.paths == ["/b", "/a", "/b", nil])
        #expect(selected.sourcePlaylists == source)
        #expect(try snapshot.applying(ITunesSyncSelection()).playlists.isEmpty)
    }

    @Test func 전체_선택을_다시_읽어도_루트_선택을_유지한다() throws {
        let snapshot = try snapshot()
        let data = try RekordboxITunesSyncChange(base: base, source: snapshot.selectionNodes,
                                                selection: .init(selectedIDs: ["0"])).render()
        let loaded = try snapshot.applyingRekordboxSelection(data)
        #expect(loaded.initialSelection.selectedIDs.contains("0"))
        #expect(loaded.initialSelection.expandedIDs(in: loaded.selectionNodes) == ["F", "A", "B"])
        #expect(loaded.unavailablePlaylistCount == 0)
    }

    @MainActor @Test func rekordbox에_적용한_선택만_표시하고_외부에서_바꾸면_다시_읽는다() async throws {
        let fixture = try RekordboxFixture(), snapshot = try snapshot()
        try snapshot.save(for: fixture.database)
        let syncURL = fixture.root.appending(path: "playlists3.sync")
        try base.write(to: syncURL)
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        store.sidebar = .itunesPlaylist("itunes:B")
        let before = try Data(contentsOf: fixture.database)
        try await store.syncITunesPlaylists(ITunesSyncSelection(selectedIDs: ["F"]), source: snapshot, database: fixture.database)
        #expect(store.iTunesLibrary.index["itunes:A"] != nil)
        #expect(store.iTunesLibrary.index["itunes:B"] == nil)
        #expect(store.sidebar == .filter(.all))
        #expect(try RekordboxITunesSelection.parse(Data(contentsOf: syncURL)).selectedIDs == ["F", "A"])
        await store.load(snapshot: fixture.database)
        #expect(store.iTunesLibrary.index["itunes:A"] != nil)
        #expect(store.iTunesLibrary.index["itunes:B"] == nil)
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(store.playlistDraft.isEmpty)
        // rekordbox에서 바꾼 선택이 DJCrate의 옛 로컬 선택에 가려지면 안 된다.
        try base.write(to: syncURL)
        await store.load(snapshot: fixture.database)
        #expect(store.iTunesLibrary.index["itunes:A"] == nil)
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
    }

    /// iTunes 동기화는 다른 쓰기만 막고 덱은 잠그지 않는다. 덱 초안을 건드리지 않으므로
    /// 덱의 실행 취소 이력과 재생이 그대로 남아야 한다(r3 P2-1, 옛 동작).
    @MainActor @Test func 동기화_쓰기는_덱을_잠그지_않는다() async throws {
        let fixture = try RekordboxFixture(), snapshot = try snapshot()
        try snapshot.save(for: fixture.database)
        try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        let store = store(fixture)
        await store.load(snapshot: fixture.database)
        let h = try DeckHarness()
        try await h.loaded()
        let undo = UndoManager()
        h.deck.undoManager = undo
        h.deck.addMemoryCue(at: 40.5)
        h.deck.togglePlay()
        #expect(undo.canUndo && h.deck.isPlaying)
        // 앱과 같은 연결(AppComposition.connect)
        store.onWriteLock = { [weak deck = h.deck] locked in deck?.isWriteLocked = locked }
        let writes = store.rekordboxWriteCount, played = h.audio.log.count
        try await store.syncITunesPlaylists(ITunesSyncSelection(selectedIDs: ["F"]), source: snapshot, database: fixture.database)
        #expect(store.rekordboxWriteCount == writes + 1, "쓰는 동안 다른 쓰기를 막는다")
        #expect(!store.isWritingRekordbox && !h.deck.isWriteLocked)
        #expect(undo.canUndo && h.deck.isPlaying)
        #expect(!h.audio.log.dropFirst(played).contains { $0 == "stop" || $0 == "pause" }, "\(h.audio.log.dropFirst(played))")
    }

    /// `--db`는 읽기 출처만 바꾼다(2026-10-10 결정): 쓰기 대상과 다른 폴더의 사본으로 열어도 iTunes 동기화는 반영·복원과 같은 대상에 쓴다.
    /// 백업도 같은 폴더에 남아 최근 쓰기 복원이 같은 대상을 되돌린다(#167 최종 리뷰 6절 P2). 연 사본은 그대로라 화면도 그대로 두고 알린다.
    @MainActor @Test func 명시한_사본으로_열어도_쓰기_대상에_쓰고_최근_쓰기_복원이_같은_대상을_되돌린다() async throws {
        let target = try RekordboxFixture(), copy = try RekordboxFixture(), snapshot = try snapshot()
        let targetSync = target.root.appending(path: "playlists3.sync"), copySync = copy.root.appending(path: "playlists3.sync")
        for fixture in [target, copy] {
            try snapshot.save(for: fixture.database)
            try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        }
        let store = store(root: target.root, opened: copy.database)
        await store.load(snapshot: copy.database)
        let copyBefore = try Data(contentsOf: copy.database)
        try await store.syncITunesPlaylists(ITunesSyncSelection(selectedIDs: ["F"]), source: snapshot, database: copy.database)
        #expect(try RekordboxITunesSelection.parse(Data(contentsOf: targetSync)).selectedIDs == ["F", "A"])
        #expect(try Data(contentsOf: copySync) == base && Data(contentsOf: copy.database) == copyBefore)
        // 연 사본에는 보이지 않으므로 화면 목록과 사본 옆 목록 사본은 그대로 두고 그 까닭을 알린다
        #expect(store.iTunesLibrary.index["itunes:B"] != nil && store.iTunesLibrary.index["itunes:A"] == nil)
        #expect(ITunesLibrarySnapshot.load(for: copy.database).selectedIDs == snapshot.selectedIDs)
        #expect(store.toast?.kind == .warning && store.toast?.detail?.contains("--db") == true)
        // 최근 쓰기 복원(`startRestoreLatest`)과 같은 고르기: 이 저장소의 백업 폴더에서 가장 최근 쓰기를 세션의 대상으로 되돌린다
        let found = store.session.writeBackups().first(where: \.isWrite)
        let latest = try #require(found)
        #expect(latest.url.deletingLastPathComponent().isSameDirectory(as: target.backups))
        try await store.session.restoreRekordbox(latest)
        #expect(try Data(contentsOf: targetSync) == base && Data(contentsOf: copySync) == base)
    }

    /// 다른 폴더의 `--db` 사본은 새로고침해도 그 사본만 다시 읽어 동기화 원문이 쓰기 대상과 맞춰지지 않는다.
    /// 그래서 쓰기 관문의 "새로고침" 안내 대신 쓰기 전에 막고 `--db` 없이 다시 열라고 알린다.
    @MainActor @Test func 다른_폴더의_명시한_사본이_쓰기_대상과_어긋나면_쓰기_전에_다시_열라고_막는다() async throws {
        let target = try RekordboxFixture(), copy = try RekordboxFixture(), snapshot = try snapshot()
        let targetSync = target.root.appending(path: "playlists3.sync")
        for fixture in [target, copy] {
            try snapshot.save(for: fixture.database)
            try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        }
        let store = store(root: target.root, opened: copy.database)
        await store.load(snapshot: copy.database)
        try await store.syncITunesPlaylists(ITunesSyncSelection(selectedIDs: ["F"]), source: snapshot, database: copy.database)
        let written = try Data(contentsOf: targetSync)
        await store.refreshITunesPlaylists()
        #expect(store.iTunesSnapshot.syncData == base)
        let error = await #expect(throws: DJCError.self) {
            try await store.syncITunesPlaylists(ITunesSyncSelection(selectedIDs: ["B"]), source: snapshot, database: copy.database)
        }
        #expect(error?.description.contains("--db 없이 다시 열어") == true, "\(String(describing: error))")
        #expect(try Data(contentsOf: targetSync) == written)
        #expect(store.session.writeBackups().filter(\.isWrite).count == 1)
    }

    @MainActor @Test func 외부_변경과_출처_변경은_표시를_바꾸지_않는다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase(), snapshot = try snapshot()
        try snapshot.save(for: folder.database)
        let syncURL = folder.url.appending(path: "playlists3.sync")
        try base.write(to: syncURL)
        let store = store(root: folder.url, withoutDatabase: true)
        await store.load(snapshot: folder.database)
        try (base + Data("\n".utf8)).write(to: syncURL)
        let writes = store.rekordboxWriteCount
        await #expect(throws: (any Error).self) {
            try await store.syncITunesPlaylists(ITunesSyncSelection(selectedIDs: ["F"]), source: snapshot, database: folder.database)
        }
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        // 잠근 뒤 쓰기에서 실패해도 잠금이 풀린다(defer)
        #expect(store.rekordboxWriteCount == writes + 1 && !store.isWritingRekordbox)
        await #expect(throws: (any Error).self) {
            try await store.syncITunesPlaylists(ITunesSyncSelection(), source: snapshot, database: folder.url.appending(path: "other.db"))
        }
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(RekordboxWriter.backups(in: folder.backups).isEmpty)
    }
}
