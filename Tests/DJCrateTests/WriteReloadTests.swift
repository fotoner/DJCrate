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
@Suite("쓰기 뒤 iTunes 사본 재사용")
struct WriteReloadTests {
    @Test(arguments: [false, true])
    func 느린_Music을_기다리지_않고_새_DB와_iTunes_사본을_보존한다(sameSecond: Bool) async throws {
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec(id: "1"))
        let directory = fixture.root.appending(path: "snapshots")
        let sourceDB = fixture.database
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = try LibrarySnapshot.take(from: sourceDB, into: directory, force: true, now: stamp)
        let cached = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "이전 목록")])
        try cached.save(for: previous)
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("write-reload"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                                 backupDirectory: fixture.backups, playlistDraftSaver: { _ in },
                                 mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in }, arguments: ["test"], environment: [:])
        await store.load(snapshot: previous)
        try fixture.add(TrackSpec(id: "2"))
        // Music 조회를 막아 둔 채 쓰기 뒤 다시 읽기가 먼저 끝나는지 순서로 판정한다(걸린 시간이 아니라 끝난 순서라 부하에 상관없다).
        // 잘못 캡처하면 두 번째 행을 적용하지 못한 채 대기한다. 그때도 조회가 시작되는 즉시 풀어 준다.
        let resume = DispatchSemaphore(value: 0)
        let captureStarted = Mutex(false)
        let finished = Mutex(false)
        let loading = Task {
            await store.takeSnapshot(force: true, quiet: true, refreshITunes: false, snapshotDirectory: directory,
                                     snapshotCopy: { force in
                                         try LibrarySnapshot.take(from: sourceDB, into: directory, force: force,
                                                                  now: stamp.addingTimeInterval(sameSecond ? 0 : 60))
                                     }, captureITunes: {
                                         captureStarted.withLock { $0 = true }
                                         resume.wait()
                                         return ITunesLibrarySnapshot(status: .unavailable)
                                     })
            finished.withLock { $0 = true }
        }
        // 다시 읽기가 끝나거나 Music 조회가 시작될 때까지 기다린다. 시간 제한은 없다(느린 실행은 오래 걸릴 뿐 판정은 같다).
        while !finished.withLock({ $0 }) && !captureStarted.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let finishedBeforeMusic = finished.withLock { $0 }
        resume.signal()
        await loading.value
        // 뒤늦게 시작한 Music 최신화도 기다려, 조회가 시작됐는지를 경쟁 없이 확인한다.
        await store.iTunesRefresh?.task.value
        #expect(finishedBeforeMusic)
        #expect(!captureStarted.withLock { $0 })
        #expect(store.rows.map(\.id).sorted() == ["1", "2"])
        #expect(store.iTunesSnapshot.status == .ready)
        #expect(store.iTunesLibrary.index["itunes:A"]?.name == "이전 목록")
        let fresh = try #require(store.snapshotURL)
        #expect(ITunesLibrarySnapshot.load(for: fresh).status == .ready)
        #expect(ITunesLibrarySnapshot.load(for: fresh).playlists == cached.playlists)

        // 별도 새로고침은 Music을 다시 읽고, 성공한 빈 선택도 그대로 채택한다.
        await store.takeSnapshot(force: true, snapshotDirectory: directory, snapshotCopy: { force in
            try LibrarySnapshot.take(from: sourceDB, into: directory, force: force, now: stamp.addingTimeInterval(120))
        }, captureITunes: { ITunesLibrarySnapshot() })
        #expect(store.iTunesSnapshot.status == .ready)
        #expect(store.iTunesSnapshot.playlists.isEmpty)
        #expect(ITunesLibrarySnapshot.load(for: try #require(store.snapshotURL)).playlists.isEmpty)
    }

    @Test(arguments: [ITunesLibrarySnapshot.Status.ready, .stale])
    func 재사용한_목록은_sync가_없어도_새_사본에_남긴다(status: ITunesLibrarySnapshot.Status) throws {
        let fixture = try RekordboxFixture()
        let previous = fixture.root.appending(path: "previous.db")
        let cached = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "보존할 목록")], status: status)
        let loaded = try LoadedLibrary.load(snapshot: fixture.database,
                                            previousITunesSnapshot: .init(source: previous, contents: cached),
                                            fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                            drafts: .dataFolder(),
                                            captureITunes: { Issue.record("재사용 중 Music을 조회했습니다"); return .init() })
        #expect(loaded.iTunesSnapshot.status == status)
        #expect(ITunesLibrarySnapshot.load(for: fixture.database).status == status)
        #expect(ITunesLibrarySnapshot.load(for: fixture.database).playlists == cached.playlists)
    }

    @Test(arguments: [false, true])
    func 진행_단계는_DB와_Music_캡처를_구분한다(refresh: Bool) throws {
        let fixture = try RekordboxFixture()
        let stages = Mutex<[LoadedLibrary.Stage]>([])
        _ = try LoadedLibrary.load(snapshot: fixture.database, refreshITunes: refresh,
                                    fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                    drafts: .dataFolder(),
                                    progress: { stage in stages.withLock { $0.append(stage) } }, captureITunes: {
                                        #expect(stages.withLock { $0.last } == .music)
                                        return ITunesLibrarySnapshot()
                                    })
        #expect(stages.withLock { $0 } == (refresh ? [.database, .music, .iTunes, .tracks] : [.database, .iTunes, .tracks]))
    }

    @Test func 재사용한_목록의_저장에_실패해도_메모리와_기존_파일은_보존한다() throws {
        let fixture = try RekordboxFixture()
        let sidecar = ITunesLibrarySnapshot.url(for: fixture.database)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        let cached = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "보존할 목록")])
        let loaded = try LoadedLibrary.load(snapshot: fixture.database, previousITunesSnapshot:
            .init(source: fixture.root.appending(path: "previous.db"),
                  contents: cached), fallbackDirectory: LibrarySnapshot.defaultDirectory, drafts: .dataFolder())
        #expect(loaded.iTunesSnapshot == cached)
        #expect(try FileManager.default.attributesOfItem(atPath: sidecar.path)[.type] as? FileAttributeType == .typeDirectory)
    }
}
