import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// R6 회귀: 임시 USB 루트·합성 바이트만 쓰며, 실행 검증은 별도로 한다.
@Suite("빈 USB 내보내기 백업 기준")
struct UsbExportBackupBaselineTests {
    func stagedRun(_ changes: UsbChangeSet, fixture: UsbChangeSetFixture, fs: FaultyUsbFileSystem) throws -> UsbWriteRun {
        let run = try UsbWriteRun.open(root: fixture.root, paths: fixture.paths, guard: fixture.writeGuard(), fileSystem: fs,
                                      ppthReader: UsbChangeSetFixture.ppthReader, now: .now, progress: { _ in })
        do {
            let plan = try run.precheck(changes, inspectors: [])
            try run.stage(changes, plan: plan)
            return run
        } catch { run.close(); throw error }
    }

    func expectNoUSBMutation(_ fs: FaultyUsbFileSystem) {
        let mutations = ["makeDirectory", "writeNew", "copyDataNew", "rename", "remove", "removeDirectoryIfEmpty", "setModificationDate"]
        #expect(!fs.calls.contains { !$0.contains("mac:") && mutations.contains(String($0.split(separator: " ")[0])) })
    }

    @Test("일반 빈 내보내기는 staged 뒤·DB 백업 복사 중·manifest 저장 뒤 새 사이드카를 C에서 거부한다",
          arguments: ["-wal", "-journal", "-shm"], ["staged", "copy", "manifest"])
    func newSidecarCannotBecomeExportBackup(suffix: String, point: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        #expect(changes.base == nil && changes.syncSelection == nil)
        let fs = fixture.fileSystem()
        let run = try stagedRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        #expect(fixture.journal()?.state == .staged)
        #expect(run.journal.plannedDatabases.allSatisfy { $0.disposition == .created && $0.oldSHA256 == nil })
        // 빈 내보내기는 원래 DB 복사본이 없다. 별도 지원하는 bak로 C의 DB 파일 복사를 흉내 낸다.
        let bak = UsbLayout.exportPdb + ".bak"
        if point == "copy" { fixture.write(bak, Data("합성 기존 bak".utf8)) }
        let path = UsbLayout.oneLibrary + suffix
        let external = Data("합성 내보내기 준비 뒤 외부 사이드카".utf8)
        let before = fixture.tree()
        var injected = point == "staged"
        if injected { fixture.write(path, external) }
        else {
            fs.onOperation = { op, url in
                let copy = point == "copy" && op == .copyDataNew && url.path.hasSuffix("/files/" + bak)
                let savedManifest = point == "manifest" && op == .syncDirectory
                    && url.path.contains("/usb-backups/")
                    && FileManager.default.fileExists(atPath: url.appending(path: "manifest.json").path)
                if !injected, fs.relative(url) == nil, copy || savedManifest {
                    injected = true
                    fixture.write(path, external)
                }
            }
        }
        #expect {
            try run.backup(changes)
        } throws: { error in
            if case let UsbError.writeRefused(blocks) = error { blocks.contains { $0.code == "sourceChangedDuringCopy" } }
            else { false }
        }
        #expect(injected && fixture.data(path) == external)
        var expected = before
        expected[path] = UsbChangeSetFixture.sha256(external)
        #expect(fixture.tree() == expected)
        expectNoUSBMutation(fs)
        #expect(fixture.journal()?.state == .rolledBack && fixture.journal()?.backupDirectory == nil)
        #expect(fixture.journal()?.entries.isEmpty == true && fixture.journal()?.databases.isEmpty == true)
        #expect(fixture.journal()?.backupManifestSHA256 == nil && fixture.backupFolders().isEmpty)
    }

    @Test("빈 내보내기에서 원래 없던 DB도 staged 뒤 생기면 D·E 전에 거부한다",
          arguments: [UsbLayout.oneLibrary, UsbLayout.exportPdb, UsbLayout.exportExtPdb])
    func newDatabaseCannotBecomeExportBackup(path: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let fs = fixture.fileSystem()
        let run = try stagedRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        fixture.write(path, Data("합성 외부 DB".utf8))
        let original = fixture.tree()
        #expect(throws: UsbError.self) { try run.backup(changes) }
        #expect(fixture.tree() == original)
        expectNoUSBMutation(fs)
        #expect(fixture.journal()?.state == .rolledBack && fixture.backupFolders().isEmpty)
    }

    @Test("빈 내보내기의 manifest 기준·coverage는 새 사이드카를 정상 백업으로 받아들이지 않는다",
          arguments: ["-wal", "-journal", "-shm"])
    func manifestCannotAdoptOriginallyAbsentSidecar(suffix: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let fs = fixture.fileSystem()
        let run = try stagedRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        try run.backup(changes)
        let path = UsbLayout.oneLibrary + suffix
        var manifest = try #require(run.manifest)
        let data = Data("합성 흡수된 사이드카 백업".utf8)
        let sha = UsbChangeSetFixture.sha256(data)
        manifest.absentBefore.removeAll { $0 == path }
        manifest.files[path] = .init(size: Int64(data.count), mtime: .now, sha256: sha)
        manifest.before[path] = .init(size: Int64(data.count), sha256: sha)
        #expect(throws: UsbWriteRun.SourceChanged.self) { try run.requireManifestBase(manifest, changes: changes) }
        #expect(throws: UsbError.self) { try run.requireManifestCoverage(manifest) }
        // manifest 해시가 없던 옛 저널도 흡수된 기준을 복원·회복 기대값으로 쓰지 못한다.
        let folder = try #require(run.backupFolder)
        let backup = folder.appending(path: "files").appending(path: path)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: backup)
        try UsbJournal.encoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
        run.journal.backupManifestSHA256 = nil
        #expect(throws: UsbError.self) { try run.loadValidatedBackup() }
        #expect(fixture.tree().isEmpty)
        expectNoUSBMutation(fs)
    }

    @Test("정상 빈 내보내기와 staged 뒤 bak는 백업·커밋·되돌리기 계약을 유지한다", arguments: [false, true])
    func normalExportAndBakRemainSupported(withBak: Bool) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let fs = fixture.fileSystem()
        let run = try stagedRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        let bak = UsbLayout.exportPdb + ".bak"
        if withBak { fixture.write(bak, Data("합성 보존할 bak".utf8)) }
        let original = fixture.tree()
        try run.backup(changes)
        #expect(fixture.journal()?.state == .backedUp)
        expectNoUSBMutation(fs)
        for path in UsbWriter.databaseFamily {
            #expect(run.manifest?.absentBefore.contains(path) == true && run.manifest?.files[path] == nil)
        }
        if withBak { #expect(run.manifest?.files[bak]?.sha256 == original[bak]) }
        try run.writeFiles(changes, isCancelled: { false })
        try run.commitDatabases(changes)
        #expect(fixture.journal()?.state == .committed)
        #expect(fixture.tree().filter { changes.target.mustExist[$0.key] != nil }
            == changes.target.mustExist.mapValues { $0.sha256 ?? "" })
        #expect(run.journal.sidecarDeletions?.isEmpty ?? true)
        #expect(try run.rollback(mode: .write).isEmpty)
        #expect(fixture.tree() == original)
    }

    @Test("base 없는 파일만 쓰기·단일 형식 내보내기는 미계획 DB family의 부재까지 가정하지 않는다",
          arguments: ["files-only", "one-only", "pdb-only"])
    func exportAbsenceFollowsCreatedDatabasePlan(kind: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = fixture.exportChanges()
        changes.databases = changes.databases.filter {
            kind == "one-only" ? $0.format == .oneLibrary : kind == "pdb-only" && $0.format == .deviceLibrary
        }
        changes.formats = kind == "one-only" ? [.oneLibrary] : kind == "pdb-only" ? [.deviceLibrary] : []
        for path in UsbWriter.databaseOrder where !changes.databases.contains(where: { $0.destination == path }) {
            changes.target.mustExist.removeValue(forKey: path)
        }
        let fs = fixture.fileSystem()
        let run = try stagedRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        let path = kind == "one-only" ? UsbLayout.exportExtPdb : UsbLayout.oneLibrary + "-wal"
        fixture.write(path, Data("합성 미계획 family 파일".utf8))
        let original = fixture.tree()
        try run.backup(changes)
        #expect(fixture.journal()?.state == .backedUp)
        #expect(run.manifest?.files[path]?.sha256 == original[path])
        #expect(fixture.tree() == original)
        expectNoUSBMutation(fs)
    }

    @Test("단일 OneLibrary 내보내기도 WAL·journal·SHM 부재 기준을 지킨다", arguments: ["-wal", "-journal", "-shm"])
    func oneLibraryOnlyExportRejectsNewSidecars(suffix: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        var changes = fixture.exportChanges()
        changes.databases.removeAll { $0.format != .oneLibrary }
        changes.formats = [.oneLibrary]
        for path in [UsbLayout.exportPdb, UsbLayout.exportExtPdb] { changes.target.mustExist.removeValue(forKey: path) }
        let fs = fixture.fileSystem()
        let run = try stagedRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        fixture.write(UsbLayout.oneLibrary + suffix, Data("합성 단일 형식 외부 사이드카".utf8))
        let original = fixture.tree()
        #expect(throws: UsbError.self) { try run.backup(changes) }
        #expect(fixture.tree() == original && fixture.backupFolders().isEmpty)
        expectNoUSBMutation(fs)
    }

    @Test("일반 편집은 계획 때 있던 각 사이드카와 bak를 백업하고 원래대로 되돌린다",
          arguments: ["-wal", "-journal", "-shm"])
    func ordinaryEditKeepsExistingSidecarAndBak(suffix: String) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        fixture.seedEdit()
        let path = UsbLayout.oneLibrary + suffix
        fixture.write(path, Data("합성 계획 전 사이드카".utf8))
        let changes = try fixture.editChanges(removals: false)
        #expect(changes.base?.files[path] != nil && changes.syncSelection == nil)
        let fs = fixture.fileSystem()
        let run = try stagedRun(changes, fixture: fixture, fs: fs)
        defer { run.close() }
        let bak = UsbLayout.exportPdb + ".bak"
        fixture.write(bak, Data("합성 편집 bak".utf8))
        let original = fixture.tree()
        try run.backup(changes)
        expectNoUSBMutation(fs)
        #expect(run.manifest?.files[path]?.sha256 == changes.base?.files[path]?.sha256)
        #expect(run.manifest?.files[bak]?.sha256 == original[bak])
        try run.writeFiles(changes, isCancelled: { false })
        try run.commitDatabases(changes)
        #expect(!fixture.exists(path))
        #expect(try run.rollback(mode: .write).isEmpty)
        #expect(fixture.tree() == original)
    }
}
