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
    /// - Parameter taker: 사본 뜨기(주지 않으면 늘 실패한다)
    /// - Parameter rekordboxRunning: rekordbox가 켜져 있다
    /// - Parameter unsupportedVersion: 설치된 rekordbox가 확인하지 않은 버전이면 그 버전
    static func world(music: MemoryMusicLibrary = MemoryMusicLibrary(), latest: URL? = nil, block: (URL, Gate)? = nil,
                      location: LibraryLocation = L.location(), taker: SnapshotTaker? = nil, rekordboxRunning: Bool = false,
                      unsupportedVersion: String? = nil) -> World {
        let libraries = [first: L.library([L.track("1"), L.track("2")]), second: L.library([L.track("1")])]
        var source = LibrarySource.memory(libraries, latest: latest, rekordboxRunning: rekordboxRunning,
                                          unsupportedRekordboxVersion: unsupportedVersion)
        let read = source.library
        source.library = { url in
            if let block, url == block.0 { block.1.pass() }
            return try read(url)
        }
        let loader = LoadLibrary(source: source, music: music.source, drafts: MemoryDrafts().store, order: ITunesRefreshCoordinator(),
                                 snapshots: taker ?? SnapshotTaker { _ in throw DJCError.snapshotNotFound },
                                 usbSnapshots: UsbSyncSnapshots(stamp: { _ in throw DJCError.snapshotNotFound },
                                                                lease: { _, _ in throw DJCError.snapshotNotFound }))
        let flow = LibraryReadFlow(loader: loader, location: location)
        let screen = FakeLibraryReadScreen()
        flow.screen = screen.port
        // 시험은 걸린 시간으로 판정하지 않는다(TEST-30): 자동 다시 읽기의 기다림은 없앤다
        flow.retryPause = {}
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
    // MARK: - 첫 실행·다시 시도 (#299)

    @Test func 저장된_사본이_없으면_바로_사본을_떠_읽는다() async {
        let forces = Record<Bool>()
        let w = Self.world(taker: SnapshotTaker { force in forces.append(force); return Self.first })

        await w.flow.loadInitial()

        #expect(forces.list == [false])
        #expect(w.screen.adopted.map(\.snapshot) == [Self.first])
        #expect(w.screen.state.phase == .loaded)
    }

    @Test func 첫_실행에서_rekordbox가_켜져_있으면_억지로_떠서_읽는다() async {
        let forces = Record<Bool>()
        let w = Self.world(taker: SnapshotTaker { force in forces.append(force); return Self.first }, rekordboxRunning: true)

        await w.flow.loadInitial()

        #expect(forces.list == [true])
        #expect(w.screen.state.phase == .loaded)
    }

    @Test func 진단_실행은_사본이_없어도_자동으로_읽지_않는다() async {
        let forces = Record<Bool>()
        let w = Self.world(taker: SnapshotTaker { force in forces.append(force); return Self.first })
        w.flow.readsOnFirstRun = false

        await w.flow.loadInitial()

        #expect(forces.list.isEmpty)
        #expect(w.screen.state.phase == .idle)
    }

    @Test func 명시한_사본으로_열면_사본을_뜨지_않고_그_사본을_읽는다() async {
        let forces = Record<Bool>()
        let w = Self.world(location: L.location(explicitCopy: Self.first), taker: SnapshotTaker { force in forces.append(force); return Self.second })

        await w.flow.loadInitial()

        #expect(forces.list.isEmpty)
        #expect(w.screen.adopted.map(\.snapshot) == [Self.first])
    }

    /// 처음 읽기에 실패하고 저장된 사본이 없으면 [다시 시도](= `loadInitial`)가 같은 "사본이 없습니다" 화면으로 돌아가던 버그(C12)
    @Test func 사본_뜨기에_실패한_뒤_다시_시도하면_다시_사본을_뜬다() async {
        let attempts = Record<Int>()
        let w = Self.world(taker: SnapshotTaker { _ in
            attempts.append(attempts.list.count + 1)
            if attempts.list.count == 1 { throw CocoaError(.fileReadNoSuchFile) }
            return Self.first
        })

        await w.flow.takeSnapshot()
        guard case .failed = w.screen.state.phase else {
            Issue.record("첫 시도가 실패 화면이 아니다: \(w.screen.state.phase)")
            return
        }
        await w.flow.loadInitial()

        #expect(attempts.list == [1, 2])
        #expect(w.screen.state.phase == .loaded)
        #expect(w.screen.adopted.map(\.snapshot) == [Self.first])
    }

    @Test func 다시_시도는_저장된_사본이_있어도_새_사본을_떠서_읽는다() async {
        let forces = Record<Bool>()
        // 저장된 사본(읽을 수 없는 파일)을 읽다 실패한 뒤
        let broken = L.snapshots.appending(path: "master-2026-01-01T000200.db")
        let w = Self.world(latest: broken, taker: SnapshotTaker { force in forces.append(force); return Self.second })
        await w.flow.loadInitial()
        guard case .failed = w.screen.state.phase else {
            Issue.record("저장된 사본을 못 읽었는데 실패 화면이 아니다: \(w.screen.state.phase)")
            return
        }

        await w.flow.retry()

        #expect(forces.list == [false])
        #expect(w.screen.adopted.map(\.snapshot) == [Self.second])
        #expect(w.screen.state.phase == .loaded)
    }

    @Test func 다시_시도에서_rekordbox가_켜져_있으면_억지로_뜬다() async {
        let forces = Record<Bool>()
        let w = Self.world(taker: SnapshotTaker { force in forces.append(force); return Self.first }, rekordboxRunning: true)
        w.flow.readsOnFirstRun = false

        await w.flow.retry()

        #expect(forces.list == [true])
        #expect(w.screen.state.phase == .loaded)
    }

    @Test func 명시한_사본의_다시_시도는_그_사본을_다시_읽는다() async {
        let forces = Record<Bool>()
        let w = Self.world(location: L.location(explicitCopy: Self.first), taker: SnapshotTaker { force in forces.append(force); return Self.second })

        await w.flow.retry()

        #expect(forces.list.isEmpty)
        #expect(w.screen.adopted.map(\.snapshot) == [Self.first])
    }

    // MARK: - 원인별 실패 (#299)

    @Test(arguments: [
        (CocoaError(.fileReadNoSuchFile) as any Error, LibraryReadFailure.Cause.libraryMissing),
        (CocoaError(.fileReadNoPermission) as any Error, .permissionDenied),
        (DJCError.databaseOpenFailed(path: "/x", message: "m") as any Error, .other),
    ])
    func 사본_뜨기_실패는_원인을_가려_알린다(_ error: any Error, _ cause: LibraryReadFailure.Cause) async {
        let w = Self.world(taker: SnapshotTaker { _ in throw error })

        await w.flow.takeSnapshot()

        #expect(w.screen.failures.map(\.cause) == [cause])
        #expect(w.screen.failures.first?.stage == .snapshotCreation)
        #expect(w.screen.failures.first?.keepsPreviousLibrary == false)
    }

    @Test func 복사하는_사이_바뀌면_알리고_자동으로_다시_뜬다() async {
        let attempts = Record<Int>()
        let pauses = Record<Int>()
        let w = Self.world(taker: SnapshotTaker { _ in
            attempts.append(attempts.list.count + 1)
            if attempts.list.count <= 2 { throw DJCError.sourceChangedDuringCopy(path: "/x/master.db") }
            return Self.first
        })
        w.flow.retryPause = { pauses.append(pauses.list.count + 1) }

        await w.flow.takeSnapshot()

        #expect(attempts.list == [1, 2, 3])
        #expect(pauses.list == [1, 2])
        #expect(w.screen.failures.isEmpty)
        #expect(w.screen.state.phase == .loaded)
        // 기다리는 동안 이유를 알린다
        #expect(w.screen.events.contains("phase loading(\"\(LibraryReadFailure.retryingMessage)\")"))
    }

    @Test func 복사_중_바뀜이_계속되면_횟수에서_멈추고_그_밖_실패로_알린다() async {
        let attempts = Record<Int>()
        let w = Self.world(taker: SnapshotTaker { _ in
            attempts.append(attempts.list.count + 1)
            throw DJCError.sourceChangedDuringCopy(path: "/x/master.db")
        })

        await w.flow.takeSnapshot()

        #expect(attempts.list.count == 1 + LibraryReadFlow.copyRetryLimit)
        #expect(w.screen.failures.map(\.cause) == [.other])
        #expect(w.screen.failures.first?.detail?.contains("/x/master.db") == true)
    }

    @Test func 이전_목록이_있으면_복사_중_바뀜도_조용히_다시_뜨고_화면을_바꾸지_않는다() async {
        let attempts = Record<Int>()
        let w = Self.world(taker: SnapshotTaker { _ in
            attempts.append(attempts.list.count + 1)
            if attempts.list.count == 1 { throw DJCError.sourceChangedDuringCopy(path: "/x/master.db") }
            return Self.second
        })
        await w.flow.load(snapshot: Self.first)
        let before = w.screen.events.count

        await w.flow.takeSnapshot(quiet: true)

        #expect(attempts.list == [1, 2])
        #expect(!w.screen.events.dropFirst(before).contains { $0.hasPrefix("phase loading") })
        #expect(w.screen.state.snapshot == Self.second)
    }

    // MARK: - 지원하지 않는 rekordbox 버전 (#299)

    @Test func 지원하지_않는_버전이면_읽은_뒤_알리고_목록은_그대로_보인다() async {
        let w = Self.world(unsupportedVersion: "7.3.1")

        await w.flow.load(snapshot: Self.first)

        #expect(w.screen.unsupportedVersions == ["7.3.1"])
        #expect(w.screen.state.phase == .loaded)
        #expect(w.screen.failures.isEmpty)
    }

    @Test func 지원하지_않는_버전은_다시_읽어도_한_번만_알린다() async {
        let w = Self.world(unsupportedVersion: "6.8.5")

        await w.flow.load(snapshot: Self.first)
        await w.flow.load(snapshot: Self.second)

        #expect(w.screen.unsupportedVersions == ["6.8.5"])
    }

    @Test func 확인한_버전이면_알리지_않는다() async {
        let w = Self.world()

        await w.flow.load(snapshot: Self.first)

        #expect(w.screen.unsupportedVersions.isEmpty)
    }

    @Test func 사본_폴더나_명시한_사본으로_열면_버전을_알리지_않는다() async {
        let overridden = Self.world(location: L.location(overridden: true), unsupportedVersion: "7.3.1")
        await overridden.flow.load(snapshot: Self.first)
        let explicit = Self.world(location: L.location(explicitCopy: Self.first), unsupportedVersion: "7.3.1")
        await explicit.flow.load(snapshot: Self.first)

        #expect(overridden.screen.unsupportedVersions.isEmpty)
        #expect(explicit.screen.unsupportedVersions.isEmpty)
    }
    @Test func 첫_실행_읽기도_받은_Music_조회와_사본_폴더를_넘긴다() async {
        let captures = Record<Int>()
        let folders = Record<URL>()
        let other = URL(filePath: "/fake/other-snapshots")
        let w = Self.world(taker: SnapshotTaker { _ in Self.first })

        await w.flow.loadInitial(snapshotDirectory: other, capture: {
            captures.append(captures.list.count + 1)
            folders.append(other)
            return Self.catalog(["A"], selected: ["A"])
        })

        // 호출한 쪽이 준 Music 조회가 실제 Music 포트 대신 쓰였다
        #expect(captures.list == [1])
        #expect(w.screen.adopted.map(\.snapshot) == [Self.first])
    }

    /// 복사 중 바뀜을 기다리다 취소되면 "rekordbox가 라이브러리를 쓰는 중" 읽는 중 화면에 남지 않는다
    @Test func 복사_중_바뀜을_기다리다_취소하면_읽는_중_화면에_남지_않는다() async {
        final class Holder: Sendable {
            private let task = Mutex<Task<Void, Never>?>(nil)
            func set(_ value: Task<Void, Never>) { task.withLock { $0 = value } }
            func cancel() { task.withLock { $0 }?.cancel() }
        }
        let holder = Holder()
        let attempts = Record<Int>()
        let w = Self.world(taker: SnapshotTaker { _ in
            attempts.append(attempts.list.count + 1)
            throw DJCError.sourceChangedDuringCopy(path: "/x/master.db")
        })
        w.flow.retryPause = { holder.cancel() }

        let task = Task { await w.flow.takeSnapshot() }
        holder.set(task)
        await task.value

        // 한 번 더 뜨지 않고 멈춘다. 읽는 중 화면도 실패 화면도 남지 않는다
        #expect(attempts.list == [1])
        #expect(w.screen.state.phase == .idle)
        #expect(w.screen.failures.isEmpty)
    }

    @Test func 자세히_보기_원문은_위치_값의_홈_폴더를_물결표로_줄인다() async {
        var location = L.location()
        location.userHome = "/Users/dj"
        let w = Self.world(location: location, taker: SnapshotTaker { _ in
            throw DJCError.databaseOpenFailed(path: "/Users/dj/Library/Application Support/DJCrate/snapshots/master.db", message: "bad")
        })

        await w.flow.takeSnapshot()

        let detail = w.screen.failures.first?.detail ?? ""
        #expect(detail.contains("~/Library/Application Support/DJCrate/snapshots/master.db"))
        #expect(!detail.contains("/Users/dj"))
    }
}
