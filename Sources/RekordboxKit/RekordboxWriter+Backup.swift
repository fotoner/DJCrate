import DJCDomain
import Foundation

/// 백업·되돌리기
extension RekordboxWriter {
    // MARK: - 백업·되돌리기

    // 백업 값은 DJCDomain에 있다(#167). 옛 이름을 남긴다.
    public typealias Backup = RekordboxWriteBackup

    /// DB 파일(+WAL·SHM)을 통째로 복사한다. 복사하는 동안 원본이 바뀌면 실패한다.
    static func makeBackup(of database: URL, in directory: URL, now: Date, label: String) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        // 같은 초에 두 번 뜨면 번호를 붙인다(이름 순서 = 시간 순서가 되게 -2, -3…)
        var name = formatter.string(from: now) + "-" + label
        var suffix = 2
        while fm.fileExists(atPath: directory.appending(path: name).path) {
            name = formatter.string(from: now) + "-" + label + "-\(suffix)"
            suffix += 1
        }
        let folder = directory.appending(path: name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: database.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let before = try fm.attributesOfItem(atPath: source.path)
            let destination = folder.appending(path: "master.db" + suffix)
            try fm.copyItem(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let after = try fm.attributesOfItem(atPath: source.path)
            let copied = try fm.attributesOfItem(atPath: destination.path)
            guard before[.size] as? Int == after[.size] as? Int,
                  before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                  copied[.size] as? Int == after[.size] as? Int
            else {
                try? fm.removeItem(at: folder)
                throw DJCError.sourceChangedDuringCopy(path: source.path)
            }
        }
        // 재생 목록 쓰기가 고치는 masterPlaylists6.xml도 둔다(되돌리면 DB와 같은 때로).
        let xml = playlistXMLURL(for: database)
        if fm.fileExists(atPath: xml.path) {
            let destination = folder.appending(path: xml.lastPathComponent)
            try fm.copyItem(at: xml, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        return folder
    }

    /// 쓴 뒤 보고서를 백업에 둔다. 저장하지 못해도 커밋한 쓰기를 실패로 돌리지 않고 경고를 돌려준다(조용히 삼키지 않는다, #66 리뷰).
    /// 만든 파일 경로 때문에 실패했으면 그 칸 없이 다시 저장해 복원·백업 목록이 DB는 되살릴 수 있게 한다.
    static func saveReport(_ report: Report, in backup: URL, shareRoot: URL?) -> String? {
        do {
            try save(report, in: backup, shareRoot: shareRoot)
            return nil
        } catch {
            var fallback = report
            fallback.createdFiles = nil
            try? save(fallback, in: backup, shareRoot: shareRoot)
            return String(ui: "저장 보고서(report.json)를 백업에 다 보관하지 못해 ‘저장 전으로 복원…’이 이번에 만든 파일을 지우지 못할 수 있으니 백업 폴더를 확인하세요: \(DJCError.reason(of: error))")
        }
    }

    /// 쓰기 기록이 있는 쓰기의 보고서 저장(R11): 기록을 지우기 전에 하고, 실패해도(주입 포함) 경고만 돌려준다. 강제 종료 흉내는 그대로 던진다
    static func saveReport(_ report: Report, in backup: URL, shareRoot: URL?, run: WriteRun) throws -> String? {
        do {
            try run.before(.reportSave)
        } catch let stop as RekordboxWriteStop {
            throw stop
        } catch {
            return String(ui: "저장 보고서(report.json)를 백업에 다 보관하지 못해 ‘저장 전으로 복원…’이 이번에 만든 파일을 지우지 못할 수 있으니 백업 폴더를 확인하세요: \(DJCError.reason(of: error))")
        }
        let warning = saveReport(report, in: backup, shareRoot: shareRoot)
        do { try run.after(.reportSave) } catch let stop as RekordboxWriteStop { throw stop } catch {}
        return warning
    }

    static func save(_ report: Report, in backup: URL, shareRoot: URL? = nil) throws {
        var report = report
        if let paths = report.createdFiles { report.createdFiles = try backupRelativePaths(paths, shareRoot: shareRoot) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: backup.appending(path: "report.json"), options: .atomic)
    }

    /// 백업을 만든 모든 경로(쓰기·곡 넣기·빼기·iTunes 동기화·복원)가 끝에 부른다(#221).
    /// 쓰기 백업만 센다. 남길 수는 폴더 이름의 시각(`backupStamp`)으로 최근 24시간 안의 쓰기 백업 수를 `backupsToKeep`~`backupsToKeepMax`로
    /// 맞춘 값이다(R13: 자동 저장이 잦아도 하루 안의 저장 전 상태는 남긴다. 시각을 읽지 못하는 이름은 이 예외에 넣지 않는다).
    /// 그 수를 넘으면, 남길 가장 옛 쓰기 백업보다 옛 백업(복원 직전 포함)을 지운다.
    /// 복원 직전 백업은 세지 않되 사이의 것을 지우지 않는다: 옛 백업으로 되돌릴 때 그 뒤 백업을 모두 거쳐야 한다(#222 연쇄 복원).
    /// 시점 복원 표시(#225)도 같은 순서로 세어 그보다 옛 쓰기 백업이 정리될 때 함께 지운다.
    /// 남은 미정리 목록(R22)과 중단 기록(R11)이 가리키는 폴더는 지우지 않는다. 목록을 읽지 못하면 무엇을 지킬지 몰라 솎지 않는다.
    static func prune(_ directory: URL, now: Date = .now) {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { fm.fileExists(atPath: $0.appending(path: "master.db").path) || isPointRestoreMarker($0) }
            .sorted { isNewer($0, than: $1) }
        let writes = folders.indices.filter { Backup.isWriteName(folders[$0].lastPathComponent) }
        let recent = writes.filter { index in
            backupDate(folders[index]).map { now.timeIntervalSince($0) < recentBackupWindow } ?? false
        }.count
        let keep = min(max(recent, backupsToKeep), backupsToKeepMax)
        guard writes.count > keep, let protected = try? protectedBackupFolders(in: directory) else { return }
        for old in folders.dropFirst(writes[keep - 1] + 1) where !protected.contains(old.lastPathComponent) { try? fm.removeItem(at: old) }
    }

    /// 백업 이름 앞의 뜬 시각(`makeBackup`과 같은 형식·시간대). 읽지 못하면 nil
    static func backupDate(_ folder: URL) -> Date? {
        guard let stamp = backupStamp(folder) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        return formatter.date(from: stamp)
    }

    /// 솎기에서 뺄 백업 폴더(백업 루트 바로 아래 이름): 남은 미정리 목록이 가리키는 폴더(R22)와 남은 중단 기록이 가리키는 폴더(R11).
    /// 읽지 못하는 미정리 목록이 있으면 던진다(무엇을 지킬지 모른다)
    public static func protectedBackupFolders(in directory: URL) throws -> Set<String> {
        try DraftCleanupList.protectedBackupFolders(cleanupLists(in: directory)).union(journalFolders(in: directory))
    }

    /// 백업 목록(최근 것부터)
    public static func backups(in directory: URL) -> [Backup] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { fm.fileExists(atPath: $0.appending(path: "master.db").path) }
            .map { folder in
                let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let name = folder.lastPathComponent
                return Backup(url: folder, createdAt: created, isWrite: Backup.isWriteName(name),
                              report: contents(of: folder).report, trackReport: RekordboxTrackWriter.report(in: folder))
            }
            // 같은 초에 뜬 백업도 뜬 순서대로(이름 끝은 순서와 상관없다, `isNewer`)
            .sorted { isNewer($0.url, than: $1.url) }
    }

    /// 백업으로 되돌린다. 되돌리기 직전 상태도 따로 백업해 둔다.
    /// 버전·DB 구조는 보지 않는다(되돌리기는 DJCrate가 쓴 것을 무르는 비상구라 막지 않는다). rekordbox 실행만 막는다.
    /// 가장 최근이 아닌 백업이면 그 뒤 백업들의 분석·그림 파일도 최신부터 차례로 되돌린다(#222, `laterBackups`).
    /// 하나라도 되돌릴 수 없으면 아무것도 바꾸지 않고 거부하며, 도중에 실패하면 복원 전으로 돌린다.
    @discardableResult
    public static func restore(_ backup: URL, to database: URL, now: Date = .now,
                               backups: URL, guard writeGuard: RekordboxWriteGuard = .system, shareRoot: URL? = nil) throws -> URL {
        let copyShare = writeGuard.isLive(database) ? nil : database.deletingLastPathComponent().appending(path: "share")
        let share = try writeGuard.resolveShareRoot(database, shareRoot: shareRoot ?? copyShare)
            ?? database.deletingLastPathComponent().appending(path: "share")
        if writeGuard.isLive(database) {
            guard !writeGuard.isRekordboxRunning() else {
                throw DJCError.writeRefused(String(ui: "rekordbox가 켜져 있습니다. rekordbox를 완전히 종료한 뒤 되돌리세요"))
            }
        }
        // 쓰기 잠금(R9). 중단 기록이 남았으면 그 기록의 백업으로 되돌리는 것만 받아 기록으로 복원한다(R11: 다른 백업·시점은 막는다).
        // 복원 실패 안내의 명령(`djc rekordbox-restore --backup <그 백업>`)과 앱의 "가장 최근 백업으로 되돌리기"가 이 길로 간다
        let run = try WriteRun.locked(database, guard: writeGuard, backups: backups)
        defer { run.close() }
        switch try run.judge() {
        case .none: break
        case .undecided: throw DJCError.rekordboxRunning
        case let .interrupted(journal, _, _):
            guard journal.entry != .pointRestore, let recorded = journal.basis.writeBackup,
                  URL(filePath: recorded).standardizedFileURL.comparablePath == backup.standardizedFileURL.comparablePath else {
                throw interruptedRefusal
            }
            switch try restoreByJournal(journal, run: run, backups: backups, shareRoot: share, now: now) {
            case let .restored(saved): return saved ?? backup
            case .alreadyRestored: return backup
            }
        }
        try checkSameLibrary(backup: backup.appending(path: "master.db"), target: database)
        // 이 백업 뒤에 시점 스냅샷으로 복원했으면 사슬로 분석 파일을 맞출 수 없다(#225).
        if let reason = pointRestoreRefusal(after: backup, in: backups) { throw DJCError.writeRefused(reason) }
        if let saved = try restoreITunesSync(backup, to: database, now: now, backups: backups, guard: writeGuard, run: run) { return saved }
        // 백업이 멀쩡한지 먼저 본다.
        for name in ["master.db", "master.db-wal", "master.db-shm", "masterPlaylists6.xml"] {
            try validateBackupFile(backup.appending(path: name), under: backup, required: name == "master.db")
        }
        try checkIntegrity(of: backup.appending(path: "master.db"))
        let later = try laterBackups(than: backup, in: backups)
        for newer in later {
            do {
                try validateBackupFile(newer.appending(path: "master.db"), under: newer, required: true)
                try checkSameLibrary(backup: newer.appending(path: "master.db"), target: database)
            } catch { throw laterBackupRefusal(newer, error) }
        }
        // 한 경로라도 잘못됐으면 DB와 복원 전 백업까지 모두 그대로 둔다.
        let (steps, touched) = try restoreSteps(later + [backup], database: database, shareRoot: share)
        let saved = try makeBackup(of: database, in: backups, now: now, label: "before-restore")
        try saveRestoreUndo(touched, in: saved, restoredFrom: backup, now: now, shareRoot: share)
        // 첫 변경 직전에 파일 쓰기 기록을 남긴다(R11). 기록으로 복원은 같은 복원을 다시 한다: DB·XML은 고른 백업에서, 파일은 사슬 끝의 상태로
        do {
            try run.recheck(.databaseReplace)
            try run.begin(RekordboxWriteJournal(operationID: UUID().uuidString, kind: .files, entry: .restore,
                                                basis: .init(writeBackup: backup.path), files: restoreJournalFiles(steps)))
        } catch {
            throw run.abandon(error)
        }
        do {
            try restoreFiles(from: backup, to: database, run: run)
            try applyRestoreSteps(steps, run: run)
            try run.step(.verify, recheck: false) { try checkIntegrity(of: database) }
        } catch {
            // 아직 아무것도 바꾸지 않았으면(준비 사본을 만든 뒤 켜짐 등) 기록을 지우고 보류·실패로 끝낸다
            if !run.changed || error is RekordboxWriteStop { throw run.abandon(error) }
            if let passed = run.passThrough(error) { throw passed }
            throw rollbackRestore(error, saved: saved, database: database, touched: touched, live: writeGuard.isLive(database), run: run)
        }
        try finishRun(run, backup: saved, backups: backups, list: nil, now: now)
        return saved
    }

    /// 연쇄 복원이 끝난 뒤 파일마다의 상태(쓰기 기록에 적는다): 마지막으로 되살린 백업 안 원본, 지운 파일은 원본 없음
    static func restoreJournalFiles(_ steps: [RestoreStep]) -> [RekordboxWriteJournal.File] {
        var order: [String] = [], final: [String: String?] = [:]
        func set(_ path: String, _ original: String?) {
            if final[path] == nil { order.append(path) }
            final[path] = .some(original)
        }
        for step in steps {
            for file in step.analysis { set(file.target.path, file.source.path) }
            for file in step.created { set(file.path, nil) }
        }
        return order.map { RekordboxWriteJournal.File(path: $0, original: final[$0] ?? nil) }
    }

    /// 다른 라이브러리(`djmdProperty.DBID`가 다름)의 백업은 되돌리지 않는다(#182: 합성 사본의 백업이 실제 라이브러리로 되돌려졌다).
    /// 대상이 없거나 읽히지 않으면(망가진 라이브러리의 비상 복원) 막지 않는다.
    static func checkSameLibrary(backup: URL, target: URL) throws {
        guard let source = libraryID(of: backup), let current = libraryID(of: target), source != current else { return }
        throw DJCError.writeRefused(String(ui: "다른 rekordbox 라이브러리에서 뜬 백업입니다. 이 라이브러리의 백업을 고르세요"))
    }

    static func libraryID(of database: URL) -> String? {
        guard FileManager.default.fileExists(atPath: database.path),
              let db = try? CipherDatabase(path: database.path, key: RekordboxKey.derive()) else { return nil }
        defer { db.close() }
        var ids: [String] = []
        try? db.query("SELECT DBID FROM djmdProperty") { ids.append($0.string(0) ?? "") }
        return ids.count == 1 && !ids[0].isEmpty ? ids[0] : nil
    }

    /// 분석 파일 원본을 백업 폴더 `anlz/`에 둔다(원래 경로는 manifest.json).
    /// - Returns: 원래 파일 경로 → 백업 안 사본(쓰기 기록이 되돌릴 근거로 적는다)
    @discardableResult
    static func backupAnalysis(_ plans: [RekordboxGridWriter.Plan], in backup: URL, shareRoot: URL) throws -> [String: URL] {
        let folder = backup.appending(path: "anlz")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: String] = [:]
        var copies: [String: URL] = [:]
        for (i, plan) in plans.enumerated() {
            let dat = folder.appending(path: "\(i).DAT")
            try plan.originalDat.write(to: dat)
            manifest[dat.lastPathComponent] = try backupTarget(plan.datURL.path, shareRoot: shareRoot).relative
            copies[plan.datURL.path] = dat
            if let extURL = plan.extURL, let originalExt = plan.originalExt {
                let ext = folder.appending(path: "\(i).EXT")
                try originalExt.write(to: ext)
                manifest[ext.lastPathComponent] = try backupTarget(extURL.path, shareRoot: shareRoot).relative
                copies[extURL.path] = ext
            }
        }
        try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
        return copies
    }

    /// 쓰기가 실패했을 때 백업의 분석 파일을 원래 자리로 되돌린다.
    static func restoreAnalysis(from backup: URL, shareRoot: URL) throws {
        try applyRestoreSteps([RestoreStep(backup: backup, analysis: analysisRestoreFiles(from: backup, shareRoot: shareRoot), created: [])])
    }

    /// DB·XML 되돌리기에서 실패한 것(꼬리표를 붙여)
    struct RestoreFilesError: Error, CustomStringConvertible {
        var problems: [String]
        var description: String { problems.joined(separator: " / ") }
    }

    /// 백업의 master.db(-wal·-shm)를 되살리고, 그게 끝난 뒤에만 masterPlaylists6.xml을 되살린다(쓰기 실패 뒤 되돌리기와 "쓰기 전으로 복원…"이
    /// 같이 쓴다). XML은 원자적으로 써서 반쯤 쓰인 상태가 없으므로, DB 복원이 실패하면 XML도 지금 상태로 두어 재생 목록 구조가 DB와 어긋나지 않게 한다.
    /// 쓰기 기록(`run`)이 있으면 DB 교체·`-wal`·`-shm` 삭제·XML 바꾸기 바로 직전마다 rekordbox 실행을 다시 보고(R10, 켜졌으면 그대로 멈춘다),
    /// DB 교체 전에 준비 사본(`.djc-restore`)의 크기·시각을, 바꾼 뒤에 master.db 크기·시각을 기록에 적는다(R11).
    static func restoreFiles(from backup: URL, to database: URL, run: WriteRun? = nil) throws {
        let fm = FileManager.default
        do {
            for suffix in ["", "-wal", "-shm"] {
                let target = URL(filePath: database.path + suffix)
                let source = backup.appending(path: "master.db" + suffix)
                let step: RekordboxWriteStep = suffix.isEmpty ? .databaseReplace : .sidecarRemove
                if fm.fileExists(atPath: source.path) {
                    let partial = URL(filePath: database.path + suffix + ".djc-restore")
                    try? fm.removeItem(at: partial)
                    try fm.copyItem(at: source, to: partial)
                    if suffix.isEmpty, let run { try run.update { $0.restoreCopy = fileStamp(partial) } }
                    try run?.recheck(step)
                    try run?.before(step)
                    run?.changed = true
                    _ = try fm.replaceItemAt(target, withItemAt: partial)
                    if suffix.isEmpty { try run?.databaseChanged() }
                    try run?.after(step)
                } else if fm.fileExists(atPath: target.path) {
                    try run?.recheck(.sidecarRemove)
                    try run?.before(.sidecarRemove)
                    run?.changed = true
                    try fm.removeItem(at: target)
                    try run?.after(.sidecarRemove)
                }
            }
        } catch let error where error is RekordboxRunningSeen || error is RekordboxWriteStop {
            throw error
        } catch {
            throw RestoreFilesError(problems: ["master.db: \(DJCError.reason(of: error))"])
        }
        // 옛 백업에는 없다(그때는 XML을 고치지 않았다).
        let xml = backup.appending(path: "masterPlaylists6.xml")
        guard fm.fileExists(atPath: xml.path) else { return }
        do {
            // 이미 같은 내용이면(쓰기가 원자적으로 실패해 원본 그대로) 다시 쓰지 않는다.
            let data = try Data(contentsOf: xml), target = playlistXMLURL(for: database)
            if (try? Data(contentsOf: target)) != data {
                try run?.recheck(.fileReplace)
                try run?.before(.fileReplace)
                run?.changed = true
                try data.write(to: target, options: .atomic)
                try run?.after(.fileReplace)
            }
        } catch let error where error is RekordboxRunningSeen || error is RekordboxWriteStop {
            throw error
        } catch {
            throw RestoreFilesError(problems: ["masterPlaylists6.xml: \(DJCError.reason(of: error))"])
        }
    }


    public static func updateCount(of database: URL) throws -> Int {
        let db = try CipherDatabase(path: database.path, key: RekordboxKey.derive())
        return try localUpdateCount(db)
    }

    /// 백업에 둔 재생 목록 편집(되돌리면 초안으로 살린다)
    public static func playlistEdits(in backup: URL) -> [PlaylistEdit] {
        guard let data = try? Data(contentsOf: backup.appending(path: "playlist-edits.json")) else { return [] }
        return (try? JSONDecoder().decode([PlaylistEdit].self, from: data)) ?? []
    }

    /// 백업에 들어 있는 쓰기 보고서와 초안.
    /// 백업에 들어 있는 그리드 초안
}

/// 쓰기 전 백업 이름 규칙
extension RekordboxWriteBackup {
    /// 쓰기 직전 백업의 이름 끝(`makeBackup`의 label)
    static let writeLabels = ["-write", "-add", "-delete"]

    /// 쓰기 직전 백업 이름인지. 같은 초에 뜬 백업은 끝에 `-2`·`-3`…이 붙는다.
    static func isWriteName(_ name: String) -> Bool {
        let base = name.replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
        return writeLabels.contains { base.hasSuffix($0) }
    }
}

extension RekordboxWriter {
    /// 자동 저장의 백업 조건(R13) 재료: 백업 폴더가 대상 master.db와 같은 볼륨이라 클론이 되는지, 그 볼륨의 여유 공간, master.db 크기.
    /// 쓰기 전 백업(`makeBackup`)은 같은 APFS 볼륨이면 클론으로 뜬다
    public struct BackupVolume: Equatable, Sendable {
        public var canClone: Bool
        /// 백업 폴더 볼륨의 여유 공간(바이트, 모르면 nil)
        public var available: Int64?
        /// master.db 크기(모르면 nil)
        public var databaseSize: Int64?

        public init(canClone: Bool, available: Int64?, databaseSize: Int64?) {
            self.canClone = canClone
            self.available = available
            self.databaseSize = databaseSize
        }
    }

    /// 백업 폴더(없으면 있는 가장 가까운 조상)와 대상 master.db로 잰다
    public static func backupVolume(backups: URL, database: URL) -> BackupVolume {
        var folder = backups
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 { folder = folder.deletingLastPathComponent() }
        let available = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        let size = (try? FileManager.default.attributesOfItem(atPath: database.path))?[.size] as? Int
        return BackupVolume(canClone: RekordboxPointSnapshot.canClone(from: database, to: backups), available: available,
                            databaseSize: size.map(Int64.init))
    }
}
