@testable import DJCrate
import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

@Suite("되돌리기 백업 조회") @MainActor
struct BackupLookupTests {
    private func withBackup(_ body: (URL, RekordboxWriter.Backup) throws -> Void) throws {
        let root = URL(filePath: "/tmp/djc-backup-lookup-\(UUID().uuidString)")
        let folder = root.appending(path: "2026-09-27T120000-write")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 조회만 확인하므로 실제 DB나 보고서 내용은 필요 없다.
        try Data().write(to: folder.appending(path: "master.db"))
        let backups = RekordboxWriter.backups(in: root)
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        try body(folder, backup)
    }

    @Test func 열거한_백업의_정확한_경로를_찾는다() throws {
        try withBackup { _, backup in
            #expect(ReflectionCoordinator.backup(matching: backup.url, in: [backup])?.url == backup.url)
        }
    }

    @Test func tmp와_private_tmp가_같은_백업을_찾는다() throws {
        try withBackup { requested, backup in
            #expect(requested.path != backup.url.path)
            #expect(requested.resolvingSymlinksInPath().path == backup.url.resolvingSymlinksInPath().path)
            #expect(ReflectionCoordinator.backup(matching: requested, in: [backup])?.url == backup.url)
            var aliased = backup
            aliased.url = requested
            #expect(ReflectionCoordinator.backup(matching: backup.url, in: [aliased])?.url == requested)
        }
    }

    @Test func 디렉터리_끝_슬래시_표기가_달라도_찾는다() throws {
        try withBackup { _, backup in
            for isDirectory in [true, false] {
                let requested = URL(fileURLWithPath: backup.url.path, isDirectory: isDirectory)
                #expect(ReflectionCoordinator.backup(matching: requested, in: [backup])?.url == backup.url)
            }
        }
    }

    @Test func 없는_백업과_빈_목록은_선택하지_않는다() throws {
        try withBackup { requested, backup in
            #expect(ReflectionCoordinator.backup(matching: requested, in: []) == nil)
            #expect(ReflectionCoordinator.backup(matching: requested.appending(path: "missing"), in: [backup]) == nil)
            try FileManager.default.removeItem(at: backup.url)
            #expect(ReflectionCoordinator.backup(matching: backup.url, in: [backup]) == nil)
        }
    }

    @Test func 다른_경로의_같은_이름이나_최신_백업을_선택하지_않는다() throws {
        try withBackup { _, backup in
            try withBackup { other, otherBackup in
                #expect(other.lastPathComponent == backup.url.lastPathComponent)
                #expect(ReflectionCoordinator.backup(matching: other, in: [backup]) == nil)
                #expect(ReflectionCoordinator.backup(matching: backup.url, in: [otherBackup, backup])?.url == backup.url)
            }
        }
    }

    @Test func 같은_실제_경로의_후보가_여럿이면_선택하지_않는다() throws {
        try withBackup { requested, backup in
            var aliased = backup
            aliased.url = requested
            #expect(ReflectionCoordinator.backup(matching: backup.url, in: [backup, aliased]) == nil)
            #expect(ReflectionCoordinator.backup(matching: requested, in: [backup, aliased]) == nil)
        }
    }

    @Test func 디렉터리가_아닌_파일은_선택하지_않는다() throws {
        try withBackup { _, backup in
            var file = backup
            file.url = backup.url.appending(path: "master.db")
            #expect(ReflectionCoordinator.backup(matching: file.url, in: [file]) == nil)
        }
    }
}
