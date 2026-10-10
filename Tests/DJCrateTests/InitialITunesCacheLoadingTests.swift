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

/// 멈춰 둔 Music 조회(#130 환경의 수 분짜리 조회). 조회 횟수를 세고, 풀어 줄 때까지 기다린다.
private final class StalledMusic: Sendable {
    let calls = Mutex(0)
    let result: ITunesLibrarySnapshot
    private let gate = DispatchSemaphore(value: 0)

    init(_ result: ITunesLibrarySnapshot) { self.result = result }
    var started: Bool { calls.withLock { $0 > 0 } }
    func capture() -> ITunesLibrarySnapshot {
        calls.withLock { $0 += 1 }
        gate.waitOffPool()
        return result
    }
    /// 잘못 다시 조회해도 시험이 멈추지 않게 넉넉히 푼다.
    func release() { for _ in 0..<4 { gate.signal() } }
}

@MainActor
@Suite("초기 iTunes 캐시 로드", .serialized)
struct InitialITunesCacheLoadingTests {
    private var sync: Data {
        Data("""
            <SYNC_ITUNES_PLAYLIST Version="3.0.0"><PLAYLISTS>
            <NODE Id="0" ParentId="0" Attribute="1" Timestamp="0" Lib_Type="1" CheckType="2"/>
            <NODE Id="A" ParentId="0" Attribute="0" Timestamp="100" Lib_Type="1" CheckType="1"/>
            </PLAYLISTS></SYNC_ITUNES_PLAYLIST>
            """.utf8)
    }

    /// 위치는 CI의 사본 경로 설정과 무관하게 정한다(기본은 명시 사본도 사본 rekordbox 폴더도 없는 실행). 쓰기 대상은 `root`의 master.db.
    /// 기본은 사본 옆 iTunes 파일만 본다(DB를 열지 않는 원본). 곡 행을 보는 시험만 `liveDatabase`로 DB를 연다.
    private func store(_ root: URL, arguments: [String] = ["test"], environment: [String: String] = [:],
                       liveDatabase: Bool = false) -> LibraryStore {
        let ports: ((inout LibraryPorts) -> Void)? = liveDatabase ? nil : { $0.source = .withoutDatabase }
        return LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("initial-itunes-cache"), persist: false),
                          resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                          backupDirectory: root.appending(path: "backups"), playlistDraftSaver: { _ in },
                          mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                          rekordboxDatabase: root.appending(path: "master.db"),
                          arguments: arguments, environment: environment,
                          ports: ports)
    }

    private func snapshot(from database: URL, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try sync.write(to: directory.appending(path: "playlists3.sync"))
        return try LibrarySnapshot.take(from: database, into: directory, force: true,
                                        now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func 정상_전체캐시는_Music을_기다리지_않고_DB와_선택창을_연다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let directory = fixture.root.appending(path: "snapshots")
        let database = try snapshot(from: fixture.database, directory: directory)
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "캐시 목록")])
            .applyingRekordboxSelection(sync)
        try cached.save(for: database)
        let newer = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "새 목록")])
            .applyingRekordboxSelection(sync)
        let store = store(fixture.root, liveDatabase: true)
        let started = Mutex(false)
        let completed = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let loading = Task {
            await store.loadInitial(snapshotDirectory: directory, captureITunes: {
                started.withLock { $0 = true }
                resume.waitOffPool()
                return newer
            })
            completed.withLock { $0 = true }
        }
        // Music 최신화가 시작될 때까지 기다린다. 시간 제한은 없다(부하가 걸리면 오래 걸릴 뿐 판정은 같다).
        // 시작하지 않는 구현이면 loadInitial이 돌아온 뒤에 남은 최신화 작업이 없으므로 그때 끝낸다.
        let musicStarted = await waitForState(giveUp: { completed.withLock { $0 } && store.music.refresh == nil },
                                              until: { started.withLock { $0 } })
        guard musicStarted else {
            resume.signal(); await loading.value
            await store.music.refresh?.task.value
            Issue.record("Music 최신화가 시작되지 않았습니다")
            return
        }
        // Music 조회는 막혀 있다. 이 시점에 DB와 행이 이미 열려 있어야 Music을 기다리지 않은 것이다(상태로 본다).
        let loadedBeforeMusic = !store.isLoading && store.rows.map(\.id) == ["1"]
        // loadInitial도 막힌 Music을 기다리지 않고 돌아와야 한다. Music이 막혀 있는 채로 돌아온 것만 센다(풀기 전에 확인).
        if loadedBeforeMusic { _ = await waitForState(until: { completed.withLock { $0 } }) }
        let returnedBeforeMusic = completed.withLock { $0 }
        // 이미 Music을 기다린 것으로 드러났다면, 아래 선택창 확인이 막힌 Music에 걸려 멈추지 않게 먼저 풀어 준다(실패로 끝낸다).
        if !(loadedBeforeMusic && returnedBeforeMusic) { resume.signal() }
        let available = await store.music.syncSource(captureITunes: {
            Issue.record("선택창이 정상 캐시 대신 Music을 다시 읽었습니다")
            return .init(status: .unavailable)
        })
        resume.signal()
        await loading.value
        await store.music.refresh?.task.value
        #expect(returnedBeforeMusic)
        #expect(loadedBeforeMusic)
        #expect(available.sourcePlaylists?.first?.name == "캐시 목록")
    }

    @Test func 늦은_초기_Music은_그뒤_시작한_DB_로드를_덮지_않는다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let directory = folder.url.appending(path: "snapshots")
        let database = try snapshot(from: folder.database, directory: directory)
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "보존 목록")])
            .applyingRekordboxSelection(sync)
        try cached.save(for: database)
        let store = store(folder.url)
        let started = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let completed = Mutex(false)
        let loading = Task {
            await store.loadInitial(snapshotDirectory: directory, captureITunes: {
                started.withLock { $0 = true }
                resume.waitOffPool()
                return ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "늦은 목록")])
            })
            completed.withLock { $0 = true }
        }
        let musicStarted = await waitForState(giveUp: { completed.withLock { $0 } && store.music.refresh == nil },
                                              until: { started.withLock { $0 } })
        guard musicStarted else {
            resume.signal()
            await loading.value
            await store.music.refresh?.task.value
            Issue.record("Music 최신화가 시작되지 않았습니다")
            return
        }
        // Music은 막혀 있다. 그 채로 초기 로드가 돌아와야 한다(돌아오지 않는 구현은 안전망 시간 뒤에 실패로 끝난다).
        guard await waitForState(until: { completed.withLock { $0 } }) else {
            resume.signal()
            await loading.value
            await store.music.refresh?.task.value
            Issue.record("Music 최신화를 기다리느라 초기 로드가 끝나지 않았습니다")
            return
        }
        await store.load(snapshot: database)
        resume.signal()
        await loading.value
        await store.music.refresh?.task.value
        #expect(store.music.snapshot.sourcePlaylists?.first?.name == "보존 목록")
    }

    /// 캐시로 연 뒤 뒤에서 도는 Music 최신화를 멈춰 둔다.
    private func openWithStalledMusic(_ store: LibraryStore, directory: URL, music: StalledMusic) async -> Bool {
        let opened = Mutex(false)
        let loading = Task {
            await store.loadInitial(snapshotDirectory: directory,
                                    captureITunes: { music.capture() })
            opened.withLock { $0 = true }
        }
        // 캐시로 열린 뒤 남은 최신화 작업이 없는데 Music 조회가 시작되지 않았다면 더 기다려도 시작하지 않는다.
        _ = await waitForState(giveUp: { opened.withLock { $0 } && store.music.refresh == nil },
                               until: { music.started && opened.withLock { $0 } })
        guard music.started, opened.withLock({ $0 }) else {
            music.release()
            await loading.value
            await store.music.refresh?.task.value
            Issue.record("캐시로 열고 Music 최신화를 시작하지 못했습니다")
            return false
        }
        return true
    }

    @Test func 쓰기_뒤_다시_읽기가_버린_Music_최신화를_새_사본에서_이어받는다() async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let directory = fixture.root.appending(path: "snapshots")
        let database = try snapshot(from: fixture.database, directory: directory)
        try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "캐시 목록")])
            .applyingRekordboxSelection(sync).save(for: database)
        let music = StalledMusic(try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "최신 목록")])
            .applyingRekordboxSelection(sync))
        let store = store(fixture.root, liveDatabase: true)
        guard await openWithStalledMusic(store, directory: directory, music: music) else { return }

        // 쓰기 뒤 다시 읽기는 Music을 기다리지 않고 캐시로 새 사본을 연다.
        try fixture.add(TrackSpec(id: "2"))
        let sourceDB = fixture.database
        let reloaded = Mutex(false)
        let reload = Task {
            await store.takeSnapshot(force: true, quiet: true, refreshITunes: false, snapshotDirectory: directory,
                                     snapshotCopy: { force in
                                         try LibrarySnapshot.take(from: sourceDB, into: directory, force: force,
                                                                  now: Date(timeIntervalSince1970: 1_800_000_060))
                                     }, captureITunes: { music.capture() })
            reloaded.withLock { $0 = true }
        }
        // Music은 막혀 있다. 그 채로 다시 읽기가 끝나야 한다(끝나지 않는 구현은 안전망 시간 뒤에 실패로 끝난다).
        _ = await waitForState(until: { reloaded.withLock { $0 } })
        let reloadedBeforeMusic = reloaded.withLock { $0 } && store.rows.count == 2
        let cachedName = store.music.snapshot.sourcePlaylists?.first?.name
        music.release()
        await reload.value
        // 멈춤이 풀리면 버려진 최신화의 결과가 새 사본에 들어와야 한다(지난 세션 목록이 남지 않게).
        // 이어받은 최신화는 결과를 채택하고 나서 끝나므로, 그 끝을 기다리면 시간을 재지 않고도 상태가 확정된다.
        await store.music.refresh?.task.value
        #expect(reloadedBeforeMusic)
        #expect(cachedName == "캐시 목록")
        #expect(store.music.snapshot.sourcePlaylists?.first?.name == "최신 목록")
        let reloadedDatabase = try #require(store.snapshotURL)
        #expect(reloadedDatabase != database)
        #expect(ITunesLibrarySnapshot.load(for: reloadedDatabase).sourcePlaylists?.first?.name == "최신 목록")
        #expect(music.calls.withLock { $0 } == 1)
    }

    @Test func Music_최신화_중에는_동기화_쓰기를_막고_끝나면_최신_목록으로_연다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let directory = folder.url.appending(path: "snapshots")
        let database = try snapshot(from: folder.database, directory: directory)
        try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "캐시 목록")])
            .applyingRekordboxSelection(sync).save(for: database)
        let music = StalledMusic(try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "최신 목록")])
            .applyingRekordboxSelection(sync))
        let store = store(folder.url)
        guard await openWithStalledMusic(store, directory: directory, music: music) else { return }

        store.music.presentSyncWindow()
        let model = store.music.syncWindow
        let opening = Task {
            await model.load(captureITunes: {
                Issue.record("선택창이 진행 중인 최신화 대신 Music을 다시 읽었습니다")
                return .init(status: .unavailable)
            })
        }
        // 캐시 목록을 보여 주며 로딩이 끝나야 한다(최신화를 기다리는 구현은 안전망 시간 뒤에 실패로 끝난다).
        _ = await waitForState(until: { !model.isLoading })
        let shownName = model.source.sourcePlaylists?.first?.name
        let blockedWhileRefreshing = !model.canSync
        // 창을 거치지 않은 쓰기도 막는다. 막지 못해도 쓰기 대상은 임시 폴더의 합성 사본이다.
        var refused: String?
        let opened = try #require(store.snapshotURL)
        do {
            try await store.music.syncPlaylists(model.selection, source: model.source, database: opened)
        } catch DJCError.writeRefused(let reason) {
            refused = reason
        } catch {
            refused = "\(error)"
        }
        music.release()
        await store.music.refresh?.task.value
        // 선택창은 최신화가 끝나면 스스로 다시 읽는다. 그 읽기까지 마치고 돌아오면(opening) 상태가 확정이다.
        await opening.value
        #expect(shownName == "캐시 목록")
        #expect(blockedWhileRefreshing)
        #expect(refused == String(ui: "Music 보관함을 새로 읽는 중이니 목록이 최신으로 바뀐 뒤 동기화하세요."))
        #expect(model.source.sourcePlaylists?.first?.name == "최신 목록")
        #expect(model.canSync)
        store.music.showingSyncWindow = false
        await opening.value
    }

    @Test func 초기_Music_최신화와_선택창_강제_새로고침은_캡처_하나를_공유한다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let directory = folder.url.appending(path: "snapshots")
        let database = try snapshot(from: folder.database, directory: directory)
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "이전 목록")])
            .applyingRekordboxSelection(sync)
        try cached.save(for: database)
        let fresh = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "최신 목록")])
            .applyingRekordboxSelection(sync)
        let store = store(folder.url)
        let calls = Mutex(0)
        let started = Mutex(false)
        let initialReturned = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let initial = Task {
            await store.loadInitial(snapshotDirectory: directory, captureITunes: {
                calls.withLock { $0 += 1 }
                started.withLock { $0 = true }
                resume.waitOffPool()
                return fresh
            })
            initialReturned.withLock { $0 = true }
        }
        let musicStarted = await waitForState(giveUp: { initialReturned.withLock { $0 } && store.music.refresh == nil },
                                              until: { started.withLock { $0 } })
        guard musicStarted else {
            resume.signal(); await initial.value
            await store.music.refresh?.task.value
            Issue.record("초기 Music 최신화가 시작되지 않았습니다")
            return
        }
        let forced = Task {
            await store.music.syncSource(forceRefresh: true, captureITunes: {
                calls.withLock { $0 += 1 }
                return ITunesLibrarySnapshot(status: .unavailable)
            })
        }
        for _ in 0..<100 { await Task.yield() }
        resume.signal()
        await initial.value
        await store.music.refresh?.task.value
        let result = await forced.value
        #expect(calls.withLock { $0 } == 1)
        #expect(result.sourcePlaylists?.first?.name == "최신 목록")
    }

    @Test func 전체캐시가_없으면_기존_Music_로딩을_유지한다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let directory = folder.url.appending(path: "snapshots")
        _ = try snapshot(from: folder.database, directory: directory)
        let store = store(folder.url)
        let started = Mutex(false)
        let returned = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let loading = Task {
            await store.loadInitial(snapshotDirectory: directory, captureITunes: {
                started.withLock { $0 = true }
                resume.waitOffPool()
                return ITunesLibrarySnapshot()
            })
            returned.withLock { $0 = true }
        }
        // 전체 캐시가 없으면 Music을 기다려야 하므로 loadInitial은 Music이 시작된 채 돌아오지 않는다. 시작하지 않고 돌아왔다면 더 기다릴 것이 없다.
        _ = await waitForState(giveUp: { returned.withLock { $0 } }, until: { started.withLock { $0 } })
        let remainedLoading = store.isLoading && store.rows.isEmpty
        resume.signal()
        await loading.value
        #expect(started.withLock { $0 })
        #expect(remainedLoading)
    }

    @Test func 명시_DB와_사본_모드에서는_Music을_조회하지_않는다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let directory = folder.url.appending(path: "djc-snapshots")
        _ = try snapshot(from: folder.database, directory: directory)
        let explicit = store(folder.url, arguments: ["test", "--db", folder.database.path])
        await explicit.loadInitial(snapshotDirectory: directory, captureITunes: {
            Issue.record("명시 DB에서 Music을 읽었습니다")
            return .init(status: .unavailable)
        })
        #expect(explicit.snapshotURL == folder.database)
        let copy = store(folder.url, environment: ["DJC_REKORDBOX_DIR": folder.url.path])
        await copy.loadInitial(snapshotDirectory: directory, captureITunes: {
            Issue.record("사본 모드에서 Music을 읽었습니다")
            return .init(status: .unavailable)
        })
        #expect(copy.snapshotURL.map { LibrarySnapshot.sameDirectory($0.deletingLastPathComponent(), directory) } == true)
    }
}
