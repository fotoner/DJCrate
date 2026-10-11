import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// R5 회귀는 합성 파일·저널과 임시 USB 루트만 사용한다. 시험 실행은 별도 검증에서 한다.
extension UsbSyncSelectionPipelineTests {
    /// 승인 저널이 내려간 첫 순간 또는 앞 복원의 완료 저장 직후, 대상 의도 생성 전에 중단한다.
    func interruptBeforeApprovedIntent(_ fixture: UsbChangeSetFixture, path: String, afterFirst: Bool) throws {
        let fs = fixture.fileSystem()
        var stopped = false
        fs.onOperation = { op, url in
            guard !stopped, op == .syncDirectory, url.path == fixture.paths.sessions.path,
                  let journal = fixture.journal(), journal.restoringBackup, journal.discardDeviceChanges == true,
                  journal.restorations?.contains(where: { $0.destination == path }) != true else { return }
            let hasCompleted = journal.restorations?.contains(where: { $0.phase == .done }) == true
            if afterFirst ? hasCompleted : journal.restorations == nil {
                stopped = true
                fs.failSide = .mac
                fs.failAt = (operation: .syncDirectory, occurrence: 1, mode: .crash)
            }
        }
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: fs, discardDeviceChanges: true) }
        #expect(stopped && fixture.journal()?.state == .restorePending)
        #expect(fixture.journal()?.restorations?.contains(where: { $0.destination == path }) != true)
        if afterFirst { #expect(fixture.journal()?.restorations?.contains(where: { $0.phase == .done }) == true) }
        expectNoApprovalBaselineBytes(fixture)
    }

    func expectNoApprovalBaselineBytes(_ fixture: UsbChangeSetFixture) {
        let baseline = fixture.journal()?.restorationBaseline
        #expect(baseline != nil)
        #expect(baseline?.keys.allSatisfy(UsbWriter.isSafeRelativePath) == true)
        #expect(baseline?.values.allSatisfy { $0.sha256 == nil || ($0.sha256?.count == 64 && $0.link == nil) } == true)
    }

    @Test("승인 저장 직후·앞 복원 완료 뒤에도 아직 의도 없는 XML·DB·DAT 변경은 새 승인을 기다린다",
          arguments: ["selection", "database", "analysis"], ["first", "later"].flatMap { point in
              ["modify", "delete", "link"].map { point + ":" + $0 }
          })
    func approvedBaselineProtectsUnstartedTargets(kind: String, interruption: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let original = fixture.tree()
        try closeReplayWrite(changes, fixture: fixture)
        // 선택 파일은 역순으로 복원하므로 먼저 쓴 선택이 뒤쪽 대상이다.
        let path = kind == "selection" ? try #require(changes.writes.first { $0.afterDatabases == true }).destination
            : replayPath(kind)
        let parts = interruption.split(separator: ":").map(String.init)
        try interruptBeforeApprovedIntent(fixture, path: path, afterFirst: parts[0] == "later")
        #expect(fixture.journal()?.restorationBaseline?[path]?.sha256 == changes.target.mustExist[path]?.sha256)
        let folder = URL(filePath: try #require(fixture.journal()?.backupDirectory))
        let outside = try injectReplayChange(fixture, path: path, damage: parts[1])
        try expectReplayPreserved(fixture)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: UsbWriter.restoredMarkerName).path))
        #expect(try Data(contentsOf: outside) == Data("합성 링크 밖 내용".utf8))
        if parts[1] == "link" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.usb(path).path) == outside.path) }
        #expect(try fixture.restore(backup: folder, discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original && fixture.journal()?.state == .restored)
    }

    @Test("의도 없는 대상의 승인 기준은 내용·부재·끝 링크를 구분하며 그대로면 재개한다",
          arguments: ["content", "absent", "link"], [false, true])
    func unstartedApprovedTargetRetainsOriginalState(state: String, change: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try replayChanges(fixture, kind: "database")
        let original = fixture.tree()
        try closeReplayWrite(changes, fixture: fixture)
        let path = replayPath("database")
        var outside: URL?
        if state != "content" { outside = try injectReplayChange(fixture, path: path, damage: state == "link" ? "link" : "delete") }
        try interruptBeforeApprovedIntent(fixture, path: path, afterFirst: false)
        let baseline = try #require(fixture.journal()?.restorationBaseline?[path])
        #expect((baseline.sha256 != nil) == (state == "content"))
        #expect((baseline.link != nil) == (state == "link"))
        if change {
            if state == "link" {
                let replacement = fixture.usb(path + ".replacement-link")
                try FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: try #require(outside))
                try PosixUsbFileSystem(synchronizes: false).rename(replacement, to: fixture.usb(path))
            } else { fixture.write(path, Data("합성 기준 이후 새 내용".utf8)) }
            try expectReplayPreserved(fixture)
            #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        } else { #expect(try fixture.recover().outcome == .restored) }
        #expect(fixture.tree() == original)
    }

    @Test("전체 승인 기준은 XML 전용 DB·사이드카·생성 파일 삭제·로컬 삭제 음원·백업 AppleDouble을 포함한다",
          arguments: ["metadata-db", "metadata-sidecar", "sidecar", "delete", "audio", "appledouble"])
    func approvalCoversEveryReplacementAndDeletion(kind: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = try kind.hasPrefix("metadata") ? metadataChanges(fixture) : nativeChanges(fixture)
        let sidecar = UsbLayout.oneLibrary + "-wal"
        fixture.write(sidecar, Data("합성 기존 WAL".utf8))
        let companion = "PIONEER/rekordbox/._export.pdb"
        fixture.write(companion, Data("합성 기존 AppleDouble".utf8))
        changes.base = try UsbWriter.databaseFingerprint(root: fixture.root, fileSystem: fixture.fileSystem())
        if kind == "audio" {
            let removals = try fixture.editChanges().removals
            changes.removals = removals
            changes.target.mustNotExist = Set(removals.map(\.path))
            for removal in removals { changes.target.mustExist.removeValue(forKey: removal.path) }
        }
        let original = fixture.tree()
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        try run.cleanup(changes)
        try run.closeJournal(.verified, outcome: .written)
        run.close()
        let path: String
        switch kind {
        case "metadata-db": path = UsbLayout.exportExtPdb
        case "metadata-sidecar", "sidecar": path = sidecar
        case "delete": path = UsbChangeSetFixture.newAnalysis[0]
        case "audio": path = UsbChangeSetFixture.goneAudio
        default: path = companion
        }
        try interruptBeforeApprovedIntent(fixture, path: path, afterFirst: false)
        #expect(fixture.journal()?.restorationBaseline?[path] != nil)
        _ = try injectReplayChange(fixture, path: path, damage: "modify")
        try expectReplayPreserved(fixture)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("승인 기준을 읽은 뒤 첫 승인 저널 저장 중 바뀐 뒤쪽 DAT도 현재 해시를 다시 채택하지 않는다")
    func baselineIsFixedBeforeApprovalJournalSave() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let original = fixture.tree()
        try closeReplayWrite(changes, fixture: fixture)
        let path = UsbChangeSetFixture.keepAnalysis[0]
        let fs = fixture.fileSystem()
        var injected = false
        fs.onOperation = { op, url in
            if !injected, op == .rename, url.path == fixture.paths.sessions.appending(path: fixture.volumeKey + ".json").path {
                injected = true
                fixture.write(path, Data("합성 승인 저장 중 외부 내용".utf8))
            }
        }
        expectPending { _ = try fixture.restore(fileSystem: fs, discardDeviceChanges: true) }
        #expect(injected)
        expectNoUSBMutation(fs)
        #expect(fixture.journal()?.restorationBaseline?[path]?.sha256 == changes.target.mustExist[path]?.sha256)
        try expectReplayPreserved(fixture)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("전체 기준 없는 구형 폐기 승인 저널은 기존 의도를 보존하고 미기록 대상에 새 승인을 요구한다",
          arguments: ["first", "later"])
    func legacyApprovalWithoutWholeBaselineCannotAdoptUnrecordedTargets(point: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let original = fixture.tree()
        try closeReplayWrite(changes, fixture: fixture)
        let path = UsbChangeSetFixture.keepAnalysis[0]
        try interruptBeforeApprovedIntent(fixture, path: path, afterFirst: point == "later")
        let url = fixture.paths.sessions.appending(path: fixture.volumeKey + ".json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "restorationBaseline")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let intents = fixture.journal()?.restorations
        _ = try injectReplayChange(fixture, path: path, damage: "modify")
        try expectReplayPreserved(fixture)
        #expect(fixture.journal()?.restorationBaseline == nil && fixture.journal()?.restorations == intents)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("단계별 의도가 전체 대상을 증명하는 구형 승인은 그대로 재개한다")
    func legacyApprovalWithCompleteIntentsRetainsResume() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let original = fixture.tree()
        let changes = try fixture.smallEditChanges()
        try fixture.write(changes)
        _ = try interruptApprovedRestore(fixture, path: UsbLayout.exportPdb, phase: "done")
        var journal = try #require(fixture.journal())
        journal.restorationBaseline = nil
        try saveSyntheticJournal(journal, fixture: fixture)
        #expect(try fixture.recover().outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("전체 기준에서 뒤쪽 한 대상만 빠져도 현재 상태로 보충하지 않고 재승인한다", arguments: [false, true])
    func missingApprovedTargetCannotBeFilledOnResume(changed: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try nativeChanges(fixture)
        let original = fixture.tree()
        try closeReplayWrite(changes, fixture: fixture)
        let path = UsbChangeSetFixture.keepAnalysis[0]
        try interruptBeforeApprovedIntent(fixture, path: path, afterFirst: true)
        var journal = try #require(fixture.journal())
        journal.restorationBaseline?.removeValue(forKey: path)
        try saveSyntheticJournal(journal, fixture: fixture)
        if changed { _ = try injectReplayChange(fixture, path: path, damage: "modify") }
        try expectReplayPreserved(fixture)
        #expect(fixture.journal()?.restorationBaseline?[path] == nil)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("삭제 음원·짝 파일의 복원 완료 뒤 pending 전환도 재승인 때 전체 대상에서 빠지지 않는다",
          arguments: ["ordinary", "native", "legacy-ordinary", "legacy-native"], ["audio", "companion"])
    func completedRemovedAudioRemainsReapprovalTarget(mode: String, target: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes: UsbChangeSet
        if mode.hasSuffix("native") {
            changes = try nativeChanges(fixture)
            changes.removals = try fixture.editChanges().removals
            changes.target.mustNotExist = Set(changes.removals.map(\.path))
            for removal in changes.removals { changes.target.mustExist.removeValue(forKey: removal.path) }
        } else { fixture.seedEdit(); changes = try fixture.editChanges() }
        let path = UsbChangeSetFixture.goneAudio
        let companion = try #require(UsbRemovalPolicy.appleDoubleCompanion(of: path))
        fixture.write(companion, Data("합성 삭제 음원의 원래 짝 파일".utf8))
        let original = fixture.tree()
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        try run.cleanup(changes)
        try run.closeJournal(.verified, outcome: .written)
        run.close()
        let fs = fixture.fileSystem()
        var stopped = false
        fs.onOperation = { op, url in
            if !stopped, op == .syncDirectory, url.path == fixture.paths.sessions.path,
               fixture.journal()?.restorations?.contains(where: { $0.destination == path && $0.phase == .done }) == true,
               fixture.journal()?.removals.first(where: { $0.path == path })?.state == .pending {
                stopped = true
                fs.failSide = .mac
                fs.failAt = (operation: .syncDirectory, occurrence: 1, mode: .crash)
            }
        }
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: fs, discardDeviceChanges: true) }
        #expect(stopped)
        if mode.hasPrefix("legacy") {
            var journal = try #require(fixture.journal())
            journal.restorationBaseline = nil
            // 옛 복원이 pending으로 되돌린 음원·짝 파일에는 새 의도 필드가 없던 경우도 재현한다.
            journal.restorations?.removeAll { $0.destination == path || $0.destination == companion }
            try saveSyntheticJournal(journal, fixture: fixture)
        }
        _ = try injectReplayChange(fixture, path: target == "companion" ? companion : path, damage: "modify")
        try expectReplayPreserved(fixture)
        #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("일반 staged 뒤 새 WAL·journal·SHM·알려진 DB는 C에서 거부하고 D·E 변경을 하지 않는다",
          arguments: ["-wal", "-journal", "-shm", "database"], ["before", "during", "after-manifest"])
    func ordinaryBackupDoesNotAdoptNewDatabaseFamilyFile(kind: String, point: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        if kind == "database" { try FileManager.default.removeItem(at: fixture.usb(UsbLayout.exportExtPdb)) }
        let changes = try fixture.editChanges(removals: false)
        #expect(changes.syncSelection == nil)
        let fs = fixture.fileSystem()
        let run = try stagedNativeRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        #expect(fixture.journal()?.state == .staged)
        let path = kind == "database" ? UsbLayout.exportExtPdb : UsbLayout.oneLibrary + kind
        #expect(changes.base?.files[path] == nil)
        let external = Data("합성 계획 뒤 새 DB family 내용".utf8)
        var injected = point == "before"
        if injected { fixture.write(path, external) }
        else {
            fs.onOperation = { op, url in
                let hit = point == "during" ? op == .fullSync && url.path.contains("/files/")
                    : op == .syncDirectory && url.path.contains("/usb-backups/")
                if !injected, hit, fs.relative(url) == nil { injected = true; fixture.write(path, external) }
            }
        }
        let before = fixture.tree()
        #expect(throws: UsbError.self) { try run.backup(changes) }
        #expect(injected && fixture.data(path) == external)
        var expected = before
        expected[path] = UsbChangeSetFixture.sha256(external)
        #expect(fixture.tree() == expected)
        expectNoUSBMutation(fs)
        #expect(fixture.journal()?.state == .rolledBack && fixture.journal()?.backupDirectory == nil)
        #expect(fixture.journal()?.entries.isEmpty == true && fixture.journal()?.databases.isEmpty == true)
        #expect(fixture.journal()?.backupManifestSHA256 == nil && fixture.backupFolders().isEmpty)
    }

    @Test("일반 백업의 정상 부재·기존 사이드카와 base 밖에서 새로 생긴 bak는 기존 계약을 유지한다",
          arguments: ["absent", "sidecars", "bak", "pdb-only"])
    func ordinaryBackupKeepsObservedRangeAndBakContract(kind: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        if kind == "pdb-only" { try FileManager.default.removeItem(at: fixture.usb(UsbLayout.oneLibrary)) }
        if kind == "sidecars" {
            for suffix in UsbLayout.oneLibrarySidecarSuffixes { fixture.write(UsbLayout.oneLibrary + suffix, Data(("합성 기존" + suffix).utf8)) }
        }
        let changes = try fixture.editChanges(removals: false)
        let fs = fixture.fileSystem()
        let run = try stagedNativeRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        let bak = UsbLayout.exportPdb + ".bak"
        if kind == "bak" { fixture.write(bak, Data("합성 새 bak".utf8)) }
        let original = fixture.tree()
        try run.backup(changes)
        #expect(fixture.journal()?.state == .backedUp)
        expectNoUSBMutation(fs)
        if kind == "bak" { #expect(run.manifest?.files[bak]?.sha256 == fixture.tree()[bak] && changes.base?.files[bak] == nil) }
        for suffix in UsbLayout.oneLibrarySidecarSuffixes {
            let path = UsbLayout.oneLibrary + suffix
            if kind == "sidecars" { #expect(run.manifest?.files[path]?.sha256 == changes.base?.files[path]?.sha256) }
            else { #expect(run.manifest?.absentBefore.contains(path) == true) }
        }
        try run.writeFiles(changes, isCancelled: { false })
        try run.commitDatabases(changes)
        #expect(try run.rollback(mode: .write).isEmpty)
        #expect(fixture.tree() == original)
    }
}
