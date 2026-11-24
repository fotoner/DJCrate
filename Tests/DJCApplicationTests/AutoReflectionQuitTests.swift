import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Synchronization
import Testing

/// ⌘Q 저장(R17): 엔진이 `prepareToQuit()`으로 대기 중인 대상 편집을 최신 초안으로 다시 판정해 쓰고 돌아온다.
/// T_edit와 순간 편집 신호(마우스 누름·입력 중)는 건너뛰고, 조용함·관문·실행 판정은 그대로 지난다.
/// 유예·확인 필요·멈춤·켜짐·편집 창은 쓰지 않고 초안으로 남긴다. 로그아웃·전원 끔은 `shutdown()`으로 새 쓰기를 시작하지 않는다.
@MainActor
@Suite("자동 저장 엔진 — ⌘Q 저장")
struct AutoReflectionQuitTests {
    /// ⌘Q 저장을 시작해 둔다. 엔진이 요청을 받아 다시 판정하고(바로 돌아오거나) 종료 대기로 쉴 때까지 기다린다
    private func preparing(_ w: AutoReflectionWorld) async throws -> Task<QuitPreparation, Never> {
        let engine = w.engine!, progress = QuitProgress()
        let task = Task {
            // 같은 메인 액터 작업 안에서 요청이 엔진에 닿는다(첫 기다림 전까지)
            progress.started = true
            let result = await engine.prepareToQuit()
            progress.finished = true
            return result
        }
        for _ in 0..<4000 where !(progress.started && (progress.finished || engine.status == .quitting && engine.isParked && w.fakes.clock.sleeping == 1)) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(progress.started && (progress.finished || engine.status == .quitting), "엔진이 ⌘Q 저장 요청을 받는다")
        return task
    }

    @MainActor final class QuitProgress {
        var started = false
        var finished = false
    }

    @Test func T_edit를_기다리지_않고_대상_편집을_쓴_뒤_다_썼다고_돌려준다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        w.cue("a")
        try await w.edited()
        #expect(w.writes.isEmpty && w.engine.status == .pending)
        let quit = try await preparing(w)
        #expect(await quit.value == .finished(run: .stopped))
        #expect(w.writes.count == 1 && w.writes.first?.drafts.map(\.trackUUID) == ["a"])
        #expect(w.fakes.publishedStatuses.contains(.quitting), "종료 대기를 알린다")
    }

    @Test func 편집_신호를_받기_전에_누른_종료도_최신_초안으로_다시_판정해_쓴다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        // 초안은 저장됐지만 엔진은 아직 편집 신호를 받지 못했다(저장됨으로 보인다)
        w.cue("a")
        #expect(w.engine.status == .saved)
        let quit = try await preparing(w)
        #expect(await quit.value == .finished(run: .stopped))
        #expect(w.writes.count == 1)
    }

    @Test func 조용함을_기다리는_중이면_기다린_뒤_쓴다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        try await w.start()
        try await w.advance(2)
        let quit = try await preparing(w)
        #expect(w.writes.isEmpty && w.engine.status == .quitting)
        try await w.advance(8)
        #expect(await quit.value == .finished(run: .stopped))
        #expect(w.writes.count == 1)
    }

    @Test(arguments: [EditActivity.fieldEditing, .composing, .pointerDown])
    func 순간_편집_신호로는_미루지_않는다(_ signal: EditActivity) async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        w.cue("a")
        try await w.edited()
        w.engine.setActivity(signal)
        try await w.settle()
        let quit = try await preparing(w)
        #expect(await quit.value == .finished(run: .stopped))
        #expect(w.writes.count == 1)
    }

    @Test func 편집_창이나_시트가_열려_있으면_기다리지_않고_쓰지_않는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        w.cue("a")
        try await w.edited()
        w.engine.setActivity(.editorOpen)
        try await w.settle()
        #expect(await (try await preparing(w)).value == .unwritten(.editing))
        w.engine.setActivity([])
        w.appHolds = [.editing]
        try await w.settle()
        #expect(await (try await preparing(w)).value == .unwritten(.editing))
        #expect(w.writes.isEmpty)
    }

    @Test func 대량_유예_대상은_쓰지_않고_초안으로_남긴다() async throws {
        let w = AutoReflectionWorld()
        let uuids = (0..<50).map { String(format: "t%03d", $0) }
        w.writable(uuids)
        uuids.forEach { w.cue($0) }
        try await w.start()
        try await w.advance(10)
        let quit = try await preparing(w)
        #expect(await quit.value == .unwritten(nil))
        #expect(w.writes.isEmpty && w.h.memory.cue("t000") != nil)
    }

    @Test func 미리_보기에서_막힌_곡은_쓰지_않고_나머지를_쓴_뒤_돌아온다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.writable("b", status: .blocked)
        try await w.start()
        try await w.advance(10)
        w.cue("a")
        w.cue("b")
        let quit = try await preparing(w)
        #expect(await quit.value == .finished(run: .stopped))
        #expect(w.writes.count == 1 && w.writes.first?.drafts.map(\.trackUUID) == ["a"])
        #expect(w.h.memory.cue("b") != nil, "확인이 필요한 곡은 초안으로 남는다")
    }

    @Test func K행을_넘는_대기열은_묶음을_나눠_모두_쓴_뒤_돌아온다() async throws {
        let w = AutoReflectionWorld()
        w.timing.rowLimit = 1
        w.writable("a", "b")
        try await w.start()
        try await w.advance(10)
        w.cue("a")
        w.cue("b")
        let quit = try await preparing(w)
        #expect(await quit.value == .finished(run: .stopped))
        #expect(w.writes.count == 2)
    }

    @Test(arguments: [RekordboxRunState.running, .agentOnly])
    func rekordbox가_켜져_있으면_쓰지_않고_확인한_실행_상태를_돌려준다(_ state: RekordboxRunState) async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        w.cue("a")
        w.fakes.setRunState(state)
        let quit = try await preparing(w)
        #expect(await quit.value == .unwritten(state == .running ? .rekordboxRunning : .agentRunning))
        #expect(w.writes.isEmpty)
    }

    @Test func 종료_대기를_취소하면_취소로_돌아오고_평소_판정으로_돌아간다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        try await w.start()
        try await w.advance(2)
        let quit = try await preparing(w)
        w.engine.cancelQuit()
        #expect(await quit.value == .cancelled)
        try await w.settle()
        #expect(w.engine.status != .quitting)
        // 평소처럼 조용함과 T_edit를 지나면 쓴다
        try await w.advance(8)
        #expect(w.writes.count == 1)
    }

    @Test func 자동_저장하지_않는_실행은_바로_돌아온다() async throws {
        let w = AutoReflectionWorld()
        w.run = .off(.debugBuild)
        w.writable("a")
        w.cue("a")
        try await w.start()
        #expect(await w.engine.prepareToQuit() == .unwritten(.notAutoRun(.debugBuild)))
        #expect(w.writes.isEmpty)
    }

    @Test func 시스템_종료는_새_쓰기를_시작하지_않고_취소되면_다시_쓴다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        w.engine.shutdown()
        w.cue("a")
        try await w.edited()
        try await w.advance(10)
        #expect(w.writes.isEmpty && w.engine.conditions.holds.contains(.shuttingDown))
        // 끄던 일이 취소됐다(로그아웃 취소·업데이트 다시 켜기 취소). 끄는 동안 지켜보지 않았으니 조용함부터 다시 센다(R2)
        w.engine.cancelShutdown()
        try await w.settle()
        try await w.advance(9)
        #expect(w.writes.isEmpty)
        try await w.advance(1)
        #expect(w.writes.count == 1)
    }

    /// 다른 쪽(CLI 등)이 재생 목록 초안 파일 잠금을 계속 쥐어 쓸 묶음이 비어도 ⌘Q 저장은 끝난다: 초안으로 남기고 돌려준다(컨실 2라운드 E)
    @Test func 재생_목록_초안_잠금을_계속_못_잡으면_초안으로_남기고_돌아온다() async throws {
        let w = AutoReflectionWorld()
        var draft = PlaylistDraft()
        _ = try draft.append(.rename(playlist: .id("B"), name: "새 이름"), rekordbox: AutoReflectionEngineTests.layout)
        try w.h.memory.store.savePlaylistDraft(draft)
        w.h.state.rekordboxPlaylists = AutoReflectionEngineTests.layout
        w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        w.h.state.playlistDraftFileLocked = false
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.isEmpty, "잠금을 못 잡으면 평소에는 쓰지 않고 다시 본다")
        let quit = try await preparing(w)
        try await w.advance(3)
        // 끝나지 않았으면 취소로 돌아온다(시험이 멈추지 않게)
        w.engine.cancelQuit()
        #expect(await quit.value == .unwritten(.lockBusy))
        #expect(w.writes.isEmpty && !w.h.memory.store.playlistDraft().isEmpty, "재생 목록 초안은 남는다")
    }

    /// 자동으로 쓸 것이 없어(대상 밖 편집만 남음) 바로 끝나도 엔진이 본 rekordbox 실행 상태를 함께 돌려준다: 종료 시트가 그 값을 쓴다(컨실 2라운드 J)
    @Test(arguments: [RekordboxRunState.running, .agentOnly])
    func 쓸_것이_없어도_엔진이_본_실행_상태를_함께_돌려준다(_ state: RekordboxRunState) async throws {
        let w = AutoReflectionWorld()
        w.h.state.rows["w"] = ReflectionHarness.row("w")
        w.h.state.artworkDrafts["w"] = ArtworkDraft(trackUUID: "w", change: .delete, base: ArtworkBase(imagePath: ""))
        try await w.start()
        w.fakes.setRunState(state)
        try await w.advance(1)
        let quit = try await preparing(w)
        #expect(await quit.value == .finished(run: state))
        #expect(w.writes.isEmpty)
    }

    /// 첫 ⌘Q의 백업 조건 확인(공간 부족) 중 취소하고 다시 ⌘Q를 누르면, 새 요청은 옛 판정 결과를 받지 않고 새로 판정한다(컨실 3라운드 P)
    @Test func 비동기_판정_중_종료_요청이_바뀌면_새_요청은_새_판정을_받는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        try await w.start()
        try await w.advance(10)
        w.h.backupsMemory.condition = .lowSpace(available: 1, required: 2)
        let gate = HoldGate()
        w.h.backupsMemory.onCondition = { gate.hold() }
        w.cue("a")
        let first = Task { await w.engine.prepareToQuit() }
        for _ in 0..<4000 where !gate.arrived { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.arrived, "첫 요청이 백업 조건을 확인하는 중이다")
        w.engine.cancelQuit()
        #expect(await first.value == .cancelled)
        // 그사이 공간이 생겼다. 새 요청은 새로 판정해 쓴다
        w.h.backupsMemory.onCondition = nil
        w.h.backupsMemory.condition = .ready
        let progress = QuitProgress()
        let second = Task {
            progress.started = true
            return await w.engine.prepareToQuit()
        }
        for _ in 0..<4000 where !progress.started { try await Task.sleep(for: .milliseconds(5)) }
        gate.release()
        #expect(await second.value == .finished(run: .stopped))
        #expect(w.writes.count == 1)
    }

    /// 메인 액터 밖의 확인을 시험이 풀 때까지 붙잡는다
    final class HoldGate: Sendable {
        private let state = Mutex(false)
        private let semaphore = DispatchSemaphore(value: 0)
        var arrived: Bool { state.withLock { $0 } }
        func hold() {
            state.withLock { $0 = true }
            semaphore.wait()
        }
        func release() { semaphore.signal() }
    }
}
