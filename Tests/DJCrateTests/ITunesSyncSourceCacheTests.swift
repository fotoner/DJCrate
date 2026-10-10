import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Synchronization
import Testing

@MainActor
@Suite("iTunes 선택창 소스 캐시", .serialized)
struct ITunesSyncSourceCacheTests {
    /// 이 묶음은 사본 옆 iTunes 파일(목록 사본·`playlists3.sync`)만 본다. 라이브러리 읽기는 DB를 열지 않는 원본(`withoutDatabase`)으로 한다.
    private func store(_ folder: TemporaryFolder, arguments: [String] = ["test"]) -> LibraryStore {
        LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("itunes-sync-source"), persist: false),
                          resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in },
                          backupDirectory: folder.backups, playlistDraftSaver: { _ in },
                          mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                          arguments: arguments, environment: [:],
                          ports: { $0.source = .withoutDatabase })
    }

    private var syncA: Data {
        Data("""
            <SYNC_ITUNES_PLAYLIST Version="3.0.0"><PLAYLISTS>
            <NODE Id="0" ParentId="0" Attribute="1" Timestamp="0" Lib_Type="1" CheckType="2"/>
            <NODE Id="A" ParentId="0" Attribute="0" Timestamp="100" Lib_Type="1" CheckType="1"/>
            </PLAYLISTS></SYNC_ITUNES_PLAYLIST>
            """.utf8)
    }

    @Test func 현재_전체_카탈로그는_선택창에서_다시_캡처하지_않는다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        try syncA.write(to: folder.url.appending(path: "playlists3.sync"))
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [
            .init(id: "A", name: "선택됨"), .init(id: "B", name: "아직 선택 안 됨")
        ]).applyingRekordboxSelection(syncA)
        try cached.save(for: folder.database)
        let store = store(folder)
        await store.load(snapshot: folder.database)
        let calls = Mutex(0)
        let source = await store.iTunesSyncSource(captureITunes: {
            calls.withLock { $0 += 1 }
            return .init(status: .unavailable)
        })
        #expect(calls.withLock { $0 } == 0)
        #expect(source.status == .ready)
        #expect(source.sourcePlaylists?.map(\.id) == ["A", "B"])
        #expect(source.selectedIDs == ["A"])
    }

    @Test func 명시적_새로고침과_동기화_원본_변경은_새_캡처를_시작한다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        try syncA.write(to: folder.url.appending(path: "playlists3.sync"))
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "이전")])
            .applyingRekordboxSelection(syncA)
        try cached.save(for: folder.database)
        let store = store(folder)
        await store.load(snapshot: folder.database)
        let calls = Mutex(0)
        let newer = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "새 내용")])
        let refreshed = await store.iTunesSyncSource(forceRefresh: true, captureITunes: {
            calls.withLock { $0 += 1 }
            return newer
        })
        #expect(refreshed.playlists == newer.playlists)
        #expect(calls.withLock { $0 } == 1)

        try (syncA + Data("\n".utf8)).write(to: folder.url.appending(path: "playlists3.sync"))
        let changed = await store.iTunesSyncSource(captureITunes: {
            calls.withLock { $0 += 1 }
            return newer
        })
        #expect(changed.playlists == newer.playlists)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func 명시한_DB는_강제_새로고침에서도_Music을_조회하지_않는다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let cached = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "사본 목록")])
        try cached.save(for: folder.database)
        let arguments = ["test", "--db", folder.database.path]
        let store = store(folder, arguments: arguments)
        await store.load(snapshot: folder.database)
        let calls = Mutex(0)
        let source = await store.iTunesSyncSource(forceRefresh: true, captureITunes: {
            calls.withLock { $0 += 1 }
            return .init(status: .unavailable)
        })
        #expect(calls.withLock { $0 } == 0)
        #expect(source.playlists == cached.playlists)
    }

    @Test func 겹친_선택창은_진행중인_캡처_하나를_공유한다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let store = store(folder)
        await store.load(snapshot: folder.database)
        let calls = Mutex(0)
        let started = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let captured = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "새 목록")])
        let firstReturned = Mutex(false)
        let first = Task {
            let value = await store.iTunesSyncSource(captureITunes: {
                calls.withLock { $0 += 1 }
                started.withLock { $0 = true }
                resume.waitOffPool()
                return captured
            })
            firstReturned.withLock { $0 = true }
            return value
        }
        // 첫 캡처가 시작될 때까지 기다린다. 시간 제한은 없다. 시작하지 않고 끝난 구현이면 더 기다릴 것이 없다.
        let captureStarted = await waitForState(giveUp: { firstReturned.withLock { $0 } }, until: { started.withLock { $0 } })
        guard captureStarted else {
            resume.signal(); _ = await first.value
            Issue.record("첫 캡처가 시작되지 않았습니다")
            return
        }
        let second = Task {
            await store.iTunesSyncSource(captureITunes: {
                calls.withLock { $0 += 1 }
                return .init(status: .unavailable)
            })
        }
        for _ in 0..<100 { await Task.yield() }
        resume.signal()
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(calls.withLock { $0 } == 1)
        #expect(firstResult == captured)
        #expect(secondResult == captured)
    }

    @Test func 강제_캡처가_진행중이어도_유효한_캐시는_즉시_연다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        try syncA.write(to: folder.url.appending(path: "playlists3.sync"))
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "기존 목록")])
            .applyingRekordboxSelection(syncA)
        try cached.save(for: folder.database)
        let store = store(folder)
        await store.load(snapshot: folder.database)
        let started = Mutex(false)
        let refreshReturned = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let refresh = Task {
            let value = await store.iTunesSyncSource(forceRefresh: true, captureITunes: {
                started.withLock { $0 = true }
                resume.waitOffPool()
                return cached
            })
            refreshReturned.withLock { $0 = true }
            return value
        }
        let captureStarted = await waitForState(giveUp: { refreshReturned.withLock { $0 } }, until: { started.withLock { $0 } })
        guard captureStarted else {
            resume.signal(); _ = await refresh.value
            Issue.record("강제 캡처가 시작되지 않았습니다")
            return
        }
        let completed = Mutex(false)
        let reopen = Task {
            let value = await store.iTunesSyncSource(captureITunes: {
                Issue.record("유효한 캐시 대신 Music을 읽었습니다")
                return .init(status: .unavailable)
            })
            completed.withLock { $0 = true }
            return value
        }
        // 강제 캡처는 막혀 있다. 그 채로 다시 연 선택창이 돌아와야 한다(돌아오지 않는 구현은 안전망 시간 뒤에 실패로 끝난다).
        _ = await waitForState(until: { completed.withLock { $0 } })
        let returnedBeforeRefresh = completed.withLock { $0 }
        resume.signal()
        _ = await refresh.value
        let value = await reopen.value
        #expect(returnedBeforeRefresh)
        #expect(value == cached)
    }

    @Test func 더_최근_store_카탈로그가_선택창_임시캐시보다_우선한다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        try syncA.write(to: folder.url.appending(path: "playlists3.sync"))
        let store = store(folder)
        await store.load(snapshot: folder.database)
        let old = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "옛 목록")])
            .applyingRekordboxSelection(syncA)
        _ = await store.iTunesSyncSource(captureITunes: { old })
        let newer = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "새 목록")])
            .applyingRekordboxSelection(syncA)
        store.iTunesSnapshot = newer
        let result = await store.iTunesSyncSource(captureITunes: {
            Issue.record("새 store 카탈로그 대신 Music을 읽었습니다")
            return .init(status: .unavailable)
        })
        #expect(result.sourcePlaylists?.first?.name == "새 목록")
    }

    @Test func 오래_걸린_캡처는_그사이_도착한_store_카탈로그를_덮지_않는다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        try syncA.write(to: folder.url.appending(path: "playlists3.sync"))
        let store = store(folder)
        await store.load(snapshot: folder.database)
        let old = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "옛 목록")])
            .applyingRekordboxSelection(syncA)
        let newer = try ITunesLibrarySnapshot(sourcePlaylists: [.init(id: "A", name: "최신 목록")])
            .applyingRekordboxSelection(syncA)
        let started = Mutex(false)
        let loadingReturned = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let loading = Task {
            let value = await store.iTunesSyncSource(captureITunes: {
                started.withLock { $0 = true }
                resume.waitOffPool()
                return old
            })
            loadingReturned.withLock { $0 = true }
            return value
        }
        let captureStarted = await waitForState(giveUp: { loadingReturned.withLock { $0 } }, until: { started.withLock { $0 } })
        guard captureStarted else {
            resume.signal(); _ = await loading.value
            Issue.record("Music 캡처가 시작되지 않았습니다")
            return
        }
        store.iTunesSnapshot = newer
        resume.signal()
        let lateResult = await loading.value
        #expect(lateResult.sourcePlaylists?.first?.name == "최신 목록")
        let reopened = await store.iTunesSyncSource(captureITunes: {
            Issue.record("최신 Store 캐시 대신 Music을 읽었습니다")
            return .init(status: .unavailable)
        })
        #expect(reopened.sourcePlaylists?.first?.name == "최신 목록")
    }

    @Test func 편집한_체크박스는_새로고침에_남고_편집하지_않은_선택은_원본을_따른다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let sync = folder.url.appending(path: "playlists3.sync")
        try syncA.write(to: sync)
        let catalog: [ITunesLibrarySnapshot.Playlist] = [
            .init(id: "A", name: "첫 목록"), .init(id: "B", name: "둘째 목록")
        ]
        let old = try ITunesLibrarySnapshot(sourcePlaylists: catalog).applyingRekordboxSelection(syncA)
        try old.save(for: folder.database)
        let store = store(folder)
        await store.load(snapshot: folder.database)
        store.presentITunesSync()
        let model = store.iTunesSync
        await model.load(store: store, captureITunes: {
            Issue.record("정상 캐시에서 Music을 다시 읽었습니다")
            return .init(status: .unavailable)
        })
        #expect(model.selection.selectedIDs == ["A"])
        model.selection = .init(selectedIDs: ["B"])
        let fresh = try ITunesLibrarySnapshot(sourcePlaylists: catalog + [.init(id: "C", name: "새 목록")])
            .applyingRekordboxSelection(syncA)
        await model.load(store: store, forceRefresh: true,
                         captureITunes: { fresh })
        #expect(model.selection.selectedIDs == ["B"])
        #expect(model.source.sourcePlaylists?.map(\.id) == ["A", "B", "C"])

        store.presentITunesSync()
        let untouched = store.iTunesSync
        await untouched.load(store: store, captureITunes: { fresh })
        #expect(untouched.selection.selectedIDs == ["A"])
        let syncB = Data(String(decoding: syncA, as: UTF8.self).replacingOccurrences(of: "Id=\"A\"", with: "Id=\"B\"").utf8)
        try syncB.write(to: sync)
        let externallyChanged = try ITunesLibrarySnapshot(sourcePlaylists: catalog).applyingRekordboxSelection(syncB)
        await untouched.load(store: store, forceRefresh: true,
                             captureITunes: { externallyChanged })
        #expect(untouched.selection.selectedIDs == ["B"])
    }

    @Test func 새로고침_실패는_체크박스를_보존하고_다음_성공에서_되살린다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        try syncA.write(to: folder.url.appending(path: "playlists3.sync"))
        let catalog: [ITunesLibrarySnapshot.Playlist] = [
            .init(id: "A", name: "첫 목록"), .init(id: "B", name: "둘째 목록")
        ]
        let cached = try ITunesLibrarySnapshot(sourcePlaylists: catalog).applyingRekordboxSelection(syncA)
        try cached.save(for: folder.database)
        let store = store(folder)
        await store.load(snapshot: folder.database)
        store.presentITunesSync()
        let model = store.iTunesSync
        await model.load(store: store, captureITunes: {
            Issue.record("기존 카탈로그를 다시 읽었습니다")
            return .init(status: .unavailable)
        })
        model.selection = .init(selectedIDs: ["B"])
        await model.load(store: store, forceRefresh: true,
                         captureITunes: { .init(status: .unavailable) })
        #expect(model.source.status == .stale)
        #expect(model.source.sourcePlaylists?.map(\.id) == ["A", "B"])
        #expect(model.selection.selectedIDs == ["B"])
        #expect(!model.canSync)
        let recovered = try ITunesLibrarySnapshot(sourcePlaylists: catalog + [.init(id: "C", name: "셋째 목록")])
            .applyingRekordboxSelection(syncA)
        await model.load(store: store, forceRefresh: true,
                         captureITunes: { recovered })
        #expect(model.source.status == .ready)
        #expect(model.selection.selectedIDs == ["B"])
    }

    @Test func 열린_선택창의_DB가_바뀌면_늦은_결과를_버리고_로딩을_끝낸다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let store = store(folder)
        await store.load(snapshot: folder.database)
        store.presentITunesSync()
        let model = store.iTunesSync
        let started = Mutex(false)
        let loadingReturned = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let loading = Task {
            await model.load(store: store, captureITunes: {
                started.withLock { $0 = true }
                resume.waitOffPool()
                return ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "늦은 목록")])
            })
            loadingReturned.withLock { $0 = true }
        }
        let captureStarted = await waitForState(giveUp: { loadingReturned.withLock { $0 } }, until: { started.withLock { $0 } })
        guard captureStarted else {
            resume.signal(); await loading.value
            Issue.record("Music 캡처가 시작되지 않았습니다")
            return
        }
        await store.load(snapshot: folder.database)
        resume.signal()
        await loading.value
        #expect(!model.isLoading)
        #expect(model.database == nil)
        #expect(model.error != nil)
        #expect(model.source.status == .loading)
    }

    @Test func 닫은_선택창의_늦은_캡처는_새_선택창을_바꾸지_않는다() async throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let store = store(folder)
        await store.load(snapshot: folder.database)
        store.presentITunesSync()
        let old = store.iTunesSync
        let started = Mutex(false)
        let loadingReturned = Mutex(false)
        let resume = DispatchSemaphore(value: 0)
        let loading = Task {
            await old.load(store: store, captureITunes: {
                started.withLock { $0 = true }
                resume.waitOffPool()
                return ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "늦은 목록")])
            })
            loadingReturned.withLock { $0 = true }
        }
        let captureStarted = await waitForState(giveUp: { loadingReturned.withLock { $0 } }, until: { started.withLock { $0 } })
        guard captureStarted else {
            resume.signal(); await loading.value
            Issue.record("Music 캡처가 시작되지 않았습니다")
            return
        }
        store.showingITunesSync = false
        store.presentITunesSync()
        let reopened = store.iTunesSync
        resume.signal()
        await loading.value
        #expect(old.source.status == .loading)
        #expect(reopened.source.status == .loading)
        #expect(reopened.selection.selectedIDs.isEmpty)
    }
}
