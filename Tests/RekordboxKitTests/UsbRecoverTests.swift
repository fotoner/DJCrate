import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 쓰는 도중 크래시(그 뒤 모든 연산 실패) → 새 파일 시스템으로 회복
@Suite("USB 쓰기 회복")
struct UsbRecoverTests {
    func expected(_ changes: UsbChangeSet) -> [String: String] {
        changes.target.mustExist.mapValues { $0.sha256 ?? "" }
    }

    /// 크래시를 흉내 내 쓰기를 끊는다(던진 오류는 무엇이든 받는다)
    func crash(_ fixture: UsbChangeSetFixture, _ changes: UsbChangeSet, _ configure: (FaultyUsbFileSystem) -> Void) {
        let fs = fixture.fileSystem()
        configure(fs)
        #expect(throws: (any Error).self) { try fixture.write(changes, fileSystem: fs) }
        #expect(fs.isCrashed)
    }

    func backupFiles(_ journal: UsbJournal?) throws -> (journal: UsbJournal, report: UsbWriteReport) {
        let folder = URL(filePath: try #require(journal?.backupDirectory))
        let copy = try UsbJournal.decoder().decode(UsbJournal.self, from: Data(contentsOf: folder.appending(path: "journal.json")))
        let report = try JSONDecoder().decode(UsbWriteReport.self, from: Data(contentsOf: folder.appending(path: "report.json")))
        return (copy, report)
    }

    func currentDatabases(_ fixture: UsbChangeSetFixture) -> [String: String] {
        fixture.tree().filter { FixtureOrder.databases.contains($0.key) }
    }

    @Test("대상을 지운 뒤 rename 전에 끊겨도 DB가 사라지지 않는다")
    func crashAfterTargetDeletedBeforeRename() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        crash(fixture, changes) { $0.renameTwoPhaseOn = UsbLayout.oneLibrary }
        #expect(!fixture.exists(UsbLayout.oneLibrary))
        let report = try fixture.recover()
        #expect(report.outcome == .recovered)
        #expect(fixture.exists(UsbLayout.oneLibrary))
        var tree = fixture.tree()
        for path in changes.target.mustNotExist { #expect(tree[path] == nil) }
        tree = tree.filter { changes.target.mustExist[$0.key] != nil }
        #expect(tree == expected(changes))
        #expect(fixture.tempCount() == 0)
        #expect(fixture.journal()?.state == .recovered)
    }

    @Test("파일 단계에서 끊기면 만든 파일을 지우고 옛 DB 그대로", arguments: [false, true])
    func crashDuringFiles_beforeCommit(edit: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        if edit { fixture.seedEdit() }
        let changes = edit ? try fixture.editChanges() : fixture.exportChanges()
        let before = fixture.tree()
        crash(fixture, changes) { $0.failAt = (operation: edit ? .writeNew : .copyDataNew, occurrence: 2, mode: .crash) }
        #expect(fixture.tempCount() == 1)
        let report = try fixture.recover()
        #expect(report.outcome == .rolledBack)
        #expect(fixture.tree() == before)
        #expect(fixture.journal()?.state == .rolledBack)
    }

    @Test("DB 사이에서 끊기면 준비 폴더가 온전할 때 마저 쓴다")
    func crashBetweenDBCommits() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit(extraSidecar: true)
        let changes = try fixture.editChanges()
        crash(fixture, changes) { fs in
            fs.failAt = (operation: .writeNew, occurrence: 2, mode: .crash)
            fs.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
        }
        #expect(fixture.tree()[UsbLayout.oneLibrary] == changes.databases[0].sha256)
        #expect(fixture.tree()[UsbLayout.exportPdb] != changes.databases[1].sha256)
        let report = try fixture.recover()
        #expect(report.outcome == .recovered)
        #expect(currentDatabases(fixture) == Dictionary(uniqueKeysWithValues: changes.databases.map { ($0.destination, $0.sha256) }))
        #expect(fixture.tempCount() == 0)
        #expect(!fixture.exists(UsbLayout.oneLibrary + "-wal"))
        for path in changes.target.mustNotExist { #expect(!fixture.exists(path)) }
    }

    @Test("기기가 DB를 바꿨으면 이어 쓰지 않고 임시만 지운다")
    func deviceChangedDBBlocksResume() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        crash(fixture, changes) { fs in
            fs.failAt = (operation: .writeNew, occurrence: 2, mode: .crash)
            fs.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
        }
        #expect(fixture.tempCount() == 1)
        let device = UsbChangeSetFixture.random(3000)
        fixture.write(UsbLayout.exportPdb, device)
        let fs = fixture.fileSystem()
        let report = try fixture.recover(fileSystem: fs)
        #expect(report.outcome == .needsReplan)
        #expect(report.notes.contains { $0.hasPrefix("USB가 기기에서 바뀌어 이어 쓰지 않았습니다") })
        #expect(fixture.data(UsbLayout.exportPdb) == device)
        #expect(fixture.tempCount() == 0)
        #expect(!fs.calls.contains { $0.hasPrefix("rename ") && !$0.contains("mac:") })
        #expect(fixture.journal()?.state == .needsReplan)
    }

    @Test("needsReplan은 새 계획은 받고 옛 계획은 usbChanged로 막는다")
    func needsReplanAllowsNewPlan() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        crash(fixture, changes) { fs in
            fs.failAt = (operation: .writeNew, occurrence: 2, mode: .crash)
            fs.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
        }
        fixture.write(UsbLayout.exportPdb, UsbChangeSetFixture.random(3000))
        #expect(try fixture.recover().outcome == .needsReplan)
        let journal = try #require(fixture.journal())
        #expect(journal.isClosed)
        #expect(UsbWriter.pendingJournal(paths: fixture.paths, volumeKey: fixture.volumeKey) == nil)
        let (copy, report) = try backupFiles(journal)
        #expect(copy.state == .needsReplan)
        #expect(!copy.databases.isEmpty)
        #expect(report.outcome == .needsReplan)
        #expect(report.resultDatabases == currentDatabases(fixture))
        let replanBackup = try #require(journal.backupDirectory)

        // ① 옛 계획은 recoveryNeeded가 아니라 usbChanged
        let before = fixture.tree()
        do {
            try fixture.write(changes)
            Issue.record("막히지 않았다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code).contains("usbChanged"))
            #expect(!blocks.map(\.code).contains("recoveryNeeded"))
        }
        #expect(fixture.tree() == before)

        // ② 그 사이 끝난(되돌린) 쓰기 다섯 개가 쌓여도 needsReplan 백업은 남는다(더 새 verified가 없음)
        // 더 새 verified가 있으면 needsReplan 백업이 풀리므로(③에서 확인) 되돌린 쓰기로 쌓는다
        for _ in 0..<5 {
            let small = try fixture.smallEditChanges()
            let fs = fixture.fileSystem()
            fs.failAt = (operation: .rename, occurrence: 1, mode: .error)
            #expect(throws: UsbError.self) { try fixture.write(small, fileSystem: fs) }
        }
        #expect(fixture.backupFolders().count == 6)
        #expect(FileManager.default.fileExists(atPath: replanBackup))

        // 그 백업으로 되돌리기는 --discard-device-changes 없이는 막힌다
        do {
            _ = try fixture.restore(backup: URL(filePath: replanBackup))
            Issue.record("막히지 않았다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code) == ["deviceChanged"])
        }

        // ③ 지금 USB 지문으로 새로 만든 계획은 쓴다. 그 뒤 정리에서야 needsReplan 백업을 지울 수 있다
        let fresh = try fixture.smallEditChanges()
        #expect(try fixture.write(fresh).outcome == .written)
        #expect(fixture.journal()?.state == .verified)
        #expect(!FileManager.default.fileExists(atPath: replanBackup))
    }

    @Test("회복으로 닫은 쓰기도 백업으로 되돌릴 수 있다", arguments: [false, true])
    func recoveredWriteIsRestorable(export: Bool) throws {
        // ① E 도중 크래시 → recovered → 되돌리기
        do {
            let fixture = UsbChangeSetFixture()
            defer { fixture.remove() }
            if export { fixture.write("Contents/keep.mp3", Data("user".utf8)); fixture.write("Contents/._keep.mp3", Data(count: 4096)) } else { fixture.seedEdit() }
            let before = fixture.tree()
            let changes = export ? fixture.exportChanges() : try fixture.editChanges()
            crash(fixture, changes) { fs in
                fs.failAt = (operation: .writeNew, occurrence: 2, mode: .crash)
                fs.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
            }
            #expect(try fixture.recover().outcome == .recovered)
            let (copy, report) = try backupFiles(fixture.journal())
            #expect(copy.state == .recovered)
            #expect(copy.databases.count == 3)
            #expect(copy.databases.allSatisfy { $0.state == .done && $0.disposition == (export ? .created : .overwritten) })
            #expect(report.resultDatabases == currentDatabases(fixture))
            #expect(report.resultDatabases == Dictionary(uniqueKeysWithValues: changes.databases.map { ($0.destination, $0.sha256) }))
            // 저널 파일을 드라이 런으로 덮어 둔다(되돌리기는 백업 폴더의 journal.json을 읽어야 한다)
            try fixture.write(fixture.smallEditChanges(), options: UsbWriteOptions(dryRun: true))
            #expect(fixture.journal()?.state == .dryRun)
            let restored = try fixture.restore()
            #expect(restored.outcome == .restored)
            #expect(fixture.tree() == before)
            #expect(fixture.appleDoubleCount() == (export ? 1 : 0))
        }
        // ② D 도중 크래시 → rolledBack → 백업에 두 파일, 되돌려도 그대로
        do {
            let fixture = UsbChangeSetFixture()
            defer { fixture.remove() }
            if !export { fixture.seedEdit() }
            let before = fixture.tree()
            let changes = export ? fixture.exportChanges() : try fixture.editChanges()
            crash(fixture, changes) { $0.failAt = (operation: .writeNew, occurrence: 2, mode: .crash) }
            #expect(try fixture.recover().outcome == .rolledBack)
            let (copy, report) = try backupFiles(fixture.journal())
            #expect(copy.state == .rolledBack)
            #expect(report.resultDatabases == currentDatabases(fixture))
            #expect(try fixture.restore().outcome == .restored)
            #expect(fixture.tree() == before)
        }
        // ③ C 전 크래시(백업 폴더 없음) → 두 파일 없이 notes 한 줄, 저널은 닫힘
        do {
            let fixture = UsbChangeSetFixture()
            defer { fixture.remove() }
            if !export { fixture.seedEdit() }
            let changes = export ? fixture.exportChanges() : try fixture.editChanges()
            crash(fixture, changes) { $0.failAt = (operation: .mountedOn, occurrence: 2, mode: .crash) }
            #expect(fixture.journal()?.state == .staged)
            let report = try fixture.recover()
            #expect(report.outcome == .rolledBack)
            #expect(report.backup == nil)
            #expect(report.notes.count == 1)
            #expect(fixture.journal()?.isClosed == true)
            #expect(fixture.journal()?.backupDirectory == nil)
        }
    }

    @Test("임시 파일은 판정이 끝난 뒤에만 지운다")
    func tempRemovedOnlyAfterDecision() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        crash(fixture, changes) { $0.failAt = (operation: .copyDataNew, occurrence: 1, mode: .crash) }
        #expect(fixture.tempCount() == 1)
        let fs = fixture.fileSystem()
        #expect(try fixture.recover(fileSystem: fs).outcome == .rolledBack)
        let calls = fs.calls
        let removeTemp = try #require(calls.firstIndex { $0.hasPrefix("remove ") && $0.contains(".djc-part-") })
        // DB 셋을 모두 읽어 판정한 뒤에야 임시 파일을 지운다
        #expect(Set(calls[..<removeTemp].filter { $0.hasPrefix("sha256 PIONEER/rekordbox/") }).count == 3)
        #expect(fixture.tempCount() == 0)
    }

    @Test("저널이 없으면 임시 파일을 보고만 하고, --discard-temp일 때 지운다")
    func noJournalOnlyReportsTemp() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.write("Contents/A/.djc-part-zzzzzzzz-000001", Data("partial".utf8))
        fixture.write("PIONEER/USBANLZ/P001/.djc-part-zzzzzzzz-000002", Data("partial".utf8))
        let report = try fixture.recover()
        #expect(fixture.tempCount() == 2)
        #expect(report.notes.contains { $0.contains("2") })
        #expect(fixture.journal() == nil)
        _ = try fixture.recover(discardTemp: true)
        #expect(fixture.tempCount() == 0)
        #expect(fixture.backupFolders().isEmpty)
    }

    struct Failing: UsbWriteVerifier {
        func verify(root: UsbRoot, changes: UsbChangeSet, fileSystem: any UsbFileSystem, scratch: URL) throws -> [String] {
            ["합성 검증 실패"]
        }
    }

    @Test("다시 복사할 수 없는 음원(원본 없음)이 있어도 회복은 알리고 저널을 닫는다", arguments: [false, true])
    func recoverAfterUnrecopyableAudioCloses(restoreInitiated: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let before = fixture.tree()
        let changes = try fixture.editChanges()
        let fs = fixture.fileSystem()
        // 되돌리며 새 음원을 지우는 연산이 실패해 되돌리기가 끝나지 않는다
        fs.failWhen = { op, path in op == .remove && path == UsbChangeSetFixture.newAudio }
        let original = fixture.sources.appending(path: "gone/gone.mp3")
        if restoreInitiated {
            try fixture.write(changes)
            try FileManager.default.removeItem(at: original)
            #expect {
                try fixture.restore(fileSystem: fs)
            } throws: { error in
                if case UsbError.restoreFailed = error { true } else { false }
            }
            #expect(fixture.journal()?.restoringBackup == true)
        } else {
            try FileManager.default.removeItem(at: original)
            #expect {
                try fixture.write(changes, fileSystem: fs, verifiers: [UsbFingerprintVerifier(), Failing()])
            } throws: { error in
                if case UsbError.restoreFailed = error { true } else { false }
            }
        }
        #expect(fixture.journal()?.state == .restoreFailed)
        let report = try fixture.recover()
        #expect(report.outcome == (restoreInitiated ? .restored : .rolledBack))
        #expect(report.notes.filter { $0.contains(UsbChangeSetFixture.goneAudio) }.count == 1)
        var expected = before
        expected[UsbChangeSetFixture.goneAudio] = nil
        #expect(fixture.tree() == expected)
        #expect(fixture.journal()?.isClosed == true)
        // 다음 쓰기는 회복을 요구하지 않는다
        #expect(try fixture.write(fixture.smallEditChanges()).outcome == .written)
    }

    @Test("쓰기 전에 없던 지울 파일은 되돌릴 때 되살릴 것이 없다(되돌리기 실패가 아님)")
    func rollbackSkipsRemovalAbsentBeforeWrite() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        // 계획 뒤 쓰기 전에 지울 아트워크 하나가 사라졌다
        try FileManager.default.removeItem(at: fixture.usb(UsbChangeSetFixture.goneArtwork[1]))
        let before = fixture.tree()
        #expect {
            try fixture.write(changes, verifiers: [UsbFingerprintVerifier(), Failing()])
        } throws: { error in
            if case UsbError.writeRolledBack = error { true } else { false }
        }
        #expect(fixture.tree() == before)
        #expect(fixture.journal()?.state == .rolledBack)
    }

    @Test("지우는 도중 끊긴 쓰기를 마저 하면 끊기기 전에 비게 된 우리 폴더도 지운다")
    func crashDuringRemovals_recoversAndPrunesFolders() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let changes = try fixture.editChanges()
        let removals = Set(changes.removals.map(\.path))
        crash(fixture, changes) { fs in
            fs.failAt = (operation: .remove, occurrence: 2, mode: .crash)
            fs.failMatching = { removals.contains($0) }
        }
        #expect(!fixture.exists(UsbChangeSetFixture.goneAudio))
        #expect(fixture.exists(UsbChangeSetFixture.goneAnalysis[0]))
        #expect(try fixture.recover().outcome == .recovered)
        for path in changes.target.mustNotExist { #expect(!fixture.exists(path)) }
        let directories = fixture.directories()
        #expect(!directories.contains("Contents/Gone/Album"))
        #expect(!directories.contains("Contents/Gone"))
        #expect(!directories.contains("PIONEER/USBANLZ/P002"))
        #expect(directories.contains("PIONEER/Artwork/00001"))
    }

    @Test("저널의 경로·백업 폴더가 USB 루트·usb-backups 밖을 가리키면 파일 연산 없이 막는다",
          arguments: ["entry", "database", "session", "backupDirectory"])
    func recoverRefusesJournalPathOutsideRoot(field: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        crash(fixture, try fixture.editChanges()) { $0.failAt = (operation: .writeNew, occurrence: 2, mode: .crash) }
        let outside = fixture.folder.appending(path: "outside.bin")
        let outsideData = UsbChangeSetFixture.random(300)
        try outsideData.write(to: outside)
        let elsewhere = fixture.folder.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let url = fixture.paths.sessions.appending(path: fixture.volumeKey + ".json")
        var journal = try #require(fixture.journal())
        switch field {
        case "entry":
            let index = try #require(journal.entries.firstIndex { $0.disposition == .created })
            journal.entries[index].destination = "../outside.bin"
            journal.entries[index].state = .done
        case "database": journal.changes.databases[0].destination = "PIONEER/rekordbox/../../../outside.bin"
        case "session": journal.changes.session = "../../x"
        default:
            let backup = URL(filePath: try #require(journal.backupDirectory))
            try FileManager.default.copyItem(at: backup.appending(path: "manifest.json"), to: elsewhere.appending(path: "manifest.json"))
            journal.backupDirectory = elsewhere.path
        }
        try UsbJournal.encoder().encode(journal).write(to: url)
        let tree = fixture.tree()
        let fs = fixture.fileSystem()
        do {
            _ = try fixture.recover(fileSystem: fs)
            Issue.record("막히지 않았다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code) == ["journalUnreadable"])
        }
        #expect(try Data(contentsOf: outside) == outsideData)
        #expect(fixture.tree() == tree)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).sorted() == (field == "backupDirectory" ? ["manifest.json"] : []))
        let mutating = ["makeDirectory", "writeNew", "copyDataNew", "rename", "remove", "removeDirectoryIfEmpty", "setModificationDate"]
        #expect(!fs.calls.contains { mutating.contains(String($0.split(separator: " ")[0])) })
        #expect(fixture.journal() == journal)
    }

    @Test("실물 USB는 회복도 막는다(쓰기가 열리기 전)")
    func recoverRefusesPhysicalBeforePhysicalWritesOpen() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        crash(fixture, changes) { $0.failAt = (operation: .copyDataNew, occurrence: 2, mode: .crash) }
        let before = fixture.tree()
        let journal = fixture.journal()
        fixture.volume = FakeUsbVolume.physicalFAT32(uuid: fixture.volumeKey)
        let fs = fixture.fileSystem()
        let gate = FakeUsbVolume.gate()
        do {
            _ = try UsbWriter.recover(root: fixture.root, paths: fixture.paths, guard: fixture.writeGuard(gate: gate), fileSystem: fs,
                                      confirmName: "DJCPHYS")
            Issue.record("막히지 않았다")
        } catch let UsbError.writeRefused(blocks) {
            #expect(blocks.map(\.code).contains("physicalDisabled"))
        }
        #expect(fixture.tree() == before)
        #expect(fixture.journal() == journal)
        #expect(!fs.calls.contains { $0.hasPrefix("rename ") || $0.hasPrefix("remove ") })
    }

    @Test("저널 없이 임시 파일 지우기도 실물이면 막는다")
    func discardTempRefusesPhysical() {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.write("Contents/A/.djc-part-zzzzzzzz-000001", Data("partial".utf8))
        fixture.volume = FakeUsbVolume.physicalFAT32()
        #expect(throws: UsbError.self) { try fixture.recover(discardTemp: true) }
        #expect(fixture.tempCount() == 1)
    }

    @Test("회복은 관문을 지난 뒤에만 USB 파일을 연다")
    func recoverChecksGateBeforeAnyFileOp() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        crash(fixture, changes) { $0.failAt = (operation: .copyDataNew, occurrence: 2, mode: .crash) }
        let fs = fixture.fileSystem()
        fixture.recorder = fs
        _ = try fixture.recover(fileSystem: fs)
        let calls = fs.calls.filter { !$0.contains("mac:") }
        #expect(calls[0] == "mountedOn .")
        #expect(calls[1] == "guard.volume")
        #expect(calls[2] == "guard.rekordbox")
        #expect(calls.count > 3)
    }
}
