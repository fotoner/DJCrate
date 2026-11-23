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
        let request = RekordboxJournalRequest(operationID: "op", database: nil)
        #expect(try gate.journal(target, nil) == .none)
        #expect(try gate.restoreJournal(target, request) == .nothing)
        #expect(try gate.keepJournal(target, request) { Issue.record("기록이 없으면 넘긴 일을 하지 않는다") } == .nothing)
        #expect(try gate.cleanupLists(target, URL(filePath: "/drafts")).isEmpty)
        try gate.removeCleanupList(DraftCleanupList(operationID: "op", target: RekordboxWriteLockKey(device: 1, inode: 2), draftHome: "/drafts",
                                                    backupFolder: "w1"), target)
        let backups = MemoryBackups().port
        #expect(backups.autoSaveCondition(URL(filePath: "/backups"), target.database) == .unknown)
    }

    /// 가짜 관문은 정한 판정을 돌려주고 부른 차례·넘긴 잠금·요청을 남긴다(엔진·세션 시험의 재료).
    /// 판정이 찾은 기록과 그때 본 DB 크기·시각이 그대로 요청이 된다(S3: 사용자가 확인한 기록만 복원·"이대로 둔다")
    @Test func 가짜_관문의_기록_판정() throws {
        var script = GateScript()
        let journal = RekordboxWriteJournal(operationID: "op-1", kind: .counter, entry: .drafts)
        let finding = RekordboxJournalFinding(journal: journal, changedSince: true, database: RekordboxFileStamp(size: 10, modifiedNanoseconds: 7))
        script.journal = .interrupted(finding)
        let calls = GateCalls()
        let gate = RekordboxWriteGate.scripted(script, calls: calls)
        let target = RekordboxWriteTarget.copy(database: URL(filePath: "/copy/master.db"), shareRoot: nil)
        let locks = MemoryWriteLocks()
        let hold = try #require(try locks.port.tryLock(MemoryWriteLocks.key(for: target.database)))
        #expect(try gate.journal(target, hold) == .interrupted(finding))
        hold.release()
        #expect(finding.request == RekordboxJournalRequest(operationID: "op-1", database: RekordboxFileStamp(size: 10, modifiedNanoseconds: 7)))
        #expect(try gate.restoreJournal(target, RekordboxJournalRequest(operationID: "op-0", database: finding.database)) == .changed)
        #expect(try gate.keepJournal(target, finding.request) {} == .kept)
        #expect(try gate.journal(target, nil) == .none)
        #expect(calls.value.journalHolds == [MemoryWriteLocks.key(for: target.database), nil])
        #expect(calls.value.journalRequests.map(\.operationID) == ["op-0", "op-1"] && calls.value.keptJournals == ["op-1"])
        #expect(calls.value.order == ["journal", "restore journal", "keep journal", "remove journal", "journal"])
    }

    /// "이대로 둔다"의 순서(S3): 요청이 다르면 넘긴 일 0회, 같으면 넘긴 일 뒤에 기록 삭제, 넘긴 일이 실패하면 기록이 남는다
    @Test func 이대로_둔다는_확인_뒤_넘긴_일을_하고_기록을_마지막에_지운다() throws {
        var script = GateScript()
        let stamp = RekordboxFileStamp(size: 10, modifiedNanoseconds: 7)
        let finding = RekordboxJournalFinding(journal: RekordboxWriteJournal(operationID: "op-1", kind: .files, entry: .pointRestore),
                                              changedSince: false, database: stamp)
        script.journal = .interrupted(finding)
        let gate = RekordboxWriteGate.scripted(script)
        let target = RekordboxWriteTarget.copy(database: URL(filePath: "/copy/master.db"), shareRoot: nil)
        try journalKeepContract(gate, target: target, matching: finding.request,
                                stale: RekordboxJournalRequest(operationID: "op-1", database: RekordboxFileStamp(size: 11, modifiedNanoseconds: 7)),
                                journalExists: { try gate.journal(target, nil) != .none })
    }

    /// 묶음은 초안마다 판과 읽어 넣은 내용의 해시를 나르고, 쓸 수 있는 묶음은 남긴 초안의 판만 나른다.
    /// 쓴 초안의 해시는 읽어 넣은 내용의 해시다(도장의 저장 때 해시가 아니다, S6)
    @Test func 묶음은_초안마다_판을_나른다() {
        let saved = DraftContentHash(hex: String(repeating: "a", count: 64)), read = DraftContentHash(hex: String(repeating: "b", count: 64))
        let entry = { (revision: UInt64) in
            DraftBatchEntry(stamp: DraftStamp(revision: DraftRevision(revision), origins: [.human], contentHash: saved), contentHash: read)
        }
        let batch = DraftWriteBatch(drafts: [ReflectionHarness.cue("a"), ReflectionHarness.cue("b")], gains: ["c": -1],
                                    revisions: DraftBatchRevisions(tracks: [DraftKey(.cue, "a"): entry(1), DraftKey(.cue, "b"): entry(2),
                                                                            DraftKey(.gain, "c"): entry(3)],
                                                                   playlistSteps: [entry(4), entry(5)]),
                                    operation: DraftWriteOperation(id: "op", draftHome: URL(filePath: "/drafts")), commitPolicy: .allOrNothing)
        #expect(batch.draftKeys == [DraftKey(.cue, "a"), DraftKey(.cue, "b"), DraftKey(.gain, "c")])
        // 쓸 수 있는 것만 쓰는 묶음(지금 동작)은 남긴 초안의 판만 나른다
        var partial = batch
        partial.commitPolicy = .writable
        let report = ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .written), ReflectionHarness.outcome("b", .blocked)])
        let writable = WritePreview(report: report, batch: partial).writableBatch
        #expect(writable.drafts.map(\.trackUUID) == ["a"] && writable.revisions.tracks.keys.sorted() == [DraftKey(.cue, "a")])
        #expect(writable.operation == batch.operation && writable.revisions.playlistSteps.isEmpty && writable.commitPolicy == .writable)
        #expect(batch.revisions.written([DraftKey(.gain, "c"), DraftKey(.cue, "a"), DraftKey(.tag, "x")])
            == [WrittenDraft(key: DraftKey(.cue, "a"), revision: DraftRevision(1), contentHash: read),
                WrittenDraft(key: DraftKey(.gain, "c"), revision: DraftRevision(3), contentHash: read)])
        #expect(batch.revisions.writtenSteps(at: [1, 7]) == [WrittenPlaylistStep(revision: DraftRevision(5), contentHash: read)])
        #expect(DraftWriteBatch().commitPolicy == .writable)
    }

    /// 전부 쓰거나 전부 안 쓰는 묶음(S8, R12): 하나라도 막혔거나 결과가 없으면 쓰기 요청이 없고(쓰기 0회), 모두 통과하면 원래 묶음 전체다
    @Test func 전부_아니면_안_쓰는_묶음은_일부만_넘기지_않는다() {
        let batch = DraftWriteBatch(drafts: [ReflectionHarness.cue("a"), ReflectionHarness.cue("b")], gains: ["c": -1],
                                    operation: DraftWriteOperation(id: "op", draftHome: URL(filePath: "/drafts")), commitPolicy: .allOrNothing)
        let oneBlocked = ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .written), ReflectionHarness.outcome("b", .blocked)],
                                                  gains: [ReflectionHarness.outcome("c", .written)])
        for preview in [WritePreview(report: oneBlocked, batch: batch),
                        WritePreview(report: ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .written)]), batch: batch),
                        WritePreview(report: ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .written), ReflectionHarness.outcome("b", .written)],
                                                                     gains: [ReflectionHarness.outcome("c", .written)]),
                                     batch: batch, exclusions: ["읽지 못한 초안"])] {
            #expect(preview.writeRequest == nil && !preview.hasWritable)
            #expect(preview.writableBatch.drafts.isEmpty && preview.writableBatch.gains.isEmpty && preview.writableBatch.commitPolicy == .allOrNothing)
        }
        let passed = ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .written), ReflectionHarness.outcome("b", .unchanged)],
                                              gains: [ReflectionHarness.outcome("c", .written)])
        let preview = WritePreview(report: passed, batch: batch)
        #expect(preview.writeRequest == batch && preview.hasWritable && preview.writableBatch == batch)
    }

    /// 쓰기 방식(S8)·판·작업 정보는 세션이 미리 보기와 관문 쓰기까지 버리지 않고 나른다
    @Test func 쓰기_방식은_관문까지_그대로_간다() async throws {
        let harness = ReflectionHarness()
        let batch = DraftWriteBatch(drafts: [ReflectionHarness.cue("a")], operation: DraftWriteOperation(id: "op", draftHome: URL(filePath: "/drafts")),
                                    commitPolicy: .allOrNothing)
        _ = try await harness.session.writeDrafts(batch, to: harness.session.target, dryRun: true)
        let gate = harness.session.ports.gate, target = harness.session.target
        _ = try await gate.preview(batch, [:], target) {}
        let calls = harness.gateCalls.value
        #expect(calls.writes.map(\.commitPolicy) == [.allOrNothing] && calls.writes.map(\.operation) == [batch.operation])
        #expect(calls.previews.map(\.commitPolicy) == [.allOrNothing])
    }

    /// 다시 켠 뒤 정리는 미정리 목록에서 쓴 단계·연결 ID·그 쓰기의 백업 폴더를 읽어 같은 사본 자리를 쓴다(S5)
    @Test func 미정리_목록으로_재생_목록_단계_정리를_만든다() {
        let hash = DraftContentHash(hex: "d")
        var list = DraftCleanupList(operationID: "op", target: RekordboxWriteLockKey(device: 1, inode: 2), draftHome: "/drafts",
                                    backupFolder: "2026-11-24_120000")
        list.playlistSteps = [.init(revision: DraftRevision(5), contentHash: hash, outcome: .written),
                              .init(revision: DraftRevision(6), contentHash: hash, outcome: .blocked("목록이 바뀌었습니다")),
                              .init(revision: DraftRevision(7), contentHash: hash, outcome: .notTried)]
        list.newPlaylistIDs = ["new:a": "123"]
        let cleanup = PlaylistStepCleanup(list: list, backups: URL(filePath: "/backups"))
        #expect(cleanup.written == [WrittenPlaylistStep(revision: DraftRevision(5), contentHash: hash)])
        #expect(cleanup.newPlaylistIDs == ["new:a": "123"] && cleanup.copyFolder.path == "/backups/2026-11-24_120000")
    }

    /// 곡 넣기 묶음도 옛 UUID별 초안 판과 작업 정보를 나른다(S2). 기본값은 지금 동작(모름·nil)이다
    @Test func 곡_넣기_묶음의_판과_작업_정보() {
        #expect(TrackAddBatch(plans: []).stagedUUIDs.isEmpty && TrackAddBatch(plans: []).revisions.isEmpty && TrackAddBatch(plans: []).operation == nil)
        let entry = DraftBatchEntry(stamp: DraftStamp(revision: DraftRevision(1), origins: [.human], contentHash: DraftContentHash(hex: "c")),
                                    contentHash: DraftContentHash(hex: "c"))
        let batch = TrackAddBatch(plans: [], stagedUUIDs: ["/a.mp3": "s1"], revisions: DraftBatchRevisions(tracks: [DraftKey(.cue, "s1"): entry]),
                                  operation: DraftWriteOperation(id: "op", draftHome: URL(filePath: "/drafts")))
        #expect(batch.revisions.written([DraftKey(.cue, "s1")]).map(\.key.id) == ["s1"] && batch.operation?.id == "op")
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
