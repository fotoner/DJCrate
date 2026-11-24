import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Synchronization
import Testing

/// 자동 저장 엔진의 쓰기 기록 판정과 재시작 정리의 차례(R9·R11·R22): 시작·자동·수동 모든 길이 같은 대상의 쓰기 잠금을 쥔 채 기록을 판정하고,
/// 기록이 없을 때만 그 잠금 아래에서 미정리 목록을 정리한다. 잠금을 못 잡아 미룬 판정과 확인한 중단은 실행 조건·대기 초안과 상관없이 다룬다.
@MainActor
@Suite("자동 저장: 기록 판정과 정리 차례")
struct AutoReflectionJournalTests {
    /// 미정리 목록을 읽을 때 쓰기 잠금을 쥐었는지와 그때까지 관문이 쓴 횟수
    final class Seen: Sendable {
        private let state = Mutex<[(held: Bool, writes: Int)]>([])
        func add(_ held: Bool, writes: Int) { state.withLock { $0.append((held, writes)) } }
        var all: [(held: Bool, writes: Int)] { state.withLock { $0 } }
    }

    static let finding = RekordboxJournalFinding(journal: RekordboxWriteJournal(operationID: "op", kind: .counter, entry: .drafts), changedSince: false,
                                                 database: nil)

    /// 앱이 쓴 뒤 정리 전에 멈춰 남은 목록: "a"의 지금 판을 썼다
    static func writtenList(_ w: AutoReflectionWorld) throws -> DraftCleanupList {
        let stamp = try #require(w.h.memory.stamp(DraftKey(.cue, "a")))
        let written = WrittenDraft(key: DraftKey(.cue, "a"), revision: stamp.revision, contentHash: try DraftContentHash(of: ReflectionHarness.cue("a")))
        return DraftCleanupList(operationID: "op-1", target: MemoryWriteLocks.key(for: w.h.session.target.database), draftHome: "/drafts",
                                backupFolder: "w1", written: [written])
    }

    // MARK: - S1·G1

    @Test func 수동_저장은_늘_잠금_아래에서_기록을_다시_판정하고_중단이면_초안을_지우지_않는다() async throws {
        let w = AutoReflectionWorld()
        let journal = ScriptedJournal(.none)
        w.h.journal = journal
        w.run = .off(.debugBuild)
        w.cue("a")
        w.h.script.cleanupLists = [try Self.writtenList(w)]
        let key = MemoryWriteLocks.key(for: w.h.session.target.database)
        // 시작 때는 다른 실행이 쓰는 중이라 판정을 미뤘다
        w.fakes.locks.holdElsewhere(key)
        try await w.start()
        #expect(w.h.memory.cue("a") != nil)
        // 그 실행이 미정리 목록을 적은 뒤 기록을 지우기 전에 멈췄다
        journal.set(.interrupted(Self.finding))
        w.fakes.locks.holdElsewhere(key, false)
        _ = await w.engine.exclusive({ ReflectionOutcome.declined }, whenHeld: { _ in .busy })
        #expect(w.h.memory.cue("a") != nil, "중단 기록이 있으면 미정리 목록으로 초안을 지우지 않는다")
        #expect(!w.h.gateCalls.value.order.contains("cleanup lists"))
    }

    @Test func 기록_판정과_정리는_같은_쓰기_잠금을_쥔_채_한다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.h.script.cleanupLists = [try Self.writtenList(w)]
        w.cue("a", at: 30)
        let key = MemoryWriteLocks.key(for: w.h.session.target.database)
        let seen = Seen()
        w.h.script.onCleanupLists = { [locks = w.fakes.locks, calls = w.h.gateCalls] in
            seen.add(locks.heldKeys.contains(key), writes: calls.value.writes.count)
        }
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.count == 1)
        // 시작 정리와 첫 자동 저장 앞의 정리(자동 저장 뒤 자기 목록 지우기는 쓰기 입구가 막 남긴 목록이라 따로다)
        let beforeWrite = seen.all.filter { $0.writes == 0 }
        #expect(beforeWrite.count >= 2 && beforeWrite.allSatisfy(\.held), "\(beforeWrite)")
        // 수동 저장 앞의 정리도 같다
        let before = seen.all.count
        _ = await w.engine.exclusive({ ReflectionOutcome.declined })
        #expect(seen.all.count > before && seen.all[before...].allSatisfy(\.held))
        #expect(w.fakes.locks.heldKeys.isEmpty, "정리를 마치면 잠금을 푼다")
    }

    // MARK: - S12·G5

    @Test(arguments: [AutoReflectionRun.Off.debugBuild, .diagnostic])
    func 자동_저장하지_않는_실행도_확인한_중단을_알린다(_ reason: AutoReflectionRun.Off) async throws {
        let w = AutoReflectionWorld()
        w.h.script.journal = .interrupted(Self.finding)
        w.run = .off(reason)
        w.cue("a")
        try await w.start()
        #expect(w.engine.status == .interrupted(recoveryFailed: false))
        #expect(w.engine.conditions.holds.contains(.interrupted(recoveryFailed: false)))
    }

    @Test(arguments: [AutoReflectionRun.live, .off(.diagnostic)])
    func 시작_때_미룬_기록_판정은_대기_초안이_없어도_잠금이_풀리면_다시_한다(_ run: AutoReflectionRun) async throws {
        let w = AutoReflectionWorld()
        let journal = ScriptedJournal(.interrupted(Self.finding))
        w.h.journal = journal
        w.run = run
        let key = MemoryWriteLocks.key(for: w.h.session.target.database)
        w.fakes.locks.holdElsewhere(key)
        try await w.start()
        #expect(w.engine.conditions.holds.contains(.lockBusy))
        w.fakes.locks.holdElsewhere(key, false)
        try await w.advance(1)
        #expect(w.engine.status == .interrupted(recoveryFailed: false))
    }

    @Test(arguments: [AutoReflectionRun.live, .off(.diagnostic)])
    func 시작_때_미룬_정리는_대기_초안이_없어도_잠금이_풀리면_한다(_ run: AutoReflectionRun) async throws {
        let w = AutoReflectionWorld()
        w.run = run
        w.h.state.rows["a"] = ReflectionHarness.row("a")
        w.h.memory.save(ReflectionHarness.cue("a"))
        w.h.script.cleanupLists = [try Self.writtenList(w)]
        let key = MemoryWriteLocks.key(for: w.h.session.target.database)
        w.fakes.locks.holdElsewhere(key)
        try await w.start()
        #expect(w.h.gateCalls.value.removedCleanupLists.isEmpty)
        w.fakes.locks.holdElsewhere(key, false)
        try await w.advance(1)
        #expect(w.h.gateCalls.value.removedCleanupLists == ["op-1"] && w.h.memory.cue("a") == nil)
    }

    // MARK: - O4·O9

    @Test func 수동_쓰기가_던지면_기록을_다시_판정한다() async throws {
        let w = AutoReflectionWorld()
        let journal = ScriptedJournal(.none)
        w.h.journal = journal
        try await w.start()
        // 시점 복원이 실패하며 기록을 남겼다
        await #expect(throws: FixtureFailure.self) {
            try await w.engine.exclusive { () throws -> ReflectionOutcome in
                journal.set(.interrupted(Self.finding))
                throw FixtureFailure()
            }
        }
        try await w.settle()
        #expect(w.engine.status == .interrupted(recoveryFailed: false))
    }

    @Test func 잠금을_못_잡은_수동_저장은_정리_보류로_알리지_않는다() async throws {
        let w = AutoReflectionWorld()
        w.run = .off(.debugBuild)
        try await w.start()
        w.fakes.locks.holdElsewhere(MemoryWriteLocks.key(for: w.h.session.target.database))
        w.engine.recheckJournal()
        var ran = false
        let outcome = await w.engine.exclusive({ ran = true; return ReflectionOutcome.declined }, whenHeld: { _ in .busy })
        #expect(ran && outcome.name == "declined", "잠금은 쓰기 입구가 기다린다: 정리 보류(R22) 문구로 거절하지 않는다")
    }

    // MARK: - S2

    @Test func 수동_저장은_저장하지_못한_재생_목록_초안을_먼저_저장해_본_뒤_정리한다() async throws {
        let w = AutoReflectionWorld()
        w.run = .off(.debugBuild)
        let list = try ReflectionSessionResumeCleanupTests.unsavedPlaylistEdit(w.h)
        w.h.script.cleanupLists = [list]
        w.h.playlistSaves = false
        w.h.playlistSaveClearsUnsaved = true
        try await w.start()
        #expect(w.h.gateCalls.value.removedCleanupLists.isEmpty, "저장하지 못한 편집이 메모리에 있으면 재생 목록 정리를 미룬다")
        w.h.playlistSaves = true
        let outcome = await w.engine.exclusive({ ReflectionOutcome.declined }, whenHeld: { _ in .busy })
        #expect(w.h.log.contains("save playlist") && w.h.gateCalls.value.removedCleanupLists == ["op-1"] && outcome.name == "declined")
    }
}
