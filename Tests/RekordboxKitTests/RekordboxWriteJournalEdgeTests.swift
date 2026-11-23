import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Synchronization
import Testing

/// 쓰기 기록·준비 폴더의 가장자리(R10·R11): 바꾸기 전 켜짐은 기록을 남기지 않는다, 강제 종료 흉내는 아무것도 치우지 않는다,
/// 커밋이 -wal에만 남은 기록은 "이미 복원됨"이 아니다, 기록 입구도 쓰기 관문을 지난다, 링크 확인은 파일을 바꾸기 전에 한다,
/// 새로 만들 자리에 파일이 이미 있으면 커밋 전에 멈춘다, XML은 실제 쓰기 길에서 준비 폴더로 끼우고 어긋나면 원본으로 돌아온다.
@Suite("rekordbox 쓰기 기록 가장자리")
struct RekordboxWriteJournalEdgeTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    typealias Kit = JournalTestKit

    @Test func 쓰기_전으로_복원이_바꾸기_전에_켜짐을_보면_기록을_남기지_않고_보류한다() throws {
        let fixture = try RekordboxFixture()
        let flow = RekordboxWriteJournalFlowTests()
        let report = try flow.writeCue(fixture, try flow.cueDraft(fixture))
        let written = try Kit.state(fixture)
        let script = WriteHookScript()
        // 기록을 남긴 뒤(준비 사본을 만드는 사이) 켜진다: DB를 바꾸기 직전 재확인이 본다
        script.startRunning(at: .after(.journalWrite))
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, now: now.addingTimeInterval(60),
                                        backups: fixture.backups, guard: script.writeGuard)
        }
        guard case .rekordboxRunning = error else { Issue.record("보류가 아님: \(error)"); return }
        #expect(try Kit.state(fixture) == written && Kit.journal(fixture) == nil && Kit.judge(fixture) == RekordboxJournalJudgment.none)
    }

    @Test func 시점_복원이_바꾸기_전에_켜짐을_보면_기록·표시·클론·복원_직전_스냅샷을_남기지_않는다() throws {
        let tests = RekordboxPointRestoreTests()
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try tests.gridTrack(fixture, title: "곡 X")
        let target = try tests.snapshot(fixture, "목표", at: now)
        _ = try tests.writeBPM(fixture, x, 131, at: now.addingTimeInterval(10))
        let database = try Data(contentsOf: fixture.database), files = tests.shareFiles(fixture)
        let markers = RekordboxWriter.backups(in: fixture.backups).count
        let script = WriteHookScript()
        script.startRunning(at: .after(.journalWrite))
        let error = try #require(throws: DJCError.self) { try tests.restore(fixture, target, at: now.addingTimeInterval(20), guard: script.writeGuard) }
        guard case .rekordboxRunning = error else { Issue.record("보류가 아님: \(error)"); return }
        #expect(try Data(contentsOf: fixture.database) == database && tests.shareFiles(fixture) == files)
        #expect(try Kit.journal(fixture) == nil && Kit.leftovers(fixture.shareRoot, fixture.root).isEmpty)
        #expect(RekordboxPointSnapshot.list(in: tests.snapshots(fixture)).filter { $0.metadata.kind == .beforeRestore }.isEmpty)
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: fixture.backups.path)) ?? []
        #expect(!folders.contains { $0.contains("point-restore") } && RekordboxWriter.backups(in: fixture.backups).count == markers)
    }

    @Test func 시점_복원의_기록을_남긴_직후_멈추면_복원_직전_스냅샷을_지우지_않는다() throws {
        let tests = RekordboxPointRestoreTests()
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try tests.gridTrack(fixture, title: "곡 X")
        let target = try tests.snapshot(fixture, "목표", at: now)
        _ = try tests.writeBPM(fixture, x, 131, at: now.addingTimeInterval(10))
        let script = WriteHookScript()
        script.stop(at: .after(.journalWrite))
        #expect(throws: RekordboxWriteStop.self) { try tests.restore(fixture, target, at: now.addingTimeInterval(20), guard: script.writeGuard) }
        let journal = try #require(try Kit.journal(fixture))
        let before = try #require(journal.pointRestore?.snapshotBeforeRestore)
        #expect(FileManager.default.fileExists(atPath: before), "기록이 가리키는 복원 직전 스냅샷은 남는다")
        #expect(try Kit.restore(fixture).isDone)
        #expect(try Kit.journal(fixture) == nil)
    }

    @Test func 커밋이_wal에만_남은_쓰기는_DB가_백업과_같아도_이미_복원됨이_아니다() throws {
        let fixture = try RekordboxFixture()
        let flow = RekordboxWriteJournalFlowTests()
        let script = WriteHookScript()
        script.stop(at: .after(.commit))
        #expect(throws: RekordboxWriteStop.self) { try flow.writeCue(fixture, try flow.cueDraft(fixture), guard: script.writeGuard) }
        let backup = URL(filePath: try #require(try Kit.journal(fixture)?.basis.writeBackup))
        // 체크포인트 전에 멈춘 모양: master.db는 쓰기 전 그대로이고 커밋은 -wal에만 있다(내용은 흉내)
        try FileManager.default.removeItem(at: fixture.database)
        try FileManager.default.copyItem(at: backup.appending(path: "master.db"), to: fixture.database)
        let wal = URL(filePath: fixture.database.path + "-wal")
        try Data(repeating: 7, count: 4096).write(to: wal)
        // 흉내 낸 -wal은 SQLite가 읽지 않아 판정이 카운터로 가리지 못하니, 사용자가 확인한 요청으로 바로 복원한다
        let journal = try #require(try Kit.journal(fixture))
        let outcome = try RekordboxWriter.restoreJournal(database: fixture.database, operationID: journal.operationID,
                                                         databaseStamp: RekordboxWriter.fileStamp(try RekordboxWriteLocks.resolve(fixture.database)),
                                                         backups: fixture.backups, shareRoot: nil, guard: Kit.copyGuard)
        guard case .done(.restored) = outcome else { Issue.record("-wal이 남은 쓰기를 이미 복원됨으로 봤다: \(outcome)"); return }
        let walSize = (try? FileManager.default.attributesOfItem(atPath: wal.path))?[.size] as? Int ?? 0
        #expect(walSize == 0, "-wal의 커밋도 되돌렸다")
        #expect(try Kit.journal(fixture) == nil)
    }

    @Test func 기록으로_복원·이대로_두기·판정도_시험의_실제_라이브러리_거부를_받는다() throws {
        let fixture = try RekordboxFixture()
        let flow = RekordboxWriteJournalFlowTests()
        let script = WriteHookScript()
        script.stop(at: .after(.commit))
        #expect(throws: RekordboxWriteStop.self) { try flow.writeCue(fixture, try flow.cueDraft(fixture), guard: script.writeGuard) }
        let found = try #require(Kit.interrupted(try Kit.judge(fixture)))
        let protected = RekordboxWriteGuard(isLive: { _ in false }, isRekordboxRunning: { false }, appVersion: { "7.2.18" },
                                            protectedInTests: [fixture.root])
        func refused(_ body: () throws -> Void) {
            let error = #expect(throws: DJCError.self) { try body() }
            #expect(error?.description.contains("시험 중에는") == true)
        }
        refused { _ = try RekordboxWriter.judgeJournal(database: fixture.database, backups: fixture.backups, locked: false, guard: protected) }
        refused {
            _ = try RekordboxWriter.restoreJournal(database: fixture.database, operationID: found.journal.operationID, databaseStamp: found.stamp,
                                                   backups: fixture.backups, shareRoot: nil, guard: protected)
        }
        refused {
            _ = try RekordboxWriter.keepJournal(database: fixture.database, operationID: found.journal.operationID, databaseStamp: found.stamp,
                                                backups: fixture.backups, guard: protected) {}
        }
        #expect(try Kit.journal(fixture) != nil)
    }

    @Test func 그림_경로에_링크가_생기면_파일을_바꾸기_전에_멈추고_share_밖을_건드리지_않는다() throws {
        let artwork = RekordboxArtworkWriterTests()
        let (fixture, track) = try artwork.library(state: 256)
        _ = try artwork.putArtwork(fixture, track, status: 256)
        let edit = try artwork.edit(fixture, track, image: artwork.smallWide)
        let folder = artwork.folder(fixture, track)
        let outside = try TemporaryFolder()
        let moved = outside.url.appending(path: "real")
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            .map { try Data(contentsOf: folder.appending(path: $0)) }
        let script = WriteHookScript(), swapped = Mutex(false)
        script.on(.recheck(.fileReplace)) {
            guard swapped.withLock({ value in defer { value = true }; return !value }) else { return }
            try? FileManager.default.moveItem(at: folder, to: moved)
            try? FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
        }
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.write(drafts: [], grids: [], gains: [:], tags: [], artworks: [edit], analysisInputs: [:], to: fixture.database,
                                      dryRun: false, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot,
                                      guard: script.writeGuard, attachesAnalysis: RekordboxWriter.attachesAnalysis)
        }
        #expect(error.description.contains(RekordboxWriter.artworkLinkReason))
        let after = try FileManager.default.contentsOfDirectory(atPath: moved.path).sorted().map { try Data(contentsOf: moved.appending(path: $0)) }
        #expect(after == before, "링크 너머(share 밖) 파일을 바꾸거나 지우지 않는다")
        withExtendedLifetime(outside) {}
    }

    @Test func 새로_만들_그림_자리에_파일이_이미_있으면_커밋_전에_멈추고_그_파일을_지우지_않는다() throws {
        let artwork = RekordboxArtworkWriterTests()
        let (fixture, track) = try artwork.library()
        let edit = try artwork.edit(fixture, track, image: artwork.square)
        let folder = artwork.folder(fixture, track)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stray = Data("다른 프로그램의 파일".utf8)
        try stray.write(to: folder.appending(path: "artwork.jpg"))
        let content = try artwork.content(fixture, track)
        let report = try? RekordboxWriter.write(drafts: [], grids: [], gains: [:], tags: [], artworks: [edit], analysisInputs: [:], to: fixture.database,
                                                dryRun: false, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot,
                                                attachesAnalysis: RekordboxWriter.attachesAnalysis)
        #expect(report == nil || report?.artworkWritten.isEmpty == true)
        #expect(try artwork.content(fixture, track) == content, "DB를 커밋하지 않았다")
        #expect(try Data(contentsOf: folder.appending(path: "artwork.jpg")) == stray)
        #expect(try Kit.journal(fixture) == nil)
    }

    @Test(arguments: [false, true]) func 실제_쓰기_길의_XML은_준비_폴더에서_끼우고_다시_읽기가_어긋나면_원본으로_돌아온다(mismatch: Bool) throws {
        let playlists = RekordboxPlaylistWriterTests()
        let fixture = try playlists.library()
        let original = try playlists.xml(fixture)
        let before = try fixture.rows("SELECT * FROM djmdPlaylist ORDER BY 1")
        let staging = RekordboxStaging.folder(root: fixture.root, key: try RekordboxWriteLocks.key(fixture.database))
        let script = WriteHookScript(), staged = Mutex<[String]>([])
        script.on(.before(.fileReplace)) {
            staged.withLock { if $0.isEmpty { $0 = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] } }
        }
        let write = {
            try RekordboxWriter.write(drafts: [], grids: [], gains: [:], analysisInputs: [:],
                                      playlists: [.create(key: "n", name: "새 목록", isFolder: false, parent: .root)], to: fixture.database,
                                      dryRun: false, now: now, backups: fixture.backups, shareRoot: nil, guard: script.writeGuard,
                                      attachesAnalysis: false, readXML: { mismatch ? original : try MasterPlaylistsXML(contentsOf: $0) })
        }
        if mismatch {
            let error = try #require(throws: DJCError.self) { _ = try write() }
            guard case .writeRolledBack = error else { Issue.record("되돌림이 아님: \(error)"); return }
            #expect(try playlists.xml(fixture) == original, "XML은 원본으로")
            #expect(try fixture.rows("SELECT * FROM djmdPlaylist ORDER BY 1") == before)
        } else {
            let report = try write()
            let written = try playlists.xml(fixture)
            #expect(report.playlistWritten.count == 1 && written != original)
        }
        #expect(staged.withLock { $0 }.count == 1, "XML 새 내용은 DB 폴더의 준비 폴더에 만들었다")
        let journal = try Kit.journal(fixture)
        #expect(Kit.leftovers(fixture.root).isEmpty && journal == nil)
    }
}
