import DJCDomain
import Foundation

/// 중단 기록의 판정·기록으로 복원·"이대로 둔다"(R11). 모두 대상의 쓰기 잠금을 쥔 채 한다. 쓰기 관문 포트(`RekordboxWriteGate.live`)가 감싼다.
extension RekordboxWriter {
    /// 기록으로 복원한 결과
    public enum JournalRestoreResult: Equatable, Sendable {
        /// 되돌렸다. 되돌리기 직전 상태를 남긴 백업(RBW-5, 없으면 nil)
        case restored(URL?)
        /// 이미 목표 상태였다
        case alreadyRestored
    }

    /// 사용자가 확인한 기록 요청(작업 ID·그때 본 master.db 크기·시각)과 지금이 다를 때
    public enum JournalRequestOutcome<Value: Sendable>: Sendable {
        case done(Value)
        /// 기록이 없다
        case nothing
        /// 잠금 안에서 본 기록의 작업 ID나 master.db 크기·시각이 요청과 다르다(아무것도 하지 않았다)
        case changed
    }

    static var journalBasisMissing: DJCError {
        .writeRefused(String(ui: "쓰기 기록에 되돌릴 근거가 없어 복원하지 않았습니다. 상태 줄에서 이대로 두세요"))
    }

    // MARK: - 판정

    /// 대상의 쓰기 기록을 판정한다. `locked`면 부르는 쪽이 이미 그 대상의 잠금을 쥐었다(잠금은 다시 들어갈 수 없다).
    /// 아니면 비차단으로 잡고, 못 잡으면 nil(다른 프로세스가 쓰는 중: 판정하지 않는다)
    public static func judgeJournal(database: URL, backups: URL?, locked: Bool, guard writeGuard: RekordboxWriteGuard = .system)
        throws -> RekordboxJournalJudgment? {
        // 판정도 기록을 조용히 지울 수 있어 쓰기 관문을 지난다(시험 프로세스의 실제 라이브러리 거부, SAFE-3)
        _ = try writeGuard.resolveShareRoot(database, shareRoot: nil)
        if locked { return try WriteRun(database: database, guard: writeGuard, backups: backups).judge() }
        guard let hold = try writeGuard.locks.tryLock(try RekordboxWriteLocks.key(database)) else { return nil }
        defer { hold.release() }
        return try WriteRun(database: database, guard: writeGuard, backups: backups).judge()
    }

    // MARK: - 기록으로 복원

    /// 사용자가 확인한 중단 기록으로 복원한다(잠금을 기다려 잡는다). 기록이 없으면 `.nothing`, 요청과 다르면 `.changed`
    public static func restoreJournal(database: URL, operationID: String, databaseStamp: RekordboxFileStamp?, backups: URL, shareRoot: URL?,
                                      snapshots: URL? = nil, now: Date = .now, guard writeGuard: RekordboxWriteGuard = .system)
        throws -> JournalRequestOutcome<JournalRestoreResult> {
        let resolvedShare = try writeGuard.resolveShareRoot(database, shareRoot: shareRoot)
        let run = try WriteRun.locked(database, guard: writeGuard, backups: backups, snapshots: snapshots)
        defer { run.close() }
        guard let journal = try readJournal(at: run.journalURL) else { return .nothing }
        guard journal.operationID == operationID, fileStamp(run.resolved) == databaseStamp else { return .changed }
        // share를 주지 않은 사본은 링크를 푼 DB 옆 share다(링크 자리 옆이 아니라)
        let share = resolvedShare ?? run.resolved.deletingLastPathComponent().appending(path: "share")
        return .done(try restoreByJournal(journal, run: run, backups: backups, shareRoot: share, now: now))
    }

    /// 기록으로 복원·"이대로 둔다" 전에 기록의 경로를 다시 검증한다: 바꾸거나 지울 파일은 이 대상의 DB 곁 파일이나 분석 루트 안의
    /// 분석·그림 파일, 원본 사본과 iTunes 동기화 근거는 기록이 남긴 백업 폴더 뿌리 안의 일반 파일, 시점 복원의 임시 폴더는 분석 루트의
    /// `PIONEER` 바로 아래 `.djc-restore-*`·`.djc-old-*`여야 한다. 하나라도 밖이면 아무것도 바꾸지 않고 거절한다(기록 파일을 고친 경우)
    static func validateJournalPaths(_ journal: RekordboxWriteJournal, database: URL, share: URL) throws {
        let refusal = DJCError.writeRefused(String(ui: "쓰기 기록이 라이브러리 밖의 경로를 가리켜 복원하지 않았습니다. 상태 줄에서 이대로 두세요"))
        func resolved(_ path: String) -> String { URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().comparablePath }
        let folder = database.deletingLastPathComponent()
        let adjacent = Set(([playlistXMLURL(for: database)] + RekordboxPointSnapshot.adjacentFiles.map { folder.appending(path: $0) }).map { resolved($0.path) })
        let backupRoot = journal.basis.writeBackup.map { URL(filePath: $0).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent() }
        func insideBackups(_ path: String) throws {
            guard let backupRoot else { throw refusal }
            do {
                try validateBackupFile(URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath(), under: backupRoot, required: true)
            } catch {
                throw refusal
            }
        }
        for file in journal.files {
            if !adjacent.contains(resolved(file.path)) {
                guard (try? backupTarget(file.path, shareRoot: share)) != nil else { throw refusal }
            }
            if let original = file.original { try insideBackups(original) }
        }
        if let before = journal.basis.iTunesSyncBefore {
            try insideBackups(before)
            try insideBackups(URL(filePath: before).deletingLastPathComponent().appending(path: "itunes-sync-after.xml").path)
        }
        if let point = journal.pointRestore {
            let parents = Set(RekordboxPointSnapshot.shareFolders.flatMap { folder -> [String] in
                let parent = share.appending(path: folder).deletingLastPathComponent().standardizedFileURL
                return [parent.comparablePath, parent.resolvingSymlinksInPath().comparablePath]
            })
            for path in point.temporaryFolders {
                let url = URL(filePath: path).standardizedFileURL, name = url.lastPathComponent
                guard parents.contains(url.deletingLastPathComponent().comparablePath),
                      name.hasPrefix(".djc-restore-") || name.hasPrefix(".djc-old-") else { throw refusal }
            }
        }
    }

    /// 그 쓰기의 미정리 목록을 지운다: 이 실행의 백업 폴더와, 기록이 남긴 원래 백업 폴더(`DJC_HOME`이 다른 실행이 복원해도 원래 목록을 지운다)
    static func removeCleanupLists(of journal: RekordboxWriteJournal, backups: URL) throws {
        var roots = [backups.standardizedFileURL]
        if let recorded = journal.basis.writeBackup {
            let original = URL(filePath: recorded).standardizedFileURL.deletingLastPathComponent()
            if original.resolvingSymlinksInPath().comparablePath != backups.standardizedFileURL.resolvingSymlinksInPath().comparablePath {
                roots.append(original)
            }
        }
        for root in roots { try removeCleanupList(operationID: journal.operationID, in: root) }
    }

    /// 기록 하나로 복원한다(잠금을 쥔 채). 입구마다:
    /// - 초안 쓰기·곡 넣기/빼기: 쓰기 전 백업으로 DB·XML을 되돌리고(카운터 쓰기만), 만든 파일을 지우고, 바꾼 파일을 원본으로 되돌린다.
    /// - 쓰기 전으로 복원: 같은 복원을 다시 한다(DB·XML은 고른 백업에서, 파일은 기록에 적힌 사슬 끝의 상태로).
    /// - 시점 복원: 같은 시점으로 다시 한다(기록의 복원 직전 스냅샷을 다시 쓴다).
    /// - iTunes 동기화(와 그 되돌리기): `playlists3.sync`만 되돌린다. 지금 파일이 적용 뒤 값이면 되돌리고, 원래 값이면 이미 되돌린 것으로 보고,
    ///   둘 다 아니면 거절한다.
    /// 백업 사슬 검사(`laterBackups`)를 타지 않고 기록의 근거와 파일 목록만으로 한다. 되돌리기 직전 상태는 백업한다(RBW-5).
    /// 시작할 때 "복원 중"을 적고, 검증이 끝나면 그 쓰기의 미정리 목록을 먼저 지우고 기록은 마지막에 지운다. 다시 멈추거나 실패하면 기록을 남긴다.
    static func restoreByJournal(_ journal: RekordboxWriteJournal, run: WriteRun, backups: URL, shareRoot: URL?, now: Date,
                                 pointTarget: URL? = nil) throws -> JournalRestoreResult {
        run.adopt(journal)
        let share = shareRoot ?? run.resolved.deletingLastPathComponent().appending(path: "share")
        do {
            try run.recheck(.recovery)
            // 기록의 경로가 하나라도 밖을 가리키면 아무것도 바꾸지 않는다(표시도 적지 않는다)
            try validateJournalPaths(journal, database: run.resolved, share: share)
            try run.update { $0.marks.insert(.restoring) }
            let result: JournalRestoreResult
            if journal.basis.iTunesSyncBefore != nil {
                result = try restoreITunesJournal(journal, run: run, backups: backups, now: now)
            } else if journal.entry == .pointRestore {
                guard let target = pointTarget ?? journal.basis.pointSnapshot.map({ URL(filePath: $0) }) else { throw journalBasisMissing }
                // 다른 목표(복원 직전 시점)로 다시 하면 기록의 목표도 고쳐 적는다: 다시 멈춰도 같은 목표로 이어 간다
                if target.standardizedFileURL.path != journal.basis.pointSnapshot.map({ URL(filePath: $0).standardizedFileURL.path }) {
                    try run.update { $0.basis.pointSnapshot = target.standardizedFileURL.path }
                }
                result = try redoPointRestore(journal, to: target, run: run, shareRoot: share)
            } else {
                result = try restoreWriteJournal(journal, run: run, backups: backups, shareRoot: share, now: now)
            }
            // 그 쓰기의 미정리 목록을 먼저 지우고(초안은 그대로 남는다), 이 대상의 준비 폴더를 치운 뒤 기록을 마지막에 지운다
            try removeCleanupLists(of: journal, backups: backups)
            removeStaging(roots: [run.resolved.deletingLastPathComponent(), share], key: run.key)
            try run.finish()
            prune(backups, now: now)
            return result
        } catch {
            // 다시 멈추거나 실패하면 기록을 남긴다(같은 목표로 다시 할 수 있다)
            throw run.passThrough(error) ?? error
        }
    }

    /// 초안 쓰기·곡 넣기/빼기·쓰기 전으로 복원의 기록으로 복원
    static func restoreWriteJournal(_ journal: RekordboxWriteJournal, run: WriteRun, backups: URL, shareRoot: URL?, now: Date) throws -> JournalRestoreResult {
        guard let recorded = journal.basis.writeBackup else { throw journalBasisMissing }
        let backup = URL(filePath: recorded)
        let fm = FileManager.default
        // DB·XML은 카운터 쓰기(DB를 커밋한 쓰기)와 복원만 되돌린다. 파일만 바꾼 쓰기는 DB를 건드리지 않았다
        let restoresDatabase = journal.kind == .counter || journal.entry == .restore
        // 링크로 가리킨 DB면 링크를 파일로 바꾸지 않게 링크를 푼 자리를 다룬다
        let database = run.resolved
        if restoresDatabase {
            try validateBackupFile(backup.appending(path: "master.db"), under: backup, required: true)
            try checkSameLibrary(backup: backup.appending(path: "master.db"), target: database)
            try checkIntegrity(of: backup.appending(path: "master.db"))
        }
        let targets = try journal.files.map { file -> (url: URL, original: Data?) in
            (URL(filePath: file.path), try file.original.map { try Data(contentsOf: URL(filePath: $0)) })
        }
        func matches() throws -> Bool {
            if restoresDatabase {
                // 커밋은 체크포인트 전까지 -wal에만 있다: master.db가 백업과 같아도 -wal이 다르면 아직 되돌리지 않았다
                guard try sameContents(database, backup.appending(path: "master.db")),
                      try sameSidecar(of: database, as: backup.appending(path: "master.db")) else { return false }
                let xml = backup.appending(path: "masterPlaylists6.xml")
                if fm.fileExists(atPath: xml.path), (try? Data(contentsOf: playlistXMLURL(for: database))) != (try Data(contentsOf: xml)) { return false }
            }
            return targets.allSatisfy { target in
                if let original = target.original { return (try? Data(contentsOf: target.url)) == original }
                return !fm.fileExists(atPath: target.url.path)
            }
        }
        if try matches() { return .alreadyRestored }
        // 되돌리기 직전 상태를 남긴다(RBW-5): DB 전체와 바꿀 파일의 지금 내용
        let share = shareRoot ?? database.deletingLastPathComponent().appending(path: "share")
        let saved = try makeBackup(of: database, in: backups, now: now, label: "before-restore")
        let touched = targets.compactMap { target -> TouchedFile? in
            guard let relative = try? backupTarget(target.url.path, shareRoot: share).relative else { return nil }
            return TouchedFile(url: target.url, relative: relative, original: try? Data(contentsOf: target.url), existsAfter: target.original != nil)
        }
        try saveRestoreUndo(touched, in: saved, restoredFrom: backup, now: now, shareRoot: share)
        if restoresDatabase { try restoreFiles(from: backup, to: database, run: run) }
        for target in targets {
            if let original = target.original {
                guard (try? Data(contentsOf: target.url)) != original else { continue }
                try run.recheck(.fileReplace)
                try run.before(.fileReplace)
                run.changed = true
                try fm.createDirectory(at: target.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try original.write(to: target.url, options: .atomic)
                try run.after(.fileReplace)
            } else if fm.fileExists(atPath: target.url.path) {
                try run.recheck(.fileReplace)
                try run.before(.fileReplace)
                run.changed = true
                try removeAnalysisFiles([target.url])
                try run.after(.fileReplace)
            }
        }
        try run.step(.verify, recheck: false) {
            try checkIntegrity(of: database)
            guard try matches() else {
                throw DJCError.writeVerificationFailed(String(ui: "기록으로 복원한 라이브러리가 기록의 근거와 다릅니다"))
            }
        }
        return .restored(saved)
    }

    /// iTunes 동기화(와 그 되돌리기)의 기록으로 복원: `playlists3.sync`만 기록의 목표 값으로
    static func restoreITunesJournal(_ journal: RekordboxWriteJournal, run: WriteRun, backups: URL, now: Date) throws -> JournalRestoreResult {
        guard let beforePath = journal.basis.iTunesSyncBefore else { throw journalBasisMissing }
        let before = URL(filePath: beforePath), after = before.deletingLastPathComponent().appending(path: "itunes-sync-after.xml")
        let target = run.resolved.deletingLastPathComponent().appending(path: "playlists3.sync")
        let original = try Data(contentsOf: before), applied = try Data(contentsOf: after)
        let current = try Data(contentsOf: target)
        if current == original { return .alreadyRestored }
        guard current == applied else { throw iTunesSyncConflict }
        let saved = try makeBackup(of: run.resolved, in: backups, now: now, label: "before-restore")
        try saveITunesSyncBackup(before: applied, after: original, in: saved)
        try run.recheck(.fileReplace)
        try run.before(.fileReplace)
        run.changed = true
        try original.write(to: target, options: .atomic)
        try run.after(.fileReplace)
        guard try Data(contentsOf: target) == original else { throw iTunesSyncConflict }
        return .restored(saved)
    }

    // MARK: - 이대로 둔다

    /// "이대로 둔다"(R11). 한 쓰기 잠금 안에서: 요청을 남은 기록·지금 DB와 다시 견주고(다르면 `.changed`, 기록이 없으면 `.nothing`),
    /// 같으면 부르는 쪽의 일(`apply`: 미정리 목록 지우기·제안 전환)을 하고, 기록을 마지막에 지운다. `apply`가 던지면 기록을 남기고 던진다
    /// 시점 복원의 기록이면 apply 전에 폴더 자리를 정리한다: 옮겨 둔 지금 내용(`.djc-old-*`)은 그 폴더 자리가 비었으면 되돌리고,
    /// 기록된 나머지 임시 폴더는 지운다(파일을 바꾸기 바로 직전마다 실행을 다시 본다)
    public static func keepJournal(database: URL, operationID: String, databaseStamp: RekordboxFileStamp?, backups: URL?, snapshots: URL? = nil,
                                   shareRoot: URL? = nil, guard writeGuard: RekordboxWriteGuard = .system,
                                   apply: () throws -> Void) throws -> JournalRequestOutcome<Void> {
        let resolvedShare = try writeGuard.resolveShareRoot(database, shareRoot: shareRoot)
        let run = try WriteRun.locked(database, guard: writeGuard, backups: backups, snapshots: snapshots)
        defer { run.close() }
        guard let journal = try readJournal(at: run.journalURL) else { return .nothing }
        guard journal.operationID == operationID, fileStamp(run.resolved) == databaseStamp else { return .changed }
        run.adopt(journal)
        if let point = journal.pointRestore {
            let share = resolvedShare ?? run.resolved.deletingLastPathComponent().appending(path: "share")
            do {
                try validateJournalPaths(journal, database: run.resolved, share: share)
                try settleTemporaryFolders(point.temporaryFolders, run: run)
            } catch {
                throw run.passThrough(error) ?? error
            }
        }
        try apply()
        try run.finish()
        return .done(())
    }

    /// 시점 복원 임시 폴더 정리: `.djc-old-<UUID>-<이름>`은 그 이름의 폴더 자리가 비었으면 그 자리로 되돌리고, 남은 임시 폴더는 지운다
    static func settleTemporaryFolders(_ paths: [String], run: WriteRun) throws {
        let fm = FileManager.default
        for path in paths {
            let folder = URL(filePath: path), name = folder.lastPathComponent
            guard name.hasPrefix(".djc-old-"), fm.fileExists(atPath: folder.path) else { continue }
            let original = String(name.dropFirst(".djc-old-".count + UUID().uuidString.count + 1))
            let target = folder.deletingLastPathComponent().appending(path: original)
            guard !original.isEmpty, !fm.fileExists(atPath: target.path) else { continue }
            try run.recheck(.fileReplace)
            try run.before(.fileReplace)
            run.changed = true
            try fm.moveItem(at: folder, to: target)
            try run.after(.fileReplace)
        }
        for path in paths where fm.fileExists(atPath: path) {
            try run.recheck(.fileReplace)
            try run.before(.fileReplace)
            run.changed = true
            try fm.removeItem(atPath: path)
            try run.after(.fileReplace)
        }
    }

    // MARK: - 도움

    /// DB 곁 `-wal`이 기준과 같은지: 기준에 `-wal`이 있으면 바이트가 같아야 하고, 없으면 없거나 비어 있어야 한다
    static func sameSidecar(of database: URL, as reference: URL) throws -> Bool {
        let wal = URL(filePath: database.path + "-wal"), expected = URL(filePath: reference.path + "-wal")
        if FileManager.default.fileExists(atPath: expected.path) { return try sameContents(wal, expected) }
        let size = (try? FileManager.default.attributesOfItem(atPath: wal.path))?[.size] as? Int ?? 0
        return size == 0
    }

    /// 두 파일의 바이트가 같은지(조각마다 견준다: DB가 크다)
    static func sameContents(_ a: URL, _ b: URL) throws -> Bool {
        let fm = FileManager.default
        guard let sizeA = try? fm.attributesOfItem(atPath: a.path)[.size] as? Int, let sizeB = try? fm.attributesOfItem(atPath: b.path)[.size] as? Int,
              sizeA == sizeB else { return false }
        let left = try FileHandle(forReadingFrom: a), right = try FileHandle(forReadingFrom: b)
        defer { try? left.close(); try? right.close() }
        while true {
            let x = try left.read(upToCount: 1 << 20) ?? Data(), y = try right.read(upToCount: 1 << 20) ?? Data()
            guard x == y else { return false }
            if x.isEmpty { return true }
        }
    }
}
