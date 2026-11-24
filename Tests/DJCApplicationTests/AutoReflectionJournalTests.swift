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

    /// 수동 쓰기는 잠금을 기다려 판정한다(G8). 그래도 판정하지 못하면(잠금·기록을 읽다 실패) 이전 보류로 판단해 정리 없이 쓰지 않고
    /// 잠금 보류로 거절한다(3라운드 O17. 1라운드 O9의 "잠금은 쓰기 입구가 기다린다"를 바꾼다)
    @Test func 잠금_아래_판정을_하지_못한_수동_저장은_정리_없이_쓰지_않고_잠금_보류로_알린다() async throws {
        let w = AutoReflectionWorld()
        w.run = .off(.debugBuild)
        try await w.start()
        // 가짜 잠금은 기다리지 않고 던진다(판정 실패)
        w.fakes.locks.holdElsewhere(MemoryWriteLocks.key(for: w.h.session.target.database))
        var ran = false, held: Set<ReflectionHold> = []
        let outcome = await w.engine.exclusive({ ran = true; return ReflectionOutcome.declined }, whenHeld: { holds in
            held = holds
            return .busy
        })
        #expect(!ran && outcome.name == "busy" && held == [.lockBusy])
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

    // MARK: - 2라운드 G8·O12

    @Test func 수동_저장은_쓰기_잠금을_기다려_판정과_정리를_마친_뒤_쓴다() async throws {
        let w = AutoReflectionWorld()
        w.run = .off(.debugBuild)
        w.cue("a")
        w.h.script.cleanupLists = [try Self.writtenList(w)]
        let key = MemoryWriteLocks.key(for: w.h.session.target.database)
        // 시작 때는 다른 쪽(시점 스냅샷·CLI)이 잠금을 쥐었다. ⌘S를 누른 순간에도 쥐고 있다
        w.fakes.locks.holdElsewhere(key)
        w.fakes.locks.blocksOnLock()
        try await w.start()
        let draftAtWork = LockedFlag()
        let engine = w.engine!, memory = w.h.memory
        let saving = Task { @MainActor in
            await engine.exclusive({ () -> ReflectionOutcome in
                draftAtWork.value = memory.cue("a") != nil
                return .declined
            }, whenHeld: { _ in .busy })
        }
        for _ in 0..<2000 where w.fakes.locks.waiting == 0 && w.h.gateCalls.value.removedCleanupLists.isEmpty && !draftAtWork.value {
            try await Task.sleep(for: .milliseconds(5))
        }
        w.fakes.locks.holdElsewhere(key, false)
        let outcome = await saving.value
        #expect(outcome.name == "declined")
        #expect(!draftAtWork.value && w.h.gateCalls.value.removedCleanupLists == ["op-1"], "잠금을 기다려 정리를 마친 뒤 쓴다(쓴 초안을 다시 쓰지 않게)")
    }

    // MARK: - 3라운드 O16

    @Test func 라이브러리를_다시_읽으면_미룬_곡_넣기_정리를_다시_한다() async throws {
        let w = AutoReflectionWorld()
        w.run = .off(.debugBuild)
        // 넣기는 핫큐를 썼고 CLI가 새 판을 남겼다. 새 곡 행을 아직 읽지 못해 정리를 미룬다
        var written = CueDraft(trackUUID: "s")
        written.place(EditableCue(id: UUID(), kind: .hot(0), time: 12))
        w.h.memory.save(written)
        let stamp = try #require(w.h.memory.stamp(DraftKey(.cue, "s")))
        var later = written
        later.place(EditableCue(id: UUID(), kind: .hot(1), time: 30))
        w.h.memory.save(later, origin: .cli)
        let add = DraftCleanupList.TrackAdd(stagedUUID: "s", trackUUID: "new-s",
                                            written: [WrittenDraft(key: DraftKey(.cue, "s"), revision: stamp.revision,
                                                                   contentHash: try DraftContentHash(of: written))],
                                            values: .init(cues: written.cues), blockedFields: [])
        w.h.script.cleanupLists = [DraftCleanupList(operationID: "op-add", target: MemoryWriteLocks.key(for: w.h.session.target.database),
                                                    draftHome: "/drafts", backupFolder: "add-1", trackAdds: [add])]
        try await w.start()
        #expect(w.h.gateCalls.value.removedCleanupLists.isEmpty)
        // 다시 읽기에 성공했는데 새 곡이 없다(그 사이 rekordbox에서 뺐다)
        w.engine.libraryReloaded()
        try await w.settle()
        #expect(w.h.gateCalls.value.removedCleanupLists == ["op-add"] && w.h.memory.cue("s") != nil)
    }
}
