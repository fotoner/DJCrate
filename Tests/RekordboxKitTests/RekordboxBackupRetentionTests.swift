import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 쓰기 백업 보존(R13)과 보호(R11·R22): 이름의 시각으로 최근 24시간 것은 최소 20·최대 200개까지 남기고, 중단 기록과 미정리 목록이
/// 가리키는 백업·시점 스냅샷은 솎기와 삭제에서 뺀다. 시각은 주입한다(`now`). 기존 솎기 시험(`RekordboxBackupPruneTests`)은 그대로다.
@Suite("rekordbox 백업 보존·보호")
struct RekordboxBackupRetentionTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)

    /// `now` 앞 `minutes`분마다의 쓰기 백업(이름의 시각은 `makeBackup`과 같은 형식·시간대). 옛 것부터 돌려준다
    func recentBackups(in folder: URL, count: Int, minutes: Double = 1, before end: Date? = nil) throws -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let end = end ?? now
        return try (0..<count).reversed().map { index in
            let name = formatter.string(from: end.addingTimeInterval(-Double(index) * minutes * 60)) + "-write"
            let backup = folder.appending(path: name)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: backup.appending(path: "master.db"))
            return name
        }
    }

    func names(_ folder: URL) -> Set<String> { Set(RekordboxWriter.backups(in: folder).map(\.url.lastPathComponent)) }

    @Test func 최근_24시간_안의_백업은_30개를_넘어도_첫_저장_전_백업까지_남긴다() throws {
        let folder = try TemporaryFolder()
        let made = try recentBackups(in: folder.url, count: 31, minutes: 30)
        RekordboxWriter.prune(folder.url, now: now)
        #expect(names(folder.url) == Set(made))
    }

    @Test func 최근_24시간_안이라도_200개를_넘으면_가장_옛_것부터_솎는다() throws {
        let folder = try TemporaryFolder()
        let made = try recentBackups(in: folder.url, count: 201)
        RekordboxWriter.prune(folder.url, now: now)
        #expect(names(folder.url) == Set(made.dropFirst()))
    }

    @Test func 하루보다_옛_것은_최근_것과_합쳐_최소_20개까지만_남긴다() throws {
        let folder = try TemporaryFolder()
        let old = try recentBackups(in: folder.url, count: 15, before: now.addingTimeInterval(-3 * 86_400))
        let recent = try recentBackups(in: folder.url, count: 10)
        RekordboxWriter.prune(folder.url, now: now)
        #expect(names(folder.url) == Set(recent + old.suffix(10)))
    }

    @Test func 시각을_읽지_못하는_이름은_24시간_예외에_넣지_않는다() throws {
        let folder = try TemporaryFolder()
        for index in 0..<25 {
            let backup = folder.url.appending(path: "backup-\(index)-write")
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: backup.appending(path: "master.db"))
        }
        RekordboxWriter.prune(folder.url, now: now)
        #expect(RekordboxWriter.backups(in: folder.url).count == RekordboxWriter.backupsToKeep)
    }

    @Test func 미정리_목록이_남은_동안_그_목록의_백업_폴더는_솎지_않고_읽지_못하는_목록이_있으면_솎지_않는다() throws {
        let folder = try TemporaryFolder()
        let old = try recentBackups(in: folder.url, count: 30, before: now.addingTimeInterval(-3 * 86_400))
        try RekordboxWriter.saveCleanupList(DraftCleanupList(operationID: "op", target: RekordboxWriteLockKey(device: 1, inode: 2),
                                                             draftHome: "/drafts", backupFolder: old[0]), in: folder.url)
        RekordboxWriter.prune(folder.url, now: now)
        #expect(names(folder.url) == Set(old.suffix(20) + [old[0]]))
        // 읽지 못하는 목록: 무엇을 지킬지 모르니 솎지 않는다
        let more = try recentBackups(in: folder.url, count: 5, before: now.addingTimeInterval(-2 * 86_400))
        try Data("깨짐".utf8).write(to: DraftCleanupList.url(backups: folder.url, operationID: "broken"))
        RekordboxWriter.prune(folder.url, now: now)
        #expect(names(folder.url) == Set(old.suffix(20) + [old[0]] + more))
        #expect(throws: DJCError.self) { try RekordboxWriter.protectedBackupFolders(in: folder.url) }
    }

    @Test func 중단_기록이_남은_동안_같은_백업_폴더에_다른_대상으로_201번_써도_그_기록의_쓰기_전_백업이_남는다() throws {
        let shared = try TemporaryFolder()
        let a = try RekordboxFixture(), b = try RekordboxFixture()
        let track = try a.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 30))
        let script = WriteHookScript()
        script.stop(at: .after(.commit))
        #expect(throws: RekordboxWriteStop.self) {
            try RekordboxWriter.write(drafts: [draft], to: a.database, dryRun: false, now: now.addingTimeInterval(-2 * 86_400),
                                      backups: shared.url, guard: script.writeGuard)
        }
        let recorded = try #require(try JournalTestKit.journal(a)?.basis.writeBackup)
        #expect(try RekordboxWriter.protectedBackupFolders(in: shared.url) == [URL(filePath: recorded).lastPathComponent])
        _ = try recentBackups(in: shared.url, count: 200, before: now.addingTimeInterval(-60))
        // 다른 대상(b)이 같은 백업 폴더에 쓰며 솎는다(201번째 쓰기 백업)
        let other = try b.add(TrackSpec())
        var otherDraft = CueDraft(trackUUID: other.uuid)
        otherDraft.place(EditableCue(kind: .memory, time: 12))
        _ = try RekordboxWriter.write(drafts: [otherDraft], to: b.database, dryRun: false, now: now, backups: shared.url)
        #expect(FileManager.default.fileExists(atPath: URL(filePath: recorded).appending(path: "master.db").path))
        #expect(RekordboxWriter.backups(in: shared.url).filter(\.isWrite).count == 201, "200개 + 지킨 기록의 백업")
        // 기록이 사라지면(기록으로 복원) 다음 솎기에서 지운다
        #expect(try JournalTestKit.restore(a).isDone)
        RekordboxWriter.prune(shared.url, now: now)
        #expect(!FileManager.default.fileExists(atPath: recorded))
    }

    @Test func 중단_기록의_시점_스냅샷은_보존_정리와_삭제에서_빠진다() throws {
        let tests = RekordboxPointRestoreTests()
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let x = try tests.gridTrack(fixture, title: "곡 X")
        let target = try tests.snapshot(fixture, "목표", at: now)
        _ = try tests.writeBPM(fixture, x, 131, at: now.addingTimeInterval(10))
        let script = WriteHookScript()
        script.stop(at: .after(.databaseReplace))
        #expect(throws: RekordboxWriteStop.self) { try tests.restore(fixture, target, at: now.addingTimeInterval(20), guard: script.writeGuard) }
        let snapshots = tests.snapshots(fixture)
        let before = try #require(RekordboxPointSnapshot.list(in: snapshots).first { $0.metadata.kind == .beforeRestore })
        // 복원 직전 스냅샷을 더 떠서 보존 개수(3)를 넘긴다
        for offset in 1...4 {
            _ = try RekordboxPointSnapshot.take(name: "", kind: .beforeRestore, database: fixture.database, shareRoot: nil, in: snapshots,
                                                now: now.addingTimeInterval(100 + Double(offset)), guard: RekordboxPointRestoreTests.copyGuard)
        }
        _ = RekordboxPointSnapshot.prune(in: snapshots, autoDays: 7, now: now.addingTimeInterval(200))
        #expect(FileManager.default.fileExists(atPath: before.url.path), "기록의 복원 직전 스냅샷은 솎지 않는다")
        #expect(throws: DJCError.self) { try RekordboxPointSnapshot.delete(target.url, in: snapshots) }
        #expect(throws: DJCError.self) { try RekordboxPointSnapshot.delete(before.url, in: snapshots) }
    }
}
