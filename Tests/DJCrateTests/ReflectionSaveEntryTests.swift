@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
@testable import RekordboxKit
import Synchronization
import Testing

/// 저장 단추가 있는 모든 자리(상태 줄·상태 팝오버·저장 대기 목록 머리 줄·곡 메뉴·⌘S)가 R3 표를 따르고 같은 저장 입구로 실행한다(#404 sol 1라운드 S2~S6).
/// - S2: 단추 보임·실행이 자리마다 같다(줄 6~8만 보인다)
/// - S3: 입구가 가져오기 시트·막힌 초안 비교 창·USB 쓰기를 지금 상태로 다시 본다
/// - S4: 저장 중 ⌘S는 요청 하나를 보관해 지금 쓰기 뒤 다음 자동 저장보다 먼저 한다
/// - S5: 엔진이 있으면 ⌘S·[저장]은 선택·필터와 무관하게 저장 대기 전체
/// - S6: 입력 확정이 끝난 것을 받은 뒤 줄과 대상을 계산한다
@MainActor
@Suite("저장 입구 R3 표")
struct ReflectionSaveEntryTests {
    typealias Harness = ReflectionStatusModelTests.Harness

    @MainActor
    struct World {
        let h: Harness
        let feed = AutoReflectionFeed()
        let rows: [TrackRow]
    }

    /// 곡 `uuids`가 저장 대기에 있는 저장소와 엔진 상태를 넣은 하네스
    func world(_ status: AutoReflectionStatus = .pending, holds: Set<ReflectionHold> = [], leftovers: Set<ReflectionLeftover> = [],
               pending uuids: [String] = ["a"], autoSaves: Bool = true) -> World {
        let h = Harness()
        let rows = uuids.map { PendingCountCacheTests.track($0) }
        h.store.showRows(rows)
        for row in rows {
            h.store.rowsByUUID[row.track.uuid] = row
            h.store.rowsByID[row.id] = row
            h.store.setDraftMark(.cue, trackUUID: row.track.uuid, exists: true)
        }
        let world = World(h: h, rows: rows)
        h.window.autoFeed = world.feed
        world.feed.update(status, ReflectionConditions(holds: holds, leftovers: leftovers, hasPending: !uuids.isEmpty, autoSaves: autoSaves))
        return world
    }

    /// 줄 하나를 만드는 대표 조건으로 만든 하네스
    func world(forRow row: ReflectionStatusRow) -> World {
        let holds: Set<ReflectionHold>, leftovers: Set<ReflectionLeftover>
        switch row {
        case .interrupted: (holds, leftovers) = ([.interrupted(recoveryFailed: false)], [])
        case .unwritable: (holds, leftovers) = ([.unwritable(.counters)], [])
        case .busy: (holds, leftovers) = ([.rekordboxRunning], [])
        case .stopped: (holds, leftovers) = ([.stoppedAfterFailure], [])
        case .leftover: (holds, leftovers) = ([], [.suggestion])
        default: (holds, leftovers) = ([], [])
        }
        let w = world(.pending, holds: holds, leftovers: leftovers, pending: row == .nothingPending ? [] : ["a"], autoSaves: row != .manualRun)
        if row == .writing { w.feed.update(.writing, ReflectionConditions(writing: true, hasPending: true, autoSaves: true)) }
        return w
    }

    func press(_ w: World, gate: RekordboxWriteGate = .restoringOnly) -> ReflectionCoordinator {
        let coordinator = ReflectionCoordinator.test(store: w.h.store, gate: gate)
        LibraryMenuAction.reflect.perform(in: w.h.window, windows: nil, reflection: coordinator)
        return coordinator
    }

    // MARK: - S3: 저장 입구가 지금 상태를 다시 본다

    @Test(arguments: [
        (ReflectionHold.importSheetOpen, "가져오기 창에서 적용하거나 닫은 뒤 다시 시도하세요", "가져오기 창이 열려 있습니다 · 저장 대기 1건"),
        (.blockedDraftsOpen, "막힌 편집 비교가 열려 있어 저장하지 않았습니다", "막힌 편집 비교 창이 열려 있습니다 · 저장 대기 1건"),
        (.usbBusy, "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 시도하세요", "USB에 쓰는 중… · 저장 대기 1건"),
    ])
    func 엔진이_알린_뒤_열린_시트와_USB_쓰기도_저장_입구가_3번_줄로_본다(_ hold: ReflectionHold, _ reason: String, _ title: String) {
        let w = world(.pending)
        #expect(w.h.window.saveRow == .waiting, "엔진 발행은 아직 모른다")
        // 발행 뒤에 시트가 열렸다(다음 발행 전)
        w.h.window.liveHolds = { [hold] }
        #expect(w.h.window.saveRow == .busy)
        #expect(!w.h.model.showsWriteButton && w.h.model.line.title == title, "상태 줄도 같은 줄을 본다")
        #expect(LibraryMenuAction.reflect.isEnabled(in: w.h.window))
        _ = press(w)
        #expect(w.h.store.writeTask == nil, "예전 줄(9번)로 쓰지 않는다")
        #expect(w.h.store.toast?.title == reason, "\(String(describing: w.h.store.toast?.title))")
    }

    @Test func 남은_편집_줄의_단추도_발행_뒤_열린_시트가_숨긴다() {
        let w = world(.leftover(count: 1), leftovers: [.suggestion])
        #expect(w.h.model.showsWriteButton)
        w.h.window.liveHolds = { [.importSheetOpen] }
        #expect(!w.h.model.showsWriteButton && w.h.window.saveRow == .busy)
    }

    // MARK: - S5: 선택·필터와 무관하게 전체

    @Test func 엔진이_있으면_저장할_곡은_선택과_상관없이_저장_대기_전체다() {
        let w = world(.leftover(count: 2), leftovers: [.outsideScope], pending: ["a", "b"])
        w.h.store.selection = [w.rows[1].id]
        #expect(w.h.window.saveRows.map(\.track.uuid) == ["a", "b"], "\(w.h.window.saveRows.map(\.track.uuid))")
        w.h.store.selection = []
        #expect(w.h.window.saveRows.map(\.track.uuid) == ["a", "b"])
    }

    @Test func 저장_대기_목록_머리_줄_단추_이름은_선택과_상관없이_전체_곡_수다() {
        let w = world(.leftover(count: 2), leftovers: [.outsideScope], pending: ["a", "b"])
        w.h.store.sidebar = .pending
        w.h.store.rowsByID = Dictionary(uniqueKeysWithValues: w.rows.map { ($0.id, $0) })
        w.h.store.showRows(w.rows)
        w.h.store.selection = [w.rows[1].id]
        let bar = ListActionBarModel(store: w.h.store)
        bar.window = w.h.window
        #expect(bar.actions.primary?.title == "전체 2곡 저장", "\(String(describing: bar.actions.primary?.title))")
        // 엔진이 없는 조립은 지금처럼 고른 곡만이다
        bar.window = nil
        #expect(bar.actions.primary?.title == "고른 1곡 저장", "\(String(describing: bar.actions.primary?.title))")
    }

    // MARK: - S2: 저장 단추가 있는 자리가 모두 같은 줄을 따른다

    @Test(arguments: [
        (ReflectionStatusRow.interrupted, false), (.unwritable, false), (.busy, false), (.nothingPending, false), (.writing, false),
        (.manualRun, true), (.stopped, true), (.leftover, true), (.waiting, false),
    ])
    func 저장_대기_목록_머리_줄_단추는_상태_줄_단추와_같은_줄에서만_보인다(_ row: ReflectionStatusRow, _ shown: Bool) {
        let w = world(forRow: row)
        w.h.store.sidebar = .pending
        let bar = ListActionBarModel(store: w.h.store)
        bar.window = w.h.window
        #expect(w.h.window.saveRow == row)
        #expect((bar.actions.primary != nil) == shown, "\(row)")
        #expect(row.showsSaveButton == shown && w.h.model.showsWriteButton == shown, "상태 줄 단추와 같다")
    }

    @Test func 저장_대기_목록_머리_줄_단추도_엔진이_없으면_늘_보인다() {
        let bar = ListActionBarModel(store: Harness().store)
        bar.store.sidebar = .pending
        #expect(bar.actions.primary != nil)
    }

    @Test func 머리_줄_저장_단추는_공통_저장_입구로_실행한다_3번_줄이면_이유만_보인다() {
        let w = world(.held(.usbBusy), holds: [.usbBusy], leftovers: [.suggestion])
        w.h.store.sidebar = .pending
        let bar = ListActionBarModel(store: w.h.store)
        let coordinator = ReflectionCoordinator.test(store: w.h.store, gate: .restoringOnly)
        bar.perform(.writePending, reflection: coordinator, window: w.h.window)
        #expect(w.h.store.writeTask == nil && w.h.store.toast?.title == "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 시도하세요")
    }

    @Test func 머리_줄_저장_단추는_남은_편집_줄에서_저장_대기_전체를_쓴다() async {
        let w = world(.leftover(count: 2), leftovers: [.outsideScope], pending: ["a", "b"])
        w.h.store.sidebar = .pending
        w.h.store.selection = [w.rows[1].id]
        let bar = ListActionBarModel(store: w.h.store)
        let coordinator = ReflectionCoordinator.test(store: w.h.store, gate: .restoringOnly)
        bar.perform(.writePending, reflection: coordinator, window: w.h.window)
        let task = w.h.store.writeTask
        await task?.value
        #expect(task != nil)
    }

    @Test(arguments: [
        (ReflectionStatusRow.interrupted, false), (.unwritable, false), (.busy, false), (.nothingPending, false), (.writing, false),
        (.manualRun, true), (.stopped, true), (.leftover, true), (.waiting, false),
    ])
    func 상태_팝오버의_저장_항목도_같은_줄에서만_보인다(_ row: ReflectionStatusRow, _ shown: Bool) {
        let w = world(forRow: row)
        #expect(w.h.window.saveRow == row, "\(String(describing: w.h.window.saveRow))")
        #expect(w.h.model.items.map(\.action).contains(.reflect) == shown, "\(row): \(w.h.model.items.map(\.action))")
        // 다른 항목은 늘 있다
        #expect(w.h.model.items.map(\.action).contains(.pending) && w.h.model.items.map(\.action).contains(.activityLog))
    }

    @Test func 곡_메뉴의_저장_항목도_같은_줄에서만_보인다() {
        let w = world(.pending)
        let actions = TrackListActions.live(store: w.h.store, reflection: nil, window: w.h.window)
        #expect(!actions.showsSave(), "9번 줄")
        w.feed.update(.leftover(count: 1), ReflectionConditions(leftovers: [.suggestion], hasPending: true, autoSaves: true))
        #expect(actions.showsSave(), "8번 줄")
        w.feed.update(.held(.usbBusy), ReflectionConditions(holds: [.usbBusy], leftovers: [.suggestion], hasPending: true, autoSaves: true))
        #expect(!actions.showsSave(), "3번 줄")
        // 엔진이 없는 조립은 지금처럼 늘 보인다
        #expect(TrackListActions.live(store: w.h.store, reflection: nil, window: nil).showsSave())
    }

    @Test func 곡_메뉴의_저장도_공통_저장_입구로_실행한다_3번_줄이면_이유만_보인다() {
        let w = world(.held(.usbBusy), holds: [.usbBusy], leftovers: [.suggestion])
        let coordinator = ReflectionCoordinator.test(store: w.h.store, gate: .restoringOnly)
        let actions = TrackListActions.live(store: w.h.store, reflection: coordinator, window: w.h.window)
        actions.writeDrafts(w.rows)
        #expect(w.h.store.writeTask == nil && w.h.store.toast?.title == "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 시도하세요")
    }

    // MARK: - S6: 입력 확정이 끝난 뒤에 줄과 대상을 계산한다

    /// 저장 대기가 이미 있어도(기존 초안) 현재 칸의 확정이 끝나기 전에 저장을 시작하지 않는다
    @Test func 기존_초안이_있어도_칸의_확정이_끝난_뒤에_저장을_시작한다() async {
        let w = world(.pending)
        let input = FieldEditingState()
        let landed = Mutex(false)
        // SwiftUI 칸: 포커스를 잃은 뒤(입력 중은 곧 끝난다) 다음 갱신에서 값을 넣는다
        input.isEditing = true
        input.commit = { [input, store = w.h.store] in
            input.isEditing = false
            Task { @MainActor in
                for _ in 0..<5 { await Task.yield() }
                store.showRows(w.rows + [PendingCountCacheTests.track("b")])
                store.rowsByUUID["b"] = PendingCountCacheTests.track("b")
                store.setDraftMark(.cue, trackUUID: "b", exists: true)
                landed.withLock { $0 = true }
            }
            return true
        }
        input.hasPendingCommit = { !landed.withLock { $0 } }
        input.settleLimit = .seconds(600)   // 한도는 안전망일 뿐이다: 다른 시험이 메인 액터를 나눠 써도 걸린 시간으로 판정하지 않는다(TEST-30)
        w.h.window.fieldEditing = input
        let coordinator = ReflectionCoordinator.test(store: w.h.store, gate: .restoringOnly)
        LibraryMenuAction.reflect.perform(in: w.h.window, windows: nil, reflection: coordinator)
        #expect(w.h.store.writeTask == nil || landed.withLock { $0 }, "확정이 끝나기 전에 저장을 시작하지 않는다")
        #expect(await waitForState(safetyNet: .seconds(90)) { w.h.store.writeTask != nil || w.h.store.rekordboxWriteCount > 0 })
        #expect(landed.withLock { $0 }, "확정이 끝난 뒤에 시작한다")
        #expect(w.h.window.saveRows.map(\.track.uuid).sorted() == ["a", "b"], "새 편집까지 대상에 든다")
        await w.h.store.writeTask?.value
    }

    // MARK: - S4: 저장 중 ⌘S는 다음 저장 요청을 보관한다

    final class Events: Sendable {
        private let state = Mutex<[String]>([])
        func add(_ event: String) { state.withLock { $0.append(event) } }
        var all: [String] { state.withLock { $0 } }
    }

    /// 엔진·가짜 관문(미리 보기마다 사건을 남기고 `blocking`에 든 번째에서 멈춘다)을 붙인 저장 대기열 시험대
    @MainActor
    final class QueueFixture {
        let store: LibraryStore
        let coordinator: ReflectionCoordinator
        let engine: AutoReflection
        let window: LibraryWindowModel
        let feed: AutoReflectionFeed
        let events = Events()
        let latches: [Int: AutoReflectionAppTests.Latch]
        let folder: TemporaryFolder

        init(blocking: Set<Int> = [1]) async throws {
            store = AutoReflectionAppTests().store()
            store.playlists.renamePlaylist("B", to: "새 이름")
            let events = events, calls = Mutex(0)
            let latches = Dictionary(uniqueKeysWithValues: blocking.map { ($0, AutoReflectionAppTests.Latch()) })
            self.latches = latches
            var gate = RekordboxWriteGate.restoringOnly
            gate.preview = { batch, _, _, copied in
                await copied()
                let call = calls.withLock { state -> Int in
                    state += 1
                    return state
                }
                events.add("미리 보기 \(call) 시작" + (batch.playlists != nil ? " 재생 목록" : ""))
                if let latch = latches[call] { await latch.wait() }
                events.add("미리 보기 \(call) 끝")
                return RekordboxWriteReport(outcomes: [], backup: nil, dryRun: true, createdAt: "", finalUpdateCount: nil)
            }
            coordinator = ReflectionCoordinator.test(store: store, gate: gate)
            folder = try TemporaryFolder(prefix: "djc-save-entry-queue")
            feed = coordinator.autoFeed
            let feed = feed
            let ports = AutoReflectionPorts(clock: .live, runState: { .stopped },
                                            quietStamps: { _ in LibraryQuietStamps(walSize: nil, shmExists: false, database: nil, playlistsXML: nil) },
                                            writeLock: .live(RekordboxWriteLocks(folder: folder.url.appending(path: "locks"))),
                                            records: .live(home: folder.url), pointSnapshot: { .satisfied }, appHolds: { [] },
                                            publish: { feed.update($0, $1) })
            engine = AutoReflection(session: coordinator.session, ports: ports, run: .off(.debugBuild))
            coordinator.engine = engine
            window = LibraryWindowModel(store: store)
            window.autoFeed = feed
            engine.start()
            guard await waitForState(safetyNet: .seconds(90), until: { engine.isParked && feed.conditions.hasPending }) else {
                throw FixtureError("엔진이 저장 대기를 보지 못했다")
            }
        }

        func press() { LibraryMenuAction.reflect.perform(in: window, windows: nil, reflection: coordinator) }

        /// 사건이 `count`개 이상 쌓일 때까지
        func waitForEvents(_ count: Int, seconds: Int = 90) async -> Bool {
            await waitForState(safetyNet: .seconds(seconds)) { events.all.count >= count }
        }

        /// 첫 저장을 시작해 첫 미리 보기에서 멈춘 상태로 만든다
        func startFirstSave() async -> Bool {
            press()
            guard await waitForEvents(1), await waitForState(safetyNet: .seconds(90), until: { feed.conditions.writing }) else { return false }
            return window.saveRow == .writing
        }

        func stop() {
            engine.stop()
            withExtendedLifetime(folder) {}
        }
    }

    @Test func 수동_저장_중에_누른_저장은_하나만_보관해_앞_쓰기가_끝난_뒤_이어_한다() async throws {
        let f = try await QueueFixture()
        defer { f.stop() }
        #expect(await f.startFirstSave())
        // 쓰는 중에 또 눌렀다: 켜져 있고, 하나만 보관한다
        #expect(LibraryMenuAction.reflect.isEnabled(in: f.window), "수동 저장 중에도 5번 줄은 켜 둔다")
        f.press()
        f.press()
        #expect(f.events.all == ["미리 보기 1 시작 재생 목록"], "앞 쓰기가 끝나기 전에는 겹쳐 쓰지 않는다")
        f.latches[1]?.release()
        #expect(await f.waitForEvents(4))
        #expect(f.events.all == ["미리 보기 1 시작 재생 목록", "미리 보기 1 끝", "미리 보기 2 시작 재생 목록", "미리 보기 2 끝"], "\(f.events.all)")
        // 세 번째는 없다(보관은 하나)
        await drainMainActor(rounds: 200)
        #expect(f.events.all.count == 4, "\(f.events.all)")
    }

    // MARK: - S4(2라운드): 보관한 요청이 차례를 받으면 자리를 비운다

    @Test func 보관한_요청이_실행_중이어도_다음_저장을_다시_보관할_수_있다() async throws {
        let f = try await QueueFixture(blocking: [1, 2])
        defer { f.stop() }
        #expect(await f.startFirstSave())
        f.press()   // 보관
        f.latches[1]?.release()
        #expect(await f.waitForEvents(3), "보관한 요청이 차례를 받아 미리 보기 2를 시작한다")
        #expect(f.events.all.last == "미리 보기 2 시작 재생 목록")
        // 보관한 요청이 실행 중이다: 지금 누른 저장은 새로 보관된다
        f.press()
        f.latches[2]?.release()
        #expect(await f.waitForEvents(6), "\(f.events.all)")
        #expect(f.events.all == ["미리 보기 1 시작 재생 목록", "미리 보기 1 끝", "미리 보기 2 시작 재생 목록", "미리 보기 2 끝",
                                 "미리 보기 3 시작 재생 목록", "미리 보기 3 끝"], "\(f.events.all)")
    }

    // MARK: - S3(2라운드): 차례를 받은 뒤 공통 저장 입구가 다시 판정한다

    @Test func 보관한_요청이_차례를_받은_뒤_열린_가져오기_시트는_3번_줄_이유로_막는다() async throws {
        let f = try await QueueFixture()
        defer { f.stop() }
        #expect(await f.startFirstSave())
        f.press()   // 보관
        // 차례를 받기 전에 가져오기 시트가 열렸다
        f.window.liveHolds = { [.importSheetOpen] }
        f.latches[1]?.release()
        #expect(await waitForState(safetyNet: .seconds(90)) { f.store.toast?.title == "가져오기 창에서 적용하거나 닫은 뒤 다시 시도하세요" },
                "\(String(describing: f.store.toast?.title)) \(f.events.all)")
        #expect(f.events.all == ["미리 보기 1 시작 재생 목록", "미리 보기 1 끝"], "보관한 저장은 쓰지 않는다: \(f.events.all)")
    }

    // MARK: - S11: 보관한 요청의 미리 보기도 기존 취소 입구가 취소한다

    @Test func 보관한_요청이_차례를_받으면_미리_보기_취소가_그_작업을_취소한다() async throws {
        let f = try await QueueFixture(blocking: [1, 2])
        defer { f.stop() }
        #expect(await f.startFirstSave())
        f.press()   // 보관
        f.latches[1]?.release()
        #expect(await f.waitForEvents(3))
        #expect(await waitForState(safetyNet: .seconds(90)) { f.store.writeStage?.cancellable == true }, "미리 보기 단계다")
        // 미리 보기 [취소]·Esc가 부르는 기존 입구
        f.store.cancelWritePreparation()
        f.latches[2]?.release()
        #expect(await waitForState(safetyNet: .seconds(90)) { f.store.toast?.title == "작업을 취소했습니다" },
                "\(String(describing: f.store.toast?.title)) \(f.events.all)")
    }

    // MARK: - S12: 보관한 요청이 범위를 유지한다

    @Test func 곡_메뉴의_고른_곡_저장은_보관돼도_재생_목록을_더하지_않는다() async throws {
        let f = try await QueueFixture()
        defer { f.stop() }
        #expect(await f.startFirstSave())
        // 메뉴를 열었을 때는 보이던 항목: 누르는 순간 저장 중이 되어 보관된다(고른 곡만, 재생 목록 제외)
        f.window.requestSave(.rows([], playlists: false), reflection: f.coordinator)
        f.latches[1]?.release()
        #expect(await waitForState(safetyNet: .seconds(90)) { f.coordinator.queuedSave == nil && f.events.all.count >= 2 })
        await drainMainActor(rounds: 200)
        #expect(!f.events.all.dropFirst(2).contains { $0.contains("재생 목록") }, "고른 곡 범위가 전체 저장으로 바뀌지 않는다: \(f.events.all)")
    }

    // MARK: - S6(2라운드): 칸 확정이 끝난 뒤에만 저장한다

    @Test func 칸이_확정을_거절하면_저장하지_않고_이유를_알린다() async {
        let w = world(.pending)
        let input = FieldEditingState()
        input.isEditing = true
        input.commit = { false }   // 입력 검증이 포커스를 놓지 못하게 한다
        w.h.window.fieldEditing = input
        let coordinator = ReflectionCoordinator.test(store: w.h.store, gate: .restoringOnly)
        LibraryMenuAction.reflect.perform(in: w.h.window, windows: nil, reflection: coordinator)
        #expect(await waitForState(safetyNet: .seconds(90)) { w.h.store.toast != nil })
        #expect(w.h.store.writeTask == nil && w.h.store.rekordboxWriteCount == 0, "칸의 값이 빠진 채 저장하지 않는다")
        #expect(w.h.store.toast?.title == "입력 중인 칸을 확정하지 못해 저장하지 않았습니다. 칸의 값을 고치거나 Return을 누른 뒤 다시 저장하세요")
    }

    @Test func 확정이_시간_안에_끝나지_않으면_저장하지_않고_이유를_알린다() async {
        let w = world(.pending)
        let input = FieldEditingState()
        input.isEditing = true
        input.commit = { [input] in
            input.isEditing = false
            return true
        }
        input.hasPendingCommit = { true }   // 확정이 끝났다는 신호가 오지 않는다
        input.settleLimit = .milliseconds(100)
        w.h.window.fieldEditing = input
        let coordinator = ReflectionCoordinator.test(store: w.h.store, gate: .restoringOnly)
        LibraryMenuAction.reflect.perform(in: w.h.window, windows: nil, reflection: coordinator)
        #expect(await waitForState(safetyNet: .seconds(90)) { w.h.store.toast != nil })
        #expect(w.h.store.writeTask == nil && w.h.store.rekordboxWriteCount == 0)
        #expect(w.h.store.toast?.title == "입력 중인 칸을 확정하지 못해 저장하지 않았습니다. 칸의 값을 고치거나 Return을 누른 뒤 다시 저장하세요")
    }
}
