import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

@Suite("SQLCipher 키 종류·열기 방식")
struct CipherKeyTests {
    /// 지어낸 64자 영숫자 키(실제 키가 아니다)
    static let passphrase = String(repeating: "TestKey0", count: 8)
    /// 지어낸 16진수 키
    static let hexKey = String(repeating: "0123456789abcdef", count: 4)

    static func temporaryDatabase() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-cipherkey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "test.db")
    }

    static func expectFailure(_ label: String, matching: (DJCError) -> Bool, _ body: () throws -> Void) {
        let error = #expect(throws: DJCError.self, performing: body)
        if let error, !matching(error) { Issue.record("\(label): 다른 오류 \(error)") }
    }

    @Test func passphraseCreateThenReopen() throws {
        let url = try Self.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let created = try CipherDatabase(path: url.path, key: .passphrase(Self.passphrase), mode: .create)
        try created.execute("CREATE TABLE t(a integer)")
        try created.run("INSERT INTO t VALUES (?)", [.int(7)])
        created.close()

        let reader = try CipherDatabase(path: url.path, key: .passphrase(Self.passphrase), mode: .readOnly)
        #expect(try reader.scalarInt("SELECT a FROM t") == 7)
        // 읽기 전용 연결은 쓰지 못한다
        #expect(throws: DJCError.self) { try reader.execute("INSERT INTO t VALUES (8)") }
        reader.close()

        let writer = try CipherDatabase(path: url.path, key: .passphrase(Self.passphrase), mode: .readWrite)
        try writer.run("INSERT INTO t VALUES (?)", [.int(8)])
        #expect(try writer.scalarInt("SELECT count(*) FROM t") == 2)
        writer.close()
    }

    @Test func hexKeyPathUnchanged() throws {
        let url = try Self.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let created = try CipherDatabase(path: url.path, key: .hex(Self.hexKey), mode: .create)
        try created.execute("CREATE TABLE t(a integer)")
        created.close()

        // 기존 init(path:key:writable:)은 그대로 16진수 키로 연다
        let writer = try CipherDatabase(path: url.path, key: Self.hexKey, writable: true)
        try writer.run("INSERT INTO t VALUES (?)", [.int(3)])
        writer.close()
        let reader = try CipherDatabase(path: url.path, key: Self.hexKey)
        #expect(try reader.scalarInt("SELECT a FROM t") == 3)
        #expect(throws: DJCError.self) { try reader.execute("DELETE FROM t") }
        reader.close()
        // 16진수가 아닌 글자는 기존처럼 거부한다
        Self.expectFailure("16진수 아님", matching: { if case .keyDerivationFailed = $0 { true } else { false } }) {
            _ = try CipherDatabase(path: url.path, key: "zz", writable: false)
        }
        // 기존 WAL 합치기(16진수 키)도 그대로 동작한다
        try CipherDatabase.mergeWriteAheadLog(ofCopyAt: url.path, key: Self.hexKey)
    }

    @Test func passphraseRejectsQuoteAndNonAlnum() throws {
        let url = try Self.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for bad in ["a'b", "ab-c", "", "키0"] {
            Self.expectFailure(bad, matching: { if case .keyDerivationFailed = $0 { true } else { false } }) {
                _ = try CipherDatabase(path: url.path, key: .passphrase(bad), mode: .create)
            }
            Self.expectFailure(bad, matching: { if case .keyDerivationFailed = $0 { true } else { false } }) {
                try CipherDatabase.mergeWriteAheadLog(ofCopyAt: url.path, key: .passphrase(bad))
            }
        }
        // 거부한 키로는 파일을 만들지 않는다
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func createFailsIfFileExists() throws {
        let url = try Self.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("existing".utf8).write(to: url)
        Self.expectFailure("이미 있음", matching: { if case .databaseOpenFailed = $0 { true } else { false } }) {
            _ = try CipherDatabase(path: url.path, key: .passphrase(Self.passphrase), mode: .create)
        }
        #expect(try Data(contentsOf: url) == Data("existing".utf8))
    }

    @Test func createRefusesPioneerLibraryPath() throws {
        // 경로 문자열만 넘긴다. 거부되므로 실제로 만들어지지 않는다.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [home + "/Library/Pioneer/djc-never-created-\(UUID().uuidString).db",
                     home + "/Library/Pioneer/rekordbox/../djc-never-created-\(UUID().uuidString).db",
                     home + "/library/PIONEER/djc-never-created-\(UUID().uuidString).db"] {
            Self.expectFailure(path, matching: { if case .databaseOpenFailed = $0 { true } else { false } }) {
                _ = try CipherDatabase(path: path, key: .passphrase(Self.passphrase), mode: .create)
            }
            #expect(!FileManager.default.fileExists(atPath: path))
        }
        #expect(CipherDatabase.isUnderPioneerLibrary(home + "/Library/Pioneer"))
        #expect(!CipherDatabase.isUnderPioneerLibrary(home + "/Library/PioneerX/a.db"))
        #expect(!CipherDatabase.isUnderPioneerLibrary(FileManager.default.temporaryDirectory.appending(path: "a.db").path))
    }

    @Test func wrongKeyFails() throws {
        let url = try Self.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let created = try CipherDatabase(path: url.path, key: .passphrase(Self.passphrase), mode: .create)
        try created.execute("CREATE TABLE t(a integer)")
        created.close()
        let wrong = String(repeating: "WrongKey", count: 8)
        for mode in [OpenMode.readOnly, .readWrite] {
            Self.expectFailure("틀린 키", matching: { if case .databaseOpenFailed = $0 { true } else { false } }) {
                _ = try CipherDatabase(path: url.path, key: .passphrase(wrong), mode: mode)
            }
        }
        Self.expectFailure("16진수 키로 열기", matching: { if case .databaseOpenFailed = $0 { true } else { false } }) {
            _ = try CipherDatabase(path: url.path, key: .hex(Self.hexKey), mode: .readOnly)
        }
    }

    @Test func credentialFilterBlocksCloudPropertyAndUuidIDMap() {
        #expect(CipherDatabase.isCredentialIdentifier("djmdCloudProperty"))
        #expect(CipherDatabase.isCredentialIdentifier("uuidIDMap"))
        // 기존 목록은 그대로
        #expect(CipherDatabase.isCredentialIdentifier("agentRegistry"))
        #expect(!CipherDatabase.isCredentialIdentifier("djmdContent"))
        #expect(!CipherDatabase.isCredentialIdentifier("content"))
    }

    @Test func diagnosticWithPassphraseBlocksCredentialTables() throws {
        let url = try Self.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let created = try CipherDatabase(path: url.path, key: .passphrase(Self.passphrase), mode: .create)
        try created.execute("CREATE TABLE uuidIDMap(a varchar)")
        try created.execute("CREATE TABLE content(a varchar)")
        try created.execute("INSERT INTO uuidIDMap VALUES ('synthetic-private-value')")
        created.close()
        let db = try CipherDatabase.diagnostic(path: url.path, key: .passphrase(Self.passphrase))
        var read = false
        #expect(throws: DJCError.self) { try db.query("SELECT a FROM uuidIDMap") { _ in read = true } }
        #expect(!read)
        #expect(try db.scalarInt("SELECT count(*) FROM content") == 0)
    }
}
