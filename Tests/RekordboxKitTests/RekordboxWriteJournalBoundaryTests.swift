import DJCDomain
import DJCTestKit
import Darwin
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Synchronization
import Testing

/// 쓰기 잠금·기록의 경계와 재확인 보강(#399 검토 2라운드): 기록 경로는 절대 경로만 받고 링크를 풀기 전·뒤 모두 경계 안이어야 하며,
/// 기록을 남긴 뒤(저장소 잠금을 기다린 뒤) 커밋·파일 교체 직전에 다시 보고, 연쇄 복원은 처음 확인한 근거로 이어 가고,
/// 시점 복원의 폴더 자리는 기록의 역할로 정리한다. 합성 사본으로만 한다.
@Suite("rekordbox 쓰기 기록 경계·재확인")
struct RekordboxWriteJournalBoundaryTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    typealias Kit = JournalTestKit
    var flow: RekordboxWriteJournalFlowTests { RekordboxWriteJournalFlowTests() }
    var points: RekordboxPointRestoreTests { RekordboxPointRestoreTests() }

    /// 그리드 쓰기를 첫 파일 교체 뒤에 멈춰 기록을 남긴다
    func interruptedGridWrite(_ fixture: RekordboxFixture) throws {
        let (grid, _) = try flow.gridDraft(fixture)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) { try flow.writeGrid(fixture, grid, guard: script.writeGuard) }
    }

    /// 남은 기록을 고친다(기록 파일을 누가 고친 경우)
    func tamper(_ fixture: RekordboxFixture, _ change: (inout RekordboxWriteJournal) -> Void) throws {
        var journal = try #require(try Kit.journal(fixture))
        change(&journal)
        try RekordboxWriter.saveJournal(journal, at: Kit.journalURL(fixture))
    }

    /// 시점 복원 재료: 곡 X의 시점 스냅샷을 뜬 뒤 BPM을 바꾼다
    func pointFixture() throws -> (RekordboxFixture, RekordboxPointSnapshot.Entry) {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try points.gridTrack(fixture, title: "곡 X")
        let target = try points.snapshot(fixture, "목표", at: now)
        _ = try points.writeBPM(fixture, x, 131, at: now.addingTimeInterval(10))
        return (fixture, target)
    }

    func keep(_ fixture: RekordboxFixture) throws -> RekordboxWriter.JournalRequestOutcome<RekordboxWriter.KeepResult> {
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        return try RekordboxWriter.keepJournal(database: fixture.database, operationID: found.journal.operationID, databaseStamp: found.stamp,
                                               backups: fixture.backups, guard: Kit.copyGuard) {}
    }

    /// 다른 폴더에 master.db 파일 링크만 둔 대상(곁 파일은 실제 DB 옆에 있다)
    func fileLink(_ fixture: RekordboxFixture) throws -> (TemporaryFolder, URL) {
        let folder = try TemporaryFolder()
        let link = folder.url.appending(path: "master.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.database)
        return (folder, link)
    }

    /// 그 폴더의 저장소 잠금을 누가 쥐었는지(비차단으로 본다: 기본 잠금 폴더의 `<키>.store.lock`)
    static func storeLocked(_ folder: URL) -> Bool {
        var info = stat()
        guard stat(folder.path, &info) == 0 else { return false }
        let key = RekordboxWriteLockKey(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
        let fd = open(RekordboxWriteLocks.defaultFolder.appending(path: key.name + ".store.lock").path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }

    // MARK: 기록 경로 검증(S1)

    @Test func 기록의_상대_경로는_share_기준으로_맞아도_거절한다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        try interruptedGridWrite(fixture)
        let analysis = try #require(try Kit.journal(fixture)?.files.first?.path)
        let relative = try RekordboxWriter.backupTarget(analysis, shareRoot: fixture.shareRoot).relative
        try tamper(fixture) { $0.files.append(.init(path: relative, original: nil)) }
        let database = try Data(contentsOf: fixture.database)
        let error = try #require(throws: DJCError.self) { try Kit.restore(fixture, shareRoot: fixture.shareRoot) }
        #expect(error.description.contains("밖의 경로"), "\(error.description)")
        #expect(try Data(contentsOf: fixture.database) == database && Kit.journal(fixture) != nil)
    }

    @Test func 기록의_경로가_밖의_링크로_DB_곁_파일을_가리켜도_거절한다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let xml = fixture.root.appending(path: "masterPlaylists6.xml")
        try Data("<xml/>".utf8).write(to: xml)
        try interruptedGridWrite(fixture)
        let outside = try TemporaryFolder()
        let link = outside.url.appending(path: "masterPlaylists6.xml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: xml)
        try tamper(fixture) { $0.files.append(.init(path: link.path, original: nil)) }
        let database = try Data(contentsOf: fixture.database)
        #expect(throws: DJCError.self) { try Kit.restore(fixture, shareRoot: fixture.shareRoot) }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "밖의 링크를 지우지 않는다")
        #expect(try Data(contentsOf: xml) == Data("<xml/>".utf8))
        #expect(try Data(contentsOf: fixture.database) == database && Kit.journal(fixture) != nil)
        withExtendedLifetime(outside) {}
    }

    @Test func 백업_폴더를_상위_이동이_든_절대_경로로_줘도_그_기록으로_복원한다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, _) = try flow.gridDraft(fixture)
        let before = try Kit.state(fixture)
        let backups = URL(filePath: fixture.backups.path + "/../" + fixture.backups.lastPathComponent)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) {
            try RekordboxWriter.write(drafts: [], grids: [grid], to: fixture.database, dryRun: false, now: now, backups: backups,
                                      shareRoot: fixture.shareRoot, guard: script.writeGuard)
        }
        #expect(try Kit.journal(fixture)?.basis.writeBackup?.contains("/../") == true)
        #expect(try Kit.restore(fixture, shareRoot: fixture.shareRoot).isRestored)
        #expect(try Kit.state(fixture) == before)
    }

    @Test func 기록의_작업_ID가_파일_이름으로_안전하지_않으면_거절하고_밖의_파일을_지우지_않는다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        try interruptedGridWrite(fixture)
        // 미정리 목록·핀 자리(`<백업>/draft-cleanup/<작업 ID>.json`)가 백업 폴더 밖을 가리킨다
        let victim = fixture.backups.deletingLastPathComponent().appending(path: "victim.json")
        try Data("남의 파일".utf8).write(to: victim)
        try tamper(fixture) { $0.operationID = "../../victim" }
        #expect(throws: DJCError.self) { try Kit.restore(fixture, shareRoot: fixture.shareRoot) }
        #expect(FileManager.default.fileExists(atPath: victim.path))
        #expect(try Kit.journal(fixture) != nil)
    }

    // MARK: 기록을 남긴 뒤 다시 확인(S12)

    @Test func 기록을_남기는_동안_켜지면_커밋하지_않고_기록을_지운_뒤_보류한다() throws {
        let fixture = try RekordboxFixture()
        let draft = try flow.cueDraft(fixture)
        let before = try Kit.state(fixture)
        let script = WriteHookScript()
        // 기록 남기기는 저장소 잠금을 기다릴 수 있다: 그 사이 켜진다
        script.startRunning(at: .before(.journalWrite))
        let error = try #require(throws: DJCError.self) { try flow.writeCue(fixture, draft, guard: script.writeGuard) }
        guard case .rekordboxRunning = error else { Issue.record("보류가 아님: \(error)"); return }
        #expect(try Kit.state(fixture) == before && Kit.journal(fixture) == nil)
    }

    @Test func 곡_빼기도_기록을_남긴_뒤_커밋_직전에_다시_본다() throws {
        let (fixture, _) = try RekordboxDeletionFilesTests().setup()
        let before = try Kit.state(fixture)
        let script = WriteHookScript()
        script.startRunning(at: .before(.journalWrite))
        let error = try #require(throws: DJCError.self) {
            try RekordboxTrackWriter.delete(contentIDs: ["100"], from: fixture.database, shareRoot: fixture.shareRoot, dryRun: false,
                                            backups: fixture.backups, guard: script.writeGuard)
        }
        guard case .rekordboxRunning = error else { Issue.record("보류가 아님: \(error)"); return }
        #expect(try Kit.state(fixture) == before && Kit.journal(fixture) == nil)
    }

    @Test func iTunes_동기화도_기록을_남긴_뒤_파일을_바꾸기_직전에_다시_본다() throws {
        let fixture = try RekordboxFixture(), target = fixture.root.appending(path: "playlists3.sync")
        try RekordboxITunesSyncTests.original.write(to: target)
        let script = WriteHookScript()
        script.startRunning(at: .before(.journalWrite))
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.writeITunesSync(RekordboxITunesSyncTests().change(), to: fixture.database, dryRun: false, now: now,
                                                backups: fixture.backups, guard: script.writeGuard)
        }
        guard case .rekordboxRunning = error else { Issue.record("보류가 아님: \(error)"); return }
        #expect(try Data(contentsOf: target) == RekordboxITunesSyncTests.original && Kit.journal(fixture) == nil)
    }

    @Test func iTunes_동기화_되돌리기도_기록을_남긴_뒤_파일을_바꾸기_직전에_다시_본다() throws {
        let fixture = try RekordboxFixture(), target = fixture.root.appending(path: "playlists3.sync")
        try RekordboxITunesSyncTests.original.write(to: target)
        let report = try RekordboxWriter.writeITunesSync(RekordboxITunesSyncTests().change(), to: fixture.database, dryRun: false, now: now,
                                                         backups: fixture.backups, guard: Kit.copyGuard)
        let applied = try Data(contentsOf: target), backup = URL(filePath: try #require(report.backup))
        let script = WriteHookScript()
        script.startRunning(at: .before(.journalWrite))
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.restore(backup, to: fixture.database, now: now.addingTimeInterval(60), backups: fixture.backups, guard: script.writeGuard)
        }
        guard case .rekordboxRunning = error else { Issue.record("보류가 아님: \(error)"); return }
        #expect(try Data(contentsOf: target) == applied && Kit.journal(fixture) == nil)
    }

    // MARK: 연쇄 복원의 근거(S15)

    @Test func 밖의_백업으로_시작한_연쇄_복원이_멈춰도_기록으로_이어_복원한다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try points.gridTrack(fixture, title: "곡 X"), y = try points.gridTrack(fixture, title: "곡 Y")
        let before = points.shareFiles(fixture)
        let first = try points.writeBPM(fixture, x, 131, at: now)
        _ = try points.writeBPM(fixture, y, 140, at: now.addingTimeInterval(10))
        // 고른 백업만 백업 폴더 밖으로 옮긴다(이름의 시각은 그대로): 뒤 백업은 백업 폴더에 남아 함께 되돌린다
        let outside = try TemporaryFolder()
        let moved = outside.url.appending(path: first.lastPathComponent)
        try FileManager.default.moveItem(at: first, to: moved)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) {
            try RekordboxWriter.restore(moved, to: fixture.database, now: now.addingTimeInterval(20), backups: fixture.backups, guard: script.writeGuard)
        }
        #expect(try Kit.restore(fixture, shareRoot: fixture.shareRoot).isDone)
        #expect(try Kit.journal(fixture) == nil)
        #expect(points.shareFiles(fixture) == before, "두 백업의 분석 파일까지 되돌렸다")
        withExtendedLifetime(outside) {}
    }

    // MARK: 시점 복원의 폴더 자리(S16·S18·G11·G12)

    @Test func 시점_복원_기록을_이대로_두면_맞바꾼_옛_폴더도_빈_자리로_되돌린다() throws {
        let (fixture, target) = try pointFixture()
        let analysis = fixture.shareRoot.appending(path: "PIONEER/USBANLZ")
        let current = points.shareFiles(fixture)
        let script = WriteHookScript()
        // 분석 폴더를 한 번에 맞바꾼 직후 멈춘다(복원 전 내용은 준비 자리에 있다)
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) { try points.restore(fixture, target, at: now.addingTimeInterval(20), guard: script.writeGuard) }
        // 맞바꾼 폴더를 지우고 옮겨 되돌리던 복구가 지운 뒤 멈춘 모양
        try FileManager.default.removeItem(at: analysis)
        #expect(try keep(fixture).isDone)
        #expect(points.shareFiles(fixture) == current, "빈 자리에 복원 전 내용을 되돌리고 임시 폴더를 지운다")
        #expect(try Kit.journal(fixture) == nil)
    }

    @Test func 시점_복원의_자동_복구는_옛_폴더를_되돌리지_못해도_폴더_자리를_비우지_않는다() throws {
        let (fixture, target) = try pointFixture()
        let analysis = fixture.shareRoot.appending(path: "PIONEER/USBANLZ")
        let outside = try TemporaryFolder()
        let journalURL = try Kit.journalURL(fixture), parked = outside.url.appending(path: "parked")
        let script = WriteHookScript()
        // 폴더를 바꾼 뒤 검증이 실패하고, 복구를 시작하기 직전 복원 전 내용(맞바꾼 준비 자리)이 사라진다
        script.fail(at: .before(.verify))
        script.on(.before(.recovery)) {
            guard let journal = try? RekordboxWriter.readJournal(at: journalURL),
                  let old = journal.pointRestore?.temporaryFolders.first(where: { $0.contains("/.djc-restore-") && $0.hasSuffix("-USBANLZ") }) else { return }
            try? FileManager.default.moveItem(at: URL(filePath: old), to: parked)
        }
        #expect(throws: DJCError.self) { try points.restore(fixture, target, at: now.addingTimeInterval(20), guard: script.writeGuard) }
        #expect(FileManager.default.fileExists(atPath: analysis.path), "되돌릴 폴더가 없으면 지금 폴더를 먼저 지우지 않는다")
        #expect(Kit.interrupted(try Kit.judge(fixture)) != nil, "복구 실패로 기록이 남는다")
        withExtendedLifetime(outside) {}
    }

    @Test func 링크_별칭으로_시점_복원을_다시_해도_기록의_목표는_실제_스냅샷이다() throws {
        let (fixture, target) = try pointFixture()
        let first = WriteHookScript()
        first.stop(at: .after(.databaseReplace))
        #expect(throws: RekordboxWriteStop.self) { try points.restore(fixture, target, at: now.addingTimeInterval(20), guard: first.writeGuard) }
        let recorded = try #require(try Kit.journal(fixture)?.basis.pointSnapshot)
        let links = try TemporaryFolder()
        let alias = links.url.appending(path: "별칭")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target.url)
        let again = WriteHookScript()
        again.stop(at: .after(.databaseReplace))
        #expect(throws: RekordboxWriteStop.self) {
            try RekordboxWriter.restore(pointSnapshot: alias, to: fixture.database, shareRoot: nil, snapshots: points.snapshots(fixture),
                                        backups: fixture.backups, autoDays: 7, now: now.addingTimeInterval(30), guard: again.writeGuard)
        }
        #expect(try Kit.journal(fixture)?.basis.pointSnapshot == recorded, "별칭을 기록에 적지 않는다")
        withExtendedLifetime(links) {}
    }

    @Test func 시점_복원의_복구_중_표시를_남기지_못하면_복원_직전_시점을_안내한다() throws {
        let (fixture, target) = try pointFixture()
        let analysis = fixture.shareRoot.appending(path: "PIONEER/USBANLZ")
        let script = WriteHookScript()
        // 폴더를 바꾼 뒤 검증이 실패하게 하고(분석 폴더에 다른 파일), 복구 중 표시를 남기지 못한다
        script.on(.before(.verify)) { try? Data("x".utf8).write(to: analysis.appending(path: "extra.DAT")) }
        script.fail(at: .before(.recovery))
        let error = try #require(throws: DJCError.self) { try points.restore(fixture, target, at: now.addingTimeInterval(20), guard: script.writeGuard) }
        guard case let .pointRestoreFailed(_, _, snapshot, _) = error else { Issue.record("시점 복원 실패 안내가 아님: \(error)"); return }
        let before = try #require(try Kit.journal(fixture)?.pointRestore?.snapshotBeforeRestore)
        #expect(snapshot == URL(filePath: before).lastPathComponent)
    }

    @Test func 시점_복원_기록에_경계_밖_임시_폴더가_있어도_이대로_두기는_끝나고_밖은_건드리지_않는다() throws {
        let (fixture, target) = try pointFixture()
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) { try points.restore(fixture, target, at: now.addingTimeInterval(20), guard: script.writeGuard) }
        let outside = try TemporaryFolder()
        let foreign = outside.url.appending(path: ".djc-old-\(UUID().uuidString)-USBANLZ")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("남의 폴더".utf8).write(to: foreign.appending(path: "keep"))
        try tamper(fixture) { $0.pointRestore?.temporaryFolders.append(foreign.path) }
        let outcome = try keep(fixture)
        guard case let .done(kept) = outcome else { Issue.record("이대로 두기가 끝나지 않음: \(outcome)"); return }
        #expect(kept.leftAsIs == [foreign.path], "경계 밖 경로는 남긴 것으로 알린다")
        #expect(FileManager.default.fileExists(atPath: foreign.appending(path: "keep").path))
        #expect(try Kit.journal(fixture) == nil)
        let pioneer = try FileManager.default.contentsOfDirectory(atPath: fixture.shareRoot.appending(path: "PIONEER").path)
        #expect(!pioneer.contains { $0.hasPrefix(".djc-") }, "경계 안 임시 폴더는 지운다: \(pioneer)")
        withExtendedLifetime(outside) {}
    }

    // MARK: 솎기와 보호 넘기기(S6·S8·S17)

    @Test func 솎기가_사슬_끊김_표시를_남기지_못하면_뒤_백업을_지우지_않는다() throws {
        let folder = try TemporaryFolder()
        let old = try RekordboxBackupRetentionTests().recentBackups(in: folder.url, count: 25, before: now.addingTimeInterval(-3 * 86_400))
        try RekordboxWriter.saveCleanupList(DraftCleanupList(operationID: "op", target: RekordboxWriteLockKey(device: 1, inode: 2),
                                                             draftHome: "/drafts", backupFolder: old[0]), in: folder.url)
        let kept = folder.url.appending(path: old[0])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: kept.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kept.path) }
        RekordboxWriter.prune(folder.url, now: now)
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: old[1]).path), "표시를 남기지 못하면 그 뒤 백업을 지우지 않는다")
    }

    @Test func 미정리_목록을_적고_기록을_지우는_동안_저장소_잠금을_쥔다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript(), backups = fixture.backups, seen = Mutex<[Bool]>([])
        for moment: RekordboxWriteMoment in [.before(.cleanupListWrite), .before(.journalRemove)] {
            script.on(moment) { seen.withLock { $0.append(Self.storeLocked(backups)) } }
        }
        _ = try flow.writeCue(fixture, try flow.cueDraft(fixture), guard: script.writeGuard, record: flow.record(fixture))
        #expect(seen.withLock { $0 } == [true, true], "보호를 기록에서 목록으로 넘기는 사이 솎기가 끼지 못한다")
    }

    @Test func 백업_폴더와_시점_폴더가_같아도_기록을_남기고_지운다() async throws {
        let fixture = try RekordboxFixture()
        let database = fixture.database, folder = fixture.backups
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let finished = Mutex<Result<Void, any Error>?>(nil)
        Thread {
            let result = Result {
                let run = try WriteRun(database: database, guard: Kit.copyGuard, backups: folder, snapshots: folder)
                try run.begin(RekordboxWriteJournal(operationID: "same-store", kind: .files, entry: .pointRestore))
                try run.finish()
            }
            finished.withLock { $0 = result }
        }.start()
        // 시간은 판정이 아니라 안전망이다(TEST-30): 끝을 기다린다
        let deadline = ContinuousClock.now + .seconds(60)
        while finished.withLock({ $0 }) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let result = try #require(finished.withLock { $0 }, "같은 저장소 잠금을 두 번 잡아 기다리지 않는다")
        try result.get()
        #expect(try Kit.journal(fixture) == nil)
    }

    // MARK: 판정·하드 링크(S13·O10·S14·G14)

    @Test func 크기·시각을_적은_뒤_카운터_그대로_DB가_바뀌면_경고한다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript()
        script.stop(at: .before(.verify))
        #expect(throws: RekordboxWriteStop.self) { try flow.writeCue(fixture, try flow.cueDraft(fixture), guard: script.writeGuard) }
        #expect(Kit.interrupted(try Kit.judge(fixture))?.changedSince == false)
        // 같은 카운터의 다른 내용(사본으로 바꾸기 등)
        try fixture.execute("UPDATE djmdContent SET Commnt = '카운터 그대로 고침'")
        #expect(Kit.interrupted(try Kit.judge(fixture))?.changedSince == true)
    }

    @Test func 하드_링크인_master_db는_기록으로_복원도_이대로_두기도_거절한다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript()
        script.stop(at: .after(.commit))
        #expect(throws: RekordboxWriteStop.self) { try flow.writeCue(fixture, try flow.cueDraft(fixture), guard: script.writeGuard) }
        let other = try TemporaryFolder()
        try FileManager.default.linkItem(at: fixture.database, to: other.url.appending(path: "master.db"))
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        let restoreError = try #require(throws: DJCError.self) { try Kit.restore(fixture) }
        #expect(restoreError.description.contains("하드 링크"), "\(restoreError.description)")
        let applied = Mutex(false)
        let keepError = try #require(throws: DJCError.self) {
            try RekordboxWriter.keepJournal(database: fixture.database, operationID: found.journal.operationID, databaseStamp: found.stamp,
                                            backups: fixture.backups, guard: Kit.copyGuard) { applied.withLock { $0 = true } }
        }
        #expect(keepError.description.contains("하드 링크") && !applied.withLock { $0 })
        #expect(try Kit.journal(fixture) != nil)
        withExtendedLifetime(other) {}
    }

    @Test func 표시가_있는_기록은_판정에서_변경_카운터를_읽지_않는다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript()
        script.stop(at: .after(.commit))
        #expect(throws: RekordboxWriteStop.self) { try flow.writeCue(fixture, try flow.cueDraft(fixture), guard: script.writeGuard) }
        try tamper(fixture) { $0.marks.insert(.recovering) }
        let judging = WriteHookScript()
        _ = try RekordboxWriter.judgeJournal(database: fixture.database, backups: fixture.backups, locked: false, guard: judging.writeGuard)
        #expect(judging.count(.before(.counterRead)) == 0, "표시가 있으면 카운터와 상관없이 중단이다")
        // 표시가 없으면 읽는다(조용히 지울지 가린다)
        try tamper(fixture) { $0.marks = [] }
        _ = try RekordboxWriter.judgeJournal(database: fixture.database, backups: fixture.backups, locked: false, guard: judging.writeGuard)
        #expect(judging.count(.before(.counterRead)) == 1)
    }

    // MARK: 파일 링크 DB의 곁 파일(O12)

    @Test func 파일_링크_DB의_재생_목록_쓰기는_실제_DB_옆_XML을_고치고_기록으로_되돌린다() throws {
        let lists = RekordboxPlaylistWriterTests()
        let fixture = try lists.library([PlaylistSpec(id: "100", name: "DJC 실험", seq: 1, isFolder: true)])
        let original = try Data(contentsOf: lists.xmlURL(fixture))
        let (links, link) = try fileLink(fixture)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) {
            try RekordboxWriter.write(drafts: [], playlists: [.create(key: "n", name: "새 목록", isFolder: false, parent: .id("100"))], to: link,
                                      dryRun: false, now: now, backups: fixture.backups, guard: script.writeGuard)
        }
        #expect(try Data(contentsOf: lists.xmlURL(fixture)) != original, "실제 DB 옆 XML을 고쳤다")
        #expect(try Kit.restore(fixture).isRestored)
        #expect(try Data(contentsOf: lists.xmlURL(fixture)) == original)
        withExtendedLifetime(links) {}
    }

    @Test func 파일_링크_DB의_iTunes_동기화는_실제_DB_옆_동기화_파일을_바꾼다() throws {
        let fixture = try RekordboxFixture(), target = fixture.root.appending(path: "playlists3.sync")
        try RekordboxITunesSyncTests.original.write(to: target)
        let (links, link) = try fileLink(fixture)
        let report = try RekordboxWriter.writeITunesSync(RekordboxITunesSyncTests().change(), to: link, dryRun: false, now: now,
                                                         backups: fixture.backups, guard: Kit.copyGuard)
        #expect(report.iTunesSyncWritten == true)
        #expect(try Data(contentsOf: target) != RekordboxITunesSyncTests.original)
        #expect(!FileManager.default.fileExists(atPath: links.url.appending(path: "playlists3.sync").path))
        withExtendedLifetime(links) {}
    }
}
