import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 제품은 SQLCipher 암호 설정을 바꾸지 않는다: 시험 전용 장치(`CipherTestKDF`)가 없는 프로세스는 SQLCipher 4 기본 키 유도(256,000번)를 쓴다.
/// 장치는 일부 시험 묶음에만 링크된다. 이 묶음(djcTests)과 여기서 띄우는 djc에는 없다.
@Suite("제품의 기본 키 유도 설정")
struct CipherDefaultKDFTests {
    @Test func djc를_띄우는_시험_프로세스는_기본_반복_수_그대로다() throws {
        #expect(try CipherKDF.processDefaultIterations() == CipherKDF.productIterations)
    }

    @Test func djc_하위_프로세스가_만든_OneLibrary는_기본_반복_수로_유도한_키로_열린다() throws {
        let tree = UsbTreeFixture()
        defer { tree.remove() }
        var library = UsbLibraryFixture()
        library.formats = [.oneLibrary]  // 이 시험은 OneLibrary만 본다
        try library.write(to: tree)
        let output = tree.base.appending(path: "rebuilt")
        let (status, log) = try run(["lab", "usb-rebuild", tree.base.path, output.path], scratch: tree.base)
        #expect(status == 0, "\(log)")
        let database = output.appending(path: UsbLayout.oneLibrary).path
        let passphrase = try RekordboxKey.oneLibrary()
        #expect(try CipherKDF.opens(path: database, passphrase: passphrase, iterations: CipherKDF.productIterations))
        #expect(try !CipherKDF.opens(path: database, passphrase: passphrase, iterations: 1))
    }

    func run(_ arguments: [String], scratch: URL) throws -> (Int32, String) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJC_HOME": scratch.appending(path: "home").path, "DJC_REKORDBOX_DIR": scratch.appending(path: "rekordbox").path, "DJC_LANG": "ko",
        ]) { _, new in new }
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
