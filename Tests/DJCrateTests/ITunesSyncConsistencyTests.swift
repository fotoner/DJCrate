import DJCAdapters
import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

private final class ITunesSyncCaptureGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func pause() {
        started.signal()
        // 쓰기가 얼마나 걸리든 명시적으로 해제하기 전에는 캡처를 끝내지 않는다.
        resume.wait()
    }

    func release() { resume.signal() }

    func finish<Value: Sendable, Failure: Error>(
        _ pending: Task<Value, Failure>, isolation: isolated (any Actor)? = #isolation,
        after operation: () async throws -> Void
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            do {
                let didStart = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        continuation.resume(returning: self.started.wait(timeout: .now() + 15) == .success)
                    }
                }
                try #require(didStart)
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
                release()
                let value = try await pending.value
                try Task.checkCancellation()
                return value
            } catch {
                // 시작 실패·쓰기 오류에서도 먼저 해제하고 작업을 회수해 사본 수명을 지킨다.
                release()
                _ = try? await pending.value
                throw error
            }
        } onCancel: {
            self.release()
        }
    }
}

@Suite("iTunes 동기화 일관성", .serialized)
struct ITunesSyncConsistencyTests {
    let base = Data("""
        <SYNC_ITUNES_PLAYLIST Version="3.0.0"><PLAYLISTS>
        <NODE Id="0" ParentId="0" Attribute="1" Timestamp="0" Lib_Type="1" CheckType="2"/>
        <NODE Id="A" ParentId="0" Attribute="0" Timestamp="100" Lib_Type="1" CheckType="1"/>
        </PLAYLISTS></SYNC_ITUNES_PLAYLIST>
        """.utf8)

    func original() throws -> ITunesLibrarySnapshot {
        try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "이전 선택"), .init(id: "B", name: "새 선택")])
            .applyingRekordboxSelection(base)
    }

    /// 위치(실행 인자·환경)를 주지 않으면 이 프로세스의 것
    @MainActor func store(_ fixture: RekordboxFixture, arguments: [String]? = nil, environment: [String: String]? = nil,
                          location: LibraryLocation? = nil) -> LibraryStore {
        LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("itunes.consistency"), persist: false),
                          resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                          playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                          arguments: arguments ?? ProcessInfo.processInfo.arguments,
                          environment: environment ?? ProcessInfo.processInfo.environment, location: location)
    }

    @MainActor @Test func 늦은_읽기는_저장한_선택을_되돌리지_않는다() async throws {
        let fixture = try RekordboxFixture(), source = try original(), database = fixture.database
        try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        try source.save(for: database)
        let store = store(fixture, arguments: ["test", "--db", database.path], environment: [:])
        await store.load(snapshot: database)
        let gate = ITunesSyncCaptureGate()
        let first = iTunesBlockingTask {
            try LoadedLibrary.load(snapshot: database, refreshITunes: true, fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                   drafts: .dataFolder(), captureITunes: {
                gate.pause()
                return source
            })
        }
        let late = try await gate.finish(first) {
            try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database)
        }
        #expect(late.iTunesSnapshot.selectedIDs == ["B"])
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["B"])
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
    }

    @MainActor @Test func 조용한_새로고침은_저장_뒤_오래된_UI를_채택하지_않는다() async throws {
        let fixture = try RekordboxFixture(), source = try original(), database = fixture.database
        try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        try source.save(for: database)
        let store = store(fixture, arguments: ["test", "--db", database.path], environment: [:])
        await store.load(snapshot: database)
        let gate = ITunesSyncCaptureGate()
        let loading = Task {
            await store.load(snapshot: database, quiet: true, refreshITunes: true, captureITunes: {
                gate.pause()
                return source
            })
        }
        try await gate.finish(loading) {
            try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database)
        }
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["B"])
    }

    @MainActor @Test func 저장_실패는_기존_화면과_정상_사본을_보존한다() async throws {
        let fixture = try RekordboxFixture(), source = try original(), database = fixture.database
        let sync = fixture.root.appending(path: "playlists3.sync")
        try base.write(to: sync)
        try source.save(for: database)
        let store = store(fixture, arguments: ["test", "--db", database.path], environment: [:])
        await store.load(snapshot: database)
        try (base + Data("\n".utf8)).write(to: sync)
        await #expect(throws: (any Error).self) {
            try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database)
        }
        #expect(store.iTunesSnapshot.selectedIDs == ["A"])
        #expect(store.iTunesLibrary.index["itunes:A"] != nil)
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["A"])
    }

    @MainActor @Test func 사본_루트의_현재_선택을_새_스냅샷에_적용한다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        let sync = fixture.root.appending(path: "playlists3.sync")
        try base.write(to: sync)
        try source.save(for: fixture.database)
        let snapshots = fixture.root.appending(path: "djc-snapshots")
        _ = try LibrarySnapshot.take(from: fixture.database, into: snapshots, force: true,
                                     now: Date(timeIntervalSince1970: 1_800_000_000))
        _ = try RekordboxWriter.write(drafts: [], iTunesSync: .init(base: base, source: source.selectionNodes,
                                                                   selection: .init(selectedIDs: ["B"])),
                                      to: fixture.database, dryRun: false, backups: fixture.backups)
        let fresh = try LibrarySnapshot.take(from: fixture.database, into: snapshots, force: true,
                                             now: Date(timeIntervalSince1970: 1_800_000_060))
        let environment = ["DJC_REKORDBOX_DIR": fixture.root.path]
        let explicit = self.store(fixture, arguments: ["test", "--db", fresh.path], environment: environment)
        await explicit.load(snapshot: fresh)
        #expect(explicit.iTunesSnapshot.selectedIDs == ["A"])
        #expect(explicit.iTunesLibrary.index["itunes:B"] == nil)
        let store = store(fixture, arguments: ["test"], environment: environment)
        await store.load(snapshot: fresh)
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
    }

    @Test func 다른_URL과_같은_초_교체에서도_늦은_캡처가_현재_선택을_덮지_못한다() async throws {
        let fixture = try RekordboxFixture(), source = try original(), rootDB = fixture.database
        let sync = fixture.root.appending(path: "playlists3.sync")
        try base.write(to: sync)
        try source.save(for: rootDB)
        let directory = fixture.root.appending(path: "djc-snapshots")
        let before = try LibrarySnapshot.take(from: rootDB, into: directory, force: true,
                                              now: Date(timeIntervalSince1970: 1_800_000_000))
        let gate = ITunesSyncCaptureGate()
        let pending = iTunesBlockingTask {
            try LoadedLibrary.load(snapshot: before, refreshITunes: true, fallbackDirectory: LibrarySnapshot.defaultDirectory, sourceDatabase: rootDB,
                                   drafts: .dataFolder(), captureITunes: {
                gate.pause()
                return source
            })
        }
        var replaced: URL?
        let late = try await gate.finish(pending) {
            _ = try RekordboxWriter.write(drafts: [], iTunesSync: .init(base: base, source: source.selectionNodes, selection: .init(selectedIDs: ["B"])),
                                          to: rootDB, dryRun: false, backups: fixture.backups)
            try source.applyingRekordboxSelection(Data(contentsOf: sync)).save(for: rootDB)
            let stamp = Date(timeIntervalSince1970: 1_800_000_060)
            let fresh = try LibrarySnapshot.take(from: rootDB, into: directory, force: true, now: stamp)
            let newest = try LoadedLibrary.load(snapshot: fresh, fallbackDirectory: LibrarySnapshot.defaultDirectory, sourceDatabase: rootDB,
                                                drafts: .dataFolder())
            ITunesRefreshCoordinator.shared.invalidateSnapshots([fresh])
            let replacement = try LibrarySnapshot.take(from: rootDB, into: directory, force: true, now: stamp)
            let sameSecond = try LoadedLibrary.load(snapshot: replacement, fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                                    sourceDatabase: rootDB,
                                                    drafts: .dataFolder())
            #expect(newest.iTunesSnapshot.selectedIDs == ["B"])
            #expect(sameSecond.iTunesSnapshot.selectedIDs == ["B"])
            replaced = replacement
        }
        #expect(late.iTunesSnapshot.selectedIDs == ["B"])
        #expect(ITunesLibrarySnapshot.load(for: try #require(replaced)).selectedIDs == ["B"])
    }

    @Test func 명시한_읽기_전용_사본의_정상_캐시는_재저장하지_않는다() throws {
        let fixture = try RekordboxFixture(), source = try original()
        let directory = fixture.root.appending(path: "readonly")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appending(path: "manual.db")
        try FileManager.default.copyItem(at: fixture.database, to: database)
        try source.save(for: database)
        try base.write(to: directory.appending(path: "playlists3.sync"))
        let originalData = try Data(contentsOf: ITunesLibrarySnapshot.url(for: database))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let loaded = try LoadedLibrary.load(snapshot: database, fallbackDirectory: LibrarySnapshot.defaultDirectory, drafts: .dataFolder())
        #expect(loaded.iTunesSnapshot.status == .ready)
        #expect(loaded.iTunesSnapshot.selectedIDs == ["A"])
        #expect(try Data(contentsOf: ITunesLibrarySnapshot.url(for: database)) == originalData)
    }

    @Test func 루트_사본에_없는_새_목록도_현재_스냅샷에서_유지한다() throws {
        let fixture = try RekordboxFixture(), source = try original()
        let directory = fixture.root.appending(path: "djc-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = directory.appending(path: "master-2026-01-01T000001.db")
        try FileManager.default.copyItem(at: fixture.database, to: snapshot)
        let oldCatalog = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "이전 선택")])
            .applyingRekordboxSelection(base)
        try oldCatalog.save(for: fixture.database)
        let updatedSync = try RekordboxITunesSyncChange(base: base, source: source.selectionNodes,
                                                        selection: .init(selectedIDs: ["B"])).render()
        try updatedSync.write(to: fixture.root.appending(path: "playlists3.sync"))
        try source.applyingRekordboxSelection(updatedSync).save(for: snapshot)
        let loaded = try LoadedLibrary.load(snapshot: snapshot, fallbackDirectory: LibrarySnapshot.defaultDirectory, sourceDatabase: fixture.database,
                                            drafts: .dataFolder())
        #expect(loaded.iTunesLibrary.index["itunes:B"] != nil)
    }

    @MainActor @Test func 같은_URL_사본이_저장_후_캐시를_지워도_현재_선택을_복구한다() async throws {
        let fixture = try RekordboxFixture(), source = try original(), database = fixture.database
        try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        try source.save(for: database)
        let store = store(fixture, arguments: ["test", "--db", database.path], environment: [:])
        await store.load(snapshot: database)
        let previous = LoadedLibrary.ITunesFallback(source: database, contents: store.iTunesSnapshot)
        try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database)
        // 같은 초의 스냅샷 교체는 같은 sidecar를 지울 수 있고, 라이브 루트에는 별도 캐시가 없다.
        try FileManager.default.removeItem(at: ITunesLibrarySnapshot.url(for: database))
        let newest = store.latestITunesFallback(previous)
        let loaded = try LoadedLibrary.load(snapshot: database, refreshITunes: true,
                                            previousITunesSnapshot: newest,
                                            fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                            drafts: .dataFolder(),
                                            captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        #expect(newest?.contents.selectedIDs == ["B"])
        #expect(loaded.iTunesSnapshot.status == .stale)
        #expect(loaded.iTunesSnapshot.selectedIDs == ["B"])
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["B"])
    }

    @MainActor @Test func 조용한_스냅샷_복사가_저장_뒤_같은_URL을_교체해도_현재_선택을_유지한다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        try fixture.add(TrackSpec())
        let directory = fixture.root.appending(path: "djc-snapshots")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let database = try LibrarySnapshot.take(from: fixture.database, into: directory, force: true, now: stamp)
        try base.write(to: directory.appending(path: "playlists3.sync"))
        try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        try source.save(for: database)
        // 앱의 보통 실행: 라이브 rekordbox 폴더(여기서는 합성 사본 폴더)에 동기화를 쓰고, 조용한 다시 뜨기는 위치의 스냅샷 폴더에 같은 이름으로
        // 사본을 바꾼다. 사본 rekordbox 폴더로 띄운 실행이 아니라 Music을 조회한다(CI의 사본 경로 설정과 무관하게 같은 위치).
        // (옛 시험은 스냅샷 뜨기는 보통 실행, 동기화는 명시한 사본으로 따로 불러 앱에 없는 조합이었다.)
        var location = LibraryLocation.resolve(arguments: ["test"], environment: [:])
        location.rekordboxDirectory = fixture.root
        location.snapshotDirectory = directory
        let store = store(fixture, location: location)
        await store.load(snapshot: database)
        #expect(store.rows.count == 1)
        let gate = ITunesSyncCaptureGate(), sourceDB = fixture.database
        let pending = Task {
            // CI의 사본 경로 설정과 무관하게 캡처 실패 뒤 메모리 복구를 검증한다.
            await store.takeSnapshot(force: true, quiet: true, snapshotDirectory: directory,
                                     snapshotCopy: { force in
                                         gate.pause()
                                         return try LibrarySnapshot.take(from: sourceDB, into: directory, force: force, now: stamp)
                                     }, captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        }
        try await gate.finish(pending) {
            #expect(!store.isLoading)
            try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database)
        }
        #expect(store.iTunesSnapshot.status == .stale)
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["B"])
    }

    @MainActor @Test func 사본_루트_캐시가_없어도_같은_초_스냅샷_교체는_현재_선택을_보존한다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        try fixture.add(TrackSpec())
        let environment = ["DJC_REKORDBOX_DIR": fixture.root.path]
        let arguments = ["test"]
        let directory = fixture.root.appending(path: "djc-snapshots")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let database = try LibrarySnapshot.take(from: fixture.database, into: directory, force: true, now: stamp)
        try base.write(to: fixture.root.appending(path: "playlists3.sync"))
        try source.save(for: database)
        #expect(ITunesLibrarySnapshot.load(for: fixture.database).status == .notCaptured)
        let store = store(fixture, arguments: arguments, environment: environment)
        await store.load(snapshot: database)
        #expect(store.rows.count == 1)
        let gate = ITunesSyncCaptureGate(), sourceDB = fixture.database
        let pending = Task {
            await store.takeSnapshot(force: true, quiet: true, snapshotDirectory: directory,
                                     snapshotCopy: { force in
                                         gate.pause()
                                         return try LibrarySnapshot.take(from: sourceDB, into: directory, force: force, now: stamp)
                                     }, captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        }
        try await gate.finish(pending) {
            #expect(!store.isLoading)
            try await store.syncITunesPlaylists(.init(selectedIDs: ["B"]), source: source, database: database)
            #expect(ITunesLibrarySnapshot.load(for: fixture.database).status == .notCaptured)
        }
        #expect(store.iTunesSnapshot.status == .ready)
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(ITunesLibrarySnapshot.load(for: database).selectedIDs == ["B"])
    }

    @Test func 같은_사본_폴더라도_다른_출처의_이전_목록은_섞지_않는다() throws {
        let fixture = try RekordboxFixture(), unrelated = try RekordboxFixture(), source = try original()
        let directory = fixture.root.appending(path: "djc-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousURL = directory.appending(path: "master-2026-01-01T000001.db")
        let fresh = directory.appending(path: "master-2026-01-01T000002.db")
        try FileManager.default.copyItem(at: fixture.database, to: fresh)
        let selected = try source.applying(ITunesSyncSelection(selectedIDs: ["B"]))
        let previous = LoadedLibrary.ITunesFallback(source: previousURL, contents: selected,
                                                    preferOverCurrent: true, sourceDatabase: unrelated.database)
        let loaded = try LoadedLibrary.load(snapshot: fresh, previousITunesSnapshot: previous,
                                            fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                            sourceDatabase: fixture.database, drafts: .dataFolder())
        #expect(loaded.iTunesSnapshot.status == .notCaptured)
        #expect(loaded.iTunesLibrary.index["itunes:B"] == nil)
    }

    @MainActor @Test func 현재_sync와_맞는_활성_카탈로그를_옛_루트_사본보다_우선한다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        try fixture.add(TrackSpec())
        let root = fixture.database
        let oldCatalog = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "이전 선택")])
            .applyingRekordboxSelection(base)
        try oldCatalog.save(for: root)
        let currentSync = try RekordboxITunesSyncChange(base: base, source: source.selectionNodes,
                                                        selection: .init(selectedIDs: ["B"])).render()
        try currentSync.write(to: fixture.root.appending(path: "playlists3.sync"))
        let directory = fixture.root.appending(path: "djc-snapshots")
        let active = try LibrarySnapshot.take(from: root, into: directory, force: true,
                                              now: Date(timeIntervalSince1970: 1_800_000_000))
        try source.applyingRekordboxSelection(currentSync).save(for: active)
        let environment = ["DJC_REKORDBOX_DIR": fixture.root.path]
        let store = store(fixture, arguments: ["test"], environment: environment)
        await store.load(snapshot: active)
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        let fresh = directory.appending(path: "master-2027-01-15T080100.db")
        await store.takeSnapshot(force: true, quiet: true, snapshotDirectory: directory,
                                 snapshotCopy: { force in
                                     try LibrarySnapshot.take(from: root, into: directory, force: force,
                                                              now: Date(timeIntervalSince1970: 1_800_000_060))
                                 }, captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        #expect(store.snapshotURL?.standardizedFileURL.path == fresh.standardizedFileURL.path)
        #expect(store.iTunesSnapshot.selectedIDs == ["B"])
        #expect(store.iTunesLibrary.index["itunes:B"] != nil)
        #expect(store.iTunesSnapshot.sourcePlaylists?.contains(where: { $0.id == "B" }) == true)
        #expect(ITunesLibrarySnapshot.load(for: root).sourcePlaylists?.map(\.id) == ["A"])
    }

    @Test func 새_캡처에서_실제로_사라진_목록은_이전_메모리에서_되살리지_않는다() throws {
        let fixture = try RekordboxFixture(), previous = try original()
        let directory = fixture.root.appending(path: "djc-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appending(path: "master-2027-01-15T080100.db")
        try FileManager.default.copyItem(at: fixture.database, to: database)
        let currentSync = try RekordboxITunesSyncChange(base: base, source: previous.selectionNodes,
                                                        selection: .init(selectedIDs: ["B"])).render()
        try currentSync.write(to: fixture.root.appending(path: "playlists3.sync"))
        let oldMemory = try previous.applyingRekordboxSelection(currentSync)
        let captured = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "남은 목록")])
            .applyingRekordboxSelection(currentSync)
        let fallback = LoadedLibrary.ITunesFallback(source: database, contents: oldMemory,
                                                    sourceDatabase: fixture.database)
        let loaded = try LoadedLibrary.load(snapshot: database, refreshITunes: true,
                                            previousITunesSnapshot: fallback, fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                            sourceDatabase: fixture.database, 
                                            drafts: .dataFolder(),
                                            captureITunes: { captured })
        #expect(loaded.iTunesSnapshot.status == .ready)
        #expect(loaded.iTunesSnapshot.selectedIDs == ["B"])
        #expect(loaded.iTunesLibrary.index["itunes:B"] == nil)
        #expect(loaded.iTunesSnapshot.unavailablePlaylistCount == 1)
    }

    @Test func 다른_URL의_성공_캡처는_나중_요청_실패의_복구_사본이_된다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        let sourceDatabase = fixture.database
        let directory = fixture.root.appending(path: "djc-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appending(path: "master-2026-01-01T000001.db")
        let secondURL = directory.appending(path: "master-2026-01-01T000002.db")
        for url in [firstURL, secondURL] { try FileManager.default.copyItem(at: fixture.database, to: url) }
        let firstGate = ITunesSyncCaptureGate(), secondGate = ITunesSyncCaptureGate()
        let first = iTunesBlockingTask {
            try LoadedLibrary.load(snapshot: firstURL, refreshITunes: true, fallbackDirectory: directory,
                                   sourceDatabase: sourceDatabase, drafts: .dataFolder(), captureITunes: {
                                       firstGate.pause()
                                       return source
                                   })
        }
        let good = try await firstGate.finish(first) {
            let second = iTunesBlockingTask {
                try LoadedLibrary.load(snapshot: secondURL, refreshITunes: true, fallbackDirectory: directory,
                                       sourceDatabase: sourceDatabase, drafts: .dataFolder(), captureITunes: {
                                           secondGate.pause()
                                           return ITunesLibrarySnapshot(status: .unavailable)
                                       })
            }
            let fallback = try await secondGate.finish(second) {
                firstGate.release()
                _ = try await first.value
            }
            #expect(fallback.iTunesSnapshot.status == .stale)
            #expect(fallback.iTunesSnapshot.selectedIDs == ["A"])
        }
        #expect(good.iTunesSnapshot.status == .ready)
        #expect(ITunesLibrarySnapshot.load(for: firstURL).selectedIDs == ["A"])
    }

    @MainActor @Test func 명시_DB가_기본_사본_폴더에_있어도_활성화_새로고침은_출처를_바꾸지_않는다() async throws {
        let fixture = try RekordboxFixture(), source = try original()
        let directory = fixture.root.appending(path: "djc-snapshots")
        let database = try LibrarySnapshot.take(from: fixture.database, into: directory, force: true,
                                                now: Date(timeIntervalSince1970: 1_700_000_000))
        try source.save(for: database)
        let environment = ["DJC_REKORDBOX_DIR": fixture.root.path]
        let arguments = ["test", "--db", database.path]
        let store = store(fixture, arguments: arguments, environment: environment)
        await store.load(snapshot: database)
        await store.refreshIfRekordboxChanged()
        #expect(store.snapshotURL == database)
        #expect(store.iTunesSnapshot.selectedIDs == ["A"])
        #expect(store.lastError == nil)
        #expect(try LibrarySnapshot.latest(in: directory).standardizedFileURL.path == database.standardizedFileURL.path)
    }
}

@Suite("iTunes 캡처 gate 정리", .serialized)
struct ITunesSyncCaptureGateTests {
    private enum WriteFailure: Error { case expected }

    @Test func 쓰기_오류에도_읽기를_해제하고_회수한다() async {
        let gate = ITunesSyncCaptureGate(), finished = DispatchSemaphore(value: 0)
        let pending = iTunesBlockingTask {
            gate.pause()
            finished.signal()
        }
        await #expect(throws: WriteFailure.self) {
            try await gate.finish(pending) { throw WriteFailure.expected }
        }
        func didFinish() -> Bool { finished.wait(timeout: .now()) == .success }
        #expect(didFinish())
    }

    @Test func 취소는_쓰기_대기_중에도_읽기를_해제한다() async throws {
        let gate = ITunesSyncCaptureGate(), finished = DispatchSemaphore(value: 0)
        let writeStarted = DispatchSemaphore(value: 0), writeResume = DispatchSemaphore(value: 0)
        let pending = iTunesBlockingTask {
            gate.pause()
            finished.signal()
        }
        let operation = Task {
            try await gate.finish(pending) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        writeStarted.signal()
                        writeResume.wait()
                        continuation.resume()
                    }
                }
            }
        }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: writeStarted.wait(timeout: .now() + 15) == .success)
            }
        }
        operation.cancel()
        let released = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: finished.wait(timeout: .now() + 15) == .success)
            }
        }
        // 실패를 보고하기 전에도 쓰기 대기와 그 소유 작업을 모두 정리한다.
        writeResume.signal()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(started)
        #expect(released)
    }
}
