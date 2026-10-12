import CryptoKit
import Foundation
import Testing

/// 앱 자동 업데이트(#59): 릴리스 워크플로가 부르는 scripts/sparkle-appcast.sh.
/// sign_update는 가짜 도구로 바꾸고(받은 인자·표준 입력을 적는다), 서명은 시험이 CryptoKit으로 만든 진짜 ed25519 서명을 준다.
/// 앱 공개 키 확인(scripts/sparkle-verify.swift)은 진짜로 돈다.
@Suite("업데이트 서명·정보 파일 스크립트")
struct SparkleAppcastScriptTests {
    /// 합성 비밀 키 문자열(가짜 sign_update는 읽기만 한다). 인자에 새지 않는지 본다.
    static let secret = "SYNTHETIC-PRIVATE-KEY-0123456789"

    @Test func 서명하고_앱_공개_키로_확인한_뒤_정보_파일을_만든다() throws {
        let key = Curve25519.Signing.PrivateKey()
        let result = try run(signing: key, appKey: key.publicKey)
        #expect(result.status == 0, "\(result.output)")
        let xml = try #require(result.appcast)
        #expect(xml.contains("<sparkle:version>77</sparkle:version>"))
        #expect(xml.contains("<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>"))
        #expect(xml.contains("<sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>"))
        #expect(xml.contains("<sparkle:releaseNotesLink>https://github.com/fotoner/DJCrate/releases/tag/v1.2.3</sparkle:releaseNotesLink>"))
        #expect(xml.contains("url=\"https://github.com/fotoner/DJCrate/releases/download/v1.2.3/DJCrate-1.2.3-macOS-arm64.zip\""))
        #expect(xml.contains("length=\"\(result.archiveLength)\""))
        #expect(xml.contains("sparkle:edSignature=\"\(result.signature)\""))
        // 비밀 키는 표준 입력으로만 넘기고 인자·출력에 남기지 않는다
        #expect(result.signArguments.contains("--ed-key-file -"))
        #expect(!result.signArguments.contains(Self.secret))
        #expect(result.signInput.contains(Self.secret))
        #expect(!result.output.contains(Self.secret))
        #expect(result.signArguments.contains("--verify"))
    }

    @Test func 앱_공개_키와_짝이_아닌_서명이면_정보_파일을_만들지_않는다() throws {
        let result = try run(signing: Curve25519.Signing.PrivateKey(), appKey: Curve25519.Signing.PrivateKey().publicKey)
        #expect(result.status != 0)
        #expect(result.appcast == nil)
        #expect(result.output.contains("앱의 공개 키와 맞지 않습니다"))
    }

    @Test(arguments: [
        ("", "v1.2.3", false),          // 시크릿이 비었다
        (secret, "v1.2.4", false),      // 태그와 앱 버전이 다르다
        (secret, "v1.2.3", true),       // sign_update --verify가 실패한다
    ])
    func 실패해야_할_때_정보_파일을_만들지_않는다(_ secret: String, _ tag: String, _ verifyFails: Bool) throws {
        let key = Curve25519.Signing.PrivateKey()
        let result = try run(signing: key, appKey: key.publicKey, secret: secret, tag: tag, verifyFails: verifyFails)
        #expect(result.status != 0)
        #expect(result.appcast == nil)
        if secret.isEmpty { #expect(result.signArguments.isEmpty) }
    }

    private func run(signing: Curve25519.Signing.PrivateKey, appKey: Curve25519.Signing.PublicKey, secret: String = Self.secret,
                     tag: String = "v1.2.3", verifyFails: Bool = false) throws
        -> (status: Int32, output: String, appcast: String?, signature: String, archiveLength: Int,
            signArguments: String, signInput: String) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "djc-appcast-script-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["scripts/sparkle-appcast.sh", "scripts/sparkle-verify.swift"] {
            try fm.createDirectory(at: root.appending(path: "scripts"), withIntermediateDirectories: true)
            try fm.copyItem(at: repo.appending(path: name), to: root.appending(path: name))
        }
        // 합성 ZIP과 그 ZIP에서 푼 앱(Info.plist만)
        let archive = root.appending(path: "dist/DJCrate-1.2.3-macOS-arm64.zip")
        try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: archive)
        let signature = try signing.signature(for: bytes).base64EncodedString()
        let info: [String: Any] = ["CFBundleVersion": "77", "CFBundleShortVersionString": "1.2.3", "LSMinimumSystemVersion": "27.0",
                                   "SUPublicEDKey": appKey.rawRepresentation.base64EncodedString()]
        let app = root.appending(path: "verify/DJCrate.app/Contents")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Info.plist"))
        // 가짜 sign_update: 인자와 표준 입력을 적고, 서명할 때는 시험이 준 서명을 낸다
        let tool = root.appending(path: ".build/artifacts/DJCrate/Sparkle/bin/sign_update")
        try fm.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"""
        #!/bin/zsh
        print -r -- "$*" >> "$DJC_TEST_ROOT/sign-args"
        cat >> "$DJC_TEST_ROOT/sign-stdin"
        if [[ " $* " == *" --verify "* ]]; then exit "$DJC_TEST_VERIFY_EXIT"; fi
        print -r -- "$DJC_TEST_SIGNATURE"
        """#.utf8).write(to: tool)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let process = Process(), output = Pipe()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [root.appending(path: "scripts/sparkle-appcast.sh").path, archive.path,
                             root.appending(path: "verify/DJCrate.app").path, tag, "fotoner/DJCrate",
                             root.appending(path: "dist/appcast.xml").path]
        var environment = ProcessInfo.processInfo.environment
        environment["DJC_TEST_ROOT"] = root.path
        environment["DJC_TEST_SIGNATURE"] = signature
        environment["DJC_TEST_VERIFY_EXIT"] = verifyFails ? "1" : "0"
        environment["SPARKLE_ED_PRIVATE_KEY"] = secret
        process.environment = environment
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        func read(_ name: String) -> String? { try? String(contentsOf: root.appending(path: name), encoding: .utf8) }
        return (process.terminationStatus, text, read("dist/appcast.xml"), signature, bytes.count,
                read("sign-args") ?? "", read("sign-stdin") ?? "")
    }
}
