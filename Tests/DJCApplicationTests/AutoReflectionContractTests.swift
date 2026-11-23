import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 자동 저장 계약(#398): 빈 엔진은 아무것도 하지 않고, 새 포트의 기본값은 지금 동작(기록·목록·잠금 없음)을 지킨다.
/// 몸체가 채워질 판정(실행 조건 R18, 상태 줄 R3 줄 고르기)은 W2가 시험을 먼저 쓴다. 여기는 값과 표만 본다.
@MainActor
@Suite("자동 저장 계약")
struct AutoReflectionContractTests {
    @Test func 자가_테스트_인자는_경우를_가르고_빈_값도_요청으로_본다() {
        #expect(AutoReflectSelfTest.allCases.map(\.rawValue) == ["save", "two-process", "kill-detect"])
        for test in AutoReflectSelfTest.allCases {
            let arguments = ["djcrate", "--auto-reflect-selftest=\(test.rawValue)"]
            #expect(AutoReflectSelfTest.requested(arguments: arguments) == test)
            #expect(AutoReflectSelfTest.isRequested(arguments: arguments))
        }
        for value in ["--auto-reflect-selftest=", "--auto-reflect-selftest=copy", "--auto-reflect-selftest"] {
            #expect(AutoReflectSelfTest.isRequested(arguments: ["djcrate", value]))
            #expect(AutoReflectSelfTest.requested(arguments: ["djcrate", value]) == nil)
        }
        // 첫 인자(실행 파일 경로)는 보지 않고, 둘 이상이면 경우를 고르지 않는다
        #expect(!AutoReflectSelfTest.isRequested(arguments: ["--auto-reflect-selftest=save"]))
        #expect(AutoReflectSelfTest.requested(arguments: ["djcrate", "--auto-reflect-selftest=save", "--auto-reflect-selftest=two-process"]) == nil)
        #expect(!AutoReflectSelfTest.isRequested(arguments: ["djcrate", "--write-selftest"]))
    }

    /// 몸체(W2-D) 전에는 어느 실행도 자동 저장하지 않는다(지금 동작)
    @Test func 실행_조건은_아직_늘_꺼짐이다() {
        for release in [true, false] {
            let run = AutoReflectionRun.decide(.init(isReleaseBuild: release, arguments: ["djcrate"], opensExplicitCopy: false, isDiagnosticRun: false))
            #expect(!run.autoSaves)
        }
        #expect(AutoReflectionRun.live.autoSaves && AutoReflectionRun.selfTest(.save).autoSaves)
    }

    /// R3 표의 "저장 단추"·"⌘S" 칸
    @Test func 상태_줄_표() {
        #expect(ReflectionStatusRow.allCases.map(\.rawValue) == Array(1...9))
        #expect(ReflectionStatusRow.allCases.filter(\.showsSaveButton) == [.manualRun, .stopped, .leftover])
        #expect(ReflectionStatusRow.allCases.map(\.saveCommand) == [.restoreOnly, .refuseWithReason, .refuseWithReason, .commitFieldThenFollow,
                                                                    .queueFront, .saveNow, .saveAndResume, .saveAllLeftovers, .saveNowIfAllowed])
        #expect(ReflectionStatusRow.interrupted < .waiting)
    }

    @Test func 보류_멈춤_중단을_가른다() {
        #expect(ReflectionHold.stoppedAfterFailure.kind == .stop && ReflectionHold.stoppedAfterRestore.kind == .stop)
        #expect(ReflectionHold.interrupted(recoveryFailed: true).kind == .interrupted)
        for hold: ReflectionHold in [.rekordboxRunning, .quietWaiting, .lockBusy, .unwritable(.counters), .backupNoClone, .preBackupFailure,
                                     .notAutoRun(.explicitCopy), .cleanupPending] {
            #expect(hold.kind == .hold)
        }
        // 집합으로 모은다(쓸 수 없음의 이유가 다르면 다른 사유)
        let holds: Set<ReflectionHold> = [.unwritable(.unsupportedVersion("7.3.0")), .unwritable(.unsupportedVersion("7.3.0")), .unwritable(.schema)]
        #expect(holds.count == 2)
    }

    @Test func 백업_조건의_여유_공간은_1GB와_DB의_3배_중_큰_값이다() {
        let gigabyte: Int64 = 1 << 30
        #expect(RekordboxBackupCondition.requiredFreeSpace(databaseSize: 100 << 20) == gigabyte)
        #expect(RekordboxBackupCondition.requiredFreeSpace(databaseSize: 500 << 20) == 1500 << 20)
        #expect(RekordboxBackupCondition.requiredFreeSpace(databaseSize: .max) == .max)
    }

    /// 빈 엔진: 신호와 요청을 받아도 잠금·기록·관문을 건드리지 않고 상태가 그대로다
    @Test func 빈_엔진은_아무것도_하지_않는다() async {
        let harness = ReflectionHarness()
        let fakes = AutoReflectionFakes()
        let engine = AutoReflection(session: harness.session, ports: fakes.ports(), run: .live,
                                    timing: AutoReflectionTiming(editDelay: .zero, quietDelay: .zero, bulkDelay: .zero, bulkTracks: 1,
                                                                 rowLimit: 1, successToasts: 0))
        engine.start()
        engine.edited()
        engine.setActivity([.fieldEditing, .composing])
        engine.enqueue(.saveNow)
        engine.enqueue(.undo(ReflectionUndoEdit(id: "u", batch: DraftWriteBatch(), rowCount: 1)))
        engine.cancelGrace()
        await engine.prepareToQuit()
        engine.shutdown()
        engine.stop()
        #expect(engine.status == .saved && engine.conditions == ReflectionConditions())
        #expect(fakes.locks.taken.isEmpty && fakes.records.saves == 0 && fakes.publishedStatuses.isEmpty)
        #expect(harness.gateCalls.value.order.isEmpty)
        #expect(AutoReflectionTiming.standard == AutoReflectionTiming(editDelay: .seconds(3), quietDelay: .seconds(10), bulkDelay: .seconds(30),
                                                                     bulkTracks: 50, rowLimit: 200, successToasts: 5))
        #expect(EditActivity([.pointerDown]).isEditing && !EditActivity().isEditing)
    }

    /// 새 관문 클로저의 기본값은 지금 동작이다: 기록이 없고, 복원할 것이 없고, 미정리 목록이 없다
    @Test func 관문의_기록_클로저_기본값은_기록_없음이다() throws {
        let fail: @Sendable () -> Never = { Issue.record("기존 입구는 부르지 않는다"); fatalError() }
        let gate = RekordboxWriteGate(write: { _, _, _, _ in fail() }, preview: { _, _, _, _ in fail() }, restore: { _, _ in fail() },
                                      addTracks: { _, _, _ in fail() }, deleteTracks: { _, _, _ in fail() },
                                      restorePointSnapshot: { _, _, _, _, _ in fail() }, writePlaylists: { _, _, _ in fail() },
                                      syncITunes: { _, _ in fail() })
        let target = RekordboxWriteTarget.copy(database: URL(filePath: "/copy/master.db"), shareRoot: nil)
        #expect(try gate.journal(target) == .none)
        #expect(try gate.restoreJournal(target) == .nothing)
        try gate.keepJournal(target, "op")
        #expect(try gate.cleanupLists(target, URL(filePath: "/drafts")).isEmpty)
        try gate.removeCleanupList(DraftCleanupList(operationID: "op", target: RekordboxWriteLockKey(device: 1, inode: 2), draftHome: "/drafts"), target)
        let backups = MemoryBackups().port
        #expect(backups.autoSaveCondition(URL(filePath: "/backups"), target.database) == .unknown)
    }

    /// 가짜 관문은 정한 판정을 돌려주고 부른 차례를 남긴다(엔진·세션 시험의 재료)
    @Test func 가짜_관문의_기록_판정() throws {
        var script = GateScript()
        let journal = RekordboxWriteJournal(operationID: "op-1", kind: .counter, entry: .drafts)
        script.journal = .interrupted(journal, changedSince: true)
        let calls = GateCalls()
        let gate = RekordboxWriteGate.scripted(script, calls: calls)
        let target = RekordboxWriteTarget.copy(database: URL(filePath: "/copy/master.db"), shareRoot: nil)
        #expect(try gate.journal(target) == .interrupted(journal, changedSince: true))
        try gate.keepJournal(target, "op-1")
        #expect(calls.value.keptJournals == ["op-1"] && calls.value.order == ["journal", "keep journal"])
    }

    /// 묶음은 초안마다 판을 나르고, 쓸 수 있는 묶음은 남긴 초안의 판만 나른다
    @Test func 묶음은_초안마다_판을_나른다() {
        let hash = DraftContentHash(hex: String(repeating: "b", count: 64))
        let stamp = { (revision: UInt64) in DraftStamp(revision: DraftRevision(revision), origins: [.human], contentHash: hash) }
        let batch = DraftWriteBatch(drafts: [ReflectionHarness.cue("a"), ReflectionHarness.cue("b")], gains: ["c": -1],
                                    revisions: DraftBatchRevisions(tracks: [DraftKey(.cue, "a"): stamp(1), DraftKey(.cue, "b"): stamp(2),
                                                                            DraftKey(.gain, "c"): stamp(3)]),
                                    operation: DraftWriteOperation(id: "op", draftHome: URL(filePath: "/drafts")))
        #expect(batch.draftKeys == [DraftKey(.cue, "a"), DraftKey(.cue, "b"), DraftKey(.gain, "c")])
        let report = ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .written)])
        let writable = WritePreview(report: report, batch: batch).writableBatch
        #expect(writable.revisions.tracks.keys.sorted() == [DraftKey(.cue, "a")])
        #expect(writable.operation == batch.operation && writable.revisions.playlistSteps.isEmpty)
        #expect(batch.revisions.written([DraftKey(.gain, "c"), DraftKey(.cue, "a"), DraftKey(.tag, "x")])
            == [WrittenDraft(key: DraftKey(.cue, "a"), revision: DraftRevision(1), contentHash: hash),
                WrittenDraft(key: DraftKey(.gain, "c"), revision: DraftRevision(3), contentHash: hash)])
    }

    /// 초안 포트의 출처: 정하지 않은 포트는 모름, 출처만 바꾼 포트는 같은 저장소를 쓴다
    @Test func 초안_포트의_출처() {
        let drafts = MemoryDrafts()
        #expect(drafts.store.origin == .human && drafts.store.with(origin: .restored).origin == .restored)
        drafts.store.with(origin: .link).saveCue(ReflectionHarness.cue("a"))
        #expect(drafts.stamp(DraftKey(.cue, "a"))?.origins == [.link])
        var bare = drafts.store
        bare.originVariant = nil
        #expect(bare.with(origin: .cli).origin == .cli)
        let files = MemoryDraftFiles().files
        #expect(files.origin == .unknown && files.stamp(DraftKey(.cue, "a")) == nil)
    }

    /// 자동 저장 기록(`DJC_HOME`의 `auto-reflection.json`): 왕복이 같고, 판은 정한 차례로 적고, 빠진 칸은 빈 값으로 읽는다
    @Test func 자동_저장_기록_형식() throws {
        let record = AutoReflectionRecord(stop: .afterRestore, cancelledRevisions: [DraftRevision(9), DraftRevision(2)],
                                          preBackupFailure: .init(cause: "사본 뜨기", count: 2))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        #expect(String(decoding: data, as: UTF8.self).contains(#""cancelledRevisions":[2,9]"#))
        #expect(try JSONDecoder().decode(AutoReflectionRecord.self, from: data) == record)
        #expect(try JSONDecoder().decode(AutoReflectionRecord.self, from: Data("{}".utf8)) == AutoReflectionRecord())
        #expect(AutoReflectionRecord.fileName == "auto-reflection.json")
    }

    /// 엔진 시험의 가짜 시계: 넘긴 시각이 지나야 깨고, 취소하면(잠들기 전이어도) 던진다
    @Test func 손으로_넘기는_시계() async throws {
        let clock = ManualReflectionClock()
        let port = clock.clock
        let start = port.now()
        let sleeping = Task { try await port.sleep(.seconds(3)) }
        while clock.sleeping == 0 { await Task.yield() }
        clock.advance(.seconds(2))
        #expect(clock.sleeping == 1)
        clock.advance(.seconds(1))
        try await sleeping.value
        #expect(port.now() == start.addingTimeInterval(3))

        let cancelled = Task { try await port.sleep(.seconds(1)) }
        while clock.sleeping == 0 { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await port.sleep(.seconds(1))
        }
        await #expect(throws: CancellationError.self) { try await early.value }
        #expect(clock.sleeping == 0)
    }

    /// 곡 단위 편집 잠금의 기본값은 아무것도 하지 않는다(동작은 W1-G)
    @Test func 곡_단위_편집_잠금_기본값() {
        let lock = WriteLock.none
        lock.setTracks(["a"])
        #expect(lock.lockedTracks().isEmpty)
    }
}
