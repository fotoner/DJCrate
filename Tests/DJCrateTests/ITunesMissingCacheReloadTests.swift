import DJCAdapters
import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Synchronization
import Testing

@MainActor
@Suite("iTunes 사본 없는 쓰기 후 재로드")
struct ITunesMissingCacheReloadTests {
    @Test func 첫_Music_캡처_실패는_쓰기_후에도_실패로_남는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let directory = fixture.root.appending(path: "snapshots")
        let sourceDB = fixture.database
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = try LibrarySnapshot.take(from: sourceDB, into: directory, force: true, now: stamp)
        let defaults = TestDefaults.make("itunes-missing-cache")
        let store = LibraryStore.test(settings: SettingsStore(defaults: defaults, persist: false),
                                 resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                                 backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 arguments: ["test"], environment: [:])

        await store.load(snapshot: previous, refreshITunes: true,
                         captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        #expect(store.iTunesSnapshot.status == .unavailable)
        #expect(ITunesLibrarySnapshot.load(for: previous).status == .notCaptured)

        await store.takeSnapshot(force: true, quiet: true, refreshITunes: false, snapshotDirectory: directory,
                                 snapshotCopy: { force in
                                     try LibrarySnapshot.take(from: sourceDB, into: directory, force: force,
                                                              now: stamp.addingTimeInterval(60))
                                 }, captureITunes: {
                                     Issue.record("쓰기 후 Music을 다시 조회했습니다")
                                     return ITunesLibrarySnapshot()
                                 })

        #expect(!store.isLoading)
        #expect(store.iTunesSnapshot.status == .unavailable)
        #expect(store.iTunesSnapshot.status.message?.contains("Music 접근 권한") == true)
        #expect(ITunesLibrarySnapshot.load(for: try #require(store.snapshotURL)).status == .notCaptured)
    }

    @Test func 명시한_DB에_캐시가_없으면_미캡처_상태를_유지한다() throws {
        let fixture = try RekordboxFixture()
        let loaded = try LoadedLibrary.load(snapshot: fixture.database, refreshITunes: false,
                                            fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                            drafts: .dataFolder(),
                                            captureITunes: {
                                                Issue.record("명시한 DB를 읽을 때 Music을 조회했습니다")
                                                return ITunesLibrarySnapshot()
                                            })
        #expect(loaded.iTunesSnapshot.status == .notCaptured)
        #expect(loaded.iTunesLibrary.status.message == String(ui: "이 사본에는 캡처한 iTunes 목록이 없습니다"),
                "읽기가 끝난 명시적 사본을 스냅샷 생성 중으로 표시하지 않는다")
    }

    /// 읽는 중은 이제 `.loading`이 따로 있어 `.notCaptured`는 "읽기가 끝났는데 캡처한 목록이 없다"만 뜻한다(#197).
    /// 그래서 Music을 조회한 적 없는 사본(`DJC_REKORDBOX_DIR`·`--db`)의 쓰기 후 재로드를 "Music 접근 권한을 확인하세요"(`.unavailable`)로 바꾸지 않는다.
    @Test func 이전도_미캡처인_완료된_재로드는_진행중이나_접근_권한_안내로_표시하지_않는다() throws {
        let fixture = try RekordboxFixture()
        let previous = fixture.root.appending(path: "previous.db")
        let loaded = try LoadedLibrary.load(snapshot: fixture.database,
                                            previousITunesSnapshot: .init(source: previous,
                                                contents: ITunesLibrarySnapshot(status: .notCaptured),
                                                preferOverCurrent: true),
                                            fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                            drafts: .dataFolder(),
                                            captureITunes: {
                                                Issue.record("쓰기 후 Music을 다시 조회했습니다")
                                                return ITunesLibrarySnapshot()
                                            })
        #expect(loaded.iTunesSnapshot.status == .notCaptured)
        #expect(loaded.iTunesLibrary.status == .notCaptured)
        #expect(loaded.iTunesLibrary.status.message == String(ui: "이 사본에는 캡처한 iTunes 목록이 없습니다"))
        #expect(loaded.iTunesLibrary.status.message?.contains("Music 접근 권한") != true)
        #expect(ITunesLibrarySnapshot.load(for: fixture.database).status == .notCaptured)
    }

    @Test func 이전_Music_조회가_실패였으면_완료된_재로드도_실패로_남는다() throws {
        // 실제로 조회해 실패한 사본은 쓰기 뒤 다시 읽어도(Music은 다시 조회하지 않는다) 접근 권한 안내가 남는다.
        let fixture = try RekordboxFixture()
        let previous = fixture.root.appending(path: "previous.db")
        let loaded = try LoadedLibrary.load(snapshot: fixture.database,
                                            previousITunesSnapshot: .init(source: previous,
                                                contents: ITunesLibrarySnapshot(status: .unavailable),
                                                preferOverCurrent: true),
                                            fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                            drafts: .dataFolder(),
                                            captureITunes: {
                                                Issue.record("쓰기 후 Music을 다시 조회했습니다")
                                                return ITunesLibrarySnapshot()
                                            })
        #expect(loaded.iTunesSnapshot.status == .unavailable)
        #expect(loaded.iTunesLibrary.status.message?.contains("Music 접근 권한") == true)
        #expect(ITunesLibrarySnapshot.load(for: fixture.database).status == .notCaptured)
    }

    @Test(arguments: [ITunesLibrarySnapshot.Status.ready, .stale])
    func 현재_사용가능한_캐시는_이전_실패나_미캡처보다_우선한다(status: ITunesLibrarySnapshot.Status) throws {
        let fixture = try RekordboxFixture()
        let current = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "현재 목록")], status: status)
        try current.save(for: fixture.database)
        let previous = fixture.root.appending(path: "previous.db")
        for oldStatus in [ITunesLibrarySnapshot.Status.unavailable, .notCaptured] {
            let loaded = try LoadedLibrary.load(snapshot: fixture.database,
                                                previousITunesSnapshot: .init(source: previous,
                                                    contents: ITunesLibrarySnapshot(status: oldStatus),
                                                    preferOverCurrent: true), fallbackDirectory: LibrarySnapshot.defaultDirectory, drafts: .dataFolder())
            #expect(loaded.iTunesSnapshot.status == status)
            #expect(loaded.iTunesSnapshot.playlists == current.playlists)
        }
    }

    // MARK: - 읽기와 한 번에 하는 캡처의 읽는 중 표시(#197)

    func quietStore(_ fixture: RekordboxFixture) -> LibraryStore {
        LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("itunes-loading"), persist: false),
                     resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                     backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                     mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                     arguments: ["test", "--db", fixture.database.path], environment: [:])
    }

    @Test func 조용히_읽으며_Music을_함께_조회하는_동안_사이드바는_읽는_중으로_보인다() async throws {
        // `refreshIfRekordboxChanged`처럼 `load(quiet: true, refreshITunes: true)`가 캡처를 한 번에 하는 경로: 사이드바가 보이는 채로
        // 캡처한 목록이 없다는 안내를 읽는 중 안내로 바꾸고, 결과를 채택하면 그 결과로 바뀐다.
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let store = quietStore(fixture)
        await store.load(snapshot: fixture.database)
        #expect(store.iTunesLibrary.status == .notCaptured)
        let resume = DispatchSemaphore(value: 0), started = Mutex(false)
        let loading = Task {
            await store.load(snapshot: fixture.database, quiet: true, refreshITunes: true,
                             captureITunes: {
                                 started.withLock { $0 = true }
                                 resume.waitOffPool()
                                 return ITunesLibrarySnapshot(status: .unavailable)
                             })
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.iTunesLibrary.status == .loading)
        #expect(store.iTunesLibrary.status.message == ITunesLibrarySnapshot.Status.loading.message)
        resume.signal()
        await loading.value
        #expect(store.iTunesLibrary.status == .unavailable, "채택한 결과(조회 실패)로 바뀐다")
    }

    @Test func 읽기가_결과를_채택하지_못하고_끝나면_읽는_중을_되돌린다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let store = quietStore(fixture)
        await store.load(snapshot: fixture.database)
        #expect(store.iTunesLibrary.status == .notCaptured)
        // 읽지 못한 사본: 캡처에 이르지 못해도 읽는 중이 남지 않는다
        await store.load(snapshot: fixture.root.appending(path: "없는.db"), quiet: true, refreshITunes: true,
                         captureITunes: {
                             Issue.record("읽지 못한 사본에서 Music을 조회했습니다")
                             return ITunesLibrarySnapshot()
                         })
        #expect(store.lastError != nil)
        #expect(store.iTunesLibrary.status == .notCaptured)
    }
}
