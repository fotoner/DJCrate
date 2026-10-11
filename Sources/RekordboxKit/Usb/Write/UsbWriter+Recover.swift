import DJCDomain
import Foundation

/// 회복: 끊긴 쓰기를 대상(DB)부터 보고 마저 쓰거나 되돌린다. 쓰기와 같은 확인(관문 포함)을 거친 뒤에만 USB 파일을 연다.
/// 1. DB마다 분류(옛 해시·새 해시·없음·그 밖). 그 밖이 하나라도 있으면(기기가 바꿈) 우리 임시 파일만 지우고 "다시 계획"으로 닫는다.
/// 2. rename 도중 끊긴 항목(대상 없음 + 임시 완전)은 rename을 마친다.
/// 3. 모든 DB가 새것이면 지우기·검증을 다시 → recovered. 일부만이면 준비 폴더가 온전할 때 마저 쓴다. 아니면 되돌린다.
/// 저널에 적힌 임시 파일은 이 판정들이 끝난 뒤 지운다. 닫을 때 백업 폴더에 journal.json·report.json을 남긴다.
/// 끊긴 되돌리기(usb-restore가 연 저널)는 되돌리기로 마저 한다. 저널·백업 기록의 경로가 USB 루트 밖을 가리키면 아무것도 하지 않는다.
extension UsbWriteRun {
    enum DatabaseState: Equatable { case absent, old, new, other }

    func recover(discardTemp: Bool, confirmName: String?) throws -> UsbWriteReport {
        let blocks = environmentBlocks(purpose: .edit, required: [], confirmName: confirmName)
        if !blocks.isEmpty { throw UsbError.writeRefused(blocks) }
        switch UsbWriter.journalStatus(paths: paths, volumeKey: volumeKey) {
        case .missing, .closed:
            return try recoverWithoutJournal(discardTemp: discardTemp)
        case .corrupt:
            throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
        case let .open(found):
            // 깨졌거나 누가 고친 기록이 USB 루트 밖을 가리키면 파일 연산 전에 막는다
            guard found.volumeUUID.uppercased() == volumeKey, UsbWriter.unsafeEntries(in: found).isEmpty else { throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock]) }
            journal = found
        }
        // 복원 재개는 폐기 승인 여부와 무관하게 온전한 백업을 먼저 요구한다.
        if let directory = journal.backupDirectory, FileManager.default.fileExists(atPath: directory) {
            backupFolder = URL(filePath: directory)
            try loadValidatedBackup()
        } else if journal.restoringBackup || ![.planned, .staged].contains(journal.state) {
            throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
        }
        report = UsbWriteReport(outcome: .recovered, session: journal.session, backup: backupFolder?.path)
        report.filesCreated = journal.entries.filter { $0.disposition == .created && $0.state == .done }.count
        emit(.recover, cancellable: false)
        do {
            return try recoverOpenJournal()
        } catch UsbWriteFailure.volumeLost {
            throw volumeGone
        }
    }

    private func recoverOpenJournal() throws -> UsbWriteReport {
        try ensureSameVolume()
        if journal.restoringBackup {
            // 끊긴 되돌리기: 기기 변경 여부는 되돌리기를 시작할 때 이미 판정했다. 같은 방식으로 마저 되돌린다
            guard let backupFolder else { throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock]) }
            return try finishRestore(errors: rollback(mode: .restore), folder: backupFolder, reason: String(ui: "회복"))
        }
        if [.planned, .staged].contains(journal.state) {
            // 백업 전에 끊겼다: USB에 쓴 것이 없다
            try removeSessionTemps()
            if backupFolder == nil {
                report.notes.append(String(ui: "쓰기 전에 끊겨 USB에 쓴 것이 없습니다(백업 기록 없음)"))
            }
            try closeJournal(.rolledBack, outcome: .rolledBack)
            return report
        }
        if journal.changes.syncSelection != nil {
            try requireUnchangedNativeFiles()
            // 두 선택 파일과 DB를 끊긴 상태에서 따로 이어 쓰지 않는다. 기존 백업으로 전체를 돌린 뒤 다시 계획한다.
            let errors = try rollback(mode: .recover)
            if errors.isEmpty {
                report.notes.append(String(ui: "동기화 선택을 쓰는 중 끊겨 USB를 쓰기 전으로 되돌렸습니다. 다시 동기화하세요"))
                try closeJournal(.rolledBack, outcome: .rolledBack)
                return report
            }
            try closeJournal(.restoreFailed, outcome: .restoreFailed)
            throw UsbError.restoreFailed(reason: String(ui: "동기화 선택 회복"), restoreError: errors.joined(separator: "\n"),
                                         backup: backupFolder?.path ?? "")
        }
        let rollbackOnly = [.restorePending, .restoreFailed].contains(journal.state) || journal.restorations != nil
        try checkRestorationProgress()
        if !rollbackOnly, try classifyDatabases().values.contains(.other) {
            try removeSessionTemps()
            report.notes.append(String(ui: "USB가 기기에서 바뀌어 이어 쓰지 않았습니다. 지금 USB 상태로 다시 미리 보기한 뒤 쓰세요"))
            try closeJournal(.needsReplan, outcome: .needsReplan)
            return report
        }
        var mustRollBack = rollbackOnly
        if !rollbackOnly { mustRollBack = try !completeInterruptedRenames() }
        let states = try classifyDatabases()
        let allNew = states.values.allSatisfy { $0 == .new }
        let someNew = states.values.contains(.new)
        // 파일 단계를 마친 뒤(DB 교체가 시작된 뒤)에만 앞으로 간다
        let filesDone = journal.entries.allSatisfy { $0.state == .done }
            && [.filesWritten, .committing, .committed, .cleaned].contains(journal.state)
        if !mustRollBack, filesDone, allNew || (someNew && canResume(states)) {
            do {
                if !allNew { try resumeCommit(states) }
                if [.filesWritten, .committing].contains(journal.state) { try journal.move(to: .committed) }
                try saveJournal()
                try cleanup(journal.changes)
                try verify(journal.changes, verifiers: [UsbFingerprintVerifier()])
                try removeSessionTemps()
                try closeJournal(.recovered, outcome: .recovered)
                return report
            } catch UsbWriteFailure.volumeLost {
                throw UsbWriteFailure.volumeLost
            } catch let error as UsbError {
                throw error
            } catch {
                report.notes.append(String(ui: "마저 쓰지 못해 되돌렸습니다: \(String(describing: error))"))
            }
        }
        let errors = try rollback(mode: .recover)
        if errors.isEmpty {
            try closeJournal(.rolledBack, outcome: .rolledBack)
            return report
        }
        try closeJournal(.restoreFailed, outcome: .restoreFailed)
        throw UsbError.restoreFailed(reason: String(ui: "회복"), restoreError: errors.joined(separator: "\n"),
                                     backup: backupFolder?.path ?? "")
    }

    /// 옛 usb-restore의 FAT 중단은 원래 쓰기의 done 항목과 백업 내용인 temp로만 이어받는다.
    /// 없는 optional 필드·own session·부모 경로·유일한 해시 일치를 모두 확인한 뒤 의도를 내린다.
    func adoptLegacyRestoreTemps() throws {
        guard journal.restoringBackup, journal.changes.syncSelection == nil,
              journal.restorations == nil, journal.discardDeviceChanges == nil,
              journal.restorationBaseline == nil,
              journal.sidecarDeletions == nil, journal.externalChangesDetected == nil,
              journal.restorationApprovalRequired == nil else { return }
        struct Candidate {
            var destination: String
            var oldSHA256: String?
        }
        let candidates = journal.entries.filter { $0.disposition == .overwritten && $0.state == .done && $0.writePhase == nil }
            .map { Candidate(destination: $0.destination, oldSHA256: $0.oldSHA256) }
            + journal.databases.filter { $0.disposition == .overwritten && $0.state == .done && $0.writePhase == nil }
                .map { Candidate(destination: $0.destination, oldSHA256: $0.oldSHA256) }
        var adopted: [UsbJournal.FileMutation] = []
        var nextSequence = journal.nextSequence
        let forwardTemps = Set(journal.entries.compactMap(\.tempName) + journal.databases.map(\.tempName))
        let prefix = UsbLayout.tempPrefix + journal.session + "-"
        for candidate in candidates {
            let path = candidate.destination
            guard let stamp = manifest?.files[path], candidate.oldSHA256 == stamp.sha256 else {
                throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
            }
            // root.url는 끝 성분까지 링크를 거부한다. 읽을 수 없는 경로는 자동 이어받지 않는다.
            guard let target = try? root.url(for: path) else { try restorationPending(path: path) }
            guard try fs.stat(target) == nil else { continue }
            let parent = UsbPath.parent(path)
            guard let directory = try? root.url(for: parent), try fs.stat(directory)?.kind == .directory else { try restorationPending(path: path) }
            let names = try fs.list(directory)
            // 백업 내용인 자기 temp가 없거나 둘 이상이면 어느 연산의 근거인지 모른다.
            let ownTemps = names.filter { $0.hasPrefix(prefix) && !forwardTemps.contains($0) && UsbWriter.isSafeTempName($0) }
            let matching = try ownTemps.filter { try isComplete(UsbPath.join(parent, $0), sha256: stamp.sha256) }
            guard matching.count == 1 else { try restorationPending(path: path) }
            let temp = matching[0]
            for name in names where name.hasPrefix(prefix) {
                guard let sequence = Int(name.dropFirst(prefix.count)), sequence >= 0, sequence < Int(Int32.max) else {
                    try restorationPending(path: path)
                }
                nextSequence = max(nextSequence, sequence + 1)
            }
            guard try fs.stat(usb(UsbPath.join(parent, temp)))?.size == stamp.size,
                  !adopted.contains(where: { $0.tempName == temp && UsbPath.parent($0.destination) == parent }) else {
                try restorationPending(path: path)
            }
            // 삭제됐던 끝 성분만 복원한다. 같은 충돌 키의 남의 파일에는 rename하지 않는다.
            try requireRestorationCollisionFree(path, temp: temp)
            adopted.append(.init(destination: path, operation: .replace, tempName: temp, backupSHA256: stamp.sha256,
                                  expectedSHA256: nil, phase: .renamePending))
        }
        if !adopted.isEmpty {
            journal.restorations = adopted
            journal.nextSequence = nextSequence
            try saveJournal()
        }
    }

    /// DB를 교체하지 않는 선택 변경도 계획 base의 DB 셋·사이드카를 보호한다.
    /// 복원 기록은 원래 쓰기 기록보다 먼저 판정하여 자기 rename·삭제 중단만 구분한다.
    func nativeFileStates(completed: Bool = false) throws -> [String: DatabaseState] {
        var states: [String: DatabaseState] = [:]
        for path in UsbWriter.databaseFamily {
            if !completed, let restoring = try restorationState(path) { states[path] = restoring; continue }
            let old = journal.base?.files[path]?.sha256
            if let database = journal.changes.databases.first(where: { $0.destination == path }) {
                let entry = journal.databases.first { $0.destination == path }
                let state = try classifyFile(path, old: old, new: database.sha256)
                if completed { states[path] = state == .new ? .new : .other }
                else if state == .absent {
                    // 진입 기록 직후 중단과 FAT 중단은 같은 모양이다. 외부 삭제를 단정해 덮지 않는다.
                    states[path] = .other
                } else if state == .old, old == nil, entry?.state == .done, entry?.rollbackCompleted != true {
                    states[path] = .other
                } else { states[path] = state }
            } else {
                let deletion = journal.sidecarDeletions?.first { $0.destination == path }
                let legacyDeleted = journal.sidecarDeletions == nil && journal.deletedSidecars.contains(path)
                let deleted = deletion?.phase == .done || legacyDeleted
                let expectAbsent = (completed && deleted) || deletion?.phase == .done
                let state = try classifyFile(path, old: expectAbsent ? nil : old, new: nil)
                if deletion?.phase == .externalChanged { states[path] = .other }
                else {
                    // 복원 완료 뒤에는 위 restorationState가 담당한다. 옛 삭제 기록을 계속 허용하지 않는다.
                    states[path] = state == .absent ? (!completed && deleted ? .old : .other) : state
                }
            }
        }
        for write in journal.changes.writes where write.afterDatabases == true || UsbSyncSelectionStage.isSelectionPath(write.destination) {
            let path = write.destination
            if !completed, let restoring = try restorationState(path) { states[path] = restoring; continue }
            let old = write.expectedExistingSHA256
            let entry = journal.entries.first { $0.destination == path }
            let state = try classifyFile(path, old: old, new: entry == nil ? nil : write.sha256)
            if completed { states[path] = state == .new ? .new : .other }
            else if state == .absent {
                states[path] = .other
            } else if state == .old, old == nil, entry?.state == .done, entry?.rollbackCompleted != true {
                states[path] = .other
            } else { states[path] = state }
        }
        return states
    }

    /// 복원 대상의 허용 상태는 해당 연산의 의도·temp·완료 기록으로만 정한다.
    func restorationState(_ path: String) throws -> DatabaseState? {
        guard let entry = journal.restorations?.first(where: { $0.destination == path }) else { return nil }
        if entry.phase == .externalChanged { return .other }
        if entry.phase == .done {
            return try classifyFile(path, old: entry.backupSHA256, new: nil) == .old ? .old : .other
        }
        if let expectedLink = entry.expectedLink {
            if try restorationLinkIdentity(path) == expectedLink { return .old }
        } else if try classifyFile(path, old: entry.expectedSHA256, new: nil) == .old { return .old }
        if entry.phase == .deleteEntered, try classifyFile(path, old: nil, new: nil) == .old { return .old }
        if entry.phase == .renameEntered {
            if try classifyFile(path, old: entry.backupSHA256, new: nil) == .old { return .old }
        }
        return .other
    }

    /// 옛것·새것과 다른 파일, 링크, 비어 버린 원래 경로를 구분한다. 부모 링크도 따라가지 않는다.
    func classifyFile(_ path: String, old: String?, new: String?) throws -> DatabaseState {
        var current = root.url
        let components = path.split(separator: "/")
        for (index, component) in components.enumerated() {
            current = current.appending(path: String(component))
            guard let info = try fs.stat(current) else { return old == nil ? .old : .absent }
            if index < components.count - 1 {
                guard info.kind == .directory else { return .other }
            } else {
                guard info.kind == .file else { return .other }
                let sha = try fs.sha256(current, uncached: true)
                if let new, sha == new { return .new }
                if let old, sha == old { return .old }
                return .other
            }
        }
        return .other
    }

    /// 자동 rollback·회복은 같은 분류를 쓴다. 판정 뒤에도 파일을 바꾸기 직전에 다시 확인한다.
    func requireUnchangedNativeFiles() throws {
        guard journal.changes.syncSelection != nil else { return }
        guard let manifest, manifest.session == journal.session, manifest.volumeUUID.uppercased() == volumeKey else {
            throw UsbError.writeRefused([UsbWriter.journalUnreadableBlock])
        }
        if journal.externalChangesDetected == true { try nativeConflict() }
        if try nativeFileStates().values.contains(.other) { try nativeConflict() }
    }

    func nativeConflict() throws -> Never {
        journal.externalChangesDetected = true
        journal.restorationApprovalRequired = true
        if journal.state != .restorePending { try journal.move(to: .restorePending) }
        try saveJournal()
        throw UsbError.restorePending(reason: String(ui: "USB의 동기화 파일이나 DB가 그 사이 바뀌었습니다. 백업을 확인하고 기기 변경을 버리는 복원으로 되돌리세요"))
    }

    /// DB 대상마다: 옛 해시(없던 DB는 없음이 옛것)·새 해시·없음(rename 도중)·그 밖(기기가 바꿈)
    func classifyDatabases() throws -> [String: DatabaseState] {
        var states: [String: DatabaseState] = [:]
        for database in journal.changes.databases {
            let planned = journal.plannedDatabases.first { $0.destination == database.destination }
            guard let url = try? root.url(for: database.destination) else {
                states[database.destination] = .other
                continue
            }
            guard let info = try fs.stat(url) else {
                states[database.destination] = planned?.disposition == .created ? .old : .absent
                continue
            }
            guard info.kind == .file else {
                states[database.destination] = .other
                continue
            }
            let sha = try fs.sha256(url, uncached: true)
            if sha == database.sha256 {
                states[database.destination] = .new
            } else if planned?.disposition == .overwritten, sha == planned?.oldSHA256 {
                states[database.destination] = .old
            } else {
                states[database.destination] = .other
            }
        }
        return states
    }

    /// 대상이 없고 임시가 완전(새 해시)하면 rename을 마친다. 대상이 없고 임시가 불완전하면 덮어쓴 것은 백업에서 되살린다.
    /// 만들 파일 자리에 남의 파일이 생겼으면 false(되돌려야 한다)
    func completeInterruptedRenames() throws -> Bool {
        var ok = true
        for index in journal.databases.indices where journal.databases[index].state == .pending {
            let entry = journal.databases[index]
            let parent = UsbPath.parent(entry.destination)
            let temp = UsbPath.join(parent, entry.tempName)
            guard entry.writePhase == nil || entry.writePhase == .renameEntered, try !exists(entry.destination) else { continue }
            // rename 진입 뒤 DB가 없으면 FAT 두 단계 rename과 외부 삭제를 구분할 수 없다. 그래도 USB에 DB가 없는 채로
            // 승인을 기다리지 않고 준비한 새 DB(완전한 temp)로 마저 쓴다. 덮을 외부 내용은 없고 옛 DB는 백업에 있다.
            if try isComplete(temp, sha256: entry.newSHA256) {
                if entry.disposition == .created, try collides(entry.destination, temp: entry.tempName) {
                    ok = false
                    continue
                }
                try finishRename(temp: temp, destination: entry.destination)
                journal.databases[index].state = .done
                journal.databases[index].writePhase = .done
                try saveJournal()
            } else if entry.disposition == .overwritten {
                // 복원 연산을 시작하면 전체 회복의 방향도 rollback으로 고정한다.
                ok = false
                if journal.state != .restorePending { try journal.move(to: .restorePending); try saveJournal() }
                try restoreFromBackup(entry.destination)
            }
        }
        for index in journal.entries.indices where journal.entries[index].state == .pending {
            let entry = journal.entries[index]
            guard let tempName = entry.tempName else { continue }
            let temp = UsbPath.join(UsbPath.parent(entry.destination), tempName)
            guard entry.writePhase == nil || entry.writePhase == .renameEntered, try !exists(entry.destination) else { continue }
            // 덮어쓴 파일(분석 파일·그림·선택 파일 등)의 rename 진입 뒤 대상이 없으면 FAT 두 단계 rename이 끊긴 것인지 그 사이
            // 밖에서 지운 것인지 구분할 수 없다. 완전한 temp가 있어도 마저 쓰지 않고 승인을 받는 복원(`restorePending`)으로 멈춘다.
            // 추측해 쓰면 밖에서 한 변경을 덮거나 지운 파일을 되살린다. DB는 USB에 DB가 없는 채로 둘 수 없어 위에서 마저 쓴다.
            // (writePhase가 없는 옛 저널은 rename 진입을 적지 않아 아래 temp 해시로만 판단한다)
            if entry.disposition == .overwritten, entry.writePhase != nil { try restorationPending(path: entry.destination) }
            if let sha = entry.newSHA256, try isComplete(temp, sha256: sha) {
                if entry.disposition == .created, try collides(entry.destination, temp: tempName) {
                    ok = false
                    continue
                }
                try finishRename(temp: temp, destination: entry.destination)
                journal.entries[index].state = .done
                journal.entries[index].writePhase = .done
                try saveJournal()
            } else if entry.disposition == .overwritten {
                // 복원 연산을 시작하면 전체 회복의 방향도 rollback으로 고정한다.
                ok = false
                if journal.state != .restorePending { try journal.move(to: .restorePending); try saveJournal() }
                try restoreFromBackup(entry.destination)
            }
        }
        return ok
    }

    func isComplete(_ relative: String, sha256: String) throws -> Bool {
        guard let url = try? root.url(for: relative), let info = try fs.stat(url), info.kind == .file else { return false }
        return try fs.sha256(url, uncached: true) == sha256
    }

    func collides(_ destination: String, temp: String) throws -> Bool {
        do {
            try recheckCollision(destination, temp: temp)
            return false
        } catch UsbWriteFailure.failed {
            return true
        }
    }

    func finishRename(temp: String, destination: String) throws {
        let parent = UsbPath.parent(destination)
        try ensureMounted()
        try fs.rename(usb(temp), to: usb(destination))
        try removeExactAppleDouble(parent: parent, name: UsbPath.name(destination))
        try removeExactAppleDouble(parent: parent, name: UsbPath.name(temp))
        try fs.syncDirectory(usb(parent))
    }

    /// 남은 DB가 모두 옛것이고 준비 폴더의 새 DB가 온전하면 마저 쓸 수 있다
    func canResume(_ states: [String: DatabaseState]) -> Bool {
        for database in journal.changes.databases where states[database.destination] != .new {
            guard states[database.destination] == .old else { return false }
            let url = URL(filePath: database.staged)
            guard (try? fs.stat(url))??.size == database.size, (try? fs.sha256(url, uncached: false)) == database.sha256 else { return false }
        }
        return true
    }

    /// 아직 옛것인 DB를 이어서 교체한다(끊긴 항목의 임시 파일은 지우고 새로 쓴다)
    func resumeCommit(_ states: [String: DatabaseState]) throws {
        let remaining = Set(journal.changes.databases.map(\.destination).filter { states[$0] != .new })
        for index in journal.databases.indices.reversed() where remaining.contains(journal.databases[index].destination) {
            let entry = journal.databases[index]
            try removeIfPresent(UsbPath.join(UsbPath.parent(entry.destination), entry.tempName))
            journal.databases.remove(at: index)
        }
        try saveJournal()
        try commitDatabases(journal.changes, only: remaining)
    }

    /// 저널이 없으면 우리 폴더의 임시 파일을 알리기만 하고, `discardTemp`일 때만 지운다
    func recoverWithoutJournal(discardTemp: Bool) throws -> UsbWriteReport {
        var report = UsbWriteReport(outcome: .recovered, session: "")
        do {
            try ensureSameVolume()
            let temps = try UsbWriter.tempFiles(root: root, fileSystem: fs)
            if temps.isEmpty {
                report.notes.append(String(ui: "끝나지 않은 쓰기가 없습니다"))
            } else if discardTemp {
                for temp in temps {
                    try ensureMounted()
                    try fs.remove(usb(temp))
                }
                report.notes.append(String(ui: "끝나지 않은 쓰기의 임시 파일 \(temps.count)개를 지웠습니다"))
            } else {
                report.notes.append(String(ui: "쓰기 기록은 없고 임시 파일 \(temps.count)개가 있습니다. 지우려면 --discard-temp를 주세요"))
            }
        } catch UsbWriteFailure.volumeLost {
            throw volumeGone
        }
        return report
    }
}
