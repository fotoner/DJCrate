import DJCDomain
import Darwin
import Foundation

/// H 되돌리기(D 이후 실패·취소·검증 실패)와 `usb-restore`.
/// 먼저 볼륨이 아직 붙어 있는지 보고(사라졌으면 되돌리지 않고 멈춘다), rekordbox가 켜져 있으면 미룬다.
/// 원래 쓰기와 복원의 temp·의도를 구분한다. 만든 것은 삭제 의도, 덮어쓴 것은 복사·rename 의도를 먼저 내린다.
/// 완료 기록이 늦은 중단은 해당 연산의 temp·해시로 판정하며, 발견한 외부 변경은 승인 전까지 보존한다.
extension UsbWriteRun {
    enum RollbackMode { case write, recover, restore }

    /// 되돌리기. 실패한 연산을 모아 돌려준다(빈 배열 = 되돌림). 볼륨이 사라지면 `UsbWriteFailure.volumeLost`
    func rollback(mode: RollbackMode) throws -> [String] {
        // 처음 USB의 백업으로 덮으므로, 그 자리의 볼륨이 처음 USB인지 다시 읽어 본다
        try ensureSameVolume()
        if writeGuard.isRekordboxRunning() {
            if journal.state != .restorePending { try journal.move(to: .restorePending) }
            try saveJournal()
            throw UsbError.restorePending(reason: String(ui: "rekordbox가 켜져 있습니다"))
        }
        emit(.restore, cancellable: false)
        try loadValidatedBackup()
        let discardChanges = mode == .restore && journal.discardDeviceChanges == true
        // 완료 항목의 후속 변경과 모호한 중단은 저장된 폐기 승인으로 넘기지 않는다.
        try adoptLegacyRestoreTemps()
        try checkRestorationProgress()
        if !discardChanges { try requireUnchangedNativeFiles() }
        // 자동 rollback도 방향을 먼저 내린다. 다시 켠 일반 USB 회복이 일부 복원된 DB를 앞으로 쓰지 않는다.
        if journal.state != .restorePending {
            try journal.move(to: .restorePending)
            try saveJournal()
        }
        var errors: [String] = []
        func attempt(_ what: String, _ body: () throws -> Void) throws {
            do {
                try ensureMounted()
                try body()
            } catch UsbWriteFailure.volumeLost {
                throw UsbWriteFailure.volumeLost
            } catch let error as UsbError {
                if case .restorePending = error { throw error }
                errors.append("\(what): \(error)")
            } catch {
                errors.append("\(what): \(error)")
            }
        }
        // F 되돌리기(검증 실패로 온 경우). 다시 복사하지 못한 음원은 removed로 남긴다(다음 되돌리기가 다시 해 본다)
        for index in journal.removals.indices.reversed() where journal.removals[index].state == .removed
            || (discardChanges && journal.restorationBaseline?[journal.removals[index].path] != nil) {
            let path = journal.removals[index].path
            try attempt(path) {
                if try restoreRemoved(path) {
                    journal.removals[index].state = .pending
                    try saveJournal()
                }
            }
        }
        if discardChanges, journal.changes.syncSelection != nil {
            let recorded = Set(journal.entries.map(\.destination))
            for write in journal.changes.writes where write.afterDatabases == true && !recorded.contains(write.destination) {
                try attempt(write.destination) {
                    if manifest?.files[write.destination] != nil { try restoreFromBackup(write.destination) }
                    else if manifest?.absentBefore.contains(write.destination) == true { try deleteForRollback(write.destination) }
                }
            }
        }
        // DB 뒤에 쓴 선택 파일부터 되돌려야 새 선택이 옛 DB를 가리키는 상태로 끝나지 않는다.
        let afterDB = Set(journal.changes.writes.filter { $0.afterDatabases == true }.map(\.destination))
        for entry in journal.entries.reversed() where afterDB.contains(entry.destination) {
            try attempt(entry.destination) {
                try rollbackFile(entry, discardChanges: discardChanges)
                if let index = journal.entries.firstIndex(where: { $0.destination == entry.destination }) {
                    journal.entries[index].rollbackCompleted = true
                    try saveJournal()
                }
            }
        }
        // E 되돌리기
        for entry in journal.databases.reversed() {
            try attempt(entry.destination) {
                try rollbackDatabase(entry, discardChanges: discardChanges)
                if let index = journal.databases.firstIndex(where: { $0.destination == entry.destination }) {
                    journal.databases[index].rollbackCompleted = true
                    try saveJournal()
                }
            }
        }
        if discardChanges, journal.changes.syncSelection != nil {
            // 선택만 바꾼 묶음도 DB 셋을 백업했다. 승인한 복원은 교체하지 않았던 DB·사이드카도 쓰기 전으로 돌린다.
            var handled = Set(journal.databases.map(\.destination))
            if journal.databases.contains(where: { $0.format == .oneLibrary }) {
                handled.formUnion(UsbLayout.oneLibrarySidecarSuffixes.map { UsbLayout.oneLibrary + $0 })
            }
            for path in UsbWriter.databaseFamily where !handled.contains(path) {
                try attempt(path) {
                    if manifest?.files[path] != nil { try restoreFromBackup(path) }
                    else if manifest?.absentBefore.contains(path) == true { try deleteForRollback(path) }
                }
            }
        }
        // D 되돌리기
        for entry in journal.entries.reversed() where !afterDB.contains(entry.destination) {
            try attempt(entry.destination) {
                try rollbackFile(entry, discardChanges: discardChanges)
                if let index = journal.entries.firstIndex(where: { $0.destination == entry.destination }) {
                    journal.entries[index].rollbackCompleted = true
                    try saveJournal()
                }
            }
        }
        // 실패한 복원의 temp는 다음 회복의 근거다. 실패 뒤 일괄 정리로 지우지 않는다.
        if !errors.isEmpty { return errors }
        for folder in journal.createdDirs.reversed() {
            try attempt(folder) {
                if try fs.removeDirectoryIfEmpty(usb(folder)) {
                    try removeExactAppleDouble(parent: UsbPath.parent(folder), name: UsbPath.name(folder))
                }
            }
        }
        if !errors.isEmpty { return errors }
        try checkRestorationProgress()
        try ensureMounted()
        let mismatches = try fingerprintMismatches()
        let nativePaths = nativeBaselinePaths
        let strict = mismatches.filter { mode != .restore || nativePaths.contains($0) }
        errors += strict.map { "fingerprint: \($0)" }
        if mode == .restore {
            report.notes += mismatches.filter { !nativePaths.contains($0) }.map { String(ui: "쓰기 전과 다른 파일이 남았습니다: \($0)") }
        }
        if errors.isEmpty { try attempt("temp") { try removeSessionTemps() } }
        return errors
    }

    var nativeBaselinePaths: Set<String> {
        guard journal.changes.syncSelection != nil else { return [] }
        return Set(UsbWriter.databaseFamily).union(journal.changes.writes.filter {
            $0.afterDatabases == true || UsbSyncSelectionStage.isSelectionPath($0.destination)
        }.map(\.destination))
    }

    /// 쓰기 전 지문(manifest)과 건드린 경로를 비교한다
    func fingerprintMismatches() throws -> [String] {
        guard let manifest else { return [] }
        var mismatches: [String] = []
        // 원본이 없거나 바뀌어 다시 복사하지 못한 음원은 알림으로 남겼다. 되돌릴 수 없는 것을 실패로 세면 회복이 끝나지 않는다
        let unrecoverable = Set(journal.removals.filter { $0.state == .removed && UsbPath.isAudio($0.path) }.map(\.path))
        for (path, stamp) in manifest.before.sorted(by: { $0.key < $1.key }) where !unrecoverable.contains(path) {
            guard let url = try? root.url(for: path), let info = try fs.stat(url), info.kind == .file, info.size == stamp.size else {
                mismatches.append(path)
                continue
            }
            if let expected = stamp.sha256, try fs.sha256(url, uncached: true) != expected { mismatches.append(path) }
        }
        // 쓰기 전에 없던 자리: 우리가 쓴 내용이 남았을 때만 틀린 것이다(그 사이 남이 만든 파일은 우리 것이 아니라 두었다)
        var ours: [String: String] = [:]
        for entry in journal.entries { if let sha = entry.newSHA256 { ours[entry.destination] = sha } }
        for entry in journal.databases { ours[entry.destination] = entry.newSHA256 }
        for path in manifest.absentBefore {
            if nativeBaselinePaths.contains(path) {
                // native DB·선택 파일은 남의 내용도 성공으로 인정하지 않는다. 링크도 부재가 아니다.
                if try classifyFile(path, old: nil, new: nil) != .old { mismatches.append(path) }
            } else if let sha = ours[path], let url = try? root.url(for: path), let info = try fs.stat(url), info.kind == .file {
                if try fs.sha256(url, uncached: true) == sha { mismatches.append(path) }
            }
        }
        return mismatches
    }

    func exists(_ relative: String) throws -> Bool { try fs.stat(usb(relative)) != nil }

    func removeIfPresent(_ relative: String) throws {
        // 명시한 폐기도 부모 링크를 거쳐 USB 밖의 파일을 지울 수는 없다. 끝 성분 링크는 unlink로만 제거한다.
        let parent = UsbPath.parent(relative)
        if !parent.isEmpty { _ = try root.url(for: parent) }
        guard try exists(relative) else { return }
        try ensureMounted()
        try fs.remove(usb(relative))
    }

    /// 이 파일이 우리가 쓴 새 내용인지(임시 파일이 없고 대상 해시 = 새 해시)
    func holdsNewContent(_ relative: String, newSHA256: String?, oldSHA256: String?) throws -> Bool {
        guard let newSHA256, let info = try fs.stat(usb(relative)), info.kind == .file else { return false }
        let sha = try fs.sha256(usb(relative), uncached: false)
        return sha == newSHA256 && sha != oldSHA256
    }

    func rollbackFile(_ entry: UsbJournal.FileEntry, discardChanges: Bool = false) throws {
        guard entry.disposition != .reused, let temp = entry.tempName else { return }
        if !discardChanges { try requireUnchangedNativeFiles() }
        let restoring = journal.restorations?.contains { $0.destination == entry.destination } == true
        let state = try classifyFile(entry.destination, old: entry.oldSHA256, new: entry.newSHA256)
        let tempPath = UsbPath.join(UsbPath.parent(entry.destination), temp)
        if !restoring, !discardChanges, state == .other {
            if journal.changes.syncSelection != nil { try nativeConflict() }
            if entry.state == .pending {
                try removeIfPresent(tempPath)
                return
            }
            throw UsbWriteFailure.failed("rollback target changed: \(entry.destination)")
        }
        if !restoring, !discardChanges, state == .absent {
            let mayRename = entry.writePhase == nil && journal.changes.syncSelection == nil
            let interrupted: Bool
            if mayRename, entry.state == .pending, let sha = entry.newSHA256 { interrupted = try isComplete(tempPath, sha256: sha) }
            else { interrupted = false }
            if !interrupted {
                if journal.changes.syncSelection != nil { try nativeConflict() }
                try restorationPending(path: entry.destination)
            }
        }
        switch entry.disposition {
        case .created:
            if discardChanges || restoring || state == .new {
                try deleteForRollback(entry.destination)
                try restoreAppleDouble(of: entry.destination, preexisted: entry.appleDoublePreexisted)
            }
        case .overwritten:
            if discardChanges || restoring || state == .new || state == .absent {
                try restoreFromBackup(entry.destination)
                try restoreAppleDouble(of: entry.destination, preexisted: entry.appleDoublePreexisted)
            }
        case .reused: break
        }
        // 원래 쓰기의 FAT 중단 근거 temp는 복원 의도가 디스크에 내려간 뒤에 지운다.
        try removeIfPresent(tempPath)
        try removeExactAppleDouble(parent: UsbPath.parent(entry.destination), name: temp)
    }

    func rollbackDatabase(_ entry: UsbJournal.DatabaseEntry, discardChanges: Bool = false) throws {
        if !discardChanges { try requireUnchangedNativeFiles() }
        let state = try classifyFile(entry.destination, old: entry.oldSHA256, new: entry.newSHA256)
        let restoring = journal.restorations?.contains { $0.destination == entry.destination } == true
        let tempPath = UsbPath.join(UsbPath.parent(entry.destination), entry.tempName)
        let sidecars = entry.format == .oneLibrary ? UsbLayout.oneLibrarySidecarSuffixes.map { entry.destination + $0 } : []
        if !discardChanges, !restoring, state == .other {
            throw UsbWriteFailure.failed("rollback target changed: \(entry.destination)")
        }
        if !discardChanges, !restoring, state == .absent, entry.writePhase != nil {
            try restorationPending(path: entry.destination)
        }
        switch entry.disposition {
        case .created:
            if discardChanges || restoring || state == .new {
                try deleteForRollback(entry.destination)
                for path in sidecars { try deleteForRollback(path) }
                for path in [entry.destination] + sidecars {
                    try restoreAppleDouble(of: path, preexisted: false)
                }
            }
        case .overwritten:
            if discardChanges || restoring || entry.state == .done || state == .new || state == .absent {
                try restoreFromBackup(entry.destination)
                for path in sidecars {
                    if manifest?.files[path] != nil { try restoreFromBackup(path) }
                    else { try deleteForRollback(path) }
                }
                try restoreAppleDouble(of: entry.destination, preexisted: entry.appleDoublePreexisted)
            } else {
                for path in entry.sidecarsPreexisted where journal.deletedSidecars.contains(path) {
                    try restoreFromBackup(path)
                }
            }
        case .reused: break
        }
        try removeIfPresent(tempPath)
        try removeExactAppleDouble(parent: UsbPath.parent(entry.destination), name: entry.tempName)
    }

    /// `._<이름>`이 원래 있었으면 백업에서 되살리고, 없었으면 정확한 그 이름만 지운다
    func restoreAppleDouble(of path: String, preexisted: Bool) throws {
        guard let companion = UsbRemovalPolicy.appleDoubleCompanion(of: path) else { return }
        if preexisted, manifest?.files[companion] != nil {
            try restoreFromBackup(companion)
        } else {
            try removeExactAppleDouble(parent: UsbPath.parent(path), name: UsbPath.name(path))
        }
    }

    var discardingRestorationChanges: Bool { journal.restoringBackup && journal.discardDeviceChanges == true }

    /// 폐기 승인으로 실제 되살리거나 지울 전체 대상. 재사용·bak·원래 쓰기의 temp는 복원 대상이 아니다.
    var restorationTargetPaths: Set<String> {
        var paths = Set((journal.restorations ?? []).map(\.destination))
        // 앞 복원에서 removed를 pending으로 돌린 항목도 같은 백업의 재승인 범위에 남는다.
        paths.formUnion((journal.restorationBaseline ?? [:]).keys)
        func include(_ path: String, appleDoublePreexisted: Bool) {
            paths.insert(path)
            if appleDoublePreexisted, let companion = UsbRemovalPolicy.appleDoubleCompanion(of: path),
               manifest?.files[companion] != nil { paths.insert(companion) }
        }
        // 옛 복원의 pending에는 이미 되살린 항목도 있다. skipped만 빼고 백업의 삭제 범위를 승인한다.
        for entry in journal.removals where entry.state != .skipped {
            let companion = UsbRemovalPolicy.appleDoubleCompanion(of: entry.path) ?? ""
            include(entry.path, appleDoublePreexisted: manifest?.appleDoublesPreexisting.contains(companion) == true)
        }
        for entry in journal.entries where entry.disposition != .reused && entry.tempName != nil {
            include(entry.destination, appleDoublePreexisted: entry.appleDoublePreexisted)
        }
        for entry in journal.databases where entry.disposition != .reused {
            include(entry.destination, appleDoublePreexisted: entry.appleDoublePreexisted)
            if entry.format == .oneLibrary {
                paths.formUnion(UsbLayout.oneLibrarySidecarSuffixes.map { entry.destination + $0 })
            }
        }
        if journal.changes.syncSelection != nil {
            paths.formUnion(UsbWriter.databaseFamily)
            paths.formUnion(journal.changes.writes.filter { $0.afterDatabases == true }.map(\.destination))
        }
        return paths
    }

    /// 전체 기준을 먼저 읽어 고정한 뒤 승인 저널 한 번에 담는다. 이어 읽은 상태로 사전을 보충하지 않는다.
    func captureRestorationBaseline() throws -> [String: UsbJournal.RestorationTarget] {
        var baseline: [String: UsbJournal.RestorationTarget] = [:]
        for path in restorationTargetPaths.sorted() {
            let sha256 = try restorationTargetHash(path)
            baseline[path] = .init(sha256: sha256, link: sha256 == nil ? try restorationLinkIdentity(path) : nil)
        }
        return baseline
    }

    func requireApprovedRestorationTarget(_ path: String, target: UsbJournal.RestorationTarget) throws {
        if let link = target.link {
            guard try restorationLinkIdentity(path) == link else { try restorationPending(path: path) }
        } else {
            guard try classifyFile(path, old: target.sha256, new: nil) == .old else { try restorationPending(path: path) }
        }
    }

    /// 저장된 전체 승인에서만 새 의도의 기대값을 가져온다. 구형 승인에 없는 대상은 재승인 전까지 보존한다.
    func initialRestorationTarget(_ path: String) throws -> UsbJournal.RestorationTarget {
        if discardingRestorationChanges {
            guard let target = journal.restorationBaseline?[path] else { try restorationPending(path: path) }
            try requireApprovedRestorationTarget(path, target: target)
            return target
        }
        let sha256 = try restorationTargetHash(path)
        try requireRestorationInitialTarget(path, observed: sha256)
        return .init(sha256: sha256, link: nil)
    }

    /// nil은 없음. 링크·부모 링크는 승인 없는 복원의 기준으로 채택하지 않는다.
    func restorationTargetHash(_ path: String) throws -> String? {
        let parent = UsbPath.parent(path)
        if !parent.isEmpty { _ = try root.url(for: parent) }
        guard let info = try fs.stat(usb(path)) else { return nil }
        guard info.kind == .file else {
            if discardingRestorationChanges, info.kind == .symlink { return nil }
            try restorationPending(path: path)
        }
        return try fs.sha256(usb(path), uncached: true)
    }

    /// 끝 성분 링크만 lstat한다. 승인 이후 같은 경로의 새 링크를 같은 부재로 흡수하지 않는다.
    func restorationLinkIdentity(_ path: String) throws -> UsbJournal.FileMutation.LinkIdentity? {
        let parent = UsbPath.parent(path)
        if !parent.isEmpty, (try? root.url(for: parent)) == nil { return nil }
        guard try fs.stat(usb(path))?.kind == .symlink else { return nil }
        var info = Darwin.stat()
        guard lstat(usb(path).path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else {
            try restorationPending(path: path)
        }
        return .init(device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                     modificationSeconds: Int64(info.st_mtimespec.tv_sec),
                     modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    /// 뒤늦게 읽은 외부 해시를 복원 시작의 기대값으로 흡수하지 않는다.
    func requireRestorationInitialTarget(_ path: String, observed: String?) throws {
        if discardingRestorationChanges {
            guard let target = journal.restorationBaseline?[path], target.sha256 == observed else { try restorationPending(path: path) }
            try requireApprovedRestorationTarget(path, target: target)
            return
        }
        let native = journal.changes.syncSelection != nil
        let file = journal.entries.first { $0.destination == path }
        let database = journal.databases.first { $0.destination == path }
        let selection = journal.changes.writes.first { $0.destination == path && UsbSyncSelectionStage.isSelectionPath(path) }
        let old: String?
        if native, UsbWriter.databaseFamily.contains(path) { old = journal.base?.files[path]?.sha256 }
        else if native, let selection { old = selection.expectedExistingSHA256 }
        else { old = manifest?.files[path]?.sha256 ?? file?.oldSHA256 ?? database?.oldSHA256 }
        let new = file?.newSHA256 ?? database?.newSHA256
        // AppleDouble은 OS가 생성하며 새 내용 해시를 원래 쓰기 저널에 담지 않는다.
        if UsbLayout.isAppleDouble(UsbPath.name(path)) { return }
        func conflict() throws -> Never {
            if native { try nativeConflict() }
            throw UsbWriteFailure.failed("rollback target changed: \(path)")
        }
        if let observed {
            if observed != old && observed != new { try conflict() }
        } else if old != nil {
            let removed = journal.deletedSidecars.contains(path) || journal.removals.contains { $0.path == path && $0.state == .removed }
            let forwardTemp: String?
            let forwardSHA: String?
            if let file, file.state == .pending,
               !native && file.writePhase == nil {
                forwardTemp = file.tempName
                forwardSHA = file.newSHA256
            } else if let database, database.state == .pending,
                      !native && database.writePhase == nil {
                forwardTemp = database.tempName
                forwardSHA = database.newSHA256
            } else { forwardTemp = nil; forwardSHA = nil }
            let interrupted: Bool
            if let forwardTemp, let forwardSHA {
                interrupted = try isComplete(UsbPath.join(UsbPath.parent(path), forwardTemp), sha256: forwardSHA)
            } else { interrupted = false }
            let legacyInterrupted = !native && (file?.state == .pending || database?.state == .pending)
                && (file?.writePhase == nil && database?.writePhase == nil)
            if !removed && !interrupted && !legacyInterrupted { try conflict() }
        }
        try requireUnchangedNativeFiles()
    }

    /// 충돌을 발견하면 temp를 보존하고 새 폐기 승인을 기다린다. 완료 기록도 더 이상 성공 근거가 아니다.
    func restorationPending(path: String) throws -> Never {
        journal.externalChangesDetected = true
        journal.restorationApprovalRequired = true
        if journal.state != .restorePending { try journal.move(to: .restorePending) }
        try saveJournal()
        throw UsbError.restorePending(reason: String(ui: "USB 복원 대상이 그 사이 바뀌었거나 중단 상태를 확정할 수 없습니다. 백업을 확인하고 기기 변경을 버리는 복원으로 다시 승인하세요"))
    }

    func restorationConflict(_ index: Int) throws -> Never {
        journal.restorations![index].phase = .externalChanged
        try restorationPending(path: journal.restorations![index].destination)
    }

    /// 재개 전에 모든 내구 의도를 검사하여 뒤쪽 항목에서 실패하기 전 USB 변경도 하지 않는다.
    func checkRestorationProgress() throws {
        if journal.restorationApprovalRequired == true { try restorationPending(path: "") }
        if discardingRestorationChanges {
            let recorded = Set((journal.restorations ?? []).map(\.destination))
            // 뒤쪽 미기록 대상도 앞쪽 복원의 USB 연산 전에 검사한다. 옛 승인은 기존 의도를 그대로 보존한다.
            for path in restorationTargetPaths.sorted() where !recorded.contains(path) {
                _ = try initialRestorationTarget(path)
            }
        }
        // 아직 완료하지 않은 사이드카 삭제도 외부 삭제와 자기 unlink를 구분할 수 없다.
        if !discardingRestorationChanges {
            for entry in journal.sidecarDeletions ?? [] where entry.phase != .done {
                let state = try classifyFile(entry.destination, old: entry.expectedSHA256, new: nil)
                if entry.phase == .externalChanged || state != .old { try restorationPending(path: entry.destination) }
            }
        }
        for index in (journal.restorations ?? []).indices { try checkRestoration(index) }
    }

    func checkRestoration(_ index: Int) throws {
        let entry = journal.restorations![index]
        let state = try restorationState(entry.destination)
        // 승인도 의도 생성 때의 대상에만 적용된다. 완료 전·후의 새 외부 기준은 재승인으로만 채택한다.
        if state == .other { try restorationConflict(index) }
        if !discardingRestorationChanges { try requireUnchangedNativeFiles() }
    }

    /// 복원 temp·백업 해시를 먼저 기록하고 복사 → 재검사 → rename 의도 → rename → 완료 순으로 간다.
    func restoreFromBackup(_ path: String, beforeRename: (() throws -> Void)? = nil) throws {
        guard let stamp = manifest?.files[path] else { throw UsbWriteFailure.failed("no backup of \(path)") }
        _ = try restoreReplacement(path, source: validatedBackupFile(path), sha256: stamp.sha256, size: stamp.size,
                                   mtime: stamp.mtime, beforeRename: beforeRename)
    }

    /// 백업과 로컬 음원 재복사는 같은 내구 의도를 사용한다. 음원 원본 변경만 기존대로 알림으로 남긴다.
    func restoreReplacement(_ path: String, source: URL, sha256: String, size: Int64, mtime: Date?,
                            sourceSHA1: String? = nil, beforeRename: (() throws -> Void)? = nil) throws -> Bool {
        if !discardingRestorationChanges { try requireUnchangedNativeFiles() }
        let index: Int
        if let found = journal.restorations?.firstIndex(where: { $0.destination == path }) {
            index = found
            guard journal.restorations![index].operation == .replace,
                  journal.restorations![index].backupSHA256 == sha256 else {
                throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
            }
        } else {
            let target = try initialRestorationTarget(path)
            let temp = nextTempName()
            if journal.restorations == nil { journal.restorations = [] }
            journal.restorations!.append(.init(destination: path, operation: .replace, tempName: temp,
                                              backupSHA256: sha256, expectedSHA256: target.sha256, phase: .copying, expectedLink: target.link))
            index = journal.restorations!.count - 1
            try saveJournal()
        }
        try checkRestoration(index)
        if journal.restorations![index].phase == .done { return true }
        let expected = journal.restorations![index].expectedSHA256
        let parent = UsbPath.parent(path)
        let temp = journal.restorations![index].tempName!
        let tempPath = UsbPath.join(parent, temp)
        let tempURL = usb(tempPath)
        if try classifyFile(path, old: sha256, new: nil) != .old {
            try makeParents(path)
            if try !isComplete(tempPath, sha256: sha256) {
                try removeIfPresent(tempPath)
                try ensureMounted()
                let copied = try fs.copyDataNew(from: source, to: tempURL) { _ in }
                guard copied.sha256 == sha256, copied.size == size, sourceSHA1.map({ $0 == copied.sha1 }) ?? true else {
                    if sourceSHA1 != nil {
                        try removeIfPresent(tempPath)
                        try removeExactAppleDouble(parent: parent, name: temp)
                        report.notes.append(String(ui: "음원 원본이 바뀌어 다시 복사하지 못했습니다: \(path)"))
                        return false
                    }
                    throw UsbWriteFailure.failed("backup damaged: \(path)")
                }
                if let mtime { try fs.setModificationDate(tempURL, mtime) }
                try fs.fullSync(tempURL)
            }
            try beforeRename?()
            try checkRestoration(index)
            // 이미 들어간 FAT rename의 재개는 그 근거를 준비 단계로 되돌리지 않는다.
            if journal.restorations![index].phase != .renameEntered {
                journal.restorations![index].phase = .renamePending
                try saveJournal()
            }
            try checkRestoration(index)
            guard try isComplete(tempPath, sha256: sha256) else { try restorationConflict(index) }
            try ensureMounted()
            journal.restorations![index].phase = .renameEntered
            try saveJournal()
            try checkRestoration(index)
            if expected == nil, try fs.stat(usb(path)) == nil { try requireRestorationCollisionFree(path, temp: temp) }
            try fs.rename(tempURL, to: usb(path))
        }
        try fs.syncDirectory(usb(parent))
        journal.restorations![index].phase = .done
        try saveJournal()
        try checkRestoration(index)
        try removeIfPresent(tempPath)
        if !UsbLayout.isAppleDouble(UsbPath.name(path)) { try removeExactAppleDouble(parent: parent, name: temp) }
        return true
    }

    /// 생성 파일 삭제도 unlink 전에 의도를 기록한다. 삭제 뒤·완료 저장 전 중단은 같은 의도로 재개한다.
    func deleteForRollback(_ path: String) throws {
        if !discardingRestorationChanges { try requireUnchangedNativeFiles() }
        let index: Int
        if let found = journal.restorations?.firstIndex(where: { $0.destination == path }) {
            index = found
            guard journal.restorations![index].operation == .delete else { throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock]) }
        } else {
            let target = try initialRestorationTarget(path)
            if journal.restorations == nil { journal.restorations = [] }
            journal.restorations!.append(.init(destination: path, operation: .delete, tempName: nil, backupSHA256: nil,
                                              expectedSHA256: target.sha256, phase: .deletePending, expectedLink: target.link))
            index = journal.restorations!.count - 1
            try saveJournal()
        }
        try checkRestoration(index)
        if journal.restorations![index].phase == .done { return }
        journal.restorations![index].phase = .deleteEntered
        try saveJournal()
        try checkRestoration(index)
        try removeIfPresent(path)
        // 이미 부모까지 정리한 삭제를 다시 하면 fsync할 폴더가 없다.
        let parent = UsbPath.parent(path)
        if try fs.stat(usb(parent))?.kind == .directory { try fs.syncDirectory(usb(parent)) }
        journal.restorations![index].phase = .done
        try saveJournal()
        try checkRestoration(index)
    }

    /// 지운 파일을 되살린다(되살렸으면 true). 음원은 로컬 원본의 SHA-1이 manifest와 같을 때만 다시 복사한다.
    /// 원본이 없거나 바뀌었으면 알림만 남기고 false: 되돌릴 수 없는 것을 실패로 세면 되돌리기·회복이 끝나지 않는다
    func restoreRemoved(_ path: String) throws -> Bool {
        if discardingRestorationChanges, journal.restorations?.contains(where: { $0.destination == path }) != true {
            _ = try initialRestorationTarget(path)
        }
        // 쓰기 전에 이미 없던 파일(백업 때 없음): 되살릴 것이 없다
        if manifest?.absentBefore.contains(path) == true { return true }
        let companion = UsbRemovalPolicy.appleDoubleCompanion(of: path) ?? ""
        let appleDoublePreexisted = manifest?.appleDoublesPreexisting.contains(companion) ?? false
        guard UsbPath.isAudio(path) else {
            try restoreFromBackup(path)
            try restoreAppleDouble(of: path, preexisted: appleDoublePreexisted)
            return true
        }
        guard let audio = manifest?.removedAudio.first(where: { $0.path == path }) else {
            throw UsbWriteFailure.failed("no record of removed audio: \(path)")
        }
        // 이미 원래 내용으로 돌아온 음원은 원본이 사라졌어도 복원 완료다. 외부 파일은 새 승인 전까지 보존한다.
        if try classifyFile(path, old: audio.sha256, new: nil) == .old {
            // 음원은 앞서 돌아왔어도 재승인한 짝 파일의 복원 대상은 그대로 남는다.
            if discardingRestorationChanges { try restoreAppleDouble(of: path, preexisted: appleDoublePreexisted) }
            return true
        }
        if !discardingRestorationChanges {
            guard try fs.stat(try root.url(for: path)) == nil else { try restorationPending(path: path) }
            if try fs.stat(usb(UsbPath.parent(path)))?.kind == .directory {
                try requireRestorationCollisionFree(path, temp: "")
            }
        }
        guard let original = audio.localOriginal, let sourceSHA1 = audio.localOriginalSHA1,
              try fs.stat(URL(filePath: original))?.kind == .file else {
            report.notes.append(String(ui: "음원 원본이 없어 다시 복사하지 못했습니다: \(path)"))
            return false
        }
        let restored = try restoreReplacement(path, source: URL(filePath: original), sha256: audio.sha256, size: audio.size,
                                               mtime: audio.modificationDate, sourceSHA1: sourceSHA1)
        if restored { try restoreAppleDouble(of: path, preexisted: appleDoublePreexisted) }
        return restored
    }

    func requireRestorationCollisionFree(_ path: String, temp: String) throws {
        do { try recheckCollision(path, temp: temp) }
        catch UsbWriteFailure.failed { try restorationPending(path: path) }
    }

    /// 이 세션 이름으로 시작하는 임시 파일(저널에 적힌 것 + 되돌리며 만든 것)을 지운다
    func removeSessionTemps() throws {
        let prefix = UsbLayout.tempPrefix + journal.session + "-"
        var known = Set(journal.entries.compactMap { entry in entry.tempName.map { UsbPath.join(UsbPath.parent(entry.destination), $0) } })
        known.formUnion((journal.restorations ?? []).compactMap { entry in entry.tempName.map { UsbPath.join(UsbPath.parent(entry.destination), $0) } })
        known.formUnion(journal.databases.map { UsbPath.join(UsbPath.parent($0.destination), $0.tempName) })
        for temp in try UsbWriter.tempFiles(root: root, fileSystem: fs) where UsbPath.name(temp).hasPrefix(prefix) {
            known.insert(temp)
        }
        for temp in known.sorted() where try exists(temp) {
            try removeIfPresent(temp)
            try removeExactAppleDouble(parent: UsbPath.parent(temp), name: UsbPath.name(temp))
        }
    }

    // MARK: - usb-restore

    func restore(backup: URL?, discardDeviceChanges: Bool, confirmName: String?, dryRun: Bool) throws -> UsbWriteReport {
        if writeGuard.isRekordboxRunning() {
            throw UsbError.restorePending(reason: String(ui: "rekordbox가 켜져 있습니다"))
        }
        let blocks = environmentBlocks(purpose: .edit, required: [], confirmName: confirmName, checkRekordbox: false)
        if !blocks.isEmpty { throw UsbError.writeRefused(blocks) }
        func refuse(_ code: String, _ message: String) -> UsbError {
            .writeRefused([UsbBlock(code: code, scope: .volume, message: message)])
        }
        let recoveryNeeded = refuse("recoveryNeeded", String(ui: "지난 USB 쓰기가 끝나지 않았습니다. `djc usb-recover`로 먼저 회복하세요"))
        var pending: UsbJournal?
        switch UsbWriter.journalStatus(paths: paths, volumeKey: volumeKey) {
        case let .open(found):
            // 복원 중 외부 변경 때문에 멈춘 일반 USB도 같은 백업·세션에 대한 새 폐기 승인으로만 다시 시작한다.
            guard discardDeviceChanges, [.restorePending, .restoreFailed].contains(found.state),
                  found.volumeUUID.uppercased() == volumeKey,
                  UsbWriter.unsafeEntries(in: found).isEmpty else { throw recoveryNeeded }
            pending = found
        case .corrupt: throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
        case .missing, .closed: break
        }
        let pendingFolder = pending?.backupDirectory.map { URL(filePath: $0) }
        guard let folder = backup ?? pendingFolder ?? UsbWriter.backups(paths: paths, volumeKey: volumeKey).first(where: {
            FileManager.default.fileExists(atPath: $0.appending(path: "journal.json").path)
                && FileManager.default.fileExists(atPath: $0.appending(path: "report.json").path)
        }) else {
            throw refuse("noBackup", String(ui: "되돌릴 백업이 없습니다. 이 USB에 DJCrate로 쓴 기록이 있는지 확인하세요"))
        }
        if pending != nil {
            guard let pendingFolder, let expected = UsbScratchRoots.realPath(pendingFolder.path),
                  UsbScratchRoots.realPath(folder.path) == expected else { throw recoveryNeeded }
        }
        // 되돌리기는 백업 폴더의 기록대로 USB 파일을 지우고 되살린다: DJCrate가 이 USB에 쓸 때 만든 폴더만 받는다
        guard isOurBackupFolder(folder) else {
            throw refuse("backupOutside", String(ui: "이 USB의 DJCrate 백업 폴더(usb-backups 안)만 되돌릴 수 있습니다. 그 안의 폴더를 주세요"))
        }
        let decoder = UsbJournal.decoder()
        let unreadable = refuse("backupUnreadable", String(ui: "백업 폴더를 읽지 못했습니다. 다른 백업 폴더를 --backup으로 주세요"))
        guard let savedManifest = try? decoder.decode(UsbManifest.self, from: Data(contentsOf: folder.appending(path: "manifest.json")))
        else { throw unreadable }
        let saved: UsbJournal
        let savedReport: UsbWriteReport?
        if let pending {
            // 중단한 쓰기는 백업의 닫힌 저널·보고서가 아직 없다. 열린 저널과 같은 manifest로만 복원한다.
            saved = pending
            savedReport = nil
        } else {
            guard let record = try? decoder.decode(UsbJournal.self, from: Data(contentsOf: folder.appending(path: "journal.json"))),
                  let result = try? decoder.decode(UsbWriteReport.self, from: Data(contentsOf: folder.appending(path: "report.json")))
            else { throw unreadable }
            saved = record
            savedReport = result
        }
        guard savedManifest.session == saved.session, saved.volumeUUID.uppercased() == volumeKey,
              savedReport == nil || savedReport?.session == saved.session else { throw unreadable }
        // 깨졌거나 누가 고친 기록이 USB 루트 밖을 가리키면 파일 연산 전에 막는다
        guard UsbWriter.unsafeEntries(in: saved).isEmpty, UsbWriter.unsafeEntries(in: savedManifest).isEmpty else { throw unreadable }
        guard savedManifest.volumeUUID.uppercased() == volumeKey else {
            throw refuse("backupOtherVolume", String(ui: "다른 USB의 백업입니다. 이 USB의 백업 폴더를 주세요"))
        }
        backupFolder = folder
        manifest = savedManifest
        journal = saved
        do { try loadValidatedBackup() } catch { throw unreadable }
        report = UsbWriteReport(outcome: dryRun ? .dryRun : .restored, session: saved.session, backup: folder.path)
        // 표지보다 같은 세션의 열린 저널이 우선이다. 명시적 재승인은 아래에서 의도를 새로 연다.
        let alreadyRestored = FileManager.default.fileExists(atPath: folder.appending(path: UsbWriter.restoredMarkerName).path)
        if pending == nil, alreadyRestored || saved.state == .rolledBack || savedReport?.outcome == .rolledBack {
            report.notes.append(alreadyRestored ? String(ui: "그 쓰기는 이미 되돌렸습니다") : String(ui: "그 쓰기는 이미 되돌려져 있어 바꿀 것이 없습니다"))
            report.resultDatabases = try restoreDatabaseHashes()
            return report
        }
        // DB와 선택 XML 모두 완료한 새 상태인지 본다. 선택만 바꾼 묶음의 DB·사이드카는 백업 상태와 같아야 한다.
        let current = try restoreDatabaseHashes()
        let changed: Bool
        if saved.changes.syncSelection != nil {
            let nativeChanged = try nativeFileStates(completed: true).values.contains(.other)
            changed = pending != nil || nativeChanged || savedReport?.outcome == .needsReplan
        } else {
            var sidecarPresent = false
            for suffix in UsbLayout.oneLibrarySidecarSuffixes where try exists(UsbLayout.oneLibrary + suffix) { sidecarPresent = true }
            changed = current != savedReport?.resultDatabases || sidecarPresent || savedReport?.outcome == .needsReplan
        }
        if changed, !discardDeviceChanges {
            throw refuse("deviceChanged",
                         String(ui: "USB가 그 뒤에 바뀌었습니다(기기가 쓴 기록 등). 되돌리면 그 내용을 잃습니다. 그래도 되돌리려면 --discard-device-changes를 주세요"))
        }
        if dryRun {
            report.filesCreated = saved.entries.filter { $0.disposition == .created }.count
            report.filesOverwritten = saved.entries.filter { $0.disposition == .overwritten }.count
            report.filesRemoved = saved.removals.filter { $0.state == .removed }.count
            report.resultDatabases = current
            return report
        }
        // 저널을 열기 전에 그 자리의 볼륨이 이 백업의 USB인지 다시 본다
        do {
            try ensureSameVolume()
        } catch UsbWriteFailure.volumeLost {
            throw volumeGone
        }
        // 되돌리기도 USB 쓰기다: 끊기면 회복이 이어서 되돌리도록 저널을 restorePending으로 연다
        journal = saved
        journal.state = .restorePending
        journal.restoringBackup = true
        journal.discardDeviceChanges = discardDeviceChanges
        journal.backupDirectory = folder.path
        // 새 폐기 승인은 완료한 복원 뒤의 외부 변경도 대상으로 삼는다. 회복 재개는 이 초기화를 하지 않는다.
        if discardDeviceChanges {
            // 기존 의도·전체 범위도 먼저 읽는다. 이미 되살린 삭제 항목을 새 승인에서 잃지 않게 한다.
            let baseline = try captureRestorationBaseline()
            journal.restorations = nil
            journal.restorationBaseline = baseline
            journal.restorationApprovalRequired = false
        } else { journal.restorationBaseline = nil }
        try saveJournal()
        options = UsbWriteOptions()
        do {
            return try finishRestore(errors: rollback(mode: .restore), folder: folder, reason: String(ui: "되돌리기"))
        } catch UsbWriteFailure.volumeLost {
            throw volumeGone
        }
    }

    /// 링크로 바뀐 DB는 보고서 해시를 읽을 때도 따라가지 않는다. 명시적 폐기는 끝 성분만 교체한다.
    func restoreDatabaseHashes() throws -> [String: String] {
        var result: [String: String] = [:]
        for path in UsbWriter.databaseOrder {
            guard let url = try? root.url(for: path), let info = try fs.stat(url), info.kind == .file else { continue }
            result[path] = try fs.sha256(url, uncached: true)
        }
        return result
    }

    /// 되돌리기 끝: 실패가 있으면 저널을 restoreFailed로 두고 던진다. 되돌렸으면 백업 폴더에 표지를 남기고 저널을 restored로 닫는다.
    /// 그 쓰기의 기록(report.json·journal.json)은 바꾸지 않는다(무엇을 되돌렸는지 남긴다)
    func finishRestore(errors: [String], folder: URL, reason: String) throws -> UsbWriteReport {
        report.filesCreated = 0
        report.filesRemoved = journal.entries.filter { $0.disposition == .created }.count
        report.filesOverwritten = journal.entries.filter { $0.disposition == .overwritten }.count
        report.resultDatabases = try restoreDatabaseHashes()
        if !errors.isEmpty {
            report.outcome = .restoreFailed
            try journal.move(to: .restoreFailed)
            try saveJournal()
            throw UsbError.restoreFailed(reason: reason, restoreError: errors.joined(separator: "\n"), backup: folder.path)
        }
        try checkRestorationProgress()
        let nativeMismatches = try fingerprintMismatches().filter { nativeBaselinePaths.contains($0) }
        if !nativeMismatches.isEmpty {
            report.outcome = .restoreFailed
            try journal.move(to: .restoreFailed)
            try saveJournal()
            throw UsbError.restoreFailed(reason: reason, restoreError: nativeMismatches.map { "fingerprint: \($0)" }.joined(separator: "\n"), backup: folder.path)
        }
        report.outcome = .restored
        // 표지를 저널을 닫기 전에 쓴다: 그 사이 끊기면 회복이 되돌리기를 한 번 더 할 뿐이다
        try UsbDurableFile.write(report, to: folder.appending(path: UsbWriter.restoredMarkerName), fileSystem: fs)
        try journal.move(to: .restored)
        try saveJournal()
        return report
    }
}
