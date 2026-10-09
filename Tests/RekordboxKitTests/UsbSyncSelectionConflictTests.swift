import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 생산 XML 계약을 열지 않고 합성 내부 단계·임시 USB 루트에서 외부 변경 보존을 재현한다.
extension UsbSyncSelectionPipelineTests {
    func metadataChanges(_ fixture: UsbChangeSetFixture) throws -> UsbChangeSet {
        var changes = try nativeChanges(fixture)
        changes.databases = []
        changes.copies = []
        changes.writes = changes.writes.filter { $0.afterDatabases == true }
        changes.target.mustExist = changes.target.mustExist.filter { path, _ in
            UsbWriter.databaseOrder.contains(path) || UsbSyncSelectionStage.isSelectionPath(path)
        }
        for path in UsbWriter.databaseOrder {
            let data = try #require(fixture.data(path))
            changes.target.mustExist[path] = .init(size: Int64(data.count), sha256: UsbChangeSetFixture.sha256(data))
        }
        return changes
    }

    func finishNative(_ changes: UsbChangeSet, fixture: UsbChangeSetFixture, fs: FaultyUsbFileSystem) throws -> UsbWriteRun {
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        do {
            try run.writeFiles(changes, isCancelled: { false })
            try run.commitDatabases(changes)
            return run
        } catch { run.close(); throw error }
    }

    func expectPending(_ action: () throws -> Void) {
        #expect { try action() } throws: { error in
            if case UsbError.restorePending = error { true } else { false }
        }
    }

    func expectRefusal(_ code: String, _ action: () throws -> Void) {
        #expect { try action() } throws: { error in
            if case let UsbError.writeRefused(blocks) = error { blocks.contains { $0.code == code } } else { false }
        }
    }

    @Test("native 회복은 DB 교체 뒤 새 사이드카를 그대로 보존한다", arguments: ["-wal", "-shm", "-journal"])
    func newSidecarStopsNativeRecovery(suffix: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        run.close()
        fixture.write(UsbLayout.oneLibrary + suffix, Data("합성 외부 사이드카".utf8))
        let before = fixture.tree()
        expectPending { _ = try fixture.recover() }
        #expect(fixture.tree() == before)
        #expect(fixture.journal()?.state == .restorePending)
    }

    @Test("선택만 쓰던 회복도 교체하지 않은 DB의 변경·삭제·링크를 보존한다", arguments: ["modify", "delete", "symlink"])
    func metadataOnlyProtectsUnreplacedDatabase(change: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try metadataChanges(fixture)
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fixture.fileSystem())
        try run.writeFiles(changes, isCancelled: { false })
        run.close()
        let path = UsbLayout.exportPdb
        let outside = fixture.source("external.bin", Data("합성 외부 원문".utf8))
        if change == "modify" { fixture.write(path, Data("합성 외부 DB".utf8)) }
        else {
            try FileManager.default.removeItem(at: fixture.usb(path))
            if change == "symlink" { try FileManager.default.createSymbolicLink(at: fixture.usb(path), withDestinationURL: outside) }
        }
        let before = fixture.tree()
        expectPending { _ = try fixture.recover() }
        #expect(fixture.tree() == before)
        #expect(try Data(contentsOf: outside) == Data("합성 외부 원문".utf8))
        if change == "symlink" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.usb(path).path) == outside.path) }
        expectRefusal("recoveryNeeded") { _ = try fixture.restore() }
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree()[path] == changes.base?.files[path]?.sha256)
    }

    @Test("직접 쓰기 실패 rollback도 완료된 선택 XML의 외부 변경을 덮지 않는다", arguments: ["modify", "delete", "symlink"])
    func automaticRollbackProtectsDoneSelection(change: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let fs = fixture.fileSystem()
        let run = try finishNative(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        let outside = fixture.source("external.xml", Data("합성 외부 XML".utf8))
        if change == "modify" { fixture.write(path, Data("합성 외부 선택".utf8)) }
        else {
            try FileManager.default.removeItem(at: fixture.usb(path))
            if change == "symlink" { try FileManager.default.createSymbolicLink(at: fixture.usb(path), withDestinationURL: outside) }
        }
        let before = fixture.tree()
        expectPending { _ = try run.rollback(mode: .write) }
        #expect(fixture.tree() == before)
        #expect(fixture.journal()?.state == .restorePending)
        #expect(try Data(contentsOf: outside) == Data("합성 외부 XML".utf8))
    }

    @Test("완료 후 XML 변경·삭제는 기본 복원이 거부하고 명시적 폐기만 복원한다", arguments: ["modify", "delete", "symlink"])
    func completedRestoreRequiresConsentForSelection(change: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let original = fixture.tree()
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        try run.journal.move(to: .cleaned)
        try run.closeJournal(.verified, outcome: .written)
        run.close()
        let path = UsbSyncSelectionFile.relativePath(for: .oneLibrary)
        let outside = fixture.source("external.xml", Data("합성 외부 XML".utf8))
        if change == "modify" { fixture.write(path, Data("합성 외부 선택".utf8)) }
        else {
            try FileManager.default.removeItem(at: fixture.usb(path))
            if change == "symlink" { try FileManager.default.createSymbolicLink(at: fixture.usb(path), withDestinationURL: outside) }
        }
        let before = fixture.tree()
        expectRefusal("deviceChanged") { _ = try fixture.restore() }
        #expect(fixture.tree() == before)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
        #expect(try Data(contentsOf: outside) == Data("합성 외부 XML".utf8))
    }

    @Test("두 선택 파일 각각의 모호한 FAT 중단은 보존하고 승인한 복원으로만 되돌린다", arguments: UsbFormat.allCases)
    func selectionTwoPhaseRenameRecovers(format: UsbFormat) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let before = fixture.tree()
        let fs = fixture.fileSystem()
        fs.renameTwoPhaseOn = UsbSyncSelectionFile.relativePath(for: format)
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        try run.writeFiles(changes, isCancelled: { false })
        #expect(throws: (any Error).self) { try run.commitDatabases(changes) }
        run.close()
        #expect(fs.isCrashed)
        let interrupted = fixture.tree()
        expectPending { _ = try fixture.recover() }
        #expect(fixture.tree() == interrupted)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == before)
        #expect(fixture.journal()?.isClosed == true)
    }

    @Test("원래 선택 파일이 없어도 임시가 없거나 불완전하면 외부 삭제로 보존한다", arguments: [false, true])
    func missingSelectionWithoutCompleteTempRequiresConsent(partial: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let fs = fixture.fileSystem()
        fs.renameTwoPhaseOn = UsbSyncSelectionFile.relativePath(for: .oneLibrary)
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        try run.writeFiles(changes, isCancelled: { false })
        #expect(throws: (any Error).self) { try run.commitDatabases(changes) }
        run.close()
        let entry = try #require(fixture.journal()?.entries.last)
        let temp = UsbPath.join(UsbPath.parent(entry.destination), try #require(entry.tempName))
        if partial { fixture.write(temp, Data("partial".utf8)) }
        else { try FileManager.default.removeItem(at: fixture.usb(temp)) }
        let before = fixture.tree()
        expectPending { _ = try fixture.recover() }
        #expect(fixture.tree() == before)
    }

    @Test("restorePending 복원 승인은 다른 백업·세션·미완료 저널을 우회하지 않는다", arguments: ["folder", "session", "state", "volume"])
    func explicitRestoreMustMatchPendingJournal(field: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        run.close()
        fixture.write(UsbSyncSelectionFile.relativePath(for: .oneLibrary), Data("external".utf8))
        expectPending { _ = try fixture.recover() }
        var journal = try #require(fixture.journal())
        let folder = URL(filePath: try #require(journal.backupDirectory))
        var requested = folder
        switch field {
        case "folder":
            requested = folder.deletingLastPathComponent().appending(path: "other")
            try FileManager.default.copyItem(at: folder, to: requested)
        case "session":
            var manifest = try UsbJournal.decoder().decode(UsbManifest.self, from: Data(contentsOf: folder.appending(path: "manifest.json")))
            manifest.session = "other-session"
            try UsbJournal.encoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
        case "volume": journal.volumeUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        default: journal.state = .committing
        }
        try UsbJournal.encoder().encode(journal).write(to: fixture.paths.sessions.appending(path: fixture.volumeKey + ".json"))
        let before = fixture.tree()
        #expect(throws: UsbError.self) { try fixture.restore(backup: requested, discardDeviceChanges: true) }
        #expect(fixture.tree() == before)
    }
}

extension UsbSyncSelectionPipelineTests {
    @Test("DB 교체와 선택 확정 사이의 새 WAL은 실패 rollback에서도 보존한다")
    func sidecarAppearingBeforeSelectionStopsCommitAndRollback() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let fs = fixture.fileSystem()
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        defer { run.close() }
        try run.writeFiles(changes, isCancelled: { false })
        for db in UsbWriteRun.orderedDatabases(changes) { try run.commitDatabase(db) }
        fixture.write(UsbLayout.oneLibrary + "-wal", Data("external".utf8))
        let before = fixture.tree()
        expectPending { try run.writeSelectionFiles(changes) }
        expectPending { _ = try run.rollback(mode: .write) }
        #expect(fixture.tree() == before)
    }

    @Test("선택만 바꿀 때 원래 사이드카의 외부 삭제도 회복이 보존한다")
    func metadataOnlyProtectsDeletedOriginalSidecar() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = try metadataChanges(fixture)
        fixture.write(UsbLayout.oneLibrary + "-wal", Data("old-sidecar".utf8))
        changes.base = try UsbWriter.databaseFingerprint(root: fixture.root, fileSystem: fixture.fileSystem())
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fixture.fileSystem())
        try run.writeFiles(changes, isCancelled: { false })
        run.close()
        try FileManager.default.removeItem(at: fixture.usb(UsbLayout.oneLibrary + "-wal"))
        let before = fixture.tree()
        expectPending { _ = try fixture.recover() }
        #expect(fixture.tree() == before)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.data(UsbLayout.oneLibrary + "-wal") == Data("old-sidecar".utf8))
    }

    @Test("승인한 복원이 다시 끊겨도 회복은 같은 폐기 승인을 이어받는다")
    func interruptedExplicitRestoreRetainsConsent() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let original = fixture.tree()
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        run.close()
        fixture.write(UsbSyncSelectionFile.relativePath(for: .oneLibrary), Data("external".utf8))
        expectPending { _ = try fixture.recover() }
        let fs = fixture.fileSystem()
        fs.failAt = (operation: .rename, occurrence: 1, mode: .crash)
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: fs, discardDeviceChanges: true) }
        #expect(fixture.journal()?.restoringBackup == true)
        #expect(fixture.journal()?.discardDeviceChanges == true)
        #expect(try fixture.recover().outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("옛 일반 USB 저널은 새 복원 필드 없이 읽고 회복·완료 복원도 이어간다")
    func oldNonNativeJournalRecoversAndRestores() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit(extraSidecar: true)
        let before = fixture.tree()
        let changes = try fixture.editChanges(removals: false)
        let fs = fixture.fileSystem()
        fs.failAt = (operation: .rename, occurrence: 2, mode: .crash)
        fs.failMatching = { UsbWriter.databaseOrder.contains($0) }
        #expect(throws: (any Error).self) { try fixture.write(changes, fileSystem: fs) }
        let url = fixture.paths.sessions.appending(path: fixture.volumeKey + ".json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for key in ["discardDeviceChanges", "restorations", "sidecarDeletions", "externalChangesDetected", "backupManifestSHA256", "restorationApprovalRequired"] { json.removeValue(forKey: key) }
        for key in ["entries", "databases"] {
            var entries = try #require(json[key] as? [[String: Any]])
            for index in entries.indices {
                entries[index].removeValue(forKey: "rollbackCompleted")
                entries[index].removeValue(forKey: "writePhase")
            }
            json[key] = entries
        }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(fixture.journal()?.discardDeviceChanges == nil)
        #expect(fixture.journal()?.restorations == nil && fixture.journal()?.sidecarDeletions == nil && fixture.journal()?.externalChangesDetected == nil)
        #expect(fixture.journal()?.entries.allSatisfy { $0.writePhase == nil } == true)
        #expect(fixture.journal()?.entries.allSatisfy { $0.rollbackCompleted == nil } == true)
        #expect(try fixture.recover().outcome == .recovered)
        #expect(try fixture.restore().outcome == .restored)
        #expect(fixture.tree() == before)
    }
}

extension UsbSyncSelectionPipelineTests {
    @Test("새 native 내보내기 rollback은 생성한 선택 파일과 DB를 모두 지우고 정상적으로 닫을 수 있다")
    func newNativeExportRollbackRemovesCreatedSelectionAndDatabases() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = fixture.exportChanges()
        var context = UsbExportAssembly.Context(staging: fixture.folder.appending(path: "sync-staging"))
        let draft = UsbSyncSelectionDraft(localDBID: 42, sourceNodes: [], selection: .init(), enabled: true,
                                          playlistRefs: [:], baseFiles: [:])
        changes.syncSelection = try UsbSyncSelectionStage.stage(draft, formats: Self.formats, model: .empty, createdIDs: [:],
            root: fixture.root, fileSystem: fixture.fileSystem(), into: &context, contract: Self.contract)
        changes.writes += context.writes
        changes.target.mustExist.merge(context.target) { _, new in new }
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        defer { run.close() }
        #expect(try run.rollback(mode: .write).isEmpty)
        #expect(fixture.tree().isEmpty)
        try run.closeJournal(.rolledBack, outcome: .rolledBack)
        #expect(fixture.journal()?.isClosed == true)
    }

    @Test("rollback 백업을 복사하는 중 선택 XML이 바뀌어도 마지막 rename 전에 멈춘다")
    func externalSelectionChangeDuringRollbackCopyIsPreserved() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let fs = fixture.fileSystem()
        let run = try finishNative(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        let path = UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
        var changed = false
        fs.onOperation = { op, url in
            if !changed, op == .copyDataNew, fs.relative(url).map({ UsbLayout.isTemp(UsbPath.name($0)) }) == true {
                changed = true
                fixture.write(path, Data("external-during-rollback".utf8))
            }
        }
        expectPending { _ = try run.rollback(mode: .write) }
        #expect(changed)
        #expect(fixture.data(path) == Data("external-during-rollback".utf8))
        for db in changes.databases { #expect(fixture.tree()[db.destination] == db.sha256) }
        #expect(fixture.journal()?.state == .restorePending)
    }

    @Test("DB 첫 교체 전에 들어온 WAL도 폐기를 승인한 복원으로만 제거한다")
    func explicitRestoreDiscardsSidecarBeforeDatabaseWasApplied() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let original = fixture.tree()
        let fs = fixture.fileSystem()
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        try run.writeFiles(changes, isCancelled: { false })
        var injected = false
        fs.onOperation = { op, url in
            if !injected, op == .writeNew, fs.relative(url).map({ $0.hasPrefix(UsbLayout.rekordboxDir + "/.djc-part-") }) == true {
                injected = true
                fixture.write(UsbLayout.oneLibrary + "-wal", Data("external-before-db".utf8))
            }
        }
        expectPending { try run.commitDatabases(changes) }
        run.close()
        #expect(injected)
        #expect(fixture.data(UsbLayout.oneLibrary + "-wal") == Data("external-before-db".utf8))
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
    }
}

extension UsbSyncSelectionPipelineTests {
    @Test("정상적인 선택 전용 쓰기는 기존 DB·사이드카를 유지하며 회복·기본 복원한다", arguments: [false, true])
    func metadataOnlyNormalRollbackAndRestorePreserveOriginalDatabase(completed: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = try metadataChanges(fixture)
        fixture.write(UsbLayout.oneLibrary + "-wal", Data("original-sidecar".utf8))
        changes.base = try UsbWriter.databaseFingerprint(root: fixture.root, fileSystem: fixture.fileSystem())
        let original = fixture.tree()
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        if completed {
            try run.journal.move(to: .cleaned)
            try run.closeJournal(.verified, outcome: .written)
        }
        run.close()
        let report: UsbWriteReport
        if completed { report = try fixture.restore() }
        else { report = try fixture.recover() }
        #expect(report.outcome == (completed ? .restored : .rolledBack))
        #expect(fixture.tree() == original)
        #expect(fixture.journal()?.isClosed == true)
    }
}
