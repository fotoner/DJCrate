import DJCDomain
import Foundation

extension RekordboxWriter {
    // 2026-09-27, rekordbox 7.2.14.0323의 선택 해제·재선택을 사본에 재현해 모든 칸·순서를 확인했다.
    static let writesITunesSync = true

    static func writeITunesSync(_ change: RekordboxITunesSyncChange, to database: URL, dryRun: Bool, now: Date,
                                backups: URL, guard writeGuard: RekordboxWriteGuard,
                                writeFile: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws -> Report {
        _ = try writeGuard.checkTargets(database, shareRoot: nil, dryRun: dryRun)
        if writeGuard.isLive(database), !writesITunesSync { throw RekordboxITunesSyncChange.invalidSource }
        let target = database.deletingLastPathComponent().appending(path: "playlists3.sync")
        try writeGuard.checkAdjacentFile(target, database: database)
        try validateBackupFile(target, under: database.deletingLastPathComponent(), required: true)
        guard try Data(contentsOf: target) == change.base else { throw iTunesSyncConflict }
        let counters: (local: Int?, cloud: Int?)
        do {
            let reader = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
            defer { reader.close() }
            try RekordboxCompatibility.checkSchema(reader)
            counters = try RekordboxCompatibility.updateCounters(reader)
            if let local = counters.local { try RekordboxCompatibility.checkCounters(local: local, cloud: counters.cloud) }
        }
        let rendered = try change.render()
        let changed = try RekordboxITunesSyncChange.state(of: rendered) != RekordboxITunesSyncChange.state(of: change.base)
        var report = Report(outcomes: [], backup: nil, dryRun: dryRun, createdAt: CueJSON.timestamps(now).json,
                            finalUpdateCount: counters.local)
        report.iTunesSyncWritten = changed
        guard changed, !dryRun else { return report }
        try checkIntegrity(of: database)
        let backup = try makeBackup(of: database, in: backups, now: now, label: "write")
        try saveITunesSyncBackup(before: change.base, after: rendered, in: backup)
        report.backup = backup.path
        // 백업 중 rekordbox를 켰거나 다른 창에서 바꿨으면 원본에 손대지 않는다.
        if writeGuard.isLive(database) { try writeGuard.checkLive(database, dryRun: false) }
        guard try Data(contentsOf: target) == change.base else { throw iTunesSyncConflict }
        do {
            try writeFile(rendered, target)
            guard try Data(contentsOf: target) == rendered else {
                throw DJCError.writeVerificationFailed(String(ui: "iTunes 동기화 파일을 다시 읽으니 저장한 내용과 다릅니다"))
            }
            _ = try RekordboxITunesSelection.parse(Data(contentsOf: target))
            try checkIntegrity(of: database)
            try save(report, in: backup)
        } catch {
            throw recoverITunesSync(from: error, original: change.base, target: target, database: database,
                                     backup: backup, guard: writeGuard)
        }
        prune(backups)
        return report
    }

    private static func saveITunesSyncBackup(before: Data, after: Data, in backup: URL) throws {
        for (name, data) in [("itunes-sync-before.xml", before), ("itunes-sync-after.xml", after)] {
            let url = backup.appending(path: name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// 동기화만 쓴 백업을 되돌릴 때는 DB를 교체하지 않는다. 이후 rekordbox에서 고친 선택도 덮지 않는다.
    static func restoreITunesSync(_ backup: URL, to database: URL, now: Date, backups: URL,
                                  guard writeGuard: RekordboxWriteGuard) throws -> URL? {
        let before = backup.appending(path: "itunes-sync-before.xml"), after = backup.appending(path: "itunes-sync-after.xml")
        guard FileManager.default.fileExists(atPath: before.path) || FileManager.default.fileExists(atPath: after.path) else { return nil }
        for url in [before, after] { try validateBackupFile(url, under: backup, required: true) }
        let original = try Data(contentsOf: before), written = try Data(contentsOf: after)
        _ = try RekordboxITunesSelection.parse(original)
        _ = try RekordboxITunesSelection.parse(written)
        let target = database.deletingLastPathComponent().appending(path: "playlists3.sync")
        try writeGuard.checkAdjacentFile(target, database: database)
        try validateBackupFile(target, under: database.deletingLastPathComponent(), required: true)
        guard try Data(contentsOf: target) == written else { throw iTunesSyncConflict }
        let saved = try makeBackup(of: database, in: backups, now: now, label: "before-restore")
        try saveITunesSyncBackup(before: written, after: original, in: saved)
        if writeGuard.isLive(database), writeGuard.isRekordboxRunning() { throw DJCError.rekordboxRunning }
        guard try Data(contentsOf: target) == written else { throw iTunesSyncConflict }
        do {
            try original.write(to: target, options: .atomic)
            guard try Data(contentsOf: target) == original else { throw iTunesSyncConflict }
        } catch {
            throw recoverITunesSync(from: error, original: written, target: target, database: database,
                                     backup: saved, guard: writeGuard)
        }
        prune(backups)
        return saved
    }

    /// 중간에 rekordbox를 켰다면 실패 복원도 쓰기이므로 멈추고, 종료 후 쓸 백업을 안내한다.
    private static func recoverITunesSync(from failure: any Error, original: Data, target: URL, database: URL,
                                          backup: URL, guard writeGuard: RekordboxWriteGuard) -> DJCError {
        do {
            if (try? Data(contentsOf: target)) != original {
                if writeGuard.isLive(database), writeGuard.isRekordboxRunning() { throw DJCError.rekordboxRunning }
                try original.write(to: target, options: .atomic)
            }
            guard try Data(contentsOf: target) == original else { throw iTunesSyncConflict }
            return .writeRolledBack(DJCError.reason(of: failure))
        } catch {
            return .restoreFailed(reason: DJCError.reason(of: failure), restoreError: DJCError.reason(of: error),
                                  backup: backup.path, database: writeGuard.isLive(database) ? nil : database.path)
        }
    }

    static var iTunesSyncConflict: DJCError {
        .writeRefused(String(ui: "rekordbox의 iTunes 동기화 선택이 바뀌었습니다. 새로고침한 뒤 다시 선택하세요."))
    }
}
