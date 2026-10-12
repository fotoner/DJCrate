// 업데이트 파일의 EdDSA(ed25519) 서명을 앱에 넣은 공개 키로 확인한다(#59).
// sign_update --verify는 비밀 키에서 공개 키를 다시 만들어 본다. 이 스크립트는 앱 Info.plist의 SUPublicEDKey로 보므로,
// 저장소의 공개 키 파일과 시크릿의 비밀 키가 짝이 아니면 Release 전에 실패한다.
// 사용: swift scripts/sparkle-verify.swift <파일> <서명 base64> <공개 키 base64>
import CryptoKit
import Foundation

let args = CommandLine.arguments.dropFirst()
guard args.count == 3 else {
    FileHandle.standardError.write(Data("사용: swift scripts/sparkle-verify.swift <파일> <서명 base64> <공개 키 base64>\n".utf8))
    exit(2)
}
let path = args[args.startIndex]
let signature = args[args.startIndex + 1]
let publicKey = args[args.startIndex + 2]
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}
guard let file = FileManager.default.contents(atPath: path) else { fail("파일을 읽지 못했습니다: \(path)") }
guard let sig = Data(base64Encoded: signature), sig.count == 64 else { fail("서명이 ed25519 base64(64바이트)가 아닙니다.") }
guard let keyData = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    fail("공개 키가 ed25519 base64(32바이트)가 아닙니다.")
}
guard key.isValidSignature(sig, for: file) else { fail("EdDSA 서명이 앱의 공개 키와 맞지 않습니다: \(path)") }
print("EdDSA 서명 확인: \((path as NSString).lastPathComponent)")
