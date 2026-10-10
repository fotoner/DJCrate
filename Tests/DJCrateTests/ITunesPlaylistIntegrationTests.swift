import DJCAdapters
import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Testing

@MainActor
@Suite("iTunes 목록 앱 연결")
struct ITunesPlaylistIntegrationTests {
    @Test(arguments: [false, true])
    func 명시한_DB의_iTunes_새로고침은_현재_사본과_옆_목록만_다시_읽는다(environmentOverride: Bool) async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let database = folder.database
        try ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "이전 목록")]).save(for: database)
        let arguments = environmentOverride ? ["DJCrate"] : ["DJCrate", "--db", database.path]
        let environment = environmentOverride ? ["DJC_DB": database.path] : [String: String]()
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("itunes.refresh"), persist: false),
                                      resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                                      playlistImportURL: nil, stagingSaver: { _ in }, arguments: arguments, environment: environment,
                                      ports: { $0.source = .withoutDatabase })
        await store.load(snapshot: database)
        #expect(store.iTunesLibrary.index["itunes:A"]?.name == "이전 목록")
        let dbBefore = try Data(contentsOf: database)
        try ITunesLibrarySnapshot(playlists: [.init(id: "B", name: "새 목록")]).save(for: database)
        await store.refreshITunesPlaylists()
        #expect(store.snapshotURL == database)
        #expect(store.iTunesLibrary.index["itunes:B"]?.name == "새 목록")
        #expect(store.iTunesLibrary.index["itunes:A"] == nil)
        #expect(try Data(contentsOf: database) == dbBefore)
    }

    @Test func 실패한_갱신은_기존_정상_사본을_보존하고_새_스냅샷은_낡음을_알린다() throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let good = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "마지막 정상 목록")])
        try good.save(for: folder.database)
        let original = try Data(contentsOf: ITunesLibrarySnapshot.url(for: folder.database))
        let same = try LoadedLibrary.load(snapshot: folder.database, refreshITunes: true,
                                          fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                          drafts: .dataFolder(), source: .withoutDatabase,
                                          captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        #expect(same.iTunesLibrary.status == .stale)
        #expect(same.iTunesLibrary.index["itunes:A"]?.name == "마지막 정상 목록")
        #expect(ITunesLibrarySnapshot.load(for: folder.database).status == .ready)
        #expect(try Data(contentsOf: ITunesLibrarySnapshot.url(for: folder.database)) == original)
        let directory = folder.url.appending(path: "snapshots")
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try LibrarySnapshot.take(from: folder.database, into: directory, force: true, now: moment)
        let previous = LoadedLibrary.ITunesFallback(source: first, contents: ITunesLibrarySnapshot.load(for: first))
        try FileManager.default.removeItem(at: ITunesLibrarySnapshot.url(for: folder.database))
        let fresh = try LibrarySnapshot.take(from: folder.database, into: directory, force: true, now: moment.addingTimeInterval(60))
        #expect(ITunesLibrarySnapshot.load(for: fresh).status == .notCaptured)
        let new = try LoadedLibrary.load(snapshot: fresh, refreshITunes: true,
                                         previousITunesSnapshot: previous,
                                         fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                         drafts: .dataFolder(), source: .withoutDatabase,
                                         captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        #expect(new.iTunesLibrary.status == .stale)
        #expect(new.iTunesLibrary.index["itunes:A"]?.name == "마지막 정상 목록")
        #expect(ITunesLibrarySnapshot.load(for: fresh).status == .stale)

        // 같은 초의 이름을 다시 쓰면 기존 sidecar가 지워진다. 메모리에 보관한 값을 쓴다.
        let reused = LoadedLibrary.ITunesFallback(source: fresh, contents: ITunesLibrarySnapshot.load(for: fresh))
        let repeated = try LibrarySnapshot.take(from: folder.database, into: directory, force: true, now: moment.addingTimeInterval(60))
        #expect(repeated == fresh)
        let recovered = try LoadedLibrary.load(snapshot: repeated, refreshITunes: true,
                                               previousITunesSnapshot: reused,
                                               fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                               drafts: .dataFolder(), source: .withoutDatabase,
                                               captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        #expect(recovered.iTunesLibrary.index["itunes:A"]?.name == "마지막 정상 목록")
        #expect(recovered.iTunesLibrary.status == .stale)

        let foreign = LoadedLibrary.ITunesFallback(source: folder.database, contents: good)
        try FileManager.default.removeItem(at: ITunesLibrarySnapshot.url(for: repeated))
        let unrelated = try LoadedLibrary.load(snapshot: repeated, refreshITunes: true,
                                               previousITunesSnapshot: foreign,
                                               fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                               drafts: .dataFolder(), source: .withoutDatabase,
                                               captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        #expect(unrelated.iTunesLibrary.status == .unavailable)
    }

    @Test func 성공한_빈_목록은_이전_사본을_비우고_저장_실패는_기존_자료로_알린다() throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let good = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "이전 목록")])
        try good.save(for: folder.database)
        let empty = try LoadedLibrary.load(snapshot: folder.database, refreshITunes: true,
                                           fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                           drafts: .dataFolder(), source: .withoutDatabase,
                                           captureITunes: { ITunesLibrarySnapshot() })
        #expect(empty.iTunesLibrary.status == .ready)
        #expect(empty.iTunesLibrary.tree.isEmpty)
        #expect(ITunesLibrarySnapshot.load(for: folder.database).playlists.isEmpty)

        let sidecar = ITunesLibrarySnapshot.url(for: folder.database)
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        let previous = LoadedLibrary.ITunesFallback(source: folder.url.appending(path: "previous.db"), contents: good)
        let failed = try LoadedLibrary.load(snapshot: folder.database, refreshITunes: true,
                                            previousITunesSnapshot: previous,
                                            fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                            drafts: .dataFolder(), source: .withoutDatabase,
                                            captureITunes: { ITunesLibrarySnapshot(playlists: [.init(id: "B", name: "새 목록")]) })
        #expect(failed.iTunesLibrary.status == .stale)
        #expect(failed.iTunesLibrary.index["itunes:A"]?.name == "이전 목록")
        #expect(failed.iTunesLibrary.index["itunes:B"] == nil)
    }

    @Test func 순서와_곡_ID를_유지하고_목록은_잠그되_태그는_초안으로_고친다() {
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("itunes"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, playlistDraftSaver: { _ in },
                                 playlistImportURL: nil, stagingSaver: { _ in })
        let a = ReflectionPresenterTests.row("a"), b = ReflectionPresenterTests.row("b")
        store.rowsByID = [a.id: a, b.id: b]
        store.rowsByUUID = [a.track.uuid: a, b.track.uuid: b]
        store.phase = .loaded
        store.iTunesLibrary = SyncedITunesLibrary(snapshot: ITunesLibrarySnapshot(playlists: [
            .init(id: "A", name: "동기화 목록", paths: [b.track.folderPath, nil, a.track.folderPath, b.track.folderPath]),
        ]), tracks: [a.track, b.track])
        store.sidebar = .itunesPlaylist("itunes:A")
        store.selection = [store.displayRows[1].id]
        #expect(store.displayRows.map(\.track.id) == [b.id, a.id, b.id])
        #expect(Set(store.displayRows.map(\.id)).count == 3)
        #expect(store.displayRows.map(\.playlistTrackNumber) == [1, 3, 4])
        #expect(store.selectedRows.map(\.track.id) == [a.id])
        #expect(store.primaryRow?.track.id == a.id)
        let retained = store.displayRows[2].id
        store.selection = [retained]
        store.iTunesLibrary = SyncedITunesLibrary(snapshot: ITunesLibrarySnapshot(playlists: [
            .init(id: "A", name: "동기화 목록", paths: [a.track.folderPath, b.track.folderPath, b.track.folderPath]),
        ]), tracks: [a.track, b.track])
        store.refreshBase()
        #expect(store.displayRows.map(\.track.id) == [a.id, b.id, b.id])
        #expect(store.displayRows[2].id == retained)
        #expect(store.selectedRows.map(\.track.id) == [b.id])
        #expect(store.primaryRow?.track.id == b.id)
        store.selection = [store.displayRows[0].id]
        #expect(store.sidebarTitle == "동기화 목록")
        #expect(store.editablePlaylistID == nil && !store.canReorderDisplayedTracks)
        #expect(!LibraryMenuAction.removeTracks.isEnabled(in: store))
        #expect(store.deleteTargets([a]).isEmpty)
        store.removeSelectedFromPlaylist()
        store.addTracks([a], toPlaylist: "itunes:A")
        store.renamePlaylist("itunes:A", to: "바꿀 수 없음")
        store.deletePlaylist("itunes:A")
        #expect(store.playlistDraft.isEmpty)
        store.tags.setTag(.comment, "메모 초안", rows: [a])
        #expect(store.tagDrafts[a.track.uuid]?.fields.comment == "메모 초안")
        #expect(store.displayRows.map(\.track.id) == [a.id, b.id, b.id])
        store.sidebar = .filter(.all)
        #expect(store.deleteTargets([a]).map(\.id) == [a.id])
    }
}
