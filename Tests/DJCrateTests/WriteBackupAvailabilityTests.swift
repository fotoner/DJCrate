@testable import DJCrate
import Foundation
import Testing

@MainActor
@Suite("되돌리기 백업 상태")
struct WriteBackupAvailabilityTests {
    @Test func 시작할_때_쓰기_백업만_되돌리기를_켠다() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), backupDirectory: root)
        #expect(!store.hasWriteBackup)
        try backup("2026-01-01-before-restore", in: root)
        store.refreshWriteBackups()
        #expect(!store.hasWriteBackup)
        try backup("2026-01-02-write", in: root)
        let reopened = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), backupDirectory: root)
        #expect(reopened.hasWriteBackup)
        #expect(LibraryMenuAction.restore.isEnabled(in: reopened))
    }

    @Test func 쓰기와_되돌리기_종료마다_백업_상태를_다시_읽는다() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), backupDirectory: root)
        store.setWriteLock(true)
        try backup("2026-01-02-write", in: root)
        #expect(!store.hasWriteBackup)
        #expect(!LibraryMenuAction.restore.isEnabled(in: store))
        store.setWriteLock(false)
        #expect(store.hasWriteBackup)
        #expect(LibraryMenuAction.restore.isEnabled(in: store))
        store.setWriteLock(true)
        try FileManager.default.removeItem(at: root.appending(path: "2026-01-02-write"))
        try backup("2026-01-03-before-restore", in: root)
        store.setWriteLock(false)
        #expect(!store.hasWriteBackup)
        #expect(!LibraryMenuAction.restore.isEnabled(in: store))
    }

    private func backup(_ name: String, in root: URL) throws {
        let directory = root.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 존재 여부만 읽으므로 실제 DB나 라이브러리 정보가 필요 없다.
        try Data().write(to: directory.appending(path: "master.db"))
    }
}
