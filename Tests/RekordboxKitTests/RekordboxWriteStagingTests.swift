import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Synchronization
import Testing

/// 커밋 뒤 단계 좁히기(R10): 초안 쓰기는 분석(그리드 포함)·그림·XML의 새 내용을 커밋 전에 준비 폴더 `.djc-staging/<대상 키>/`에 만들고,
/// 파일을 바꾸기 바로 직전마다 rekordbox 실행을 다시 본다. 켜짐은 훅으로 흉내 낸다. 합성 사본으로만 한다.
@Suite("rekordbox 쓰기 준비 폴더·직전 재확인")
struct RekordboxWriteStagingTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    typealias Kit = JournalTestKit

    func gridDraft(_ fixture: RekordboxFixture) throws -> (GridDraft, TrackSpec) {
        try RekordboxWriteJournalFlowTests().gridDraft(fixture)
    }

    func writeGrid(_ fixture: RekordboxFixture, _ grid: GridDraft, drafts: [CueDraft] = [],
                   guard writeGuard: RekordboxWriteGuard = JournalTestKit.copyGuard) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: drafts, grids: [grid], to: fixture.database, dryRun: false, now: now, backups: fixture.backups,
                                  shareRoot: fixture.shareRoot, guard: writeGuard)
    }

    func sidecars(_ fixture: RekordboxFixture) -> [URL] { ["-wal", "-shm"].map { URL(filePath: fixture.database.path + $0) } }

    @Test func 커밋_직후_켜짐을_보면_파일을_바꾸지_않고_wal·shm을_지우지_않으며_쓰기_기록을_그대로_둔다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, track) = try gridDraft(fixture)
        let dat = try Data(contentsOf: fixture.analysisURL(for: track))
        let script = WriteHookScript()
        let journalURL = try Kit.journalURL(fixture), seen = Mutex<Data?>(nil)
        let files = sidecars(fixture)
        // 커밋을 마치고 DB를 확인한 뒤 rekordbox가 켜져 -wal·-shm을 만들었다
        script.on(.after(.verify)) { seen.withLock { $0 = try? Data(contentsOf: journalURL) } }
        script.on(.recheck(.fileReplace)) { for file in files { FileManager.default.createFile(atPath: file.path, contents: Data()) } }
        script.startRunning(at: .recheck(.fileReplace))
        let error = try #require(throws: DJCError.self) { try writeGrid(fixture, grid, guard: script.writeGuard) }
        guard case let .restoreFailed(reason, _, _, _) = error else { Issue.record("멈춤 오류가 아님: \(error)"); return }
        #expect(reason.contains("rekordbox가 켜졌"))
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "-wal·-shm을 지우지 않는다")
        #expect(try Data(contentsOf: journalURL) == seen.withLock { $0 }, "쓰기 기록을 고치지 않는다")
        #expect(try Data(contentsOf: fixture.analysisURL(for: track)) == dat, "남은 파일 단계를 멈춘다")
        #expect(Kit.interrupted(try Kit.judge(fixture)) != nil)
    }

    @Test func 커밋_뒤_복구_직전에_켜짐을_보면_되돌리지_않고_쓰기_기록을_그대로_둔다() throws {
        let fixture = try RekordboxFixture()
        let draft = try RekordboxWriteJournalFlowTests().cueDraft(fixture)
        try RekordboxRestoreFailureTests().tamperOnCommit(fixture, "UPDATE contentCue SET rb_cue_count = rb_cue_count + 100")
        let script = WriteHookScript()
        let journalURL = try Kit.journalURL(fixture), seen = Mutex<Data?>(nil), written = Mutex<Data?>(nil)
        let files = sidecars(fixture), database = fixture.database
        script.on(.after(.commit)) {
            seen.withLock { $0 = try? Data(contentsOf: journalURL) }
            written.withLock { $0 = try? Data(contentsOf: database) }
        }
        script.on(.recheck(.recovery)) { for file in files { FileManager.default.createFile(atPath: file.path, contents: Data()) } }
        script.startRunning(at: .recheck(.recovery))
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.write(drafts: [draft], to: fixture.database, dryRun: false, now: now, backups: fixture.backups,
                                      guard: script.writeGuard)
        }
        guard case .restoreFailed = error else { Issue.record("멈춤 오류가 아님: \(error)"); return }
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: fixture.database) == written.withLock { $0 }, "DB를 되돌리지 않는다")
        #expect(try Data(contentsOf: journalURL) == seen.withLock { $0 })
    }

    @Test func 커밋_직전_켜짐을_보면_롤백하고_보류한다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, track) = try gridDraft(fixture)
        let before = try Kit.state(fixture), dat = try Data(contentsOf: fixture.analysisURL(for: track))
        let script = WriteHookScript()
        script.running(at: [.commit])
        let error = try #require(throws: DJCError.self) { try writeGrid(fixture, grid, guard: script.writeGuard) }
        guard case .rekordboxRunning = error else { Issue.record("보류가 아님: \(error)"); return }
        #expect(try Kit.state(fixture) == before && Data(contentsOf: fixture.analysisURL(for: track)) == dat)
        #expect(try Kit.journal(fixture) == nil && Kit.judge(fixture) == RekordboxJournalJudgment.none, "멈춤·중단이 아니다")
        #expect(Kit.leftovers(fixture.shareRoot, fixture.root).isEmpty)
    }

    @Test func 분석_루트에_준비_폴더를_둘_수_없으면_커밋_전에_거절한다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, track) = try gridDraft(fixture)
        let before = try Kit.state(fixture), dat = try Data(contentsOf: fixture.analysisURL(for: track))
        // 그 볼륨에 준비 폴더를 만들 수 없다(같은 이름의 파일이 막는다)
        try Data("x".utf8).write(to: fixture.shareRoot.appending(path: RekordboxStaging.folderName))
        let error = try #require(throws: DJCError.self) { try writeGrid(fixture, grid) }
        guard case let .writeRefused(reason) = error else { Issue.record("거절이 아님: \(error)"); return }
        #expect(reason.contains("준비 폴더"))
        #expect(try Kit.state(fixture) == before && Data(contentsOf: fixture.analysisURL(for: track)) == dat)
        #expect(try Kit.journal(fixture) == nil)
    }

    @Test func 새_내용은_루트의_준비_폴더에서_끼우고_곡_분석_폴더에_임시_파일을_두지_않으며_끝나면_준비_폴더를_지운다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, track) = try gridDraft(fixture)
        let key = try RekordboxWriteLocks.key(fixture.database)
        let staging = RekordboxStaging.folder(root: fixture.shareRoot, key: key)
        let trackFolder = fixture.analysisURL(for: track).deletingLastPathComponent()
        let script = WriteHookScript(), observed = Mutex<(staged: [String], trackFolder: [String])>(([], []))
        script.on(.before(.fileReplace)) {
            let staged = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
            let inTrack = (try? FileManager.default.contentsOfDirectory(atPath: trackFolder.path)) ?? []
            observed.withLock { if $0.staged.isEmpty { $0 = (staged, inTrack) } }
        }
        let report = try writeGrid(fixture, grid, guard: script.writeGuard)
        #expect(report.gridWritten.count == 1)
        let seen = observed.withLock { $0 }
        #expect(seen.staged.count == 2, "DAT·EXT의 새 내용을 커밋 전에 준비했다")
        #expect(Set(seen.trackFolder) == ["ANLZ0000.DAT", "ANLZ0000.EXT"], "곡 분석 폴더에는 임시 파일을 두지 않는다")
        #expect(!FileManager.default.fileExists(atPath: staging.deletingLastPathComponent().path))
        #expect(Kit.leftovers(fixture.shareRoot, fixture.root).isEmpty)
    }

    @Test func 같은_분석_루트를_쓰는_다른_대상의_준비_파일을_지우지_않고_남은_자기_준비_폴더는_지운다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, _) = try gridDraft(fixture)
        let other = RekordboxWriteLockKey(device: 1, inode: 42)
        let otherFile = RekordboxStaging.folder(root: fixture.shareRoot, key: other).appending(path: "0-ANLZ0000.DAT")
        try FileManager.default.createDirectory(at: otherFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("다른 대상".utf8).write(to: otherFile)
        let own = RekordboxStaging.folder(root: fixture.shareRoot, key: try RekordboxWriteLocks.key(fixture.database))
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("남은 것".utf8).write(to: own.appending(path: "old"))
        _ = try writeGrid(fixture, grid)
        #expect(try Data(contentsOf: otherFile) == Data("다른 대상".utf8))
        #expect(!FileManager.default.fileExists(atPath: own.path))
    }

    @Test func XML_새_내용도_DB_폴더의_준비_폴더에서_끼운다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        _ = try fixture.add(TrackSpec())
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        var original = MasterPlaylistsXML(text: MasterPlaylistsXMLTests.empty)
        try original.append(id: "201", parentID: "root", isFolder: false, timestamp: 1_000)
        try original.text.write(to: url, atomically: true, encoding: .utf8)
        let backup = try RekordboxWriter.makeBackup(of: fixture.database, in: fixture.backups, now: now, label: "write")
        var updated = original
        updated.touch(ids: ["201"], timestamp: 2_000)
        try RekordboxWriter.writePlaylistXML(updated, original: original, to: url, database: fixture.database, backup: backup, live: false)
        #expect(try MasterPlaylistsXML(contentsOf: url) == updated)
        #expect(Kit.leftovers(fixture.root).isEmpty)
    }
}

