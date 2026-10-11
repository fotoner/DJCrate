import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 쓰는 도중 한 연산이 실패하면(`.error`) 쓰는 쪽이 백업으로 되돌린다.
@Suite("USB 쓰기 실패 → 되돌리기")
struct UsbWriterFailureTests {
    enum Shape: Sendable { case export, edit, editWithSidecar }

    struct Case: Sendable, CustomStringConvertible {
        var name: String
        var shape: Shape
        var configure: @Sendable (FaultyUsbFileSystem) -> Void
        var verifier: Bool = false
        var description: String { name }
    }

    static let cases: [Case] = [
        Case(name: "백업 복사", shape: .edit) { fs in
            fs.failAt = (operation: .copyDataNew, occurrence: 1, mode: .error)
            fs.failSide = .mac
        },
        Case(name: "두 번째 음원 복사", shape: .export) { $0.failAt = (operation: .copyDataNew, occurrence: 2, mode: .error) },
        Case(name: "임시 fullSync", shape: .export) { $0.failAt = (operation: .fullSync, occurrence: 1, mode: .error) },
        Case(name: "rename", shape: .export) { $0.failAt = (operation: .rename, occurrence: 3, mode: .error) },
        Case(name: "._ 지우기", shape: .export) { fs in
            fs.simulateAppleDouble = true
            fs.failAt = (operation: .remove, occurrence: 2, mode: .error)
            fs.failMatching = { ($0 as NSString).lastPathComponent.hasPrefix("._") }
        },
        Case(name: "사이드카 지우기", shape: .editWithSidecar) { fs in
            fs.failAt = (operation: .remove, occurrence: 1, mode: .error)
            fs.failMatching = { $0.hasSuffix("-wal") }
        },
        Case(name: "첫 DB 교체 뒤(내보내기)", shape: .export) { fs in
            fs.failAt = (operation: .writeNew, occurrence: 2, mode: .error)
            fs.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
        },
        Case(name: "첫 DB 교체 뒤(수정)", shape: .editWithSidecar) { fs in
            fs.failAt = (operation: .writeNew, occurrence: 2, mode: .error)
            fs.failMatching = { $0.hasPrefix("PIONEER/rekordbox/") }
        },
        Case(name: "지우기", shape: .edit) { fs in
            fs.failAt = (operation: .remove, occurrence: 1, mode: .error)
            fs.failMatching = { $0 == UsbChangeSetFixture.goneAnalysis[1] }
        },
        Case(name: "검증", shape: .edit, configure: { _ in }, verifier: true),
    ]

    struct Failing: UsbWriteVerifier {
        func verify(root: UsbRoot, changes: UsbChangeSet, fileSystem: any UsbFileSystem, scratch: URL) throws -> [String] {
            ["합성 검증 실패"]
        }
    }

    @Test("실패하면 우리 경로 트리(._* 포함)가 쓰기 전과 같고 outcome은 rolledBack", arguments: cases)
    func failureRollsBack(testCase: Case) throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes: UsbChangeSet
        switch testCase.shape {
        case .export: changes = fixture.exportChanges()
        case .edit:
            fixture.seedEdit(extraAppleDouble: true)
            changes = try fixture.editChanges()
        case .editWithSidecar:
            fixture.seedEdit(extraSidecar: true, extraAppleDouble: true)
            changes = try fixture.editChanges()
        }
        let before = fixture.tree()
        let beforeDirs = fixture.directories()
        let fs = fixture.fileSystem()
        testCase.configure(fs)
        var verifiers: [any UsbWriteVerifier] = [UsbFingerprintVerifier()]
        if testCase.verifier { verifiers.append(Failing()) }
        #expect {
            try fixture.write(changes, fileSystem: fs, verifiers: verifiers)
        } throws: { error in
            if case UsbError.writeRolledBack = error { true } else { false }
        }
        #expect(fixture.tree() == before)
        #expect(fixture.directories() == beforeDirs)
        let journal = try #require(fixture.journal())
        #expect(journal.state == .rolledBack)
        if let backup = journal.backupDirectory {
            let report = try JSONDecoder().decode(UsbWriteReport.self, from: Data(contentsOf: URL(filePath: backup).appending(path: "report.json")))
            #expect(report.outcome == .rolledBack)
            #expect(report.resultDatabases == (try UsbWriter.databaseFingerprint(root: fixture.root, fileSystem: PosixUsbFileSystem())
                .files.filter { !$0.key.hasSuffix("-wal") }.mapValues(\.sha256)))
        }
        // 이어서 다시 쓰면 된다(닫힌 저널)
        #expect(UsbWriter.pendingJournal(paths: fixture.paths, volumeKey: fixture.volumeKey) == nil)
    }

    @Test("되돌리기도 실패하면 restoreFailed와 백업 폴더를 알린다")
    func restoreFailureReportsBackup() throws {
        let fixture = UsbChangeSetFixture()
        defer { fixture.remove() }
        let changes = fixture.exportChanges()
        let fs = fixture.fileSystem()
        fs.failAt = (operation: .rename, occurrence: 4, mode: .error)
        // 되돌리며 만든 음원을 지우는 연산도 실패
        fs.failWhen = { op, path in op == .remove && path == UsbChangeSetFixture.exportAudio[0] }
        var backupInError: String?
        #expect {
            try fixture.write(changes, fileSystem: fs)
        } throws: { error in
            guard case let UsbError.restoreFailed(_, _, backup) = error else { return false }
            backupInError = backup
            return true
        }
        let journal = try #require(fixture.journal())
        #expect(journal.state == .restoreFailed)
        #expect(!journal.isClosed)
        let backup = try #require(journal.backupDirectory)
        #expect(backupInError == backup)
        let report = try JSONDecoder().decode(UsbWriteReport.self, from: Data(contentsOf: URL(filePath: backup).appending(path: "report.json")))
        #expect(report.outcome == .restoreFailed)
        #expect(fixture.exists(UsbChangeSetFixture.exportAudio[0]))
        // 회복으로 끝낸다
        let recovered = try fixture.recover()
        #expect(recovered.outcome == .rolledBack)
        #expect(fixture.tree().isEmpty)
    }
}
