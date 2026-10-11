import CommonCrypto
import DJCTestKit
import Foundation
import RekordboxKit
import SQLCipher

/// 이 프로세스의 SQLCipher 키 유도 설정과 파일이 쓴 반복 수를 본다.
///
/// 제품 연결이 많은 시험 묶음은 시험 전용 장치(`CipherTestKDF`)가 프로세스 시작 때 기본 반복 수를 낮춘다.
/// djc를 띄우는 시험 묶음(djcTests)과 djc·앱 프로세스는 SQLCipher 4 기본값 그대로다.
public enum CipherKDF {
    /// SQLCipher 4 기본 반복 수(rekordbox와 제품이 쓰는 값)
    public static let productIterations = 256_000

    /// 이 프로세스의 SQLCipher 기본 키 유도 반복 수(`PRAGMA cipher_default_kdf_iter`).
    /// 제품 연결(`CipherDatabase`)로 메모리 DB를 열어 읽는다. 그래야 처음 여는 순간의 초기화 경쟁(#154, CIP-1)을 제품과 같은 관문으로 넘는다.
    public static func processDefaultIterations() throws -> Int {
        let db = try CipherDatabase(path: ":memory:", key: nil, mode: .readWrite)
        defer { db.close() }
        var value: Int?
        try db.query("PRAGMA cipher_default_kdf_iter") { value = $0.int(0) }
        guard let value else { throw FixtureError("cipher_default_kdf_iter 값이 없습니다") }
        return value
    }

    /// 문자열 키를 PBKDF2-HMAC-SHA512로 `iterations`번 유도한 원시 키(16진수 64자). 솔트는 파일 첫 16바이트.
    public static func rawKey(path: String, passphrase: String, iterations: Int) throws -> (salt: Data, key: String) {
        guard let file = FileHandle(forReadingAtPath: path) else { throw FixtureError("DB 머리를 읽지 못했습니다") }
        defer { try? file.close() }
        guard let salt = try file.read(upToCount: 16), salt.count == 16 else { throw FixtureError("DB 머리가 짧습니다") }
        return (salt, try rawKey(salt: salt, passphrase: passphrase, iterations: iterations))
    }

    static func rawKey(salt: Data, passphrase: String, iterations: Int) throws -> String {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passphrase, passphrase.utf8.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations), &derived, derived.count)
        }
        guard status == kCCSuccess else { throw FixtureError("키를 유도하지 못했습니다") }
        return derived.map { String(format: "%02x", $0) }.joined()
    }

    /// 문자열 키를 `iterations`번 유도한 원시 키로 열어 표를 읽을 수 있는지(읽기 전용). 파일이 그 반복 수로 만들어졌다는 뜻이다.
    public static func opens(path: String, passphrase: String, iterations: Int) throws -> Bool {
        let raw = try rawKey(path: path, passphrase: passphrase, iterations: iterations).key
        _ = try processDefaultIterations()  // SQLCipher 초기화를 제품 관문으로 먼저 마친다
        var handle: OpaquePointer?
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_exec(handle, "PRAGMA key = \"x'\(raw)'\"", nil, nil, nil) == SQLITE_OK
        else { return false }
        return sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK
    }
}
