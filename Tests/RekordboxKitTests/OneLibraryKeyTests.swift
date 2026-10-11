import CryptoKit
import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

@Suite("OneLibrary 키")
struct OneLibraryKeyTests {
    /// 키 자체는 적지도 출력하지도 않는다. 모양과 해시 앞부분만 본다.
    @Test func keyShape() throws {
        let key = try RekordboxKey.oneLibrary()
        #expect(key.count == 64)
        #expect(key.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        let allHex = key.allSatisfy(\.isHexDigit)
        #expect(!allHex)
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest.hasPrefix("1226445cecea"))
    }

    @Test func masterKeyUnchanged() throws {
        let key = try RekordboxKey.derive()
        #expect(key.count == 64)
        #expect(key.hasPrefix("402fd"))
        let allHex = key.allSatisfy(\.isHexDigit)
        #expect(allHex)
        let other = try RekordboxKey.oneLibrary()
        #expect(key != other)
    }

    @Test func deriveRejectsWhenValidationFails() {
        let error = #expect(throws: DJCError.self) { try RekordboxKey.derive(blob: RekordboxKey.oneLibraryBlob) { _ in false } }
        if let error, case .keyDerivationFailed = error {} else { Issue.record("keyDerivationFailed가 아님") }
        #expect(throws: DJCError.self) { try RekordboxKey.derive(blob: "\"not base85\"") { _ in true } }
    }
}
