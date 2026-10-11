import DJCDomain
import Foundation

/// 연쇄 복원(#222). 백업은 DB 전체와 그 쓰기가 바꾸는 분석·그림 파일만 담는다. 그래서 가장 최근이 아닌 백업으로 되돌릴 때는
/// 그 뒤 백업들의 파일을 최신부터 차례로 되돌려야 DB와 분석 파일이 같은 시점을 가리킨다. DB·XML은 고른 백업 것 하나만 쓴다.
extension RekordboxWriter {
    /// 복원 한 단계: 한 백업이 되돌리는 파일(쓰기 전 내용으로 되살릴 파일, 그 쓰기가 만들어 지울 파일)
    struct RestoreStep {
        var backup: URL
        var analysis: [AnalysisRestoreFile]
        var created: [URL]
    }

    /// 연쇄 복원이 건드리는 파일 하나와 복원 전 내용(없었으면 nil), 복원 뒤 있는지
    struct TouchedFile {
        var url: URL
        var relative: String
        var original: Data?
        var existsAfter: Bool
    }

    /// 고른 백업보다 뒤에 뜬 백업(최신부터). iTunes 동기화만 담은 백업은 DB·분석 파일을 바꾸지 않아 뺀다.
    /// 백업 폴더 밖의 백업은 이름의 시각으로 순서를 정하고, 이름에 시각이 없으면 그 뒤 쓰기를 알 수 없어 거부한다.
    public static func laterBackups(than backup: URL, in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        let selected = backup.standardizedFileURL
        let folders = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { fm.fileExists(atPath: $0.appending(path: "master.db").path) }
            .filter { $0.standardizedFileURL.comparablePath != selected.comparablePath }
        let inside = selected.deletingLastPathComponent().comparablePath == directory.standardizedFileURL.comparablePath
        if !inside, backupStamp(selected) == nil, !folders.isEmpty {
            throw invalidBackup(String(ui: "백업 폴더 밖에 있고 이름에 뜬 시각이 없어 그 뒤 쓰기를 알 수 없음"))
        }
        return folders.filter { isNewer($0, than: selected) && !isITunesSyncOnly($0) }
            .sorted { isNewer($0, than: $1) }
    }

    /// 백업 이름 앞의 뜬 시각(`yyyy-MM-ddTHHmmss`)
    static func backupStamp(_ folder: URL) -> String? {
        let stamp = String(folder.lastPathComponent.prefix(17))
        guard stamp.count == 17, stamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{6}$"#, options: .regularExpression) != nil else { return nil }
        return stamp
    }

    /// 이름의 시각(초 단위)을 먼저 보고, 같은 초면 폴더를 만든 시각으로 가린다. 이름 끝(-write·-delete·-before-restore)은
    /// 뜬 순서와 상관이 없어 같은 초에 쓰고 빼면 이름 순서가 뒤바뀐다.
    static func isNewer(_ a: URL, than b: URL) -> Bool {
        let stampA = backupStamp(a) ?? "", stampB = backupStamp(b) ?? ""
        if stampA != stampB { return stampA > stampB }
        func created(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast }
        let createdA = created(a), createdB = created(b)
        if createdA != createdB { return createdA > createdB }
        return a.lastPathComponent > b.lastPathComponent
    }

    static func isITunesSyncOnly(_ backup: URL) -> Bool {
        ["itunes-sync-before.xml", "itunes-sync-after.xml"].contains { FileManager.default.fileExists(atPath: backup.appending(path: $0).path) }
    }

    /// 단계마다 되돌릴 파일을 미리 모두 확인한다(하나라도 안 되면 아무것도 바꾸지 않는다). 지울 파일의 소유권은 그 단계에서의 DB로 본다:
    /// 첫 단계는 지금 DB, 그 뒤는 바로 앞(더 최근) 백업의 DB다. 파일이 있는지도 앞 단계를 되돌린 뒤 상태로 셈한다.
    static func restoreSteps(_ chain: [URL], database: URL, shareRoot: URL) throws -> (steps: [RestoreStep], touched: [TouchedFile]) {
        let fm = FileManager.default
        func key(_ url: URL) -> String { url.path.precomposedStringWithCanonicalMapping.lowercased() }
        var exists: [String: Bool] = [:]
        var touched: [String: TouchedFile] = [:], order: [String] = []
        func touch(_ url: URL, relative: String, existsAfter: Bool) throws {
            let k = key(url)
            if touched[k] == nil {
                let original = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
                touched[k] = TouchedFile(url: url, relative: relative, original: original, existsAfter: existsAfter)
                order.append(k)
            }
            touched[k]?.existsAfter = existsAfter
            exists[k] = existsAfter
        }
        var steps: [RestoreStep] = []
        var current = database
        for (index, backup) in chain.enumerated() {
            do {
                let analysis = try analysisRestoreFiles(from: backup, shareRoot: shareRoot)
                let created = try createdRestoreFiles(from: backup, database: current, shareRoot: shareRoot) {
                    exists[key($0)] ?? fm.fileExists(atPath: $0.path)
                }
                try rejectDuplicateTargets(analysis.map(\.target) + created)
                for file in analysis { try touch(file.target, relative: file.relative, existsAfter: true) }
                for file in created { try touch(file, relative: try backupTarget(file.path, shareRoot: shareRoot).relative, existsAfter: false) }
                steps.append(RestoreStep(backup: backup, analysis: analysis, created: created))
            } catch where index < chain.count - 1 {
                throw laterBackupRefusal(backup, error)
            }
            current = backup.appending(path: "master.db")
        }
        return (steps, order.compactMap { touched[$0] })
    }

    static func laterBackupRefusal(_ backup: URL, _ error: any Error) -> DJCError {
        .writeRefused(String(ui: "고른 백업 뒤에 뜬 백업(\(backup.lastPathComponent))까지 차례로 되돌려야 분석 파일이 DB와 맞는데 그 백업을 되돌릴 수 없어 복원하지 않았습니다: \(DJCError.reason(of: error))"))
    }

    /// 복원 직전 백업에 복원이 건드릴 파일의 지금 내용을 두고(`anlz/`), 복원이 새로 만들 파일은 보고서의 만든 파일로 적는다.
    /// 그래서 이 백업으로 되돌리면 분석·그림 파일까지 복원 전으로 돌아온다(복원이 되살린 파일도 지운다).
    static func saveRestoreUndo(_ touched: [TouchedFile], in saved: URL, restoredFrom backup: URL, now: Date, shareRoot: URL) throws {
        let folder = saved.appending(path: "anlz")
        var manifest: [String: String] = [:]
        for (index, file) in touched.enumerated() {
            guard let original = file.original else { continue }
            if manifest.isEmpty { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let name = "restore-\(index).\(file.url.pathExtension)"
            try original.write(to: folder.appending(path: name))
            manifest[name] = file.relative
        }
        if !manifest.isEmpty { try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"), options: .atomic) }
        let created = touched.filter { $0.original == nil && $0.existsAfter }
        guard !created.isEmpty else { return }
        var report = Report(outcomes: [], backup: saved.path, dryRun: false, createdAt: CueJSON.timestamps(now).json,
                            finalUpdateCount: try? updateCount(of: backup.appending(path: "master.db")))
        report.createdFiles = created.map(\.relative)
        try save(report, in: saved, shareRoot: shareRoot)
    }

    /// 단계마다 분석·그림 파일을 쓰기 전 내용으로 되살리고, 그 쓰기가 만든 파일을 지운다(최신 단계부터).
    static func applyRestoreSteps(_ steps: [RestoreStep]) throws {
        let fm = FileManager.default
        for step in steps {
            for file in step.analysis {
                // 곡을 지우면서 폴더째 지운 경우가 있다.
                try fm.createDirectory(at: file.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: file.target, options: .atomic)
            }
            try removeOwnedFiles(step.created.filter { fm.fileExists(atPath: $0.path) })
        }
    }

    /// 복원 도중 실패하면 DB·XML·건드린 파일을 복원 전으로 돌린다. 그것도 못 하면 복원 직전 백업으로 되돌릴 명령을 준다.
    static func rollbackRestore(_ failure: any Error, saved: URL, database: URL, touched: [TouchedFile], live: Bool) -> any Error {
        let fm = FileManager.default
        do {
            try restoreFiles(from: saved, to: database)
            for file in touched {
                if let original = file.original {
                    try fm.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? Data(contentsOf: file.url)) != original { try original.write(to: file.url, options: .atomic) }
                } else if fm.fileExists(atPath: file.url.path) {
                    try removeOwnedFiles([file.url])
                }
            }
            return failure
        } catch {
            return DJCError.restoreFailed(reason: DJCError.reason(of: failure), restoreError: DJCError.reason(of: error),
                                          backup: saved.path, database: live ? nil : database.path)
        }
    }
}
