import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Synchronization
import Testing

/// 자동 쓰기 동안의 조용함(#295 E4): 엔진의 자동 쓰기 동안 rekordbox 실행 상태만 메인 액터 밖에서 1초마다 본다. 꺼져 있으면 조용함을
/// 이어(쓰기가 3초를 넘어도 다음 편집이 T_quiet를 다시 기다리지 않는다), 켜짐·틈·바깥 변경이면 처음부터 센다. 관문 직전 확인 지점과
/// 관문 안에서 잡은 쓴 뒤 파일 상태로 바깥 변경을 가린다. 수치는 시험 값(T_edit 3초·T_quiet 10초)이다.
@MainActor
@Suite("자동 쓰기 동안의 조용함")
struct AutoReflectionWriteWatchTests {
    nonisolated static let otherDatabase = LibraryQuietStamps(walSize: nil, shmExists: false, database: RekordboxFileStamp(size: 8192, modifiedNanoseconds: 2),
                                                  playlistsXML: nil)
    nonisolated static let laterDatabase = LibraryQuietStamps(walSize: nil, shmExists: false, database: RekordboxFileStamp(size: 8192, modifiedNanoseconds: 3),
                                                  playlistsXML: nil)

    /// 조용함을 채운 뒤 곡 a를 편집하고 T_edit 직전까지 간다(다음 1초에 자동 쓰기가 시작한다)
    static func ready(_ w: AutoReflectionWorld) async throws {
        try await w.start()
        try await w.advance(10)
        w.cue("a")
        try await w.edited()
        try await w.advance(2)
    }

    /// 쓴 뒤 곡 b를 편집하면 T_edit(3초) 뒤 곧바로 쓰는지(조용함을 이었는지)
    static func nextEditSavesAfterTEdit(_ w: AutoReflectionWorld, _ comment: Comment) async throws {
        #expect(w.writes.count == 1)
        w.cue("b")
        try await w.edited()
        try await w.advance(3)
        #expect(w.writes.count == 2 && w.writes.last?.drafts.map(\.trackUUID) == ["b"], comment)
    }

    /// 쓴 뒤 곡 b를 편집하면 조용함을 처음부터 센다(T_edit 뒤에도 쓰지 않고, 다시 센 T_quiet가 차야 쓴다)
    static func nextEditWaitsQuiet(_ w: AutoReflectionWorld, writesBefore: Int, _ comment: Comment) async throws {
        w.cue("b")
        try await w.edited()
        try await w.advance(3)
        #expect(w.writes.count == writesBefore && w.engine.status == .quietWaiting, comment)
        try await w.advance(7)
        #expect(w.writes.count == writesBefore + 1, "다시 센 T_quiet가 차면 쓴다")
    }

    // MARK: - 쓰는 동안 꺼져 있으면 조용함을 잇는다

    /// 5초 걸리는 자동 쓰기 뒤 다음 편집은 T_edit 뒤 곧바로 저장한다. 관문이 라이브러리 변경 자리에서 잡은 파일 상태가 쓰기 전과 같으면
    /// (BPM 그대로 그리드만 쓴 쓰기처럼 DB·XML을 바꾸지 않음) 쓰기 전 기준을 잇는다
    @Test func 오래_걸린_자동_쓰기_뒤_다음_편집은_T_edit_뒤_곧바로_저장한다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a", "b")
        let hold = WriteHold()
        w.h.script.duringWrite = { hold.wait() }
        try await Self.ready(w)
        hold.hold()
        try await w.advanceIntoWrite { hold.isWaiting }
        try await w.advanceWhileWriting(5)
        hold.release()
        try await w.settle()
        try await Self.nextEditSavesAfterTEdit(w, "쓰는 동안 꺼져 있었으면 10초를 다시 기다리지 않는다")
    }

    /// 메인 액터가 3초 넘게 막혀도 메인 밖 표본이 이어지면 조용함을 처음부터 세지 않는다(틈은 메인 밖 표본 시각 사이로 잰다)
    @Test func 메인_액터가_막혀도_메인_밖_표본이_이어지면_조용함을_잇는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a", "b")
        let hold = WriteHold()
        w.h.script.duringWrite = { hold.wait() }
        try await Self.ready(w)
        hold.hold()
        try await w.advanceIntoWrite { hold.isWaiting }
        try await w.advanceWhileWriting(5, blocksMain: true)
        hold.release()
        try await w.settle()
        try await Self.nextEditSavesAfterTEdit(w, "메인 밖 표본이 이어졌으면 조용함을 잇는다")
    }

    /// 쓰는 중 시작한 관찰(실행 상태 보기)이 쓰기가 끝난 뒤 돌아와도 10초를 다시 세지 않는다
    @Test func 쓰는_중_시작한_관찰이_쓰기_뒤_돌아와도_조용함을_잇는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a", "b")
        let hold = WriteHold()
        w.h.script.duringWrite = { hold.wait() }
        try await Self.ready(w)
        hold.hold()
        try await w.advanceIntoWrite { hold.isWaiting }
        try await w.advanceWhileWriting(2)
        // 다음 표본이 실행 상태를 보는 중에 쓰기가 끝난다
        w.fakes.holdRunState()
        w.fakes.clock.advance(.seconds(2))
        for _ in 0..<1000 where w.fakes.clock.sleeping != 0 { try await Task.sleep(for: .milliseconds(5)) }
        hold.release()
        w.fakes.holdRunState(false)
        try await w.settle()
        try await Self.nextEditSavesAfterTEdit(w, "쓰는 동안 시작한 관찰이 꺼짐으로 돌아오면 조용함을 잇는다")
    }

    /// 자기 쓰기가 DB를 바꿨으면 관문이 잡은 값을 새 기준으로 받아 잇는다(쓴 뒤 첫 관찰이 그 값과 같다)
    @Test func 자기_쓰기가_바꾼_파일은_관문이_잡은_값으로_새_기준이_된다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a", "b")
        let hold = WriteHold()
        w.h.script.duringWrite = { [fakes = w.fakes] in
            hold.wait()
            fakes.setQuietStamps(Self.otherDatabase)
        }
        try await Self.ready(w)
        hold.hold()
        try await w.advanceIntoWrite { hold.isWaiting }
        try await w.advanceWhileWriting(5)
        hold.release()
        try await w.settle()
        try await Self.nextEditSavesAfterTEdit(w, "쓴 뒤 첫 관찰이 관문이 잡은 값과 같으면 잇는다")
    }

    /// DB·XML을 바꾸지 않고 끝난 쓰기(모두 막혀 아무것도 안 씀: 관문이 라이브러리 변경 자리를 지나지 않음)는 쓰기 전 기준을 잇는다
    @Test func 모두_막혀_아무것도_쓰지_않은_자동_쓰기_뒤에도_조용함을_잇는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a", "b")
        w.h.script.write = ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .blocked, reason: "바뀜"),
                                                           ReflectionHarness.outcome("b", .blocked, reason: "바뀜")], dryRun: false)
        w.h.script.callsAfterChanges = false
        let hold = WriteHold()
        w.h.script.duringWrite = { hold.wait() }
        try await Self.ready(w)
        hold.hold()
        try await w.advanceIntoWrite { hold.isWaiting }
        try await w.advanceWhileWriting(5)
        hold.release()
        try await w.settle()
        #expect(w.writes.count == 1)
        w.cue("b")
        try await w.edited()
        try await w.advance(3)
        #expect(w.writes.count == 2 && w.writes.last?.drafts.map(\.trackUUID) == ["b"], "쓰기 전 기준을 잇는다(관문은 다시 막는다)")
    }

    // MARK: - 처음부터 센다

    /// 쓰는 동안 rekordbox가 켜졌다 꺼지면 조용함을 처음부터 센다. 실행 경계도 넘긴다(R23)
    @Test func 쓰는_동안_켜졌다_꺼지면_조용함을_처음부터_센다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a", "b")
        let hold = WriteHold()
        w.h.script.duringWrite = { hold.wait() }
        try await Self.ready(w)
        let epoch = w.h.memory.runEpoch.current
        hold.hold()
        try await w.advanceIntoWrite { hold.isWaiting }
        w.fakes.setRunState(.running)
        try await w.advanceWhileWriting(1)
        w.fakes.setRunState(.stopped)
        try await w.advanceWhileWriting(1)
        hold.release()
        try await w.settle()
        #expect(w.h.memory.runEpoch.current != epoch, "쓰는 동안 본 켜짐으로 실행 경계를 넘긴다")
        try await Self.nextEditWaitsQuiet(w, writesBefore: 1, "쓰는 동안 켜졌다 꺼졌으면 처음부터 센다")
    }

    /// 미리 보기 중 켜졌다 꺼지면 그 판정은 관문으로 가지 않는다(얼림을 풀고 조용함을 처음부터)
    @Test func 미리_보기_중_켜졌다_꺼지면_관문으로_가지_않는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.h.previewHold.hold()
        try await Self.ready(w)
        try await w.advanceIntoWrite { w.h.previewHold.isWaiting }
        w.fakes.setRunState(.running)
        try await w.advanceWhileWriting(1)
        w.fakes.setRunState(.stopped)
        try await w.advanceWhileWriting(1)
        w.h.previewHold.release()
        try await w.settle()
        #expect(w.writes.isEmpty && w.previews.count == 1, "미리 본 묶음을 관문으로 보내지 않는다")
        try await w.advance(3)
        #expect(w.writes.isEmpty && w.engine.status == .quietWaiting)
        try await w.advance(7)
        #expect(w.writes.count == 1)
    }

    /// 마지막 꺼짐 표본이 3초 넘게 오래되면 관문을 부르지 않는다
    @Test func 마지막_표본이_오래되면_관문을_부르지_않는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.h.previewHold.hold()
        try await Self.ready(w)
        try await w.advanceIntoWrite { w.h.previewHold.isWaiting }
        try await w.advanceWhileWriting(1)
        // 다음 표본이 실행 상태를 보느라 오래 걸린다(그동안 4초가 지난다)
        w.fakes.holdRunState()
        w.fakes.clock.advance(.seconds(4))
        for _ in 0..<1000 where w.fakes.clock.sleeping != 0 { try await Task.sleep(for: .milliseconds(5)) }
        w.h.previewHold.release()
        w.fakes.holdRunState(false)
        try await w.settle()
        #expect(w.writes.isEmpty, "오래된 표본으로는 관문을 부르지 않는다")
    }

    /// 미리 보기 중 바깥 프로세스가 DB를 바꾸면 관문을 부르지 않고 조용함을 처음부터 센다
    @Test func 미리_보기_중_바깥에서_DB가_바뀌면_관문으로_가지_않는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.h.previewHold.hold()
        try await Self.ready(w)
        try await w.advanceIntoWrite { w.h.previewHold.isWaiting }
        w.fakes.setQuietStamps(Self.otherDatabase)
        w.h.previewHold.release()
        try await w.settle()
        #expect(w.writes.isEmpty)
        try await w.advance(3)
        #expect(w.writes.isEmpty && w.engine.status == .quietWaiting)
        try await w.advance(7)
        #expect(w.writes.count == 1)
    }

    /// 쓴 뒤 관문이 잡은 값과 첫 관찰이 다르면(잠금이 풀린 틈의 바깥 변경) 처음부터 센다
    @Test func 쓴_뒤_잡은_값과_첫_관찰이_다르면_처음부터_센다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a", "b")
        w.h.script.duringWrite = { [fakes = w.fakes] in fakes.setQuietStamps(Self.otherDatabase) }
        w.h.script.afterWriteUnlocked = { [fakes = w.fakes] in fakes.setQuietStamps(Self.laterDatabase) }
        try await Self.ready(w)
        try await w.advance(1)
        #expect(w.writes.count == 1)
        try await Self.nextEditWaitsQuiet(w, writesBefore: 1, "자기 쓰기가 아닌 변경은 받지 않는다")
    }

    /// DB를 쓴 뒤 관문이 던지면(백업 뒤 실패와 복구) 조용함을 처음부터 센다. ⌘S로 멈춤을 풀어도 다음 자동 저장은 다시 센 T_quiet를 기다린다.
    /// 백업을 뜨기 전 실패는 라이브러리를 바꾸지 않아 쓰기 전 기준을 잇는다(자동 저장 엔진 시험의 백업 전 실패 시험들)
    @Test func 라이브러리를_바꾼_뒤_관문이_던지면_처음부터_센다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a", "b")
        let calls = Mutex(0)
        w.h.script.writeErrorFor = { _ in calls.withLock { $0 += 1; return $0 } == 1 ? DJCError.writeRolledBack("검증 실패") : nil }
        try await Self.ready(w)
        try await w.advance(1)
        #expect(w.writes.count == 1 && w.engine.status == .stopped(.stoppedAfterFailure), "첫 쓰기에서 관문이 던졌다")
        _ = await w.engine.exclusive { ReflectionOutcome.written(ReflectionHarness.report(), preview: ReflectionHarness.report(), followUp: []) }
        try await w.settle()
        try await Self.nextEditWaitsQuiet(w, writesBefore: 1, "다시 쓰기 전에 조용함을 처음부터 센다")
    }
}
