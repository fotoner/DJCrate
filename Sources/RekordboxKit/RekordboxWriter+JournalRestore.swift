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

    /// "이대로 둔다"의 결과
    public struct KeepResult: Equatable, Sendable {
        /// 기록에 적혔지만 경계 밖이라 손대지 않고 남긴 경로(기록을 고친 경우). 이대로 두기는 막지 않는다
        public var leftAsIs: [String]

        public init(leftAsIs: [String] = []) { self.leftAsIs = leftAsIs }
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

    /// 다시 검증한 기록의 경로. 적용에는 기록의 글자가 아니라 검사한 이 URL만 쓴다(S1: 표준 모양은 실제 자리에 파일이 없으면 글자대로 풀려,
    /// 기록의 글자를 다시 열면 링크 너머 다른 자리를 열 수 있다)
    struct JournalPaths {
        /// 기록의 파일마다 바꾸거나 지울 대상과 원본 사본(nil이면 그 쓰기가 만든 파일이라 지운다)
        var files: [(target: URL, original: URL?)] = []
        /// 쓰기 전 백업 폴더(근거)
        var writeBackup: URL?
        /// iTunes 동기화 전·뒤 파일(백업 안)
        var iTunesSync: (before: URL, after: URL)?
        /// 시점 복원의 목표 스냅샷·복원 직전 스냅샷(쓰기 전에 `validPointSnapshot`으로 다시 본다)
        var pointSnapshot: URL?
        var snapshotBeforeRestore: URL?
    }

    /// 기록으로 복원 전에 기록의 경로를 다시 검증한다(S1). 작업 ID는 파일 이름으로 안전해야 하고, 경로는 모두 절대 경로 글자여야 한다
    /// (상대 경로는 검사와 적용이 다른 기준으로 풀린다). 경로는 표준 모양(`.`·`..`·겹친 `/`를 푼 것)으로 검사하고 그 URL을 그대로 적용에 쓴다.
    /// 바꾸거나 지울 파일은 이 대상(링크를 푼 DB)의 곁 파일 자리나 분석 루트 안의
    /// 분석·그림 파일, 원본 사본과 iTunes 동기화 근거는 쓰기 전 백업 폴더나 처음 복원 때 확인한 연쇄 백업 폴더(S15) 안의 일반 파일,
    /// 시점 복원의 폴더 역할은 분석 루트의 폴더 자리와 `PIONEER` 바로 아래 `.djc-restore-*`·`.djc-old-*`여야 한다. 경계는 링크를 풀지
    /// 않은 경로와 푼 경로가 모두 안이어야 하고 마지막 조각이 링크면 받지 않는다. 하나라도 밖이면 아무것도 바꾸지 않고 거절한다(기록 파일을 고친 경우)
    static func validateJournalPaths(_ journal: RekordboxWriteJournal, database: URL, share: URL) throws -> JournalPaths {
        let refusal = DJCError.writeRefused(String(ui: "쓰기 기록이 라이브러리 밖의 경로를 가리켜 복원하지 않았습니다. 상태 줄에서 이대로 두세요"))
        guard isSafeOperationID(journal.operationID), journalPathStrings(journal).allSatisfy(isAbsolutePath) else { throw refusal }
        let folder = database.deletingLastPathComponent()
        let adjacent = Set(([playlistXMLURL(for: database)] + RekordboxPointSnapshot.adjacentFiles.map { folder.appending(path: $0) }).map(\.comparablePath))
        func adjacentFile(_ url: URL) -> Bool {
            adjacent.contains(url.comparablePath) && adjacent.contains(url.resolvingSymlinksInPath().comparablePath) && !isSymbolicLink(url)
        }
        var paths = JournalPaths()
        paths.writeBackup = journal.basis.writeBackup.map(standardURL)
        paths.pointSnapshot = journal.basis.pointSnapshot.map(standardURL)
        paths.snapshotBeforeRestore = journal.pointRestore.map { standardURL($0.snapshotBeforeRestore) }
        // 원본 사본·iTunes 근거의 뿌리: 쓰기 전 백업 폴더와, 처음 복원 때 함께 되돌린 뒤 백업 폴더(master.db가 든 실제 폴더여야 한다)
        var roots = paths.writeBackup.map { [$0] } ?? []
        for path in journal.basis.chain ?? [] {
            let backup = standardURL(path).resolvingSymlinksInPath()
            guard (try? validateBackupFile(backup.appending(path: "master.db"), under: backup, required: true)) != nil else { throw refusal }
            roots.append(URL(filePath: path))
        }
        func insideBackups(_ path: String) throws -> URL {
            let url = standardURL(path)
            for root in roots {
                let spelled = root.standardizedFileURL, resolved = spelled.resolvingSymlinksInPath()
                guard let prefix = [spelled, resolved].map({ $0.comparablePath + "/" }).first(where: url.comparablePath.hasPrefix) else { continue }
                // 뿌리 아래 조각마다 실제 폴더이고 마지막은 일반 파일이어야 한다(링크가 없으니 링크를 푼 경로도 뿌리 안이다)
                let relative = String(url.comparablePath.dropFirst(prefix.count))
                guard (try? validateBackupFile(resolved.appending(path: relative), under: resolved, required: true)) != nil else { throw refusal }
                return url
            }
            throw refusal
        }
        for file in journal.files {
            let url = standardURL(file.path)
            let target: URL
            if adjacentFile(url) {
                target = url
            } else {
                // 분석·그림 파일: 분석 루트 안이고 조각마다 실제 폴더, 마지막은 일반 파일이거나 없다(검사한 URL을 쓴다)
                guard let checked = try? backupTarget(url.path, shareRoot: share).url else { throw refusal }
                target = checked
            }
            paths.files.append((target, try file.original.map(insideBackups)))
        }
        if let recorded = journal.basis.iTunesSyncBefore {
            let before = try insideBackups(recorded)
            paths.iTunesSync = (before, try insideBackups(before.deletingLastPathComponent().appending(path: "itunes-sync-after.xml").path))
        }
        if let point = journal.pointRestore {
            let temporary = point.temporaryFolders + (point.folders ?? []).flatMap { [$0.staged, $0.old] }
            guard temporary.allSatisfy({ pointTemporaryFolder($0, share: share) != nil }),
                  (point.folders ?? []).allSatisfy({ pointFolderSlot($0.target, share: share) != nil }) else { throw refusal }
        }
        return paths
    }

    /// 기록에 적힌 모든 경로 글자
    static func journalPathStrings(_ journal: RekordboxWriteJournal) -> [String] {
        [journal.basis.writeBackup, journal.basis.pointSnapshot, journal.basis.iTunesSyncBefore, journal.pointRestore?.snapshotBeforeRestore]
            .compactMap { $0 } + (journal.basis.chain ?? []) + journal.files.flatMap { [$0.path] + [$0.original].compactMap { $0 } }
            + (journal.pointRestore?.temporaryFolders ?? []) + (journal.pointRestore?.folders ?? []).flatMap { [$0.target, $0.staged, $0.old] }
    }

    /// 절대 경로 글자인지(NUL 없음)
    static func isAbsolutePath(_ path: String) -> Bool { path.hasPrefix("/") && !path.contains("\0") }

    /// 기록의 경로 글자를 검사·적용에 쓸 표준 URL로(`.`·`..`·겹친 `/`를 푼다. 링크는 풀지 않는다)
    static func standardURL(_ path: String) -> URL { URL(filePath: path).standardizedFileURL }

    /// 그 경로의 마지막 조각이 심볼릭 링크인지(없으면 아니다)
    static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    /// 시점 복원 임시 폴더가 경계 안이면 그 URL: 분석 루트의 `PIONEER` 바로 아래(링크를 풀기 전·뒤 모두) `.djc-restore-*`·`.djc-old-*`이고 링크가 아니다
    static func pointTemporaryFolder(_ path: String, share: URL) -> URL? {
        guard isAbsolutePath(path) else { return nil }
        let url = standardURL(path), name = url.lastPathComponent, parent = url.deletingLastPathComponent()
        let parents = Set(RekordboxPointSnapshot.shareFolders.flatMap { folder -> [String] in
            let parent = share.appending(path: folder).deletingLastPathComponent().standardizedFileURL
            return [parent.comparablePath, parent.resolvingSymlinksInPath().comparablePath]
        })
        guard name.hasPrefix(".djc-restore-") || name.hasPrefix(".djc-old-"), parents.contains(parent.comparablePath),
              parents.contains(parent.resolvingSymlinksInPath().comparablePath), !isSymbolicLink(url) else { return nil }
        return url
    }

    /// 시점 복원이 바꿔 끼우는 폴더 자리(분석·앨범아트 폴더)면 그 URL(링크를 풀기 전·뒤 모두 그 자리이고 링크가 아니다)
    static func pointFolderSlot(_ path: String, share: URL) -> URL? {
        guard isAbsolutePath(path) else { return nil }
        let url = standardURL(path)
        let slots = Set(RekordboxPointSnapshot.shareFolders.flatMap { folder -> [String] in
            let slot = share.appending(path: folder).standardizedFileURL
            return [slot.comparablePath, slot.resolvingSymlinksInPath().comparablePath]
        })
        guard slots.contains(url.comparablePath), slots.contains(url.resolvingSymlinksInPath().comparablePath), !isSymbolicLink(url) else { return nil }
        return url
    }

    /// 그 쓰기의 미정리 목록을 지운다: 이 실행의 백업 폴더와, 기록이 남긴 원래 백업 폴더(`DJC_HOME`이 다른 실행이 복원해도 원래 목록을 지운다).
    /// 원래 백업 폴더는 검사한 쓰기 전 백업 URL(`writeBackup`)의 부모다
    static func removeCleanupLists(of journal: RekordboxWriteJournal, writeBackup: URL?, backups: URL) throws {
        var roots = [backups.standardizedFileURL]
        if let writeBackup {
            let original = writeBackup.deletingLastPathComponent()
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
            let paths = try validateJournalPaths(journal, database: run.resolved, share: share)
            try run.update { $0.marks.insert(.restoring) }
            let result: JournalRestoreResult
            if let iTunesSync = paths.iTunesSync {
                result = try restoreITunesJournal(before: iTunesSync.before, after: iTunesSync.after, run: run, backups: backups, now: now)
            } else if journal.entry == .pointRestore {
                guard let target = pointTarget ?? paths.pointSnapshot else { throw journalBasisMissing }
                // 다른 목표(복원 직전 시점)로 다시 하면 기록의 목표도 고쳐 적는다: 다시 멈춰도 같은 목표로 이어 간다
                if target.standardizedFileURL.path != paths.pointSnapshot?.path {
                    try run.update { $0.basis.pointSnapshot = target.standardizedFileURL.path }
                }
                result = try redoPointRestore(journal, to: target, run: run, shareRoot: share, beforeRestore: paths.snapshotBeforeRestore)
            } else {
                result = try restoreWriteJournal(journal, paths: paths, run: run, backups: backups, shareRoot: share, now: now)
            }
            // 그 쓰기의 미정리 목록을 먼저 지우고(초안은 그대로 남는다), 이 대상의 준비 폴더를 치운 뒤 기록을 마지막에 지운다
            try removeCleanupLists(of: journal, writeBackup: paths.writeBackup, backups: backups)
            removeStaging(roots: [run.resolved.deletingLastPathComponent(), share], key: run.key)
            try run.finish()
            prune(backups, now: now)
            return result
        } catch {
            // 다시 멈추거나 실패하면 기록을 남긴다(같은 목표로 다시 할 수 있다)
            throw run.passThrough(error) ?? error
        }
    }

    /// 초안 쓰기·곡 넣기/빼기·쓰기 전으로 복원의 기록으로 복원. 파일은 검증한 경로(`paths`)로 다룬다
    static func restoreWriteJournal(_ journal: RekordboxWriteJournal, paths: JournalPaths, run: WriteRun, backups: URL, shareRoot: URL?,
                                    now: Date) throws -> JournalRestoreResult {
        guard let backup = paths.writeBackup else { throw journalBasisMissing }
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
        let targets = try paths.files.map { file -> (url: URL, original: Data?) in
            (file.target, try file.original.map { try Data(contentsOf: $0) })
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

    /// iTunes 동기화(와 그 되돌리기)의 기록으로 복원: `playlists3.sync`만 기록의 목표 값으로. 근거는 검사한 백업 안 URL이다
    static func restoreITunesJournal(before: URL, after: URL, run: WriteRun, backups: URL, now: Date) throws -> JournalRestoreResult {
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

    /// "이대로 둔다"(R11). 사용자가 기록을 끝내는 탈출구다. 한 쓰기 잠금 안에서: 요청을 남은 기록·지금 DB와 다시 견주고(다르면 `.changed`,
    /// 기록이 없으면 `.nothing`), 같으면 부르는 쪽의 일(`apply`: 미정리 목록 지우기·제안 전환)을 하고, 기록을 마지막에 지운다.
    /// `apply`가 던지면 기록을 남기고 던진다. 시점 복원의 기록이면 apply 전에 폴더 자리를 정리한다(`settleTemporaryFolders`).
    /// 기록의 경로가 경계 밖이어도 막지 않는다(G12): 경계 안 임시 폴더만 정리하고, 밖은 손대지 않고 결과(`leftAsIs`)로 알린다
    public static func keepJournal(database: URL, operationID: String, databaseStamp: RekordboxFileStamp?, backups: URL?, snapshots: URL? = nil,
                                   shareRoot: URL? = nil, guard writeGuard: RekordboxWriteGuard = .system,
                                   apply: () throws -> Void) throws -> JournalRequestOutcome<KeepResult> {
        let resolvedShare = try writeGuard.resolveShareRoot(database, shareRoot: shareRoot)
        let run = try WriteRun.locked(database, guard: writeGuard, backups: backups, snapshots: snapshots)
        defer { run.close() }
        guard let journal = try readJournal(at: run.journalURL) else { return .nothing }
        guard journal.operationID == operationID, fileStamp(run.resolved) == databaseStamp else { return .changed }
        run.adopt(journal)
        var left: [String] = []
        if let point = journal.pointRestore {
            let share = resolvedShare ?? run.resolved.deletingLastPathComponent().appending(path: "share")
            do {
                left = try settleTemporaryFolders(point, share: share, run: run)
            } catch {
                throw run.passThrough(error) ?? error
            }
        }
        try apply()
        try run.finish()
        return .done(KeepResult(leftAsIs: left))
    }

    /// 시점 복원 임시 폴더 정리(S16·S19·G12). 먼저 빈 폴더 자리를 기록의 폴더 역할로 채운다(나중 시도부터): 바꿔 끼운 뒤 복원 전 내용은 늘
    /// `old` 자리에 있어 그 자리만 되돌린다. 준비 자리(`staged`)는 아직 바꿔 끼우지 않은 시점 복제라 빈 자리에 넣지 않는다(복원 전에 없던
    /// 폴더 자리에 다른 시점 내용을 넣지 않는다). 그 뒤 기록된 임시 폴더 중 경계 안의 것은 지우고, 밖의 것은 손대지 않고 돌려준다.
    /// 파일을 바꾸기 바로 직전마다 실행을 다시 본다
    static func settleTemporaryFolders(_ point: RekordboxWriteJournal.PointRestore, share: URL, run: WriteRun) throws -> [String] {
        let fm = FileManager.default
        func change(_ body: () throws -> Void) throws {
            try run.recheck(.fileReplace)
            try run.before(.fileReplace)
            run.changed = true
            try body()
            try run.after(.fileReplace)
        }
        for role in (point.folders ?? []).reversed() {
            guard let target = pointFolderSlot(role.target, share: share), !fm.fileExists(atPath: target.path),
                  let source = pointTemporaryFolder(role.old, share: share), fm.fileExists(atPath: source.path) else { continue }
            try change { try fm.moveItem(at: source, to: target) }
        }
        var left: [String] = [], seen = Set<String>()
        for path in point.temporaryFolders + (point.folders ?? []).flatMap({ [$0.staged, $0.old] }) where seen.insert(path).inserted {
            guard let folder = pointTemporaryFolder(path, share: share) else {
                left.append(path)
                continue
            }
            if fm.fileExists(atPath: folder.path) { try change { try fm.removeItem(at: folder) } }
        }
        return left
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
