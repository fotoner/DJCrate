import DJCDomain
import Foundation

extension RekordboxWriter {
    // 2026-09-27, rekordbox 7.2.14.0323의 선택 해제·재선택을 사본에 재현해 모든 칸·순서를 확인했다.
    static let writesITunesSync = true

    static func writeITunesSync(_ change: RekordboxITunesSyncChange, to database: URL, dryRun: Bool, now: Date,
                                backups: URL, guard writeGuard: RekordboxWriteGuard,
                                writeFile: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws -> Report {
        _ = try writeGuard.checkTargetsBeforeLock(database, shareRoot: nil, dryRun: dryRun)
        if writeGuard.isLive(database), !writesITunesSync { throw RekordboxITunesSyncChange.invalidSource }
        // 쓰기 잠금(R9)을 잡은 뒤 라이브 확인·중단 기록 거절(R11)을 한다. 시험 실행은 잠그지 않는다
        let locked = dryRun ? nil : try WriteRun.locked(database, guard: writeGuard, backups: backups, refusesHardLinks: false)
        defer { locked?.close() }
        try locked?.prepareWrite()
        // 곁 파일은 링크를 푼 DB 옆 것이다(파일 링크 DB도 실제 DB의 동기화 파일을 고친다. 기록 경로 검증과 같은 기준, O12)
        let resolved = try locked?.resolved ?? RekordboxWriteLocks.resolve(database)
        let target = resolved.deletingLastPathComponent().appending(path: "playlists3.sync")
        try writeGuard.checkAdjacentFile(target, database: database)
        try validateBackupFile(target, under: resolved.deletingLastPathComponent(), required: true)
        guard try Data(contentsOf: target) == change.base else { throw iTunesSyncConflict }
        let counters: (local: Int?, cloud: Int?)
        do {
            let snapshot = try WriteReadSnapshot(database)
            defer { snapshot.close() }
            let reader = snapshot.db
            try RekordboxCompatibility.checkSchema(reader)
            counters = try RekordboxCompatibility.updateCounters(reader)
            if let local = counters.local { try RekordboxCompatibility.checkCounters(local: local, cloud: counters.cloud) }
        }
        let rendered = try change.render()
        let changed = try RekordboxITunesSyncChange.state(of: rendered) != RekordboxITunesSyncChange.state(of: change.base)
        var report = Report(outcomes: [], backup: nil, dryRun: dryRun, createdAt: CueJSON.timestamps(now).json,
                            finalUpdateCount: counters.local)
        report.iTunesSyncWritten = changed
        guard changed, let run = locked else { return report }
        try checkIntegrity(of: database)
        let backup = try makeBackup(of: resolved, in: backups, now: now, label: "write")
        try saveITunesSyncBackup(before: change.base, after: rendered, in: backup)
        report.backup = backup.path
        // 백업 중 rekordbox를 켰거나 다른 창에서 바꿨으면 원본에 손대지 않는다.
        if writeGuard.isLive(database) { try writeGuard.checkLive(database, dryRun: false) }
        guard try Data(contentsOf: target) == change.base else { throw iTunesSyncConflict }
        // 첫 파일 변경 직전에 실행을 다시 보고 파일 쓰기 기록을 남긴다(R10·R11). 기록으로 복원은 `playlists3.sync`만 되돌린다
        do {
            try run.recheck(.fileReplace)
            let before = backup.appending(path: "itunes-sync-before.xml")
            try run.begin(RekordboxWriteJournal(operationID: UUID().uuidString, kind: .files, entry: .iTunesSync,
                                                basis: .init(writeBackup: backup.path, iTunesSyncBefore: before.path),
                                                files: [.init(path: target.path, original: before.path)]))
            // 기록 남기기는 저장소 잠금을 기다릴 수 있다: 파일을 바꾸기 직전에 다시 본다(켜졌으면 기록을 지운 뒤 보류, S12)
            try run.recheck(.fileReplace)
        } catch {
            throw run.abandon(error)
        }
        do {
            try run.before(.fileReplace)
            // 쓰기가 도중에 실패해도 파일이 바뀌었을 수 있다(되돌리기와 켜짐 처리는 바꾼 뒤로 본다)
            run.changed = true
            try writeFile(rendered, target)
            guard try Data(contentsOf: target) == rendered else {
                throw DJCError.writeVerificationFailed(String(ui: "iTunes 동기화 파일을 다시 읽으니 저장한 내용과 다릅니다"))
            }
            _ = try RekordboxITunesSelection.parse(Data(contentsOf: target))
            try run.after(.fileReplace)
            try checkIntegrity(of: database)
        } catch {
            if let passed = run.passThrough(error) { throw passed }
            throw recoverITunesSync(from: error, original: change.base, target: target, database: database,
                                     backup: backup, guard: writeGuard, run: run)
        }
        // 보고서 저장은 기록을 지우기 전에 하되, 실패해도 적용한 선택을 되돌리지 않고 경고한다(R11)
        if let warning = try saveReport(report, in: backup, shareRoot: nil, run: run) { report.warnings = [warning] }
        try finishRun(run, backup: backup, backups: backups, list: nil, now: now)
        return report
    }

    static func saveITunesSyncBackup(before: Data, after: Data, in backup: URL) throws {
        for (name, data) in [("itunes-sync-before.xml", before), ("itunes-sync-after.xml", after)] {
            let url = backup.appending(path: name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// 동기화만 쓴 백업을 되돌릴 때는 DB를 교체하지 않는다. 이후 rekordbox에서 고친 선택도 덮지 않는다.
    static func restoreITunesSync(_ backup: URL, to database: URL, now: Date, backups: URL,
                                  guard writeGuard: RekordboxWriteGuard, run: WriteRun) throws -> URL? {
        let before = backup.appending(path: "itunes-sync-before.xml"), after = backup.appending(path: "itunes-sync-after.xml")
        guard FileManager.default.fileExists(atPath: before.path) || FileManager.default.fileExists(atPath: after.path) else { return nil }
        for url in [before, after] { try validateBackupFile(url, under: backup, required: true) }
        let original = try Data(contentsOf: before), written = try Data(contentsOf: after)
        _ = try RekordboxITunesSelection.parse(original)
        _ = try RekordboxITunesSelection.parse(written)
        let target = run.resolved.deletingLastPathComponent().appending(path: "playlists3.sync")
        try writeGuard.checkAdjacentFile(target, database: database)
        try validateBackupFile(target, under: run.resolved.deletingLastPathComponent(), required: true)
        guard try Data(contentsOf: target) == written else { throw iTunesSyncConflict }
        let saved = try makeBackup(of: run.resolved, in: backups, now: now, label: "before-restore")
        try saveITunesSyncBackup(before: written, after: original, in: saved)
        if writeGuard.isLive(database), writeGuard.isRekordboxRunning() { throw DJCError.rekordboxRunning }
        guard try Data(contentsOf: target) == written else { throw iTunesSyncConflict }
        // 첫 파일 변경 직전에 실행을 다시 보고 파일 쓰기 기록을 남긴다(R10·R11). 기록으로 복원은 같은 되돌리기를 다시 한다
        do {
            try run.recheck(.fileReplace)
            try run.begin(RekordboxWriteJournal(operationID: UUID().uuidString, kind: .files, entry: .restore,
                                                basis: .init(writeBackup: backup.path, iTunesSyncBefore: before.path),
                                                files: [.init(path: target.path, original: before.path)]))
            try run.recheck(.fileReplace)
        } catch {
            throw run.abandon(error)
        }
        do {
            try run.before(.fileReplace)
            run.changed = true
            try original.write(to: target, options: .atomic)
            guard try Data(contentsOf: target) == original else { throw iTunesSyncConflict }
            try run.after(.fileReplace)
        } catch {
            if let passed = run.passThrough(error) { throw passed }
            throw recoverITunesSync(from: error, original: written, target: target, database: database,
                                     backup: saved, guard: writeGuard, run: run)
        }
        try finishRun(run, backup: saved, backups: backups, list: nil, now: now)
        return saved
    }

    /// 중간에 rekordbox를 켰다면 실패 복원도 쓰기이므로 멈추고, 종료 후 쓸 백업을 안내한다.
    /// 쓰기 기록이 있으면 첫 변경 전에 "복구 중"을 적고, 되돌리면 기록을 지우고, 못 되돌리면 "복구 실패"로 남긴다(R7·R11).
    /// 켜짐을 보면 되돌리지 않고 기록을 그대로 둔 채 멈춘다(R10).
    private static func recoverITunesSync(from failure: any Error, original: Data, target: URL, database: URL,
                                          backup: URL, guard writeGuard: RekordboxWriteGuard, run: WriteRun) -> any Error {
        do {
            if (try? Data(contentsOf: target)) != original {
                if let refused = run.markRecovering(failure) { return refused }
                try run.recheck(.fileReplace)
                try original.write(to: target, options: .atomic)
            }
            guard try Data(contentsOf: target) == original else { throw iTunesSyncConflict }
            try run.finish()
            return DJCError.writeRolledBack(DJCError.reason(of: failure))
        } catch {
            if let passed = run.passThrough(error) { return passed }
            try? run.update { $0.marks.insert(.recoveryFailed) }
            // 기록이 남으니 안내는 기록이 받는 백업을 가리킨다
            return DJCError.restoreFailed(reason: DJCError.reason(of: failure), restoreError: DJCError.reason(of: error),
                                          backup: run.journal?.basis.writeBackup ?? backup.path,
                                          database: writeGuard.isLive(database) ? nil : database.path)
        }
    }

    static var iTunesSyncConflict: DJCError {
        .writeRefused(String(ui: "rekordbox의 iTunes 동기화 선택이 바뀌었습니다. 새로고침한 뒤 다시 선택하세요."))
    }
}
