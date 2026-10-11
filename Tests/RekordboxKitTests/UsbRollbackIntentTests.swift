import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 모두 임시 루트와 합성 바이트만 쓴다. 생산 XML 계약과 실행 검증은 열지 않는다.
extension UsbSyncSelectionPipelineTests {
    func stagedNativeRun(_ changes: UsbChangeSet, fixture: UsbChangeSetFixture, fs: FaultyUsbFileSystem) throws -> UsbWriteRun {
        let run = try UsbWriteRun.open(root: fixture.root, paths: fixture.paths, guard: fixture.writeGuard(), fileSystem: fs,
                                      ppthReader: UsbChangeSetFixture.ppthReader, now: .now, progress: { _ in })
        let plan = UsbWriteRun.Plan(databases: changes.databases.map {
            .init(destination: $0.destination, disposition: changes.base?.files[$0.destination] == nil ? .created : .overwritten,
                  oldSHA256: changes.base?.files[$0.destination]?.sha256)
        })
        do { try run.stage(changes, plan: plan); return run }
        catch { run.close(); throw error }
    }

    @Test("native 백업은 준비 뒤의 WAL·선택 전용 DB 변경을 새 기준으로 삼지 않는다",
          arguments: ["wal-before", "wal-during", "db-before", "db-during"])
    func backupCannotAdoptExternalBaseline(race: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try race.hasPrefix("db") ? metadataChanges(fixture) : nativeChanges(fixture)
        let fs = fixture.fileSystem()
        let run = try stagedNativeRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        let path = race.hasPrefix("db") ? UsbLayout.exportPdb : UsbLayout.oneLibrary + "-wal"
        let external = Data("합성 백업 중 외부 변경".utf8)
        var injected = false
        if race.hasSuffix("before") { fixture.write(path, external); injected = true }
        else {
            fs.onOperation = { op, url in
                if !injected, op == .fullSync, fs.relative(url) == nil, url.path.contains("/files/") {
                    injected = true
                    fixture.write(path, external)
                }
            }
        }
        #expect(throws: UsbError.self) { try run.backup(changes) }
        #expect(injected)
        #expect(fixture.data(path) == external)
        #expect(fixture.backupFolders().isEmpty)
        #expect(!fs.calls.contains { $0.hasPrefix("rename ") && !$0.contains("mac:") })
    }

    @Test("빈 native 계획 base는 기존 DB를 백업의 새 기준으로 삼지 않는다", arguments: [false, true])
    func emptyNativeBaseCannotAdoptExistingFiles(nilBase: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = try nativeChanges(fixture)
        changes.base = nilBase ? nil : .init(files: [:])
        let before = fixture.tree()
        let fs = fixture.fileSystem()
        let run = try stagedNativeRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        #expect(throws: UsbError.self) { try run.backup(changes) }
        #expect(fixture.tree() == before)
        #expect(fixture.backupFolders().isEmpty)
    }

    @Test("WAL·SHM 백업 복사 중 외부 변경은 최종 복원 rename 전에 보존한다", arguments: ["-wal", "-shm"])
    func sidecarCopyRechecksTarget(suffix: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = try nativeChanges(fixture)
        for value in ["-wal", "-shm"] { fixture.write(UsbLayout.oneLibrary + value, Data(("old" + value).utf8)) }
        changes.base = try UsbWriter.databaseFingerprint(root: fixture.root, fileSystem: fixture.fileSystem())
        let fs = fixture.fileSystem()
        let run = try finishNative(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        let path = UsbLayout.oneLibrary + suffix
        let external = Data("합성 복원 중 외부 사이드카".utf8)
        var injected = false
        fs.onOperation = { op, url in
            if !injected, op == .copyDataNew, fs.relative(url) != nil,
               fixture.journal()?.restorations?.last?.destination == path {
                injected = true
                fixture.write(path, external)
            }
        }
        expectPending { _ = try run.rollback(mode: .write) }
        #expect(injected)
        #expect(fixture.data(path) == external)
        #expect(!fs.calls.contains { $0.hasPrefix("rename ") && $0.hasSuffix(" -> " + path) })
    }

    @Test("되살린 사이드카의 후속 변경·삭제는 옛 삭제 기록으로 허용하지 않는다", arguments: [false, true])
    func restoredSidecarCannotUseOldDeletionAllowance(deleted: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = try nativeChanges(fixture)
        for suffix in ["-wal", "-shm"] { fixture.write(UsbLayout.oneLibrary + suffix, Data(("old" + suffix).utf8)) }
        changes.base = try UsbWriter.databaseFingerprint(root: fixture.root, fileSystem: fixture.fileSystem())
        let original = fixture.tree()
        let fs = fixture.fileSystem()
        let run = try finishNative(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        let path = UsbLayout.oneLibrary + "-wal"
        var injected = false
        fs.onOperation = { op, url in
            if !injected, op == .copyDataNew, fs.relative(url) != nil,
               fixture.journal()?.restorations?.contains(where: { $0.destination == path && $0.phase == .done }) == true {
                injected = true
                if deleted { try! FileManager.default.removeItem(at: fixture.usb(path)) }
                else { fixture.write(path, Data("external-after-restoration".utf8)) }
            }
        }
        expectPending { _ = try run.rollback(mode: .write) }
        #expect(injected)
        #expect(deleted ? !fixture.exists(path) : fixture.data(path) == Data("external-after-restoration".utf8))
        run.close()
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("사이드카 삭제 의도는 한 항목씩 기록해 아직 들어가지 않은 다음 삭제를 삼키지 않는다")
    func sidecarDeletionIntentCannotCoverNextSidecar() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = try nativeChanges(fixture)
        for suffix in ["-wal", "-shm"] { fixture.write(UsbLayout.oneLibrary + suffix, Data(("old" + suffix).utf8)) }
        changes.base = try UsbWriter.databaseFingerprint(root: fixture.root, fileSystem: fixture.fileSystem())
        let fs = fixture.fileSystem()
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        defer { run.close() }
        try run.writeFiles(changes, isCancelled: { false })
        let deleted = UsbLayout.oneLibrary + "-shm"
        var injected = false
        fs.onOperation = { op, url in
            if !injected, op == .remove, fs.relative(url) == UsbLayout.oneLibrary + "-wal" {
                injected = true
                try! FileManager.default.removeItem(at: fixture.usb(deleted))
            }
        }
        expectPending { try run.commitDatabases(changes) }
        #expect(injected)
        #expect(fixture.journal()?.sidecarDeletions?.contains(where: { $0.destination == deleted }) == false)
        let before = fixture.tree()
        expectPending { _ = try run.rollback(mode: .write) }
        #expect(fixture.tree() == before)
        #expect(!fixture.exists(deleted))
    }

    @Test("완전한 원래 쓰기 temp가 있어도 rename 전에 발견한 외부 XML 삭제를 되돌리지 않는다")
    func deletionBeforeWriteRenameIsStickyConflict() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let fs = fixture.fileSystem()
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        try run.writeFiles(changes, isCancelled: { false })
        let path = UsbSyncSelectionFile.relativePath(for: .oneLibrary)
        var injected = false
        fs.onOperation = { op, url in
            if !injected, op == .fullSync, fs.relative(url) != nil,
               let entry = fixture.journal()?.entries.last, entry.destination == path, entry.state == .pending {
                injected = true
                try! FileManager.default.removeItem(at: fixture.usb(path))
            }
        }
        #expect(throws: (any Error).self) { try run.commitDatabases(changes) }
        #expect(injected)
        let before = fixture.tree()
        expectPending { _ = try run.rollback(mode: .write) }
        #expect(fixture.tree() == before)
        #expect(fixture.journal()?.entries.last?.writePhase == .externalChanged)
        run.close()
        expectPending { _ = try fixture.recover() }
        #expect(fixture.tree() == before)
    }

    @Test("rename 준비 검사 중 중단과 외부 삭제는 실제 rename 진입으로 해석하지 않는다")
    func interruptedRenameChecksDoNotGrantFATAbsence() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let fs = fixture.fileSystem()
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        try run.writeFiles(changes, isCancelled: { false })
        let path = UsbSyncSelectionFile.relativePath(for: .oneLibrary)
        var injected = false
        fs.onOperation = { op, url in
            if !injected, op == .syncDirectory, fs.relative(url) == nil,
               fixture.journal()?.entries.last?.destination == path,
               fixture.journal()?.entries.last?.writePhase == .renamePending {
                injected = true
                try! FileManager.default.removeItem(at: fixture.usb(path))
                fs.failSide = .mac
                fs.failAt = (operation: .syncDirectory, occurrence: 1, mode: .crash)
            }
        }
        #expect(throws: (any Error).self) { try run.commitDatabases(changes) }
        run.close()
        #expect(injected)
        #expect(fixture.journal()?.entries.last?.writePhase == .renamePending)
        let before = fixture.tree()
        expectPending { _ = try fixture.recover() }
        #expect(fixture.tree() == before)
    }

    @Test("완료 native 기본 복원의 모호한 XML FAT 중단은 temp를 보존하고 새 승인을 요구한다", arguments: UsbFormat.allCases)
    func restoreSelectionTwoPhaseRenameResumes(format: UsbFormat) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let before = fixture.tree()
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        try run.journal.move(to: .cleaned)
        try run.closeJournal(.verified, outcome: .written)
        run.close()
        let fs = fixture.fileSystem()
        let path = UsbSyncSelectionFile.relativePath(for: format)
        fs.renameTwoPhaseOn = path
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: fs) }
        #expect(fixture.journal()?.restorations?.contains(where: { $0.destination == path && $0.phase == .renameEntered }) == true)
        let interrupted = fixture.tree()
        expectPending { _ = try fixture.recover() }
        #expect(fixture.tree() == interrupted)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == before)
        #expect(fixture.journal()?.isClosed == true)
    }

    @Test("일반 USB의 새 복원 저널도 모호한 DAT FAT 중단을 보존하고 새 승인을 요구한다")
    func genericRestoreDATTwoPhaseRenameResumes() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let before = fixture.tree()
        try fixture.write(fixture.editChanges(removals: false))
        let fs = fixture.fileSystem()
        fs.renameTwoPhaseOn = UsbChangeSetFixture.keepAnalysis[0]
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: fs) }
        #expect(fs.isCrashed)
        let interrupted = fixture.tree()
        expectPending { _ = try fixture.recover() }
        #expect(fixture.tree() == interrupted)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == before)
    }

    @Test("일반 DAT 복원 중 외부 변경·삭제는 보존하고 같은 백업의 명시적 폐기 승인으로 재개한다", arguments: [false, true])
    func genericRestoreConflictNeedsFreshConsent(deleted: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let before = fixture.tree()
        try fixture.write(fixture.editChanges(removals: false))
        let fs = fixture.fileSystem()
        let path = UsbChangeSetFixture.keepAnalysis[0]
        var injected = false
        fs.onOperation = { op, url in
            if !injected, op == .copyDataNew, fs.relative(url) != nil,
               fixture.journal()?.restorations?.last?.destination == path {
                injected = true
                if deleted { try! FileManager.default.removeItem(at: fixture.usb(path)) }
                else { fixture.write(path, Data("external-generic-dat".utf8)) }
            }
        }
        #expect(throws: UsbError.self) { try fixture.restore(fileSystem: fs) }
        #expect(injected)
        #expect(deleted ? !fixture.exists(path) : fixture.data(path) == Data("external-generic-dat".utf8))
        #expect(throws: UsbError.self) { try fixture.recover() }
        #expect(deleted ? !fixture.exists(path) : fixture.data(path) == Data("external-generic-dat".utf8))
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == before)
    }

    @Test("일반 자동 rollback은 DB 복원 뒤 중단되어도 앞으로 쓰지 않고 복원으로 재개한다")
    func genericRollbackDirectionIsDurableBeforeUSBMutation() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let before = fixture.tree()
        let changes = try fixture.editChanges(removals: false)
        let fs = fixture.fileSystem()
        let run = try stagedNativeRun(changes, fixture: fixture, fs: fs)
        try run.backup(changes)
        try run.writeFiles(changes, isCancelled: { false })
        try run.commitDatabases(changes)
        fs.failAt = (operation: .syncDirectory, occurrence: 1, mode: .crash)
        fs.failMatching = { $0 == UsbLayout.rekordboxDir }
        #expect(throws: (any Error).self) { try run.rollback(mode: .write) }
        run.close()
        #expect(fixture.journal()?.state == .restorePending)
        #expect(fixture.journal()?.restoringBackup == false)
        #expect(fixture.tree()[UsbLayout.exportExtPdb] == changes.base?.files[UsbLayout.exportExtPdb]?.sha256)
        #expect(try fixture.recover().outcome == .rolledBack)
        #expect(fixture.tree() == before)
    }

    @Test("새 XML 삭제 뒤 완료 저널 저장 전 중단도 삭제 의도로 회복한다")
    func createdSelectionDeleteBeforeCompletionResumes() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = fixture.exportChanges()
        var context = UsbExportAssembly.Context(staging: fixture.folder.appending(path: "sync-staging"))
        changes.syncSelection = try UsbSyncSelectionStage.stage(
            .init(localDBID: 42, sourceNodes: [], selection: .init(), enabled: true, playlistRefs: [:], baseFiles: [:]),
            formats: Self.formats, model: .empty, createdIDs: [:], root: fixture.root, fileSystem: fixture.fileSystem(),
            into: &context, contract: Self.contract)
        changes.writes += context.writes
        changes.target.mustExist.merge(context.target) { _, new in new }
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        try run.journal.move(to: .cleaned)
        try run.closeJournal(.verified, outcome: .written)
        run.close()
        let fs = fixture.fileSystem()
        fs.failAt = (operation: .syncDirectory, occurrence: 1, mode: .crash)
        fs.failMatching = { $0 == UsbLayout.rekordboxDir }
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: fs) }
        let deletion = try #require(fixture.journal()?.restorations?.first { $0.phase == .deleteEntered })
        #expect(UsbSyncSelectionStage.isSelectionPath(deletion.destination))
        #expect(!fixture.exists(deletion.destination))
        #expect(try fixture.recover().outcome == .restored)
        #expect(fixture.tree().isEmpty)
    }

    @Test("승인한 복원 재개도 손상된 manifest·백업은 모든 USB 변경 전에 거부한다",
          arguments: ["missing", "decode", "session", "volume", "path", "missing-file", "damaged-file", "linked-file", "intent-path", "intent-temp", "intent-hash"])
    func approvedRestoreResumeRequiresValidBackup(damage: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        run.close()
        fixture.write(UsbSyncSelectionFile.relativePath(for: .oneLibrary), Data("external".utf8))
        expectPending { _ = try fixture.recover() }
        let crashing = fixture.fileSystem()
        crashing.failAt = (operation: .rename, occurrence: 1, mode: .crash)
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: crashing, discardDeviceChanges: true) }
        let folder = URL(filePath: try #require(fixture.journal()?.backupDirectory))
        let url = folder.appending(path: "manifest.json")
        var manifest = try UsbJournal.decoder().decode(UsbManifest.self, from: Data(contentsOf: url))
        switch damage {
        case "missing": try FileManager.default.removeItem(at: url)
        case "decode": try Data("{".utf8).write(to: url)
        case "session": manifest.session = "other"
        case "volume": manifest.volumeUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        case "path": manifest.absentBefore.append("../outside")
        case "intent-path", "intent-temp", "intent-hash":
            var journal = try #require(fixture.journal())
            let index = try #require(journal.restorations?.indices.first)
            if damage == "intent-path" { journal.restorations![index].destination = "../outside" }
            else if damage == "intent-temp" { journal.restorations![index].tempName = "../outside" }
            else { journal.restorations![index].backupSHA256 = "damaged" }
            try UsbJournal.encoder().encode(journal).write(to: fixture.paths.sessions.appending(path: fixture.volumeKey + ".json"))
        default:
            let target = folder.appending(path: "files").appending(path: UsbLayout.oneLibrary)
            if damage == "damaged-file" { try Data("damaged".utf8).write(to: target) }
            else {
                try FileManager.default.removeItem(at: target)
                if damage == "linked-file" {
                    let outside = fixture.source("outside-backup", Data("outside".utf8))
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
                }
            }
        }
        if ["session", "volume", "path"].contains(damage) { try UsbJournal.encoder().encode(manifest).write(to: url) }
        let before = fixture.tree()
        let fs = fixture.fileSystem()
        #expect(throws: UsbError.self) { try fixture.recover(fileSystem: fs) }
        #expect(fixture.tree() == before)
        let writes = ["makeDirectory", "writeNew", "copyDataNew", "rename", "remove", "removeDirectoryIfEmpty", "setModificationDate"]
        #expect(!fs.calls.contains { !$0.contains("mac:") && writes.contains(String($0.split(separator: " ")[0])) })
    }
}
