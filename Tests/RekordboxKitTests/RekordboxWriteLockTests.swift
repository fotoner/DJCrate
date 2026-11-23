import DJCDomain
import DJCEnvironment
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Synchronization
import Testing

/// 프로세스 사이 쓰기 잠금(R9): 키는 링크를 푼 master.db 부모 폴더의 (장치, inode)라 별칭에 흔들리지 않고 복원으로 파일이 바뀌어도 같다.
/// 잠금은 다시 들어갈 수 없고, 쥔 동안 다른 입구는 기다린다. 시험의 잠금 파일은 샌드박스 안에만 생긴다.
@Suite("rekordbox 쓰기 잠금")
struct RekordboxWriteLockTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)

    @Test func 파일·폴더_링크와_대소문자·시스템_볼륨_별칭이_같은_키다() throws {
        let fixture = try RekordboxFixture()
        let key = try RekordboxWriteLocks.key(fixture.database)
        let links = try TemporaryFolder()
        let fileLink = links.url.appending(path: "master.db")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: fixture.database)
        let folderLink = links.url.appending(path: "library")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: fixture.root)
        var aliases = [fileLink, folderLink.appending(path: "master.db")]
        // 대소문자를 가리지 않는 볼륨이면 다른 대소문자도 같은 폴더다
        let upper = fixture.root.deletingLastPathComponent().appending(path: fixture.root.lastPathComponent.uppercased()).appending(path: "master.db")
        if FileManager.default.fileExists(atPath: upper.path) { aliases.append(upper) }
        // 시스템 볼륨 별칭(/System/Volumes/Data)으로 같은 폴더를 가리킨다
        let data = URL(filePath: "/System/Volumes/Data" + fixture.database.resolvingSymlinksInPath().path)
        if FileManager.default.fileExists(atPath: data.path) { aliases.append(data) }
        for alias in aliases {
            #expect(try RekordboxWriteLocks.key(alias) == key, "\(alias.path)")
        }
        #expect(try RekordboxWriteLocks.resolve(fileLink) == RekordboxWriteLocks.resolve(fixture.database))
        let other = try RekordboxFixture()
        #expect(try RekordboxWriteLocks.key(other.database) != key)
        withExtendedLifetime((links, other)) {}
    }

    @Test func 복원으로_master_db가_바뀌어도_같은_키다() throws {
        let fixture = try RekordboxFixture()
        let key = try RekordboxWriteLocks.key(fixture.database)
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 30))
        let report = try RekordboxWriter.write(drafts: [draft], to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
        let inode = try FileManager.default.attributesOfItem(atPath: fixture.database.path)[.systemFileNumber] as? UInt64
        _ = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, now: now.addingTimeInterval(60),
                                        backups: fixture.backups)
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.database.path)[.systemFileNumber] as? UInt64 != inode)
        #expect(try RekordboxWriteLocks.key(fixture.database) == key)
    }

    @Test func 시험의_잠금_파일은_샌드박스_안에만_생기고_DJC_HOME과_상관없다() throws {
        let folder = RekordboxWriteLocks.defaultFolder
        #expect(folder.path.hasPrefix(TestProcess.sandbox.path) && folder.lastPathComponent == RekordboxWriteLockKey.folderName)
        if let home = ProcessInfo.processInfo.environment["DJC_HOME"] { #expect(!folder.path.hasPrefix(home)) }
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 30))
        _ = try RekordboxWriter.write(drafts: [draft], to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
        let lock = folder.appending(path: try RekordboxWriteLocks.key(fixture.database).lockFileName)
        #expect(FileManager.default.fileExists(atPath: lock.path), "풀 때 잠금 파일을 지우지 않는다")
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(mode == Int(RekordboxWriteLockKey.folderMode))
    }

    @Test func 잠금은_다시_들어갈_수_없고_풀면_다시_잡힌다() throws {
        let folder = try TemporaryFolder()
        let locks = RekordboxWriteLocks(folder: folder.url.appending(path: "djc-locks"))
        let key = RekordboxWriteLockKey(device: 7, inode: 9)
        let hold = try locks.lock(key)
        #expect(try locks.tryLock(key) == nil)
        let other = try #require(try locks.tryLock(RekordboxWriteLockKey(device: 7, inode: 10)))
        hold.release()
        hold.release()
        let again = try #require(try locks.tryLock(key))
        again.release()
        other.release()
        withExtendedLifetime(folder) {}
    }

    @Test func 링크_폴더는_잠금_폴더로_쓰지_않는다() throws {
        let folder = try TemporaryFolder()
        let real = folder.url.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = folder.url.appending(path: "djc-locks")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: DJCError.self) { try RekordboxWriteLocks(folder: link).lock(RekordboxWriteLockKey(device: 1, inode: 1)) }
        withExtendedLifetime(folder) {}
    }

    @Test func 하드_링크_master_db에는_쓰지_않는다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        let alias = try TemporaryFolder()
        try FileManager.default.linkItem(at: fixture.database, to: alias.url.appending(path: "master.db"))
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 30))
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.write(drafts: [draft], to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
        }
        #expect(error.description.contains("하드 링크"))
        withExtendedLifetime(alias) {}
    }

    @Test func 다른_쪽이_잠금을_쥐면_쓰기는_풀릴_때까지_기다린다() async throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 30))
        let contended = Mutex(false)
        var writeGuard = JournalTestKit.copyGuard
        writeGuard.locks = RekordboxWriteLocks(contended: { _ in contended.withLock { $0 = true } })
        let hold = try RekordboxWriteLocks.system.lock(try RekordboxWriteLocks.key(fixture.database))
        let database = fixture.database, backups = fixture.backups, now = now, guardCopy = writeGuard, cue = draft
        let finished = Mutex(false)
        // 쓰기는 오래 막는 입출력이라 따로 띄운 스레드에서 부른다(GCD 풀이 다른 시험으로 꽉 차도 굶지 않게)
        async let write: Result<RekordboxWriter.Report, any Error> = withCheckedContinuation { continuation in
            Thread {
                let result = Result {
                    try RekordboxWriter.write(drafts: [cue], to: database, dryRun: false, now: now, backups: backups, guard: guardCopy)
                }
                finished.withLock { $0 = true }
                continuation.resume(returning: result)
            }.start()
        }
        // 시간은 판정이 아니라 안전망이다(TEST-30): 경합 신호를 기다린다
        let deadline = ContinuousClock.now + .seconds(240)
        while !contended.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(contended.withLock { $0 }, "쓰기가 잠금 경합에 닿았다")
        #expect(!finished.withLock { $0 }, "쥔 동안에는 쓰지 않는다")
        hold.release()
        let report = try await write.get()
        #expect(report.written.count == 1)
    }
}
