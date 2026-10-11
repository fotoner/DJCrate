import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// R3 재현은 임시 루트의 합성 바이트·저널만 사용한다.
extension UsbSyncSelectionPipelineTests {
    func expectNoUSBMutation(_ fs: FaultyUsbFileSystem) {
        let mutations = ["makeDirectory", "writeNew", "copyDataNew", "rename", "remove", "removeDirectoryIfEmpty", "setModificationDate"]
        #expect(!fs.calls.contains { !$0.contains("mac:") && mutations.contains(String($0.split(separator: " ")[0])) })
    }

    func saveSyntheticJournal(_ journal: UsbJournal, fixture: UsbChangeSetFixture) throws {
        try UsbJournal.encoder().encode(journal).write(to: fixture.paths.sessions.appending(path: fixture.volumeKey + ".json"))
    }

    func stripRestoreProgress(_ fixture: UsbChangeSetFixture) throws {
        let url = fixture.paths.sessions.appending(path: fixture.volumeKey + ".json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for key in ["discardDeviceChanges", "restorationBaseline", "restorations", "sidecarDeletions", "externalChangesDetected", "backupManifestSHA256", "restorationApprovalRequired"] { json.removeValue(forKey: key) }
        for key in ["entries", "databases"] {
            var entries = try #require(json[key] as? [[String: Any]])
            for index in entries.indices {
                entries[index].removeValue(forKey: "rollbackCompleted")
                entries[index].removeValue(forKey: "writePhase")
            }
            json[key] = entries
        }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    @Test("승인된 복원 재개도 완료 XML·DB·사이드카의 변경·삭제·링크에 새 승인을 요구한다",
          arguments: ["selection", "database", "sidecar"], ["modify", "delete", "link"])
    func approvedResumeRechecksCompletedTargets(kind: String, damage: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = try nativeChanges(fixture)
        for suffix in ["-wal", "-shm"] { fixture.write(UsbLayout.oneLibrary + suffix, Data(("old" + suffix).utf8)) }
        changes.base = try UsbWriter.databaseFingerprint(root: fixture.root, fileSystem: fixture.fileSystem())
        let original = fixture.tree()
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        run.close()
        fixture.write(UsbSyncSelectionFile.relativePath(for: .oneLibrary), Data("external-before-consent".utf8))
        expectPending { _ = try fixture.recover() }
        let path = kind == "selection" ? UsbSyncSelectionFile.relativePath(for: .deviceLibrary)
            : kind == "database" ? UsbLayout.exportExtPdb : UsbLayout.oneLibrary + "-wal"
        let crashing = fixture.fileSystem()
        var stopped = false
        crashing.onOperation = { op, url in
            if !stopped, op == .copyDataNew, crashing.relative(url) != nil,
               fixture.journal()?.restorations?.contains(where: { $0.destination == path && $0.phase == .done }) == true {
                stopped = true
                crashing.failAt = (operation: .copyDataNew, occurrence: 1, mode: .crash)
            }
        }
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: crashing, discardDeviceChanges: true) }
        #expect(stopped && fixture.journal()?.discardDeviceChanges == true)
        let folder = URL(filePath: try #require(fixture.journal()?.backupDirectory))
        let external = Data("external-after-done".utf8)
        let outside = fixture.source("outside-completed", external)
        if damage == "modify" { fixture.write(path, external) }
        else {
            try FileManager.default.removeItem(at: fixture.usb(path))
            if damage == "link" { try FileManager.default.createSymbolicLink(at: fixture.usb(path), withDestinationURL: outside) }
        }
        let beforeResume = fixture.tree()
        let fs = fixture.fileSystem()
        expectPending { _ = try fixture.recover(fileSystem: fs) }
        #expect(fixture.tree() == beforeResume)
        expectNoUSBMutation(fs)
        #expect(fixture.journal()?.isClosed == false)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: UsbWriter.restoredMarkerName).path))
        #expect(try Data(contentsOf: outside) == external)
        if damage == "link" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.usb(path).path) == outside.path) }
        #expect(throws: UsbError.self) { try fixture.restore() }
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("아직 복원하지 않은 DAT의 백업 항목 누락·null·부재 위장은 승인된 재개 전에 거부한다",
          arguments: [false, true], ["missing", "null", "absent"])
    func missingUnstartedBackupCoverageRejectsBeforeUSBIO(native: Bool, damage: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes: UsbChangeSet
        if native { changes = try nativeChanges(fixture) }
        else { fixture.seedEdit(); changes = try fixture.editChanges(removals: false) }
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        try run.journal.move(to: .cleaned)
        try run.closeJournal(.verified, outcome: .written)
        run.close()
        let crashing = fixture.fileSystem()
        crashing.failAt = (operation: .rename, occurrence: 1, mode: .crash)
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: crashing, discardDeviceChanges: true) }
        var journal = try #require(fixture.journal())
        journal.backupManifestSHA256 = nil
        try saveSyntheticJournal(journal, fixture: fixture)
        let path = UsbChangeSetFixture.keepAnalysis[0]
        #expect(journal.restorations?.contains(where: { $0.destination == path }) == false)
        let folder = URL(filePath: try #require(journal.backupDirectory))
        let url = folder.appending(path: "manifest.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for key in ["files", "before"] {
            var files = try #require(json[key] as? [String: Any])
            if damage == "null" { files[path] = NSNull() } else { files.removeValue(forKey: path) }
            json[key] = files
        }
        if damage == "absent" {
            var absent = try #require(json["absentBefore"] as? [String])
            absent.append(path)
            json["absentBefore"] = absent
        }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let before = fixture.tree()
        let fs = fixture.fileSystem()
        expectRefusal("journalUnreadable") { _ = try fixture.recover(fileSystem: fs) }
        #expect(fixture.tree() == before)
        expectNoUSBMutation(fs)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: UsbWriter.restoredMarkerName).path))
    }

    @Test("필수 삭제 백업·계획 DB·생성 파일의 원래 부재·대기 의도 누락은 USB 연산 전에 거부한다",
          arguments: ["removal", "planned-database", "sidecar", "created", "intent"])
    func manifestCoverageIncludesWholeJournal(scope: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit(extraSidecar: true)
        let changes = try fixture.editChanges()
        let fs = fixture.fileSystem()
        let run = try stagedNativeRun(changes, fixture: fixture, fs: fs)
        try run.backup(changes)
        try run.writeFiles(changes, isCancelled: { false })
        try run.commitDatabases(changes)
        if scope == "removal" { try run.cleanup(changes) }
        run.journal.state = .restorePending
        run.journal.restoringBackup = true
        run.journal.discardDeviceChanges = true
        run.journal.backupManifestSHA256 = nil
        let path: String
        switch scope {
        case "removal": path = UsbChangeSetFixture.goneAnalysis[0]
        case "sidecar": path = UsbLayout.oneLibrary + "-wal"
        case "planned-database":
            path = UsbLayout.oneLibrary
            run.journal.databases = []
        case "intent":
            path = UsbChangeSetFixture.keepAnalysis[0]
            run.journal.restorations = [.init(destination: path, operation: .replace,
                tempName: UsbLayout.tempName(session: changes.session, sequence: 500),
                backupSHA256: run.manifest?.files[path]?.sha256, expectedSHA256: changes.writes.first?.sha256, phase: .copying)]
        default: path = UsbChangeSetFixture.newAudio
        }
        try run.saveJournal()
        let folder = try #require(run.backupFolder)
        run.close()
        let url = folder.appending(path: "manifest.json")
        var manifest = try UsbJournal.decoder().decode(UsbManifest.self, from: Data(contentsOf: url))
        manifest.files.removeValue(forKey: path)
        manifest.before.removeValue(forKey: path)
        manifest.absentBefore.removeAll { $0 == path }
        try UsbJournal.encoder().encode(manifest).write(to: url)
        let before = fixture.tree()
        let resumed = fixture.fileSystem()
        expectRefusal("journalUnreadable") { _ = try fixture.recover(fileSystem: resumed) }
        #expect(fixture.tree() == before)
        expectNoUSBMutation(resumed)
    }

    @Test("옛 일반 USB 중단 복원은 done 원래 항목과 유일한 백업 temp를 내구 의도로 이어받는다",
          arguments: [UsbChangeSetFixture.keepAnalysis[0], UsbLayout.exportExtPdb])
    func legacyInterruptedRestoreAdoptsBackupTemp(path: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit(extraSidecar: true)
        let original = fixture.tree()
        try fixture.write(fixture.editChanges(removals: false))
        let crashing = fixture.fileSystem()
        crashing.renameTwoPhaseOn = path
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: crashing) }
        let intent = try #require(fixture.journal()?.restorations?.first { $0.destination == path })
        let temp = UsbPath.join(UsbPath.parent(path), try #require(intent.tempName))
        #expect(!fixture.exists(path) && fixture.exists(temp))
        try stripRestoreProgress(fixture)
        #expect(fixture.journal()?.restoringBackup == true && fixture.journal()?.restorations == nil)
        #expect(fixture.journal()?.backupManifestSHA256 == nil && fixture.journal()?.restorationApprovalRequired == nil)
        let resumed = fixture.fileSystem()
        var durableBeforeRename = false
        resumed.onOperation = { op, url in
            if op == .rename, resumed.relative(url) == path {
                durableBeforeRename = fixture.journal()?.restorations?.contains(where: {
                    $0.destination == path && $0.tempName == intent.tempName && $0.phase == .renameEntered
                }) == true
            }
        }
        #expect(try fixture.recover(fileSystem: resumed).outcome == .restored)
        #expect(durableBeforeRename)
        #expect(fixture.tree() == original)
    }

    @Test("모호한 옛 복원 temp는 근거를 지우지 않고 새 승인을 기다린다",
          arguments: ["duplicate", "partial", "foreign-session", "linked"])
    func uncertainLegacyRestoreKeepsEvidence(damage: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        try fixture.write(fixture.editChanges(removals: false))
        let path = UsbChangeSetFixture.keepAnalysis[0]
        let crashing = fixture.fileSystem()
        crashing.renameTwoPhaseOn = path
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: crashing) }
        let journal = try #require(fixture.journal())
        let intent = try #require(journal.restorations?.first { $0.destination == path })
        let temp = UsbPath.join(UsbPath.parent(path), try #require(intent.tempName))
        if damage == "duplicate" {
            fixture.write(UsbPath.join(UsbPath.parent(path), UsbLayout.tempName(session: journal.session, sequence: 600)), try #require(fixture.data(temp)))
        } else if damage == "partial" { fixture.write(temp, Data("partial".utf8)) }
        else {
            let data = try #require(fixture.data(temp))
            try FileManager.default.removeItem(at: fixture.usb(temp))
            if damage == "foreign-session" {
                fixture.write(UsbPath.join(UsbPath.parent(path), UsbLayout.tempName(session: "other-session", sequence: 600)), data)
            } else {
                let outside = fixture.source("outside-legacy-temp", data)
                try FileManager.default.createSymbolicLink(at: fixture.usb(temp), withDestinationURL: outside)
            }
        }
        try stripRestoreProgress(fixture)
        let before = fixture.tree()
        let fs = fixture.fileSystem()
        expectPending { _ = try fixture.recover(fileSystem: fs) }
        #expect(fixture.tree() == before && !fixture.exists(path))
        expectNoUSBMutation(fs)
        #expect(fixture.journal()?.state == .restorePending)
        let repeated = fixture.fileSystem()
        expectPending { _ = try fixture.recover(fileSystem: repeated) }
        #expect(fixture.tree() == before)
        expectNoUSBMutation(repeated)
    }

    @Test("rename 진입 기록 직후 외부 삭제는 FAT로 단정하지 않고 temp와 변경을 보존한다",
          arguments: ["write", "restore"])
    func deletionAfterRenameIntentRequiresConsent(stage: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let original = fixture.tree()
        let path = UsbSyncSelectionFile.relativePath(for: .oneLibrary)
        let fs = fixture.fileSystem()
        var injected = false
        fs.onOperation = { op, url in
            let entered: Bool
            // 파일 단계의 앞 항목도 renameEntered를 거친다. DB 뒤에 쓰는 이 선택 파일의 진입 기록에서만 끊는다.
            if stage == "write" {
                entered = fixture.journal()?.entries.last?.destination == path
                    && fixture.journal()?.entries.last?.writePhase == .renameEntered
            } else {
                entered = fixture.journal()?.restorations?.last?.destination == path
                    && fixture.journal()?.restorations?.last?.phase == .renameEntered
            }
            if !injected, entered, op == .syncDirectory, fs.relative(url) == nil {
                injected = true
                try! FileManager.default.removeItem(at: fixture.usb(path))
                fs.failSide = .mac
                fs.failAt = (operation: .syncDirectory, occurrence: 1, mode: .crash)
            }
        }
        if stage == "write" {
            let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
            try run.writeFiles(changes, isCancelled: { false })
            #expect(throws: (any Error).self) { try run.commitDatabases(changes) }
            run.close()
        } else {
            let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
            try run.journal.move(to: .cleaned)
            try run.closeJournal(.verified, outcome: .written)
            run.close()
            #expect(throws: (any Error).self) { try fixture.restore(fileSystem: fs) }
        }
        #expect(injected)
        let before = fixture.tree()
        let resumed = fixture.fileSystem()
        expectPending { _ = try fixture.recover(fileSystem: resumed) }
        #expect(fixture.tree() == before)
        expectNoUSBMutation(resumed)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("삭제 음원 복원은 기존 외부 파일·같은 이름 충돌·복사 중 출현을 승인 없이 덮지 않는다",
          arguments: ["existing", "collision", "during-copy"])
    func removedAudioDoesNotOverwriteExternalFile(race: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        try fixture.write(changes)
        let path = UsbChangeSetFixture.goneAudio
        let externalPath = race == "collision" ? path.replacingOccurrences(of: "gone.mp3", with: "GONE.MP3") : path
        let external = Data("external-audio".utf8)
        if race != "during-copy" { fixture.write(externalPath, external) }
        let fs = fixture.fileSystem()
        var injected = false
        fs.onOperation = { op, url in
            if race == "during-copy", !injected, op == .copyDataNew, fs.relative(url) != nil {
                injected = true
                fixture.write(path, external)
            }
        }
        expectPending { _ = try fixture.restore(fileSystem: fs) }
        #expect(fixture.data(externalPath) == external)
        #expect(!fs.calls.contains { $0.hasPrefix("rename ") && $0.hasSuffix(" -> " + path) })
        let beforeResume = fixture.tree()
        expectPending { _ = try fixture.recover() }
        #expect(fixture.tree() == beforeResume)
    }

    @Test("native 기본 복원의 최종 DB·XML 기준 불일치는 성공 표지를 남기지 않는다", arguments: [false, true])
    func nativeFinalBaselineMismatchCannotCloseSuccess(selection: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        try run.journal.move(to: .cleaned)
        try run.closeJournal(.verified, outcome: .written)
        run.close()
        let path = selection ? UsbSyncSelectionFile.relativePath(for: .oneLibrary) : UsbLayout.oneLibrary
        let fs = fixture.fileSystem()
        var injected = false
        fs.onOperation = { op, url in
            if !injected, op == .removeDirectoryIfEmpty,
               fixture.journal()?.restorations?.contains(where: { $0.destination == path && $0.phase == .done }) == true {
                injected = true
                fixture.write(path, Data("external-after-final-restoration".utf8))
            }
        }
        #expect(throws: UsbError.self) { try fixture.restore(fileSystem: fs) }
        #expect(injected)
        #expect(fixture.journal()?.isClosed == false)
        let folder = URL(filePath: try #require(fixture.journal()?.backupDirectory))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: UsbWriter.restoredMarkerName).path))
    }
}


extension UsbSyncSelectionPipelineTests {
    @Test("새 백업은 삭제 파일을 원래 부재로 위장한 manifest 변경도 전체 해시로 거부한다")
    func savedManifestDigestRejectsRemovedBackupAbsenceForgery() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        try fixture.write(changes)
        var journal = try #require(fixture.journal())
        #expect(journal.backupManifestSHA256 != nil)
        journal.state = .restorePending
        journal.restoringBackup = true
        journal.discardDeviceChanges = true
        try saveSyntheticJournal(journal, fixture: fixture)
        let folder = URL(filePath: try #require(journal.backupDirectory))
        let url = folder.appending(path: "manifest.json")
        var manifest = try UsbJournal.decoder().decode(UsbManifest.self, from: Data(contentsOf: url))
        let path = UsbChangeSetFixture.goneAnalysis[0]
        manifest.files.removeValue(forKey: path)
        manifest.before.removeValue(forKey: path)
        manifest.absentBefore.append(path)
        try UsbJournal.encoder().encode(manifest).write(to: url)
        let before = fixture.tree()
        let fs = fixture.fileSystem()
        expectRefusal("journalUnreadable") { _ = try fixture.recover(fileSystem: fs) }
        #expect(fixture.tree() == before)
        expectNoUSBMutation(fs)
    }

    @Test("음원 재사용과 원래 없던 비음원 삭제는 필수 백업 누락으로 오판하지 않는다")
    func manifestCoverageAllowsReuseAndOriginallyAbsentRemoval() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let path = UsbChangeSetFixture.goneArtwork[0]
        var changes = try fixture.editChanges()
        try FileManager.default.removeItem(at: fixture.usb(path))
        let original = fixture.tree()
        // 존재하던 때의 삭제 요청도 백업 시 부재로 기록할 수 있다. cleanup은 이미 없는 항목을 removed로 남긴다.
        changes.target.mustNotExist.insert(path)
        try fixture.write(changes)
        let journal = try #require(fixture.journal())
        #expect(journal.entries.contains(where: { $0.disposition == .reused }))
        let folder = URL(filePath: try #require(journal.backupDirectory))
        let manifest = try UsbJournal.decoder().decode(UsbManifest.self, from: Data(contentsOf: folder.appending(path: "manifest.json")))
        #expect(manifest.absentBefore.contains(path))
        #expect(try fixture.restore().outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("음원 원본의 부재·변경은 기존 알림 범위로 복원 완료를 허용한다", arguments: [false, true])
    func unavailableRemovedAudioStillHasEstablishedRestoreAllowance(missing: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let original = fixture.tree()
        let changes = try fixture.editChanges()
        try fixture.write(changes)
        let source = fixture.sources.appending(path: "gone/gone.mp3")
        if missing { try FileManager.default.removeItem(at: source) }
        else { try Data("changed-local-audio".utf8).write(to: source) }
        let result = try fixture.restore()
        #expect(result.outcome == .restored)
        #expect(result.notes.contains(where: { $0.contains(UsbChangeSetFixture.goneAudio) }))
        var expected = original
        expected.removeValue(forKey: UsbChangeSetFixture.goneAudio)
        #expect(fixture.tree() == expected)
    }

    @Test("native 최종 완료 함수는 복원 의도가 없는 DB·XML·새 WAL의 기준 불일치도 거부한다",
          arguments: ["database", "selection", "sidecar"], [false, true])
    func finalRestoreGateRequiresNativeBaseline(kind: String, approved: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try metadataChanges(fixture)
        let fs = fixture.fileSystem()
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        defer { run.close() }
        run.journal.state = .restorePending
        run.journal.restoringBackup = true
        run.journal.discardDeviceChanges = approved
        try run.saveJournal()
        let folder = try #require(run.backupFolder)
        let path = kind == "database" ? UsbLayout.oneLibrary : kind == "selection"
            ? UsbSyncSelectionFile.relativePath(for: .oneLibrary) : UsbLayout.oneLibrary + "-wal"
        fixture.write(path, Data("unrestored-baseline".utf8))
        #expect(try run.fingerprintMismatches().contains(path))
        if approved {
            // 전체 기준 없는 구형 승인은 최종 완료 함수에서도 미기록 대상을 자동 승인하지 않는다.
            expectPending { _ = try run.finishRestore(errors: [], folder: folder, reason: "합성 최종 관문") }
            #expect(fixture.journal()?.state == .restorePending && fixture.journal()?.restorationApprovalRequired == true)
        } else {
            #expect(throws: UsbError.self) { _ = try run.finishRestore(errors: [], folder: folder, reason: "합성 최종 관문") }
            #expect(fixture.journal()?.state == .restoreFailed)
        }
        expectNoUSBMutation(fs)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: UsbWriter.restoredMarkerName).path))
    }

    @Test("진입 기록을 내리는 동안 변한 XML은 같은 실행의 마지막 검사에서도 덮지 않는다")
    func writeRechecksAfterDurableRenameEntry() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let fs = fixture.fileSystem()
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        defer { run.close() }
        try run.writeFiles(changes, isCancelled: { false })
        let path = UsbSyncSelectionFile.relativePath(for: .oneLibrary)
        var injected = false
        fs.onOperation = { op, url in
            if !injected, op == .syncDirectory, fs.relative(url) == nil,
               fixture.journal()?.entries.last?.destination == path,
               fixture.journal()?.entries.last?.writePhase == .renameEntered {
                injected = true
                try! FileManager.default.removeItem(at: fixture.usb(path))
            }
        }
        expectPending { try run.commitDatabases(changes) }
        #expect(injected && !fixture.exists(path))
        #expect(fixture.journal()?.entries.last?.writePhase == .externalChanged)
        #expect(!fs.calls.contains { $0.hasPrefix("rename ") && $0.hasSuffix(" -> " + path) })
        let before = fixture.tree()
        expectPending { _ = try run.rollback(mode: .write) }
        #expect(fixture.tree() == before)
    }
}


extension UsbSyncSelectionPipelineTests {
    @Test("사이드카 삭제 진입 직후 중단도 외부 삭제와 구분하지 않고 USB 트리를 보존한다")
    func interruptedSidecarDeletionRequiresExplicitRestore() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = try nativeChanges(fixture)
        let path = UsbLayout.oneLibrary + "-wal"
        fixture.write(path, Data("original-wal".utf8))
        changes.base = try UsbWriter.databaseFingerprint(root: fixture.root, fileSystem: fixture.fileSystem())
        let original = fixture.tree()
        let fs = fixture.fileSystem()
        let run = try preparedRun(changes, fixture: fixture, fileSystem: fs)
        try run.writeFiles(changes, isCancelled: { false })
        var injected = false
        fs.onOperation = { op, url in
            if !injected, op == .syncDirectory, fs.relative(url) == nil,
               fixture.journal()?.sidecarDeletions?.last?.phase == .deleteEntered {
                injected = true
                try! FileManager.default.removeItem(at: fixture.usb(path))
                fs.failSide = .mac
                fs.failAt = (operation: .syncDirectory, occurrence: 1, mode: .crash)
            }
        }
        #expect(throws: (any Error).self) { try run.commitDatabases(changes) }
        run.close()
        #expect(injected)
        let before = fixture.tree()
        let resumed = fixture.fileSystem()
        expectPending { _ = try fixture.recover(fileSystem: resumed) }
        #expect(fixture.tree() == before)
        expectNoUSBMutation(resumed)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
    }
}
