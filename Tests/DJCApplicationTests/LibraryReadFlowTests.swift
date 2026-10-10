import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Synchronization
import Testing

/// 라이브러리 읽기 순서(유스케이스 `LibraryReadFlow`). 옛 `LibraryStore+Loading`·`+MusicRefresh`·`+ITunesSync`가 정하던 순서를
/// 가짜 화면(`FakeLibraryReadScreen`)과 메모리 포트로 본다: 늦게 끝난 옛 결과 버리기, 사본 뜨기 요청 합치기, 읽은 뒤·최신화 뒤 다시 읽기.
@MainActor
@Suite("라이브러리 읽기 순서")
struct LibraryReadFlowTests {
    typealias L = LoadLibraryTests

    nonisolated static let first = L.snapshots.appending(path: "master-2026-01-01T000000.db")
    nonisolated static let second = L.snapshots.appending(path: "master-2026-01-01T000100.db")

    /// 메인 밖 일을 붙드는 문. 한 번 열면 기다리던 일과 뒤에 오는 일이 모두 지나간다
    final class Gate: Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let count = Mutex(0)
        func pass() {
            count.withLock { $0 += 1 }
            semaphore.wait()
            semaphore.signal()
        }
        var entered: Int { count.withLock { $0 } }
        func open() { semaphore.signal() }
    }

    /// 차례로 남기는 값
    final class Record<Value: Sendable>: Sendable {
        private let value = Mutex<[Value]>([])
        func append(_ item: Value) { value.withLock { $0.append(item) } }
        var list: [Value] { value.withLock { $0 } }
    }

    struct World {
        let flow: LibraryReadFlow
        let screen: FakeLibraryReadScreen
        let music: MemoryMusicLibrary
    }

    /// 메모리 라이브러리 두 사본(`first`·`second`)과 가짜 화면을 묶은 흐름
    /// - Parameter block: 이 사본을 읽을 때 문에서 기다린다
    static func world(music: MemoryMusicLibrary = MemoryMusicLibrary(), latest: URL? = nil, block: (URL, Gate)? = nil,
                      location: LibraryLocation = L.location()) -> World {
        let libraries = [first: L.library([L.track("1"), L.track("2")]), second: L.library([L.track("1")])]
        var source = LibrarySource.memory(libraries, latest: latest)
        let read = source.library
        source.library = { url in
            if let block, url == block.0 { block.1.pass() }
            return try read(url)
        }
        let loader = LoadLibrary(source: source, music: music.source, drafts: MemoryDrafts().store, order: ITunesRefreshCoordinator(),
                                 snapshots: SnapshotTaker { _ in throw DJCError.snapshotNotFound },
                                 usbSnapshots: UsbSyncSnapshots(stamp: { _ in throw DJCError.snapshotNotFound },
                                                                lease: { _, _ in throw DJCError.snapshotNotFound }))
        let flow = LibraryReadFlow(loader: loader, location: location)
        let screen = FakeLibraryReadScreen()
        flow.screen = screen.port
        return World(flow: flow, screen: screen, music: music)
    }

    /// 동기화 선택 창에 바로 쓸 수 있는 전체 목록(동기화 원문은 `ids`)
    nonisolated static func catalog(_ playlists: [String], selected ids: [String]) -> ITunesLibrarySnapshot {
        let all = playlists.map { ITunesLibrarySnapshot.Playlist(id: $0, name: "목록 \($0)") }
        var snapshot = ITunesLibrarySnapshot(playlists: all.filter { ids.contains($0.id) }, sourcePlaylists: all, selectedIDs: Set(ids))
        snapshot.syncData = MemoryMusicLibrary.syncData(ids)
        return snapshot
    }

    /// 상태를 기다린다. 안전망(300초)은 판정이 오지 않는 잘못된 구현에서 시험이 멈추지 않게 할 뿐이다(TEST-30~32)
    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(300)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    // MARK: - 옛 결과 버리기

    @Test func 늦게_끝난_옛_읽기는_버리고_새_읽기만_화면에_넣는다() async throws {
        let gate = Gate()
        let w = Self.world(block: (Self.first, gate))

        let older = Task { await w.flow.load(snapshot: Self.first) }
        try await waitUntil { gate.entered == 1 }
        await w.flow.load(snapshot: Self.second)
        gate.open()
        await older.value

        #expect(w.screen.adopted.map(\.snapshot) == [Self.second])
        #expect(w.screen.state.snapshot == Self.second)
    }

    @Test func 늦게_끝난_Music_최신화는_새_읽기가_시작되면_목록에_넣지_않는다() async throws {
        let gate = Gate()
        let w = Self.world()
        await w.flow.load(snapshot: Self.first)
        let captured = Self.catalog(["A"], selected: ["A"])

        let refresh = w.flow.startMusicRefresh(snapshot: Self.first, quiet: true, previous: nil, fallbackDirectory: L.snapshots,
                                               sourceDatabase: nil, capture: { gate.pass(); return captured })
        try await waitUntil { gate.entered == 1 }
        #expect(w.screen.state.musicStatus == .loading)
        await w.flow.load(snapshot: Self.second)
        gate.open()
        await refresh.value

        #expect(w.screen.music.isEmpty)
        #expect(w.flow.musicRefresh == nil)
        #expect(w.screen.state.snapshot == Self.second)
    }

    @Test func 같은_사본을_다시_읽으면_그_전에_시작한_Music_최신화는_목록에_넣지_않는다() async throws {
        let gate = Gate()
        let w = Self.world()
        await w.flow.load(snapshot: Self.first)
        let captured = Self.catalog(["A"], selected: ["A"])

        let refresh = w.flow.startMusicRefresh(snapshot: Self.first, quiet: true, previous: nil, fallbackDirectory: L.snapshots,
                                               sourceDatabase: nil, capture: { gate.pass(); return captured })
        try await waitUntil { gate.entered == 1 }
        // 사본이 같아 세대만 결과를 가른다
        await w.flow.load(snapshot: Self.first)
        gate.open()
        await refresh.value

        #expect(w.screen.adopted.map(\.snapshot) == [Self.first, Self.first])
        #expect(w.screen.music.isEmpty)
        #expect(w.flow.musicRefresh == nil)
    }

    // MARK: - 요청 합치기

    @Test func 사본을_뜨는_동안_온_요청은_하나로_합쳐_한_번만_더_뜬다() async throws {
        let gate = Gate()
        let w = Self.world()
        let forces = Record<Bool>()
        let copy: @Sendable (Bool) throws -> URL = { force in
            forces.append(force)
            if forces.list.count == 1 { gate.pass(); return Self.first }
            return Self.second
        }

        let running = Task { await w.flow.takeSnapshot(refreshMusic: false, copy: copy) }
        try await waitUntil { gate.entered == 1 }
        let quiet = Task { await w.flow.takeSnapshot(quiet: true, refreshMusic: false, copy: copy) }
        try await waitUntil { w.flow.waitingSnapshotRequests == 1 }
        let forced = Task { await w.flow.takeSnapshot(force: true, quiet: true, refreshMusic: false, copy: copy) }
        try await waitUntil { w.flow.waitingSnapshotRequests == 2 }
        gate.open()
        await running.value
        await quiet.value
        await forced.value

        // 기다린 두 요청은 한 번에 뜬다. 하나라도 억지로 뜨라고 했으면 억지로 뜬다
        #expect(forces.list == [false, true])
        #expect(w.screen.adopted.map(\.snapshot) == [Self.first, Self.second])
    }

    // MARK: - 읽은 뒤·최신화 뒤 다시 읽기

    @Test func 처음_열_때_사본_옆_목록이_지금_선택과_같으면_먼저_보이고_Music은_뒤에서_최신화한다() async throws {
        let music = MemoryMusicLibrary()
        music.setCached(Self.catalog(["A", "B"], selected: ["A"]), for: Self.first)
        music.setSelection(["A"], in: L.root)
        music.setCapture(Self.catalog(["A", "B", "C"], selected: ["A"]))
        let w = Self.world(music: music, latest: Self.first)

        await w.flow.loadInitial()
        // 읽기는 Music을 기다리지 않는다
        #expect(w.screen.adopted.map(\.snapshot) == [Self.first])
        #expect(w.screen.state.music.sourcePlaylists?.map(\.id) == ["A", "B"])
        let refresh = try #require(w.flow.musicRefresh)
        await refresh.task.value

        #expect(music.captureCount == 1)
        #expect(w.screen.music.map { $0.sourcePlaylists?.map(\.id) } == [["A", "B", "C"]])
        #expect(!w.screen.events.contains { $0.hasPrefix("phase loading") && $0.contains(LoadedLibrary.Stage.music.message) })
    }

    @Test func 사본_뜨기는_읽은_뒤_Music_최신화가_끝날_때까지_기다린다() async {
        let music = MemoryMusicLibrary()
        music.setCapture(Self.catalog(["A"], selected: ["A"]))
        let w = Self.world(music: music)

        await w.flow.takeSnapshot(copy: { _ in Self.first })

        #expect(w.screen.adopted.map(\.snapshot) == [Self.first])
        #expect(w.screen.music.count == 1)
        #expect(w.flow.musicRefresh == nil)
        #expect(w.screen.state.phase == .loaded)
    }

    @Test func 쓰기_뒤_다시_읽기는_버린_Music_조회를_새_사본에서_이어받는다() async throws {
        let gate = Gate()
        let w = Self.world()
        await w.flow.load(snapshot: Self.first)
        let captures = Record<Int>()
        let captured = Self.catalog(["A"], selected: ["A"])
        w.flow.startMusicRefresh(snapshot: Self.first, quiet: true, previous: nil, fallbackDirectory: L.snapshots, sourceDatabase: nil,
                                 capture: { captures.append(1); gate.pass(); return captured })
        try await waitUntil { gate.entered == 1 }
        let interrupted = try #require(w.flow.musicRefresh)

        // 쓰기 뒤 다시 읽기는 Music을 기다리지 않는다(후속 작업 없이 돌아온다)
        await w.flow.takeSnapshot(force: true, quiet: true, refreshMusic: false, copy: { _ in Self.second })
        let continued = try #require(w.flow.musicRefresh)
        #expect(continued.capture == interrupted.capture && continued.id != interrupted.id)
        gate.open()
        await continued.task.value

        #expect(captures.list.count == 1)
        #expect(w.screen.state.snapshot == Self.second)
        #expect(w.screen.music.count == 1)
    }

    @Test func 창으로_돌아와_동기화_선택만_바뀌었으면_같은_사본을_Music과_함께_다시_읽는다() async {
        let music = MemoryMusicLibrary()
        music.setCached(Self.catalog(["A", "B"], selected: ["A"]), for: Self.first)
        music.setSelection(["A"], in: L.root)
        let w = Self.world(music: music)
        await w.flow.load(snapshot: Self.first)
        music.setSelection(["B"], in: L.root)
        music.setCapture(Self.catalog(["A", "B"], selected: ["B"]))

        await w.flow.refreshIfChanged()

        #expect(w.screen.adopted.map(\.snapshot) == [Self.first, Self.first])
        #expect(music.captureCount == 1)
        #expect(w.screen.state.music.selectedIDs == ["B"])
    }

    @Test func 동기화_창은_Music_최신화가_도는_동안_캐시를_보이고_끝나면_새_목록으로_다시_연다() async throws {
        let gate = Gate()
        let music = MemoryMusicLibrary()
        music.setCached(Self.catalog(["A", "B"], selected: ["A"]), for: Self.first)
        music.setSelection(["A"], in: L.root)
        let w = Self.world(music: music)
        await w.flow.load(snapshot: Self.first)
        let latest = Self.catalog(["A", "B", "C"], selected: ["A"])
        w.flow.startMusicRefresh(snapshot: Self.first, quiet: true, previous: nil, fallbackDirectory: L.snapshots, sourceDatabase: nil,
                                 capture: { gate.pass(); return latest })
        try await waitUntil { gate.entered == 1 }

        let opening = await w.flow.openSyncWindow(shown: ITunesSyncShown(source: ITunesLibrarySnapshot(status: .loading),
                                                                         selection: ITunesSyncSelection()))
        guard case let .opened(cached) = opening else { Issue.record("창을 열지 못했다: \(opening)"); return }
        #expect(cached.source.sourcePlaylists?.map(\.id) == ["A", "B"])
        #expect(cached.selection.selectedIDs == ["A"])
        let refresh = try #require(cached.refresh)
        gate.open()
        await refresh.value

        let reopened = await w.flow.openSyncWindow(shown: ITunesSyncShown(source: cached.source, selection: cached.selection),
                                                   capture: { latest })
        guard case let .opened(fresh) = reopened else { Issue.record("다시 열지 못했다: \(reopened)"); return }
        #expect(fresh.refresh == nil)
        #expect(fresh.source.sourcePlaylists?.map(\.id) == ["A", "B", "C"])
    }

    @Test func 동기화_창을_여는_사이_라이브러리가_바뀌면_목록을_버린다() async throws {
        let gate = Gate()
        let w = Self.world()
        await w.flow.load(snapshot: Self.first)
        let catalog = Self.catalog(["A"], selected: ["A"])

        let opening = Task {
            await w.flow.openSyncWindow(shown: ITunesSyncShown(source: ITunesLibrarySnapshot(status: .loading), selection: ITunesSyncSelection()),
                                        capture: { gate.pass(); return catalog })
        }
        try await waitUntil { gate.entered == 1 }
        await w.flow.load(snapshot: Self.second)
        gate.open()

        guard case .superseded = await opening.value else { Issue.record("바뀐 라이브러리의 목록을 보였다"); return }
    }

    @Test func 동기화_쓰기는_Music_최신화가_도는_동안_막고_끝나면_쓴_뒤_기다리던_읽기를_버린다() async throws {
        let gate = Gate()
        let music = MemoryMusicLibrary()
        music.setCached(Self.catalog(["A", "B"], selected: ["A"]), for: Self.first)
        music.setSelection(["A"], in: L.root)
        let w = Self.world(music: music)
        await w.flow.load(snapshot: Self.first)
        let source = w.screen.state.music
        let writes = Record<ITunesSyncSelection>()
        let write: (ITunesSyncWrite) async throws -> (target: URL, syncData: Data) = { request in
            writes.append(request.selection)
            return (L.root.appending(path: "master.db"), MemoryMusicLibrary.syncData(["B"]))
        }
        let refresh = w.flow.startMusicRefresh(snapshot: Self.first, quiet: true, previous: nil, fallbackDirectory: L.snapshots,
                                               sourceDatabase: nil, capture: { gate.pass(); return source })
        try await waitUntil { gate.entered == 1 }

        let selection = ITunesSyncSelection(selectedIDs: ["B"])
        let refused = await #expect(throws: DJCError.self) {
            try await w.flow.syncMusic(selection, source: source, database: Self.first, write: write) { _ in }
        }
        guard case let .writeRefused(reason)? = refused else { Issue.record("막지 않았다: \(String(describing: refused))"); return }
        #expect(reason == LibraryReadFlow.waitingForMusicMessage)
        #expect(writes.list.isEmpty)
        gate.open()
        await refresh.value

        let before = w.flow.reads.generation
        var published: LoadLibrary.SyncedSelection?
        try await w.flow.syncMusic(selection, source: w.screen.state.music, database: Self.first, write: write) { published = $0 }

        #expect(writes.list == [selection])
        #expect(published?.selected.selectedIDs == ["B"] && published?.visible == true)
        // 쓰기 전후로 기다리던 읽기를 버린다
        #expect(w.flow.reads.generation == before + 2)
    }
}
