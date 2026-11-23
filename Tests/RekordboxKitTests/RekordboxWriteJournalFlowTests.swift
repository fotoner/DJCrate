import CryptoKit
import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 쓰기 기록(R11)과 복구 실패(R7): 입구마다 강제 종료를 흉내 낸 뒤(훅이 `RekordboxWriteStop`을 던진다) 재시작 판정이 중단인지,
/// 같은 대상의 새 쓰기를 거절하는지, 기록으로 복원하면 작업 전(복원 작업이면 복원을 마친 뒤)과 같은지 본다. 합성 사본으로만 한다.
@Suite("rekordbox 쓰기 기록")
struct RekordboxWriteJournalFlowTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    typealias Kit = JournalTestKit

    func cueDraft(_ fixture: RekordboxFixture) throws -> CueDraft {
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 30))
        return draft
    }

    func writeCue(_ fixture: RekordboxFixture, _ draft: CueDraft, guard writeGuard: RekordboxWriteGuard = JournalTestKit.copyGuard,
                  record: RekordboxDraftRecord<RekordboxWriter.Report>? = nil) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: [draft], to: fixture.database, dryRun: false, now: now, backups: fixture.backups,
                                  guard: writeGuard, record: record)
    }

    /// BPM이 바뀌는 그리드(.DAT·.EXT 두 파일)
    func gridDraft(_ fixture: RekordboxFixture) throws -> (GridDraft, TrackSpec) {
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        var grid = GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track)))
        grid.setBPM(130, at: 0)
        return (grid, track)
    }

    func writeGrid(_ fixture: RekordboxFixture, _ grid: GridDraft, drafts: [CueDraft] = [],
                   guard writeGuard: RekordboxWriteGuard = JournalTestKit.copyGuard) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: drafts, grids: [grid], to: fixture.database, dryRun: false, now: now, backups: fixture.backups,
                                  shareRoot: fixture.shareRoot, guard: writeGuard)
    }

    func analysisFiles(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> [Data] {
        [try Data(contentsOf: fixture.analysisURL(for: track)), try Data(contentsOf: fixture.analysisURL(for: track, ext: "EXT"))]
    }

    func refusesNewWrite(_ fixture: RekordboxFixture) throws {
        let draft = try cueDraft(fixture)
        let error = try #require(throws: DJCError.self) { try writeCue(fixture, draft) }
        guard case let .writeRefused(reason) = error else { Issue.record("거절이 아님: \(error)"); return }
        #expect(reason.contains("끝나지 않은 저장 기록"))
    }

    // MARK: 중단 판정

    @Test func 커밋_직후에_멈추면_재시작_판정이_중단이고_같은_대상의_쓰기를_거절한다() throws {
        let fixture = try RekordboxFixture()
        let draft = try cueDraft(fixture)
        let start = try fixture.localUpdateCount()
        let script = WriteHookScript()
        script.stop(at: .after(.commit))
        #expect(throws: RekordboxWriteStop.self) { try writeCue(fixture, draft, guard: script.writeGuard) }
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        #expect(found.journal.kind == .counter && found.journal.entry == .drafts && found.journal.startCounter == start)
        #expect(found.journal.basis.writeBackup != nil && !found.changedSince)
        try refusesNewWrite(fixture)
        // 다른 백업으로 되돌리는 것도 기록이 남은 동안 막는다
        let other = try RekordboxWriter.makeBackup(of: fixture.database, in: fixture.backups, now: now.addingTimeInterval(-60), label: "write")
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.restore(other, to: fixture.database, backups: fixture.backups, guard: Kit.copyGuard)
        }
        #expect(error.description.contains("끝나지 않은 저장 기록"))
    }

    @Test(arguments: [1, 2]) func 파일_경계마다_멈추면_중단이다(boundary: Int) throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, _) = try gridDraft(fixture)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace), occurrence: boundary)
        #expect(throws: RekordboxWriteStop.self) { try writeGrid(fixture, grid, guard: script.writeGuard) }
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        #expect(found.journal.kind == .counter && found.journal.files.count == 2)
        try refusesNewWrite(fixture)
    }

    @Test func BPM이_그대로인_그리드만_든_쓰기가_파일_경계에서_멈추면_중단이다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        var grid = GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track)))
        grid.shift(by: 0.01)
        let before = try Kit.state(fixture), files = try analysisFiles(fixture, track)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) { try writeGrid(fixture, grid, guard: script.writeGuard) }
        #expect(try Kit.state(fixture) == before, "DB는 바꾸지 않는 쓰기(ROLLBACK 뒤 파일만)")
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        #expect(found.journal.kind == .files && found.journal.startCounter == nil)
        try refusesNewWrite(fixture)
        #expect(try Kit.restore(fixture, shareRoot: fixture.shareRoot).isRestored)
        #expect(try analysisFiles(fixture, track) == files && Kit.leftovers(fixture.shareRoot, fixture.root).isEmpty)
    }

    @Test func 커밋_직전_멈춤·커밋_전_롤백·정상_끝·보고서_저장만_실패한_쓰기는_재시작_판정에_알림이_없다() throws {
        let fixture = try RekordboxFixture()
        // 커밋 직전 멈춤: 기록은 남지만 카운터가 그대로라 판정이 조용히 지운다
        let stopped = WriteHookScript()
        stopped.stop(at: .before(.commit))
        #expect(throws: RekordboxWriteStop.self) { try writeCue(fixture, try cueDraft(fixture), guard: stopped.writeGuard) }
        #expect(try Kit.journal(fixture) != nil)
        #expect(try Kit.judge(fixture) == RekordboxJournalJudgment.none)
        #expect(try Kit.journal(fixture) == nil)
        // 커밋 전 롤백(실패): 바꾼 것이 없어 기록을 지운다
        let failed = WriteHookScript()
        failed.fail(at: .before(.commit))
        #expect(throws: WriteHookScript.Injected.self) { try writeCue(fixture, try cueDraft(fixture), guard: failed.writeGuard) }
        #expect(try Kit.journal(fixture) == nil && Kit.judge(fixture) == RekordboxJournalJudgment.none)
        // 정상 끝
        _ = try writeCue(fixture, try cueDraft(fixture))
        #expect(try Kit.journal(fixture) == nil && Kit.judge(fixture) == RekordboxJournalJudgment.none)
        // 보고서 저장만 실패: 경고만 하고 기록을 지운다
        let reportFails = WriteHookScript()
        reportFails.fail(at: .before(.reportSave))
        let report = try writeCue(fixture, try cueDraft(fixture), guard: reportFails.writeGuard)
        #expect(report.written.count == 1 && !(report.warnings ?? []).isEmpty)
        #expect(try Kit.journal(fixture) == nil && Kit.judge(fixture) == RekordboxJournalJudgment.none)
        #expect(Kit.leftovers(fixture.root).isEmpty)
    }

    @Test func 다른_프로세스가_잠금을_쥔_동안에는_기록을_판정하지_않는다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript()
        script.stop(at: .after(.commit))
        #expect(throws: RekordboxWriteStop.self) { try writeCue(fixture, try cueDraft(fixture), guard: script.writeGuard) }
        let hold = try RekordboxWriteLocks.system.lock(try RekordboxWriteLocks.key(fixture.database))
        #expect(try Kit.judge(fixture) == nil, "잠금을 못 잡으면 판정하지 않는다(진행 중)")
        hold.release()
        #expect(Kit.interrupted(try Kit.judge(fixture)) != nil)
    }

    // MARK: 기록으로 복원

    @Test func 기록으로_복원하면_쓰기_전과_같고_만든_파일과_준비_폴더가_남지_않는다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, track) = try gridDraft(fixture)
        let cue = try cueDraft(fixture)
        let before = try Kit.state(fixture), files = try analysisFiles(fixture, track)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) { try writeGrid(fixture, grid, drafts: [cue], guard: script.writeGuard) }
        #expect(try Kit.state(fixture) != before)
        #expect(try Kit.restore(fixture, shareRoot: fixture.shareRoot).isRestored)
        #expect(try Kit.state(fixture) == before)
        #expect(try analysisFiles(fixture, track) == files)
        #expect(try Kit.journal(fixture) == nil && Kit.leftovers(fixture.shareRoot, fixture.root).isEmpty)
        #expect(try Kit.judge(fixture) == RekordboxJournalJudgment.none)
        // 기록이 없으면 할 일이 없다
        #expect(try RekordboxWriter.restoreJournal(database: fixture.database, operationID: "x", databaseStamp: nil, backups: fixture.backups,
                                                   shareRoot: fixture.shareRoot, guard: Kit.copyGuard).isNothing)
    }

    @Test func 기록으로_복원이_다시_멈춘_뒤_또_복원해도_쓰기_전과_같다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, track) = try gridDraft(fixture)
        let before = try Kit.state(fixture), files = try analysisFiles(fixture, track)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) { try writeGrid(fixture, grid, guard: script.writeGuard) }
        let again = WriteHookScript()
        again.stop(at: .after(.databaseReplace))
        #expect(throws: RekordboxWriteStop.self) { try Kit.restore(fixture, shareRoot: fixture.shareRoot, guard: again.writeGuard) }
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        #expect(found.journal.marks.contains(.restoring))
        #expect(try Kit.restore(fixture, shareRoot: fixture.shareRoot).isRestored)
        #expect(try Kit.state(fixture) == before && analysisFiles(fixture, track) == files)
        #expect(try Kit.journal(fixture) == nil)
    }

    @Test func 요청이_기록과_다르면_복원하지_않는다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript()
        script.stop(at: .after(.commit))
        #expect(throws: RekordboxWriteStop.self) { try writeCue(fixture, try cueDraft(fixture), guard: script.writeGuard) }
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        let changed = try RekordboxWriter.restoreJournal(database: fixture.database, operationID: "다른 작업", databaseStamp: found.stamp,
                                                         backups: fixture.backups, shareRoot: nil, guard: Kit.copyGuard)
        #expect(try changed.isChanged && Kit.journal(fixture) != nil)
    }

    @Test func 쓰기_전으로_복원이_DB를_바꾼_뒤_멈추면_중단이고_기록으로_복원하면_복원을_마친_상태이며_경고가_없다() throws {
        for stopsBeforeJournalUpdate in [false, true] {
            let fixture = try RekordboxFixture()
            let draft = try cueDraft(fixture)
            let original = try Kit.state(fixture)
            let report = try writeCue(fixture, draft)
            let target = try Kit.state(fixture)
            let backup = URL(filePath: try #require(report.backup))
            let script = WriteHookScript()
            if stopsBeforeJournalUpdate {
                // DB를 바꾼 직후, 기록에 바꾼 DB 크기·시각을 적기 전에 멈춘다(준비 사본의 크기·시각은 이미 적었다)
                script.stop(at: .before(.journalWrite), occurrence: 3)
            } else {
                script.stop(at: .after(.databaseReplace))
            }
            #expect(throws: RekordboxWriteStop.self) {
                try RekordboxWriter.restore(backup, to: fixture.database, now: now.addingTimeInterval(60), backups: fixture.backups,
                                            guard: script.writeGuard)
            }
            #expect(try Kit.state(fixture) != target, "DB를 먼저 되돌렸다")
            let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
            #expect(found.journal.entry == .restore && found.journal.kind == .files)
            #expect(!found.changedSince, "DB를 되돌린 뒤 멈춘 복원을 다시 할 때는 경고하지 않는다")
            #expect(try Kit.restore(fixture).isDone)
            #expect(try Kit.state(fixture) == original && Kit.journal(fixture) == nil)
        }
    }

    @Test func 중단_뒤_라이브러리가_바뀌면_경고한다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript()
        script.stop(at: .after(.commit))
        #expect(throws: RekordboxWriteStop.self) { try writeCue(fixture, try cueDraft(fixture), guard: script.writeGuard) }
        #expect(Kit.interrupted(try Kit.judge(fixture))?.changedSince == false)
        // rekordbox의 편집은 변경 카운터를 올린다(이 쓰기의 최종 카운터와 달라진다)
        try fixture.execute("UPDATE djmdContent SET Commnt = 'rekordbox에서 고침'")
        try fixture.execute("UPDATE agentRegistry SET int_1 = int_1 + 1 WHERE registry_id = 'localUpdateCount'")
        #expect(Kit.interrupted(try Kit.judge(fixture))?.changedSince == true)
    }

    @Test func 파일_쓰기_기록은_카운터가_같아도_크기·시각이_바뀌면_경고한다() throws {
        let fixture = try RekordboxFixture()
        let report = try writeCue(fixture, try cueDraft(fixture))
        let backup = URL(filePath: try #require(report.backup))
        let script = WriteHookScript()
        script.stop(at: .after(.databaseReplace))
        #expect(throws: RekordboxWriteStop.self) {
            try RekordboxWriter.restore(backup, to: fixture.database, now: now.addingTimeInterval(60), backups: fixture.backups, guard: script.writeGuard)
        }
        let counter = try fixture.localUpdateCount()
        try fixture.execute("UPDATE djmdContent SET Commnt = 'rekordbox에서 고침'")
        try fixture.execute("UPDATE agentRegistry SET int_1 = ? WHERE registry_id = 'localUpdateCount'", [.int(counter)])
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        #expect(found.changedSince)
    }

    // MARK: 시점 복원·iTunes 동기화

    @Test func 시점_복원이_첫_파일_변경_뒤_멈추면_중단이고_기록으로_복원하면_그_시점이며_복원_직전_스냅샷을_다시_쓴다() throws {
        let tests = RekordboxPointRestoreTests()
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try tests.gridTrack(fixture, title: "곡 X"), y = try tests.gridTrack(fixture, title: "곡 Y")
        _ = try tests.writeBPM(fixture, x, 131, at: now)
        let middle = try tests.snapshot(fixture, "가운데", at: now.addingTimeInterval(10))
        let middleFiles = tests.shareFiles(fixture), middleDB = try Data(contentsOf: fixture.database)
        _ = try tests.writeBPM(fixture, y, 140, at: now.addingTimeInterval(20))
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) {
            try tests.restore(fixture, middle, at: now.addingTimeInterval(30), guard: script.writeGuard)
        }
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        #expect(found.journal.entry == .pointRestore && found.journal.pointRestore?.temporaryFolders.isEmpty == false)
        try refusesNewWrite(fixture)
        let beforeRestores = RekordboxPointSnapshot.list(in: tests.snapshots(fixture)).filter { $0.metadata.kind == .beforeRestore }
        #expect(beforeRestores.count == 1)
        // 기록의 복원 직전 스냅샷은 기록이 남은 동안 지우지 않는다
        #expect(throws: DJCError.self) { try RekordboxPointSnapshot.delete(beforeRestores[0].url, in: tests.snapshots(fixture)) }
        #expect(try Kit.restore(fixture).isRestored)
        #expect(try Data(contentsOf: fixture.database) == middleDB)
        #expect(tests.shareFiles(fixture) == middleFiles, "시점이 섞인 상태를 남기지 않는다")
        #expect(Kit.leftovers(fixture.shareRoot, fixture.root).isEmpty)
        #expect(RekordboxPointSnapshot.list(in: tests.snapshots(fixture)).filter { $0.metadata.kind == .beforeRestore }.map(\.url)
                == beforeRestores.map(\.url), "복원 직전 스냅샷을 새로 뜨지 않았다")
        #expect(try Kit.journal(fixture) == nil)
    }

    @Test func iTunes_동기화가_파일을_바꾼_뒤_멈추면_중단이고_기록으로_복원하면_원래_선택이다() throws {
        let fixture = try RekordboxFixture(), target = fixture.root.appending(path: "playlists3.sync")
        try RekordboxITunesSyncTests.original.write(to: target)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) {
            try RekordboxWriter.writeITunesSync(RekordboxITunesSyncTests().change(), to: fixture.database, dryRun: false, now: now,
                                                backups: fixture.backups, guard: script.writeGuard)
        }
        #expect(try Data(contentsOf: target) != RekordboxITunesSyncTests.original)
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        #expect(found.journal.entry == .iTunesSync && found.journal.kind == .files)
        #expect(try Kit.restore(fixture).isRestored)
        #expect(try Data(contentsOf: target) == RekordboxITunesSyncTests.original && Kit.journal(fixture) == nil)
    }

    // MARK: 자동 복구(R7)

    @Test func 자동_복구가_DB를_되돌린_직후_멈추면_재시작_판정이_중단이다() throws {
        let fixture = try RekordboxFixture()
        let draft = try cueDraft(fixture)
        try RekordboxRestoreFailureTests().tamperOnCommit(fixture, "UPDATE contentCue SET rb_cue_count = rb_cue_count + 100")
        let script = WriteHookScript()
        script.stop(at: .after(.databaseReplace))
        #expect(throws: RekordboxWriteStop.self) { try writeCue(fixture, draft, guard: script.writeGuard) }
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        #expect(found.journal.marks.contains(.recovering))
        try refusesNewWrite(fixture)
    }

    @Test func 복구까지_실패하면_복구_실패로_남아_같은_대상의_쓰기를_거절하고_기록으로_복원은_된다() throws {
        let failures = RekordboxRestoreFailureTests()
        let fixture = try RekordboxFixture()
        defer { failures.unlock(fixture) }
        let draft = try cueDraft(fixture)
        try failures.tamperOnCommit(fixture, "UPDATE contentCue SET rb_cue_count = rb_cue_count + 100")
        let before = try failures.state(fixture)
        try failures.blockRestore(fixture)
        let error = try #require(throws: DJCError.self) { try writeCue(fixture, draft) }
        guard case .restoreFailed = error else { Issue.record("복구 실패가 아님: \(error)"); return }
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        #expect(found.journal.marks.contains(.recoveryFailed))
        try fixture.execute("DROP TRIGGER djc_test_tamper")
        try refusesNewWrite(fixture)
        failures.unlock(fixture)
        try FileManager.default.removeItem(at: URL(filePath: fixture.database.path + ".djc-restore"))
        #expect(try Kit.restore(fixture).isRestored)
        #expect(try failures.state(fixture) == before && Kit.journal(fixture) == nil)
    }

    // MARK: 미정리 목록(R22)

    func record(_ fixture: RekordboxFixture, operationID: String = "op-1") -> RekordboxDraftRecord<RekordboxWriter.Report> {
        let home = fixture.root.appending(path: "drafts").path
        let written = WrittenDraft(key: DraftKey(.cue, "x"), revision: DraftRevision(7), contentHash: DraftContentHash(hex: "ab"))
        return RekordboxDraftRecord(operationID: operationID, drafts: .init(home: home, written: [written])) { report in
            DraftCleanupList(operationID: operationID, target: RekordboxWriteLockKey(device: 0, inode: 0), draftHome: home, backupFolder: "",
                             written: report.written.isEmpty ? [] : [written])
        }
    }

    @Test func 앱의_쓰기는_기록에_초안의_판을_적고_기록을_지우기_직전에_미정리_목록을_적는다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript()
        let journalSeen = JournalBox(), journalURL = try Kit.journalURL(fixture)
        script.on(.before(.cleanupListWrite)) { journalSeen.value = try? RekordboxWriter.readJournal(at: journalURL) }
        let report = try writeCue(fixture, try cueDraft(fixture), guard: script.writeGuard, record: record(fixture))
        let lists = try RekordboxWriter.cleanupLists(in: fixture.backups)
        let list = try #require(lists.first)
        let key = try RekordboxWriteLocks.key(fixture.database), backup = URL(filePath: try #require(report.backup))
        #expect(lists.count == 1 && list.operationID == "op-1" && list.target == key)
        #expect(list.backupFolder == backup.lastPathComponent && list.written.count == 1)
        #expect(journalSeen.value?.drafts?.written.map(\.revision) == [DraftRevision(7)] && journalSeen.value?.operationID == "op-1")
        #expect(try Kit.journal(fixture) == nil)
        let order = script.moments.filter { [.after(.cleanupListWrite), .before(.journalRemove)].contains($0) }
        #expect(order == [.after(.cleanupListWrite), .before(.journalRemove)])
    }

    @Test func 미정리_목록을_적은_직후_멈춘_쓰기를_기록으로_복원하거나_이대로_두면_목록을_먼저_지운다() throws {
        for keeps in [false, true] {
            let fixture = try RekordboxFixture()
            let script = WriteHookScript()
            script.stop(at: .after(.cleanupListWrite))
            #expect(throws: RekordboxWriteStop.self) {
                try writeCue(fixture, try cueDraft(fixture), guard: script.writeGuard, record: record(fixture))
            }
            #expect(try RekordboxWriter.cleanupLists(in: fixture.backups).count == 1)
            let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
            if keeps {
                let listGone = JournalBox()
                let outcome = try RekordboxWriter.keepJournal(database: fixture.database, operationID: found.journal.operationID,
                                                              databaseStamp: found.stamp, backups: fixture.backups, guard: Kit.copyGuard) {
                    try RekordboxWriter.removeCleanupList(operationID: found.journal.operationID, in: fixture.backups)
                    listGone.journal = try? Kit.journal(fixture)
                }
                #expect(outcome.isDone && listGone.journal != nil, "목록을 먼저 지우고 기록은 마지막에")
            } else {
                #expect(try Kit.restore(fixture).isRestored)
            }
            #expect(try RekordboxWriter.cleanupLists(in: fixture.backups).isEmpty && Kit.journal(fixture) == nil)
        }
    }

    @Test func 미정리_목록을_적지_못하면_기록을_남겨_중단으로_다룬다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript()
        script.fail(at: .before(.cleanupListWrite))
        let error = try #require(throws: DJCError.self) {
            try writeCue(fixture, try cueDraft(fixture), guard: script.writeGuard, record: record(fixture))
        }
        guard case .restoreFailed = error else { Issue.record("기록을 남긴 실패가 아님: \(error)"); return }
        #expect(try RekordboxWriter.cleanupLists(in: fixture.backups).isEmpty)
        #expect(Kit.interrupted(try Kit.judge(fixture)) != nil)
    }

    // MARK: 시각 훅

    @Test func 재확인과_단계_끝마다_시각을_넘긴다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, _) = try gridDraft(fixture)
        let script = WriteHookScript()
        _ = try writeGrid(fixture, grid, guard: script.writeGuard)
        let timings = script.timings
        for moment: RekordboxWriteMoment in [.recheck(.commit), .after(.commit), .after(.verify), .recheck(.fileReplace), .after(.fileReplace),
                                             .after(.journalWrite), .after(.journalRemove), .after(.reportSave)] {
            #expect(timings.contains(moment), "\(moment)")
        }
        #expect(timings.firstIndex(of: .recheck(.fileReplace))! < timings.firstIndex(of: .after(.fileReplace))!)
    }
}

/// 훅 안에서 본 값을 시험으로 넘긴다
final class JournalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RekordboxWriteJournal?
    var value: RekordboxWriteJournal? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    var journal: RekordboxWriteJournal? {
        get { value }
        set { value = newValue }
    }
}

extension RekordboxWriter.JournalRequestOutcome {
    var isNothing: Bool { if case .nothing = self { true } else { false } }
    var isChanged: Bool { if case .changed = self { true } else { false } }
    var isDone: Bool { if case .done = self { true } else { false } }
}

extension RekordboxWriter.JournalRequestOutcome where Value == RekordboxWriter.JournalRestoreResult {
    var isRestored: Bool { if case .done(.restored) = self { true } else { false } }
}
