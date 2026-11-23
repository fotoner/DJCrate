import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Synchronization
import Testing

/// 쓰기 잠금·기록·준비 폴더의 보강(#399 검토 1라운드): 사전 확인은 잠금 안에서, 다시 하는 시점 복원은 DB 옆 파일까지 보고, 복구는 파일마다
/// 다시 확인하고, 기록으로 복원은 기록 경로를 다시 검증하고, 솎기가 사슬을 끊은 옛 백업은 일반 복원을 거절하고, 복구 표시를 남기지 못하면
/// 복구를 시작하지 않는다. 합성 사본으로만 한다.
@Suite("rekordbox 쓰기 기록 보강")
struct RekordboxWriteJournalHardeningTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    typealias Kit = JournalTestKit
    var flow: RekordboxWriteJournalFlowTests { RekordboxWriteJournalFlowTests() }

    // MARK: 사전 확인은 잠금 안에서(A1)

    /// 라이브로 보는 사본 관문: 실행 상태를 시험이 바꾸고, 잠금 경합을 알린다
    final class LiveState: Sendable {
        let running = Mutex(false)
        let contended = Mutex(false)
        let finished = Mutex(false)
    }

    /// 그 픽스처를 라이브 폴더로 보는 관문(실제 라이브 판정·share 경계를 그대로 탄다)
    func liveGuard(_ state: LiveState, _ fixture: RekordboxFixture) -> RekordboxWriteGuard {
        var writeGuard = RekordboxWriteGuard(isRekordboxRunning: { state.running.withLock { $0 } }, appVersion: { "7.2.18" },
                                             liveDirectories: [fixture.root])
        writeGuard.locks = RekordboxWriteLocks(contended: { _ in state.contended.withLock { $0 = true } })
        return writeGuard
    }

    /// 다른 쪽이 잠금을 쥔 동안 쓰기를 띄우고, 쓰기가 잠금 경합에 닿으면 `whileWaiting`을 한 뒤 잠금을 푼다
    func writeWaitingForLock(_ fixture: RekordboxFixture, _ draft: CueDraft, state: LiveState,
                             whileWaiting: () throws -> Void) async throws -> Result<RekordboxWriter.Report, any Error> {
        let hold = try RekordboxWriteLocks.system.lock(try RekordboxWriteLocks.key(fixture.database))
        let database = fixture.database, backups = fixture.backups, now = now, writeGuard = liveGuard(state, fixture)
        async let result: Result<RekordboxWriter.Report, any Error> = withCheckedContinuation { continuation in
            Thread {
                let result = Result { try RekordboxWriter.write(drafts: [draft], to: database, dryRun: false, now: now, backups: backups, guard: writeGuard) }
                state.finished.withLock { $0 = true }
                continuation.resume(returning: result)
            }.start()
        }
        // 시간은 판정이 아니라 안전망이다(TEST-30): 경합 신호나 끝을 기다린다
        let deadline = ContinuousClock.now + .seconds(240)
        while !state.contended.withLock({ $0 }), !state.finished.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.contended.withLock { $0 }, "쓰기가 잠금을 기다렸다")
        try whileWaiting()
        hold.release()
        return await result
    }

    @Test func 잠금을_기다리는_동안_rekordbox가_켜지면_잠금을_잡은_뒤_확인이_거절하고_백업도_뜨지_않는다() async throws {
        let fixture = try RekordboxFixture()
        let draft = try flow.cueDraft(fixture)
        let state = LiveState()
        let result = try await writeWaitingForLock(fixture, draft, state: state) { state.running.withLock { $0 = true } }
        guard case let .failure(error as DJCError) = result, case let .writeRefused(reason) = error else {
            Issue.record("잠금 뒤 실행 확인의 거절이 아님: \(result)")
            return
        }
        #expect(reason.contains("켜져"))
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty, "막힐 조건은 백업을 뜨기 전에 본다")
    }

    @Test func 다른_프로세스가_체크포인트_전이라_wal이_남아도_잠금을_기다린_뒤_쓴다() async throws {
        let fixture = try RekordboxFixture()
        let draft = try flow.cueDraft(fixture)
        let wal = URL(filePath: fixture.database.path + "-wal")
        try Data(repeating: 1, count: 64).write(to: wal)
        let result = try await writeWaitingForLock(fixture, draft, state: LiveState()) { try FileManager.default.removeItem(at: wal) }
        #expect(try result.get().written.count == 1)
    }

    @Test func 쓰기_연결을_열기_직전에_켜짐을_보면_보류하고_바꾸지_않는다() throws {
        let fixture = try RekordboxFixture()
        let draft = try flow.cueDraft(fixture)
        let before = try Kit.state(fixture)
        let script = WriteHookScript()
        script.running(at: [.begin])
        let error = try #require(throws: DJCError.self) { try flow.writeCue(fixture, draft, guard: script.writeGuard) }
        guard case .rekordboxRunning = error else { Issue.record("보류가 아님: \(error)"); return }
        #expect(try Kit.state(fixture) == before && Kit.journal(fixture) == nil)
    }

    // MARK: 시점 복원 다시 하기(A2·O4·O9·G5)

    @Test func 시점_복원_다시_하기는_DB_옆_파일까지_같아야_이미_복원됨이다() throws {
        let tests = RekordboxPointRestoreTests()
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        _ = try tests.gridTrack(fixture, title: "곡 X")
        let xml = fixture.root.appending(path: "masterPlaylists6.xml")
        try Data("<xml 0/>".utf8).write(to: xml)
        let target = try tests.snapshot(fixture, "목표", at: now)
        try Data("<xml 2/>".utf8).write(to: xml)
        _ = try fixture.add(TrackSpec())
        let script = WriteHookScript()
        script.stop(at: .after(.databaseReplace))
        #expect(throws: RekordboxWriteStop.self) { try tests.restore(fixture, target, at: now.addingTimeInterval(20), guard: script.writeGuard) }
        #expect(try Data(contentsOf: xml) == Data("<xml 2/>".utf8), "DB만 바꾸고 멈췄다")
        #expect(try Kit.restore(fixture).isRestored, "DB 옆 파일이 시점과 다르면 다시 한다")
        #expect(try Data(contentsOf: xml) == Data("<xml 0/>".utf8))
    }

    @Test func 시점_복원은_폴더를_바꾸는_도중_켜져도_폴더_자리를_비우지_않는다() throws {
        let tests = RekordboxPointRestoreTests()
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try tests.gridTrack(fixture, title: "곡 X")
        let target = try tests.snapshot(fixture, "목표", at: now)
        _ = try tests.writeBPM(fixture, x, 131, at: now.addingTimeInterval(10))
        let script = WriteHookScript()
        script.startRunning(at: .after(.fileReplace))
        _ = try? tests.restore(fixture, target, at: now.addingTimeInterval(20), guard: script.writeGuard)
        #expect(FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/USBANLZ").path),
                "두 이름 바꾸기 사이에는 다시 확인하지 않는다")
    }

    @Test func 시점_복원_기록을_이대로_두면_빈_폴더_자리를_되돌리고_임시_폴더를_지운다() throws {
        let tests = RekordboxPointRestoreTests()
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try tests.gridTrack(fixture, title: "곡 X")
        let target = try tests.snapshot(fixture, "그림 전", at: now)
        let artwork = try tests.artwork(fixture, x)
        let artworkBytes = try Data(contentsOf: artwork)
        let script = WriteHookScript()
        // 분석 폴더를 바꿔 끼운 뒤, 시점에 없는 그림 폴더를 옆으로 옮긴 직후 멈춘다
        script.stop(at: .after(.fileReplace), occurrence: 2)
        #expect(throws: RekordboxWriteStop.self) { try tests.restore(fixture, target, at: now.addingTimeInterval(20), guard: script.writeGuard) }
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        let outcome = try RekordboxWriter.keepJournal(database: fixture.database, operationID: found.journal.operationID, databaseStamp: found.stamp,
                                                      backups: fixture.backups, guard: Kit.copyGuard) {}
        #expect(outcome.isDone)
        #expect(try Data(contentsOf: artwork) == artworkBytes, "빈 자리에 옮겨 둔 폴더를 되돌린다")
        let pioneer = try FileManager.default.contentsOfDirectory(atPath: fixture.shareRoot.appending(path: "PIONEER").path)
        #expect(!pioneer.contains { $0.hasPrefix(".djc-") }, "기록된 임시 폴더를 지운다: \(pioneer)")
        #expect(try Kit.journal(fixture) == nil)
    }

    @Test func 복원_직전_시점으로_다시_하면_기록의_목표를_고쳐_적는다() throws {
        let tests = RekordboxPointRestoreTests()
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try tests.gridTrack(fixture, title: "곡 X")
        let target = try tests.snapshot(fixture, "목표", at: now)
        _ = try tests.writeBPM(fixture, x, 131, at: now.addingTimeInterval(10))
        let first = WriteHookScript()
        first.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) { try tests.restore(fixture, target, at: now.addingTimeInterval(20), guard: first.writeGuard) }
        let before = try #require(try Kit.journal(fixture)?.pointRestore?.snapshotBeforeRestore)
        let again = WriteHookScript()
        again.stop(at: .after(.databaseReplace))
        #expect(throws: RekordboxWriteStop.self) {
            try RekordboxWriter.restore(pointSnapshot: URL(filePath: before), to: fixture.database, shareRoot: nil, snapshots: tests.snapshots(fixture),
                                        backups: fixture.backups, autoDays: 7, now: now.addingTimeInterval(30), guard: again.writeGuard)
        }
        #expect(try Kit.journal(fixture)?.basis.pointSnapshot == before)
    }

    @Test func 기록으로_복원한_시점_복원은_스냅샷_폴더의_기록_핀도_지운다() throws {
        let tests = RekordboxPointRestoreTests()
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try tests.gridTrack(fixture, title: "곡 X")
        let target = try tests.snapshot(fixture, "목표", at: now)
        _ = try tests.writeBPM(fixture, x, 131, at: now.addingTimeInterval(10))
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) { try tests.restore(fixture, target, at: now.addingTimeInterval(20), guard: script.writeGuard) }
        let operation = try #require(try Kit.journal(fixture)?.operationID)
        let pin = tests.snapshots(fixture).appending(path: RekordboxWriter.journalPinFolder).appending(path: operation + ".json")
        #expect(FileManager.default.fileExists(atPath: pin.path))
        #expect(try Kit.restore(fixture).isDone)
        #expect(!FileManager.default.fileExists(atPath: pin.path))
    }

    // MARK: 복구는 파일마다 다시 확인(A3·S7·G6·G8)

    @Test func 곡_빼기_자동_복구는_되살리는_파일마다_실행을_다시_본다() throws {
        let deletion = RekordboxDeletionFilesTests()
        let (fixture, _) = try deletion.setup()
        let folder = try #require(RekordboxShare.analysisURL(deletion.relative, root: fixture.shareRoot)).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["ANLZ0000.DAT", "ANLZ0000.EXT", "ANLZ0000.2EX", "ANLZ0000.3EX"]
        for name in names { try Data([1]).write(to: folder.appending(path: name)) }
        let script = WriteHookScript()
        script.fail(at: .after(.fileReplace), occurrence: 2)
        #expect(throws: DJCError.self) {
            try RekordboxTrackWriter.delete(contentIDs: ["100"], from: fixture.database, shareRoot: fixture.shareRoot, dryRun: false,
                                            backups: fixture.backups, guard: script.writeGuard)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == names.sorted())
        #expect(script.count(.recheck(.fileReplace)) >= 2 + names.count, "앞 단계 둘 + 되살린 파일마다")
    }

    @Test func 곡_넣기_자동_복구는_지우는_파일마다_실행을_다시_본다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        var existing = TrackSpec()   // 곡 넣기는 기존 곡에서 기기 정보를 읽는다
        existing.folderPath = "/tmp/djc-journal-existing.mp3"
        try fixture.add(existing)
        let plan = try await RekordboxTrackWriterTests().plan("mp3-tagged.mp3")
        let analysis = RekordboxTrackWriter.Analysis(segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], loudness: -8, peak: 0.9)
        let script = WriteHookScript()
        script.fail(at: .after(.fileReplace), occurrence: 2)
        #expect(throws: DJCError.self) {
            try RekordboxTrackWriter.add([plan], analyses: [plan.path: analysis], to: fixture.database, shareRoot: fixture.shareRoot,
                                         dryRun: false, now: now, backups: fixture.backups, guard: script.writeGuard)
        }
        #expect(script.count(.recheck(.fileReplace)) >= 2 + 2, "앞 단계 둘 + 지운 파일마다: \(script.moments)")
        let journal = try Kit.journal(fixture)
        #expect(Kit.leftovers(fixture.shareRoot).isEmpty && journal == nil)
    }

    @Test func 복구_중_표시를_남기지_못하면_복구를_시작하지_않고_기록을_남긴다() throws {
        let fixture = try RekordboxFixture()
        let draft = try flow.cueDraft(fixture)
        try RekordboxRestoreFailureTests().tamperOnCommit(fixture, "UPDATE contentCue SET rb_cue_count = rb_cue_count + 100")
        let script = WriteHookScript(), database = fixture.database, written = Mutex<Data?>(nil)
        script.on(.before(.verify)) { written.withLock { $0 = try? Data(contentsOf: database) } }
        // 기록 남기기(1)·커밋 뒤 크기·시각(2) 다음, 복구 중 표시(3)를 남기지 못한다
        script.fail(at: .before(.journalWrite), occurrence: 3)
        let error = try #require(throws: DJCError.self) { try flow.writeCue(fixture, draft, guard: script.writeGuard) }
        guard case .restoreFailed = error else { Issue.record("복구 실패가 아님: \(error)"); return }
        #expect(try Data(contentsOf: fixture.database) == written.withLock { $0 }, "복구를 시작하지 않았다")
        #expect(Kit.interrupted(try Kit.judge(fixture)) != nil)
    }

    @Test func 파일만_바꾸는_기록으로_복원이_도중에_켜짐을_보면_멈춤으로_알린다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        var grid = GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track)))
        grid.shift(by: 0.01)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace), occurrence: 2)
        #expect(throws: RekordboxWriteStop.self) { try flow.writeGrid(fixture, grid, guard: script.writeGuard) }
        let restoring = WriteHookScript()
        restoring.startRunning(at: .recheck(.fileReplace), occurrence: 2)
        let error = try #require(throws: DJCError.self) { try Kit.restore(fixture, shareRoot: fixture.shareRoot, guard: restoring.writeGuard) }
        guard case .restoreFailed = error else { Issue.record("파일을 바꾼 뒤 켜짐인데 멈춤이 아님: \(error)"); return }
        #expect(Kit.interrupted(try Kit.judge(fixture)) != nil)
    }

    @Test func 되돌리기도_링크가_생긴_그림_경로를_건드리지_않는다() throws {
        let artwork = RekordboxArtworkWriterTests()
        let (fixture, track) = try artwork.library(state: 256)
        _ = try artwork.putArtwork(fixture, track, status: 256)
        let edit = try artwork.edit(fixture, track, image: artwork.smallWide)
        let folder = artwork.folder(fixture, track)
        let outside = try TemporaryFolder()
        let moved = outside.url.appending(path: "real")
        let script = WriteHookScript(), rechecks = Mutex(0), seen = Mutex<Data?>(nil)
        script.fail(at: .after(.fileReplace))
        script.on(.recheck(.fileReplace)) {
            // 첫 파일을 바꾼 뒤 되돌리기 직전에 그림 폴더가 share 밖 링크로 바뀐다
            guard rechecks.withLock({ value in value += 1; return value }) == 2 else { return }
            try? FileManager.default.moveItem(at: folder, to: moved)
            try? FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
            seen.withLock { $0 = try? Data(contentsOf: moved.appending(path: "artwork.jpg")) }
        }
        #expect(throws: DJCError.self) {
            try RekordboxWriter.write(drafts: [], grids: [], gains: [:], tags: [], artworks: [edit], analysisInputs: [:], to: fixture.database,
                                      dryRun: false, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot,
                                      guard: script.writeGuard, attachesAnalysis: RekordboxWriter.attachesAnalysis)
        }
        #expect(try Data(contentsOf: moved.appending(path: "artwork.jpg")) == seen.withLock { $0 }, "링크 너머 파일을 되돌리며 쓰지 않는다")
        withExtendedLifetime(outside) {}
    }

    // MARK: 기록으로 복원(S1·S5·G4·G7·G9·O3)

    @Test func 기록으로_복원은_기록의_경로가_경계_밖이면_아무것도_바꾸지_않고_거절한다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, _) = try flow.gridDraft(fixture)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) { try flow.writeGrid(fixture, grid, guard: script.writeGuard) }
        let outside = try TemporaryFolder()
        let victim = outside.url.appending(path: "victim.txt")
        try Data("남의 파일".utf8).write(to: victim)
        var journal = try #require(try Kit.journal(fixture))
        journal.files.append(.init(path: victim.path, original: nil))
        try RekordboxWriter.saveJournal(journal, at: Kit.journalURL(fixture))
        let database = try Data(contentsOf: fixture.database)
        #expect(throws: DJCError.self) { try Kit.restore(fixture, shareRoot: fixture.shareRoot) }
        #expect(FileManager.default.fileExists(atPath: victim.path), "경계 밖 파일을 지우지 않는다")
        #expect(try Data(contentsOf: fixture.database) == database, "DB도 바꾸지 않는다")
        #expect(try Kit.journal(fixture) != nil)
    }

    @Test func 다른_백업_폴더에서_기록으로_복원해도_원래_미정리_목록을_지운다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript()
        script.stop(at: .after(.cleanupListWrite))
        #expect(throws: RekordboxWriteStop.self) {
            try flow.writeCue(fixture, try flow.cueDraft(fixture), guard: script.writeGuard, record: flow.record(fixture))
        }
        #expect(try RekordboxWriter.cleanupLists(in: fixture.backups).count == 1)
        let other = try TemporaryFolder()
        let found = try #require(Kit.interrupted(try Kit.judge(fixture, backups: other.url)))
        _ = try RekordboxWriter.restoreJournal(database: fixture.database, operationID: found.journal.operationID, databaseStamp: found.stamp,
                                               backups: other.url, shareRoot: nil, guard: Kit.copyGuard)
        #expect(try RekordboxWriter.cleanupLists(in: fixture.backups).isEmpty, "기록이 가리킨 원래 백업 폴더의 목록을 지운다")
    }

    @Test func 링크로_가리킨_DB로_기록으로_복원해도_원래_DB와_분석_파일_백업을_다룬다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, _) = try flow.gridDraft(fixture)
        let before = try Kit.state(fixture)
        let script = WriteHookScript()
        script.stop(at: .after(.fileReplace))
        #expect(throws: RekordboxWriteStop.self) { try flow.writeGrid(fixture, grid, guard: script.writeGuard) }
        let links = try TemporaryFolder()
        let link = links.url.appending(path: "master.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.database)
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        let outcome = try RekordboxWriter.restoreJournal(database: link, operationID: found.journal.operationID, databaseStamp: found.stamp,
                                                         backups: fixture.backups, shareRoot: nil, guard: Kit.copyGuard)
        guard case let .done(.restored(saved?)) = outcome else { Issue.record("복원하지 않음: \(outcome)"); return }
        #expect(FileManager.default.fileExists(atPath: saved.appending(path: "anlz/manifest.json").path), "되돌리기 직전 분석 파일도 백업")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "링크를 파일로 바꾸지 않는다")
        #expect(try Kit.state(fixture) == before)
        withExtendedLifetime(links) {}
    }

    @Test func 링크로_가리킨_같은_백업이면_기록으로_복원한다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript()
        script.stop(at: .after(.commit))
        #expect(throws: RekordboxWriteStop.self) { try flow.writeCue(fixture, try flow.cueDraft(fixture), guard: script.writeGuard) }
        let backup = URL(filePath: try #require(try Kit.journal(fixture)?.basis.writeBackup))
        let links = try TemporaryFolder()
        let linked = links.url.appending(path: "backups")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.backups)
        _ = try RekordboxWriter.restore(linked.appending(path: backup.lastPathComponent), to: fixture.database, now: now.addingTimeInterval(60),
                                        backups: linked, guard: Kit.copyGuard)
        #expect(try Kit.journal(fixture) == nil)
        withExtendedLifetime(links) {}
    }

    @Test func DB를_바꾸기_직전에_켜짐을_보면_준비_사본을_남기지_않는다() throws {
        let fixture = try RekordboxFixture()
        let report = try flow.writeCue(fixture, try flow.cueDraft(fixture))
        let script = WriteHookScript()
        script.startRunning(at: .after(.journalWrite))
        #expect(throws: DJCError.self) {
            try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, now: now.addingTimeInterval(60),
                                        backups: fixture.backups, guard: script.writeGuard)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.database.path + ".djc-restore"), "클라우드 토큰이 든 사본을 남기지 않는다")
    }

    @Test func 쓰기_전으로_복원의_되돌리기도_실패하면_안내는_기록이_받는_백업을_가리킨다() throws {
        let failures = RekordboxRestoreFailureTests()
        let fixture = try RekordboxFixture()
        defer { failures.unlock(fixture) }
        let report = try flow.writeCue(fixture, try flow.cueDraft(fixture))
        let backup = URL(filePath: try #require(report.backup))
        let script = WriteHookScript()
        // 바꾼 뒤 되돌리기(복원 직전 백업으로)도 막는다: 되돌리기가 쓰는 임시 자리를 지울 수 없는 폴더로 둔다
        let blocker = URL(filePath: fixture.database.path + ".djc-restore")
        script.on(.after(.databaseReplace)) {
            try? FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
            try? Data("x".utf8).write(to: blocker.appending(path: "keep"))
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocker.path)
        }
        script.fail(at: .after(.databaseReplace))
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.restore(backup, to: fixture.database, now: now.addingTimeInterval(60), backups: fixture.backups, guard: script.writeGuard)
        }
        guard case let .restoreFailed(_, _, guided, _) = error else { Issue.record("복원 실패가 아님: \(error)"); return }
        #expect(guided == backup.path, "안내대로 되돌리면 기록으로 복원이 된다")
        #expect(try Kit.journal(fixture)?.basis.writeBackup == guided)
    }

    // MARK: 솎기와 보호(S6·S8)

    @Test func 솎기가_뒤_백업을_지운_보호된_옛_백업은_일반_연쇄_복원을_거절한다() throws {
        let folder = try TemporaryFolder()
        let old = try RekordboxBackupRetentionTests().recentBackups(in: folder.url, count: 25, before: now.addingTimeInterval(-3 * 86_400))
        try RekordboxWriter.saveCleanupList(DraftCleanupList(operationID: "op", target: RekordboxWriteLockKey(device: 1, inode: 2),
                                                             draftHome: "/drafts", backupFolder: old[0]), in: folder.url)
        RekordboxWriter.prune(folder.url, now: now)
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: old[0]).path))
        #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: old[1]).path))
        let fixture = try RekordboxFixture()
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.restore(folder.url.appending(path: old[0]), to: fixture.database, backups: folder.url, guard: Kit.copyGuard)
        }
        #expect(error.description.contains("정리"), "\(error.description)")
    }

    @Test func 기록이_가리킬_백업이_사라졌으면_기록을_남기지_않고_복원하지_않는다() throws {
        let tests = RekordboxPointRestoreTests()
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try tests.gridTrack(fixture, title: "곡 X"), y = try tests.gridTrack(fixture, title: "곡 Y")
        let first = try tests.writeBPM(fixture, x, 131, at: now)
        let second = try tests.writeBPM(fixture, y, 140, at: now.addingTimeInterval(10))
        let after = try Kit.state(fixture)
        let script = WriteHookScript(), removed = Mutex(false)
        // 고른 백업을 확인한 뒤 다른 프로세스의 솎기가 뒤 백업을 지웠다(기록 핀을 두기 전)
        script.on(.before(.journalWrite)) {
            guard !removed.withLock({ value in defer { value = true }; return value }) else { return }
            try? FileManager.default.removeItem(at: second)
        }
        #expect(throws: DJCError.self) {
            try RekordboxWriter.restore(first, to: fixture.database, now: now.addingTimeInterval(20), backups: fixture.backups, guard: script.writeGuard)
        }
        #expect(try Kit.state(fixture) == after && Kit.journal(fixture) == nil)
    }

    // MARK: iTunes·카운터(S11·O5)

    @Test func iTunes_동기화의_보고서_저장만_실패하면_되돌리지_않고_경고한다() throws {
        let fixture = try RekordboxFixture(), target = fixture.root.appending(path: "playlists3.sync")
        try RekordboxITunesSyncTests.original.write(to: target)
        let script = WriteHookScript()
        script.fail(at: .before(.reportSave))
        let report = try RekordboxWriter.writeITunesSync(RekordboxITunesSyncTests().change(), to: fixture.database, dryRun: false, now: now,
                                                         backups: fixture.backups, guard: script.writeGuard)
        #expect(!(report.warnings ?? []).isEmpty)
        #expect(try Data(contentsOf: target) != RekordboxITunesSyncTests.original && Kit.journal(fixture) == nil)
    }

    @Test func 커밋과_크기·시각_사이에_멈춰도_그_차이는_이_쓰기의_것이라_경고하지_않는다() throws {
        let fixture = try RekordboxFixture()
        let script = WriteHookScript()
        // 기록 남기기(1) 다음, 커밋 뒤 크기·시각을 적기(2) 직전에 멈춘다
        script.stop(at: .before(.journalWrite), occurrence: 2)
        #expect(throws: RekordboxWriteStop.self) { try flow.writeCue(fixture, try flow.cueDraft(fixture), guard: script.writeGuard) }
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        #expect(found.journal.database != found.stamp, "커밋 뒤 크기·시각을 적기 전에 멈췄다")
        #expect(!found.changedSince, "그 차이는 이 쓰기의 커밋이다(최종 카운터가 같다)")
    }

    @Test func 옛_쓰기_기록에_최종_카운터_칸이_없어도_읽는다() throws {
        var journal = RekordboxWriteJournal(operationID: "op", kind: .counter, entry: .drafts, startCounter: 10, finalCounter: 12)
        var object = try #require(try JSONSerialization.jsonObject(with: RekordboxWriteJournal.encoder.encode(journal)) as? [String: Any])
        #expect(object["finalCounter"] as? Int == 12)
        object["finalCounter"] = nil
        journal.finalCounter = nil
        #expect(try RekordboxWriteJournal.decode(JSONSerialization.data(withJSONObject: object)) == journal)
    }
}
