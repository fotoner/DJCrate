import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// R4 회귀는 합성 바이트·저널과 임시 USB 루트만 사용한다. 실행 검증은 별도 담당자가 한다.
extension UsbSyncSelectionPipelineTests {
    func replayChanges(_ fixture: UsbChangeSetFixture, kind: String) throws -> UsbChangeSet {
        if kind == "selection" || kind == "native-dat" { return try nativeChanges(fixture) }
        fixture.seedEdit()
        return try fixture.editChanges(removals: false)
    }

    func replayPath(_ kind: String) -> String {
        if kind == "selection" { return UsbSyncSelectionFile.relativePath(for: .deviceLibrary) }
        if kind == "analysis" || kind == "native-dat" { return UsbChangeSetFixture.keepAnalysis[0] }
        return UsbLayout.exportExtPdb
    }

    func closeReplayWrite(_ changes: UsbChangeSet, fixture: UsbChangeSetFixture) throws {
        let run = try finishNative(changes, fixture: fixture, fs: fixture.fileSystem())
        defer { run.close() }
        try run.journal.move(to: .cleaned)
        try run.closeJournal(.verified, outcome: .written)
    }

    /// 단계 저널 rename 뒤 폴더 fsync에서 중단한다. 완료 이전 단계는 대상 rename·unlink 호출 전에 멈춘다.
    func interruptApprovedRestore(_ fixture: UsbChangeSetFixture, path: String, phase: String) throws -> UsbJournal.FileMutation {
        let fs = fixture.fileSystem()
        var stopped = false
        fs.onOperation = { op, url in
            if !stopped, op == .syncDirectory, url.path == fixture.paths.sessions.path,
               fixture.journal()?.restorations?.contains(where: { $0.destination == path && $0.phase.rawValue == phase }) == true {
                stopped = true
                fs.failSide = .mac
                fs.failAt = (operation: .syncDirectory, occurrence: 1, mode: .crash)
            }
        }
        #expect(throws: (any Error).self) { try fixture.restore(fileSystem: fs, discardDeviceChanges: true) }
        #expect(stopped && fixture.journal()?.discardDeviceChanges == true)
        let entry = try #require(fixture.journal()?.restorations?.first { $0.destination == path })
        #expect(entry.phase.rawValue == phase)
        return entry
    }

    func injectReplayChange(_ fixture: UsbChangeSetFixture, path: String, damage: String) throws -> URL {
        let outside = fixture.source("outside-replay", Data("합성 링크 밖 내용".utf8))
        if damage == "modify" { fixture.write(path, Data("합성 승인 뒤 외부 내용".utf8)) }
        else {
            if fixture.exists(path) { try FileManager.default.removeItem(at: fixture.usb(path)) }
            if damage == "link" { try FileManager.default.createSymbolicLink(at: fixture.usb(path), withDestinationURL: outside) }
        }
        return outside
    }

    func expectReplayPreserved(_ fixture: UsbChangeSetFixture) throws {
        let before = fixture.tree()
        let directories = fixture.directories()
        for _ in 0..<2 {
            let fs = fixture.fileSystem()
            expectPending { _ = try fixture.recover(fileSystem: fs) }
            #expect(fixture.tree() == before && fixture.directories() == directories)
            expectNoUSBMutation(fs)
            #expect(fixture.journal()?.state == .restorePending)
            #expect(fixture.journal()?.restorationApprovalRequired == true)
        }
    }

    @Test("복원 폐기 승인은 XML·일반 DB·DAT의 각 단계 이후 새 변경·삭제·링크까지 허용하지 않는다",
          arguments: ["selection", "database", "analysis"],
          ["copying", "renamePending", "renameEntered", "done"].flatMap { phase in
              ["modify", "delete", "link"].map { phase + ":" + $0 }
          })
    func approvedIntentRejectsLaterExternalChanges(kind: String, replay: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try replayChanges(fixture, kind: kind)
        let original = fixture.tree()
        try closeReplayWrite(changes, fixture: fixture)
        let path = replayPath(kind)
        let parts = replay.split(separator: ":").map(String.init)
        let intent = try interruptApprovedRestore(fixture, path: path, phase: parts[0])
        #expect(intent.expectedSHA256 == changes.target.mustExist[path]?.sha256)
        let folder = URL(filePath: try #require(fixture.journal()?.backupDirectory))
        let outside = try injectReplayChange(fixture, path: path, damage: parts[1])
        try expectReplayPreserved(fixture)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: UsbWriter.restoredMarkerName).path))
        #expect(try Data(contentsOf: outside) == Data("합성 링크 밖 내용".utf8))
        if parts[1] == "link" {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.usb(path).path) == outside.path)
        }
        #expect(try fixture.restore(backup: folder, discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original && fixture.journal()?.state == .restored)
    }

    @Test("승인 복원의 각 단계는 저장된 기대 내용이 그대로면 자동 재개한다",
          arguments: ["selection", "database", "analysis"], ["copying", "renamePending", "renameEntered", "done"])
    func approvedIntentWithUnchangedTargetResumes(kind: String, phase: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try replayChanges(fixture, kind: kind)
        let original = fixture.tree()
        try closeReplayWrite(changes, fixture: fixture)
        _ = try interruptApprovedRestore(fixture, path: replayPath(kind), phase: phase)
        #expect(try fixture.recover().outcome == .restored)
        #expect(fixture.tree() == original)
    }

    @Test("백업 결과는 rename 진입 이후에만 완료 저장이 늦은 합법 결과다",
          arguments: ["copying", "renamePending", "renameEntered"])
    func replacementResultRequiresDurableRenameEntry(phase: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try replayChanges(fixture, kind: "database")
        let original = fixture.tree()
        let path = replayPath("database")
        let backupBytes = try #require(fixture.data(path))
        try closeReplayWrite(changes, fixture: fixture)
        let intent = try interruptApprovedRestore(fixture, path: path, phase: phase)
        if phase == "renameEntered" {
            let temp = UsbPath.join(UsbPath.parent(path), try #require(intent.tempName))
            // 진입은 내렸으나 rename·완료 저장이 늦은 중단의 실제 파일 결과를 만든다.
            try PosixUsbFileSystem(synchronizes: false).rename(fixture.usb(temp), to: fixture.usb(path))
            #expect(try fixture.recover().outcome == .restored)
        } else {
            fixture.write(path, backupBytes)
            try expectReplayPreserved(fixture)
            #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        }
        #expect(fixture.tree() == original)
    }

    @Test("승인할 때 있던 끝 성분 링크는 같은 신원일 때만 재개하고 교체·삭제에는 재승인을 요구한다",
          arguments: ["copying", "renamePending", "renameEntered"], ["unchanged", "replace", "delete"])
    func approvedLinkIdentitySurvivesOnlySameLink(phase: String, damage: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try replayChanges(fixture, kind: "database")
        let original = fixture.tree()
        try closeReplayWrite(changes, fixture: fixture)
        let path = replayPath("database")
        let outside = try injectReplayChange(fixture, path: path, damage: "link")
        _ = try interruptApprovedRestore(fixture, path: path, phase: phase)
        if damage != "unchanged" {
            // 새 링크를 먼저 만들어 옛 링크 inode의 즉시 재사용도 피한다. 목적지는 같아도 다른 링크다.
            if damage == "replace" {
                let replacement = fixture.usb(path + ".replacement-link")
                try FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: outside)
                try PosixUsbFileSystem(synchronizes: false).rename(replacement, to: fixture.usb(path))
            } else { try FileManager.default.removeItem(at: fixture.usb(path)) }
            try expectReplayPreserved(fixture)
            #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        } else { #expect(try fixture.recover().outcome == .restored) }
        #expect(fixture.tree() == original)
        #expect(try Data(contentsOf: outside) == Data("합성 링크 밖 내용".utf8))
    }

    @Test("expectedLink가 없는 옛 의도는 일반 파일의 정상 중단을 이어가고 링크는 새 승인을 기다린다",
          arguments: [false, true])
    func missingOptionalLinkIdentityPreservesLegacyContract(linked: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try replayChanges(fixture, kind: "database")
        let original = fixture.tree()
        try closeReplayWrite(changes, fixture: fixture)
        let path = replayPath("database")
        if linked { _ = try injectReplayChange(fixture, path: path, damage: "link") }
        _ = try interruptApprovedRestore(fixture, path: path, phase: "copying")
        let url = fixture.paths.sessions.appending(path: fixture.volumeKey + ".json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try #require(json["restorations"] as? [[String: Any]])
        for index in entries.indices { entries[index].removeValue(forKey: "expectedLink") }
        json["restorations"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(fixture.journal()?.restorations?.first(where: { $0.destination == path })?.expectedLink == nil)
        if linked {
            try expectReplayPreserved(fixture)
            #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        } else { #expect(try fixture.recover().outcome == .restored) }
        #expect(fixture.tree() == original)
    }

    @Test("삭제 의도는 새 내용·링크를 거부하고 진입 뒤 부재만 unlink의 합법 결과로 허용한다",
          arguments: ["deletePending", "deleteEntered", "done"], ["modify", "delete", "link"])
    func approvedDeleteIntentChecksStageResult(phase: String, damage: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try replayChanges(fixture, kind: "analysis")
        let original = fixture.tree()
        try closeReplayWrite(changes, fixture: fixture)
        let path = UsbChangeSetFixture.newAnalysis[0]
        _ = try interruptApprovedRestore(fixture, path: path, phase: phase)
        _ = try injectReplayChange(fixture, path: path, damage: damage)
        if damage == "delete", phase != "deletePending" {
            #expect(try fixture.recover().outcome == .restored)
        } else {
            try expectReplayPreserved(fixture)
            #expect(try fixture.restore(discardDeviceChanges: true).outcome == .restored)
        }
        #expect(fixture.tree() == original)
    }

    @Test("일반 exportExt DB와 native·일반 DAT의 백업 전 변경은 backedUp 전에 USB 변경 없이 거부한다",
          arguments: ["database", "native-dat", "analysis"], ["modify", "delete", "link"])
    func completedBackupMustMatchWholePlanBeforeMutation(kind: String, damage: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try replayChanges(fixture, kind: kind)
        let fs = fixture.fileSystem()
        let run = try stagedNativeRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        #expect(fixture.journal()?.state == .staged)
        _ = try injectReplayChange(fixture, path: replayPath(kind), damage: damage)
        let before = fixture.tree()
        let directories = fixture.directories()
        #expect(throws: UsbError.self) { try run.backup(changes) }
        #expect(fixture.tree() == before && fixture.directories() == directories)
        expectNoUSBMutation(fs)
        #expect(fixture.journal()?.state == .rolledBack)
        #expect(fixture.journal()?.entries.isEmpty == true && fixture.journal()?.databases.isEmpty == true)
        #expect(fixture.journal()?.backupDirectory == nil && fixture.journal()?.backupManifestSHA256 == nil)
        #expect(fixture.backupFolders().isEmpty)
    }

    @Test("성공 표지 뒤 저널 닫기가 끊겨도 XML·일반 DB 후속 변경은 재승인으로 복원할 수 있다",
          arguments: ["selection", "database"], ["modify", "delete"])
    func restoredMarkerCannotBypassOpenSessionReapproval(kind: String, damage: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = try replayChanges(fixture, kind: kind)
        let original = fixture.tree()
        try closeReplayWrite(changes, fixture: fixture)
        let folder = try #require(fixture.backupFolders().first)
        let savedJournal = try Data(contentsOf: folder.appending(path: "journal.json"))
        let savedReport = try Data(contentsOf: folder.appending(path: "report.json"))
        let marker = folder.appending(path: UsbWriter.restoredMarkerName)
        let fs = fixture.fileSystem()
        var stopped = false
        fs.onOperation = { op, url in
            if !stopped, op == .rename, url.path == fixture.paths.sessions.appending(path: fixture.volumeKey + ".json").path,
               FileManager.default.fileExists(atPath: marker.path) {
                stopped = true
                fs.failSide = .mac
                fs.failAt = (operation: .rename, occurrence: 1, mode: .crash)
            }
        }
        #expect(throws: (any Error).self) { try fixture.restore(backup: folder, fileSystem: fs, discardDeviceChanges: true) }
        #expect(stopped && FileManager.default.fileExists(atPath: marker.path))
        #expect(fixture.journal()?.isClosed == false)
        let path = replayPath(kind)
        #expect(fixture.journal()?.restorations?.contains(where: { $0.destination == path && $0.phase == .done }) == true)
        _ = try injectReplayChange(fixture, path: path, damage: damage)
        try expectReplayPreserved(fixture)
        let beforeApproval = fixture.tree()
        let dryFS = fixture.fileSystem()
        #expect(try fixture.restore(backup: folder, fileSystem: dryFS, discardDeviceChanges: true, dryRun: true).outcome == .dryRun)
        #expect(fixture.tree() == beforeApproval && fixture.journal()?.restorationApprovalRequired == true)
        expectNoUSBMutation(dryFS)
        #expect(try fixture.restore(backup: folder, discardDeviceChanges: true).outcome == .restored)
        #expect(fixture.tree() == original && fixture.journal()?.state == .restored)
        #expect(try Data(contentsOf: folder.appending(path: "journal.json")) == savedJournal)
        #expect(try Data(contentsOf: folder.appending(path: "report.json")) == savedReport)
        // 정상적으로 닫힌 세션의 같은 백업은 그 뒤 외부 변경이 있어도 다시 실행하지 않는다.
        fixture.write(path, Data("합성 닫힌 복원 뒤 변경".utf8))
        let afterClosed = fixture.tree()
        let closedJournal = fixture.journal()
        let noopFS = fixture.fileSystem()
        let repeated = try fixture.restore(backup: folder, fileSystem: noopFS, discardDeviceChanges: true)
        #expect(repeated.notes.contains(String(ui: "그 쓰기는 이미 되돌렸습니다")))
        #expect(fixture.tree() == afterClosed && fixture.journal() == closedJournal)
        expectNoUSBMutation(noopFS)
    }
}
