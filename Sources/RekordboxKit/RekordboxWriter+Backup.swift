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
            return String(ui: "쓰기 보고서(report.json)를 백업에 다 저장하지 못해 ‘쓰기 전으로 복원…’이 이번에 만든 파일을 지우지 못할 수 있으니 백업 폴더를 확인하세요: \(DJCError.reason(of: error))")
        }
    }

    static func save(_ report: Report, in backup: URL, shareRoot: URL? = nil) throws {
        var report = report
        if let paths = report.createdFiles { report.createdFiles = try backupRelativePaths(paths, shareRoot: shareRoot) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: backup.appending(path: "report.json"), options: .atomic)
    }

    /// 백업을 만든 모든 경로(쓰기·곡 넣기·빼기·iTunes 동기화·복원)가 끝에 부른다(#221).
    /// 쓰기 백업만 세어 `backupsToKeep`개를 넘으면, 남길 가장 옛 쓰기 백업보다 옛 백업(복원 직전 포함)을 지운다.
    /// 복원 직전 백업은 세지 않되 사이의 것을 지우지 않는다: 옛 백업으로 되돌릴 때 그 뒤 백업을 모두 거쳐야 한다(#222 연쇄 복원).
    /// 시점 복원 표시(#225)도 같은 순서로 세어 그보다 옛 쓰기 백업이 정리될 때 함께 지운다.
    static func prune(_ directory: URL) {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { fm.fileExists(atPath: $0.appending(path: "master.db").path) || isPointRestoreMarker($0) }
            .sorted { isNewer($0, than: $1) }
        let writes = folders.indices.filter { Backup.isWriteName(folders[$0].lastPathComponent) }
        guard writes.count > backupsToKeep else { return }
        for old in folders.dropFirst(writes[backupsToKeep - 1] + 1) { try? fm.removeItem(at: old) }
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
        try checkSameLibrary(backup: backup.appending(path: "master.db"), target: database)
        // 이 백업 뒤에 시점 스냅샷으로 복원했으면 사슬로 분석 파일을 맞출 수 없다(#225).
        if let reason = pointRestoreRefusal(after: backup, in: backups) { throw DJCError.writeRefused(reason) }
        if let saved = try restoreITunesSync(backup, to: database, now: now, backups: backups, guard: writeGuard) { return saved }
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
        do {
            try saveRestoreUndo(touched, in: saved, restoredFrom: backup, now: now, shareRoot: share)
            try restoreFiles(from: backup, to: database)
            try applyRestoreSteps(steps)
            try checkIntegrity(of: database)
        } catch {
            throw rollbackRestore(error, saved: saved, database: database, touched: touched, live: writeGuard.isLive(database))
        }
        prune(backups)
        return saved
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
    static func backupAnalysis(_ plans: [RekordboxGridWriter.Plan], in backup: URL, shareRoot: URL) throws {
        let folder = backup.appending(path: "anlz")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: String] = [:]
        for (i, plan) in plans.enumerated() {
            let dat = folder.appending(path: "\(i).DAT")
            try plan.originalDat.write(to: dat)
            manifest[dat.lastPathComponent] = try backupTarget(plan.datURL.path, shareRoot: shareRoot).relative
            if let extURL = plan.extURL, let originalExt = plan.originalExt {
                let ext = folder.appending(path: "\(i).EXT")
                try originalExt.write(to: ext)
                manifest[ext.lastPathComponent] = try backupTarget(extURL.path, shareRoot: shareRoot).relative
            }
        }
        try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
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
    static func restoreFiles(from backup: URL, to database: URL) throws {
        let fm = FileManager.default
        do {
            for suffix in ["", "-wal", "-shm"] {
                let target = URL(filePath: database.path + suffix)
                let source = backup.appending(path: "master.db" + suffix)
                if fm.fileExists(atPath: source.path) {
                    let partial = URL(filePath: database.path + suffix + ".djc-restore")
                    try? fm.removeItem(at: partial)
                    try fm.copyItem(at: source, to: partial)
                    _ = try fm.replaceItemAt(target, withItemAt: partial)
                } else if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
            }
        } catch {
            throw RestoreFilesError(problems: ["master.db: \(DJCError.reason(of: error))"])
        }
        // 옛 백업에는 없다(그때는 XML을 고치지 않았다).
        let xml = backup.appending(path: "masterPlaylists6.xml")
        guard fm.fileExists(atPath: xml.path) else { return }
        do {
            // 이미 같은 내용이면(쓰기가 원자적으로 실패해 원본 그대로) 다시 쓰지 않는다.
            let data = try Data(contentsOf: xml), target = playlistXMLURL(for: database)
            if (try? Data(contentsOf: target)) != data { try data.write(to: target, options: .atomic) }
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
