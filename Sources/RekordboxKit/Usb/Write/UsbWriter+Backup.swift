import DJCDomain
import Foundation

/// C 백업(맥): DB 파일·사이드카, 덮어쓸 파일, 지울 파일(음원 빼고)과 원래 있던 `._<이름>`.
/// 파일마다 복사 전후 크기·mtime이 같아야 하고, 복사본은 F_FULLFSYNC한다. manifest와 저널 backedUp이 디스크에 내려간 뒤에만 D로 간다.
extension UsbWriteRun {
    struct SourceChanged: Error { var path: String }

    func backup(_ changes: UsbChangeSet) throws {
        do {
            try ensureSameVolume()
        } catch {
            // 아직 USB에 쓴 것이 없다. 저널은 staged 그대로 두고 회복이 닫는다
            throw volumeGone
        }
        emit(.backup, cancellable: true)
        var folder: URL?
        do {
            try requireBackupBase(changes)
            let created = try makeBackupFolder(label: changes.label)
            folder = created
            backupFolder = created
            let completed = try makeManifest(changes, in: created)
            manifest = completed
            try requireBackupBase(changes)
            try requireManifestBase(completed, changes: changes)
            // 일반 USB도 복원할 수 있는 계획 기준의 백업을 모두 갖춘 뒤에만 D·E로 간다.
            try requireManifestCoverage(completed)
            try UsbDurableFile.write(completed, to: created.appending(path: "manifest.json"), fileSystem: fs)
            journal.backupManifestSHA256 = try fs.sha256(created.appending(path: "manifest.json"), uncached: true)
            try requireBackupBase(changes)
            journal.backupDirectory = created.path
            try journal.move(to: .backedUp)
            try saveJournal()
        } catch UsbWriteFailure.volumeLost {
            throw volumeGone
        } catch {
            // USB에 쓴 것이 없으니 백업 폴더를 지우고 저널을 닫는다
            if let folder { try? FileManager.default.removeItem(at: folder) }
            backupFolder = nil
            journal.backupDirectory = nil
            journal.backupManifestSHA256 = nil
            if (try? journal.move(to: .rolledBack)) != nil { try? saveJournal() }
            if let changed = error as? SourceChanged {
                throw UsbError.writeRefused([UsbBlock(code: "sourceChangedDuringCopy", scope: .file(changed.path),
                                                      message: String(ui: "백업하는 동안 USB 파일이 바뀌었습니다. 다른 프로그램이 USB를 쓰지 않는지 확인한 뒤 다시 시도하세요"))])
            }
            throw UsbError.writeRolledBack(reason: String(describing: error))
        }
    }

    /// `usb-backups/<볼륨키>/<yyyy-MM-dd'T'HHmmss>-<이름>/`(같은 초면 -2, -3…)
    func makeBackupFolder(label: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let safe = String(label.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(40))
        let stem = formatter.string(from: now) + "-" + (safe.isEmpty ? "write" : safe)
        let base = paths.backups.appending(path: volumeKey)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var name = stem
        var suffix = 2
        while FileManager.default.fileExists(atPath: base.appending(path: name).path) {
            name = stem + "-\(suffix)"
            suffix += 1
        }
        let folder = base.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    func makeManifest(_ changes: UsbChangeSet, in folder: URL) throws -> UsbManifest {
        var manifest = UsbManifest(volumeUUID: volumeKey, volumeName: volume.name, appVersion: UsbManifest.currentAppVersion,
                                   session: changes.session, createdAt: Date())
        let audioRemovals = changes.removals.filter { UsbPath.isAudio($0.path) }
        var copyList = UsbWriter.databaseBackupFiles
        copyList += changes.writes.filter { $0.disposition == .overwrite }.map(\.destination)
        copyList += changes.removals.filter { !UsbPath.isAudio($0.path) }.map(\.path)
        // 되돌린 뒤 쓰기 전과 같아야 하는 경로(파일만)
        var touched = copyList
        touched += changes.copies.filter { $0.disposition == .create }.map(\.destination)
        touched += changes.writes.filter { $0.disposition == .create }.map(\.destination)
        touched += changes.databases.map(\.destination)
        touched += audioRemovals.map(\.path)
        touched = unique(touched)
        let companions = touched.compactMap(UsbRemovalPolicy.appleDoubleCompanion(of:))

        for path in unique(copyList) {
            try ensureMounted()
            guard let info = try fs.stat(usb(path)) else { continue }
            guard info.kind == .file else { throw UsbWriteFailure.failed("not a regular file: \(path)") }
            manifest.files[path] = try backupFile(path, info: info, into: folder)
        }
        for companion in unique(companions) {
            try ensureMounted()
            guard let info = try fs.stat(usb(companion)), info.kind == .file else { continue }
            manifest.files[companion] = try backupFile(companion, info: info, into: folder)
            manifest.appleDoublesPreexisting.append(companion)
        }
        for removal in audioRemovals {
            guard let info = try fs.stat(usb(removal.path)), info.kind == .file else { continue }
            manifest.removedAudio.append(.init(path: removal.path, localOriginal: removal.localOriginal,
                                               localOriginalSHA1: removal.localOriginalSHA1, size: info.size,
                                               sha256: removal.expectedSHA256, modificationDate: info.modificationDate))
        }
        for path in unique(touched + companions) {
            if let stamp = manifest.files[path] {
                manifest.before[path] = UsbTreeStamp(size: stamp.size, sha256: stamp.sha256)
            } else if let audio = manifest.removedAudio.first(where: { $0.path == path }) {
                // 음원은 백업하지 않는다(크기만 비교)
                manifest.before[path] = UsbTreeStamp(size: audio.size, sha256: nil)
            } else if try fs.stat(usb(path)) == nil {
                manifest.absentBefore.append(path)
            }
        }
        return manifest
    }

    /// USB 파일 하나를 백업 폴더 `files/<상대 경로>`로(데이터만). 복사하는 동안 바뀌면 `SourceChanged`
    func backupFile(_ path: String, info before: UsbFileStat, into folder: URL) throws -> UsbFingerprint.Stamp {
        let destination = folder.appending(path: "files").appending(path: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let copied = try fs.copyDataNew(from: usb(path), to: destination) { _ in }
        try fs.fullSync(destination)
        guard let after = try fs.stat(usb(path)), after.size == before.size, after.modificationDate == before.modificationDate,
              copied.size == before.size, try fs.sha256(usb(path), uncached: true) == copied.sha256 else { throw SourceChanged(path: path) }
        return .init(size: copied.size, mtime: before.modificationDate, sha256: copied.sha256)
    }

    /// base의 DB family 또는 빈 내보내기의 생성 DB·OneLibrary 사이드카만 기준으로 삼는다. bak는 범위 밖이다.
    func backupBaseDatabasePaths(_ changes: UsbChangeSet) -> [String] {
        if changes.base != nil || changes.syncSelection != nil { return UsbWriter.databaseFamily }
        guard changes.purpose == .export else { return [] }
        // A의 빈 USB 확인·생성 계획이 전제한 부재다. 파일만 쓰기·미계획 형식까지 넓히지 않는다.
        let created = Set(journal.plannedDatabases.filter { $0.disposition == .created && $0.oldSHA256 == nil }.map(\.destination))
        return unique(changes.databases.filter { created.contains($0.destination) }.flatMap { database in
            [database.destination] + (database.destination == UsbLayout.oneLibrary && database.format == .oneLibrary
                ? UsbLayout.oneLibrarySidecarSuffixes.map { database.destination + $0 } : [])
        })
    }

    func requireBackupBase(_ changes: UsbChangeSet) throws {
        for path in backupBaseDatabasePaths(changes) {
            let stamp = changes.base?.files[path]
            guard try classifyFile(path, old: stamp?.sha256, new: nil) == .old else { throw SourceChanged(path: path) }
            if let stamp, try fs.stat(usb(path))?.size != stamp.size { throw SourceChanged(path: path) }
        }
        guard changes.syncSelection != nil else { return }
        for write in changes.writes where UsbSyncSelectionStage.isSelectionPath(write.destination) {
            guard try classifyFile(write.destination, old: write.expectedExistingSHA256, new: nil) == .old else {
                throw SourceChanged(path: write.destination)
            }
        }
    }

    func requireManifestBase(_ manifest: UsbManifest, changes: UsbChangeSet) throws {
        for path in backupBaseDatabasePaths(changes) {
            let expected = changes.base?.files[path]
            guard manifest.files[path]?.sha256 == expected?.sha256, manifest.files[path]?.size == expected?.size,
                  expected != nil || manifest.absentBefore.contains(path) else { throw SourceChanged(path: path) }
        }
        guard changes.syncSelection != nil else { return }
        for write in changes.writes where UsbSyncSelectionStage.isSelectionPath(write.destination) {
            guard manifest.files[write.destination]?.sha256 == write.expectedExistingSHA256,
                  write.expectedExistingSHA256 != nil || manifest.absentBefore.contains(write.destination) else {
                throw SourceChanged(path: write.destination)
            }
        }
    }

    func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    /// 복원은 승인 여부와 무관하게 기록·모든 백업의 경로와 내용을 USB 연산 전에 검증한다.
    func loadValidatedBackup() throws {
        guard let backupFolder, isOurBackupFolder(backupFolder),
              try fs.stat(backupFolder)?.kind == .directory,
              journal.volumeUUID.uppercased() == volumeKey,
              try fs.stat(backupFolder.appending(path: "manifest.json"))?.kind == .file,
              let loaded = try? UsbJournal.decoder().decode(UsbManifest.self, from: Data(contentsOf: backupFolder.appending(path: "manifest.json"))),
              loaded.session == journal.session, loaded.volumeUUID.uppercased() == volumeKey,
              UsbWriter.unsafeEntries(in: journal).isEmpty, UsbWriter.unsafeEntries(in: loaded).isEmpty else {
            throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
        }
        if let expected = journal.backupManifestSHA256,
           try fs.sha256(backupFolder.appending(path: "manifest.json"), uncached: true) != expected {
            throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
        }
        do { try requireManifestBase(loaded, changes: journal.changes) }
        catch { throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock]) }
        let absent = Set(loaded.absentBefore)
        guard absent.count == loaded.absentBefore.count, absent.isDisjoint(with: loaded.files.keys), absent.isDisjoint(with: loaded.before.keys),
              absent.isDisjoint(with: loaded.removedAudio.map(\.path)),
              loaded.files.allSatisfy({ path, stamp in
                  loaded.before[path]?.sha256 == stamp.sha256 && loaded.before[path]?.size == stamp.size
              }) else { throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock]) }
        try requireManifestCoverage(loaded)
        let known = Set(loaded.files.keys).union(absent).union(loaded.before.keys)
        guard Set((journal.restorationBaseline ?? [:]).keys).isSubset(of: known) else {
            throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
        }
        for entry in journal.sidecarDeletions ?? [] {
            guard known.contains(entry.destination), entry.expectedSHA256 == loaded.files[entry.destination]?.sha256 else {
                throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
            }
        }
        for entry in journal.restorations ?? [] {
            guard known.contains(entry.destination),
                  entry.operation != .replace || (entry.backupSHA256 != nil && entry.backupSHA256 ==
                      (loaded.files[entry.destination]?.sha256 ?? loaded.removedAudio.first { $0.path == entry.destination }?.sha256)),
                  entry.operation != .delete || absent.contains(entry.destination) else {
                throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
            }
            if journal.changes.syncSelection != nil, !discardingRestorationChanges, let expected = entry.expectedSHA256,
               UsbWriter.databaseFamily.contains(entry.destination) || UsbSyncSelectionStage.isSelectionPath(entry.destination) {
                let old = UsbWriter.databaseFamily.contains(entry.destination) ? journal.base?.files[entry.destination]?.sha256
                    : journal.changes.writes.first(where: { $0.destination == entry.destination })?.expectedExistingSHA256
                let new = journal.databases.first(where: { $0.destination == entry.destination })?.newSHA256
                    ?? journal.entries.first(where: { $0.destination == entry.destination })?.newSHA256
                guard expected == old || expected == new else { throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock]) }
            }
        }
        for (path, stamp) in loaded.files {
            let source = try validatedBackupFile(path)
            guard let info = try fs.stat(source), info.kind == .file, info.size == stamp.size,
                  try fs.sha256(source, uncached: true) == stamp.sha256 else {
                throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
            }
        }
        manifest = loaded
    }

    /// 백업에 남아 있는 항목만 검사하면 files·before를 함께 지운 손상을 놓친다.
    /// 원래 계획·진행 기록의 전체 범위를 먼저 대조한다. 이 단계는 USB 파일 연산을 하지 않는다.
    func requireManifestCoverage(_ loaded: UsbManifest) throws {
        let absent = Set(loaded.absentBefore)
        func refuse() throws -> Never { throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock]) }
        func backup(_ path: String, sha256: String? = nil, size: Int64? = nil) throws {
            guard let stamp = loaded.files[path], !stamp.sha256.isEmpty, stamp.size >= 0,
                  let before = loaded.before[path], before.sha256 == stamp.sha256, before.size == stamp.size,
                  sha256 == nil || sha256 == stamp.sha256, size == nil || size == stamp.size else { try refuse() }
        }
        func missing(_ path: String) throws {
            guard absent.contains(path), loaded.files[path] == nil, loaded.before[path] == nil else { try refuse() }
        }
        func recorded(_ path: String) throws {
            if absent.contains(path) { try missing(path) } else { try backup(path) }
        }
        func disposition(_ path: String, _ kind: UsbJournal.FileDisposition, old: String?) throws {
            switch kind {
            case .created: try missing(path)
            case .overwritten:
                guard let old else { try refuse() }
                try backup(path, sha256: old)
            case .reused: break
            }
        }
        // C의 기준 검사와 같은 부재를 요구한다. 미계획 형식·bak는 백업 시점의 기존 처리를 유지한다.
        let basePaths = Set(backupBaseDatabasePaths(journal.changes))
        for path in UsbWriter.databaseBackupFiles {
            if let stamp = journal.base?.files[path] { try backup(path, sha256: stamp.sha256, size: stamp.size) }
            else if basePaths.contains(path) { try missing(path) }
            else { try recorded(path) }
        }
        for planned in journal.plannedDatabases {
            guard planned.disposition != .reused else { try refuse() }
            try disposition(planned.destination, planned.disposition, old: planned.oldSHA256)
        }
        for database in journal.changes.databases {
            guard let planned = journal.plannedDatabases.first(where: { $0.destination == database.destination }) else { try refuse() }
            try disposition(database.destination, planned.disposition, old: planned.oldSHA256)
        }
        for entry in journal.databases {
            guard entry.disposition != .reused else { try refuse() }
            try disposition(entry.destination, entry.disposition, old: entry.oldSHA256)
            for path in entry.sidecarsPreexisted { try backup(path) }
            if entry.appleDoublePreexisted, let companion = UsbRemovalPolicy.appleDoubleCompanion(of: entry.destination) { try backup(companion) }
        }
        for write in journal.changes.writes {
            switch write.disposition {
            case .overwrite:
                guard let old = write.expectedExistingSHA256 else { try refuse() }
                try backup(write.destination, sha256: old)
            case .create: try missing(write.destination)
            case .reuse: break
            }
        }
        for copy in journal.changes.copies where copy.disposition != .reuse {
            guard copy.disposition == .create else { try refuse() }
            try missing(copy.destination)
        }
        for entry in journal.entries {
            try disposition(entry.destination, entry.disposition, old: entry.oldSHA256)
            if entry.disposition != .reused, entry.appleDoublePreexisted,
               let companion = UsbRemovalPolicy.appleDoubleCompanion(of: entry.destination) { try backup(companion) }
        }
        func removal(_ path: String) throws {
            if absent.contains(path) { try missing(path); return }
            if !UsbPath.isAudio(path) { try backup(path); return }
            guard let audio = loaded.removedAudio.first(where: { $0.path == path }), !audio.sha256.isEmpty,
                  audio.size >= 0, loaded.files[path] == nil,
                  let before = loaded.before[path], before.size == audio.size, before.sha256 == nil else { try refuse() }
        }
        for item in journal.changes.removals { try removal(item.path) }
        for entry in journal.removals { try removal(entry.path) }
        for entry in journal.sidecarDeletions ?? [] {
            if let sha = entry.expectedSHA256 { try backup(entry.destination, sha256: sha) }
            else { try missing(entry.destination) }
        }
        for entry in journal.restorations ?? [] {
            switch entry.operation {
            case .replace:
                guard let sha = entry.backupSHA256 else { try refuse() }
                if loaded.files[entry.destination] != nil { try backup(entry.destination, sha256: sha) }
                else {
                    try removal(entry.destination)
                    guard loaded.removedAudio.contains(where: { $0.path == entry.destination && $0.sha256 == sha }) else { try refuse() }
                }
            case .delete: try missing(entry.destination)
            }
        }
        var touched = UsbWriter.databaseBackupFiles
        touched += journal.changes.writes.filter { $0.disposition != .reuse }.map(\.destination)
        touched += journal.changes.copies.filter { $0.disposition == .create }.map(\.destination)
        touched += journal.changes.databases.map(\.destination) + journal.changes.removals.map(\.path)
        for path in unique(touched).compactMap(UsbRemovalPolicy.appleDoubleCompanion(of:)) { try recorded(path) }
        for path in loaded.appleDoublesPreexisting { try backup(path) }
        // before-only는 백업하지 않는 삭제 음원에만 허용한다.
        for path in loaded.before.keys where loaded.files[path] == nil { try removal(path) }
        guard Set(loaded.removedAudio.map(\.path)).count == loaded.removedAudio.count else { try refuse() }
        for audio in loaded.removedAudio {
            guard UsbPath.isAudio(audio.path), journal.changes.removals.contains(where: { $0.path == audio.path }) else { try refuse() }
            try removal(audio.path)
        }
    }

    func validatedBackupFile(_ path: String) throws -> URL {
        guard let backupFolder, UsbWriter.isSafeRelativePath(path) else {
            throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
        }
        var url = backupFolder
        let parts = ["files"] + path.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            url = url.appending(path: part)
            guard let info = try fs.stat(url), info.kind == (index == parts.count - 1 ? .file : .directory) else {
                throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
            }
        }
        return url
    }
}
