import Foundation
import Testing

/// 실제 실행 확인(`LibrarySnapshot.isRekordboxRunning` → `RekordboxProcessCheck.system`)이 pgrep을 띄우지 못하면 켜진 것으로 보는지(#323).
/// djc를 pgrep 실행을 막은 샌드박스에서 띄운다. 전에는 '꺼짐'으로 봐 스냅샷을 떴다. 이 Mac에서 rekordbox가 켜져 있든 꺼져 있든 막혀야 한다.
/// rekordbox 폴더·데이터 폴더는 임시 폴더이고 master.db는 빈 자리 파일이다(막히지 않아도 임시 폴더 안에만 복사한다)
@Suite("rekordbox 실행 확인 실패(CLI)")
struct RekordboxDetectionCLITests {
    static let denyPgrep = #"(version 1)(allow default)(deny process-exec (literal "/usr/bin/pgrep"))"#

    @Test func pgrep을_띄우지_못하면_스냅샷을_뜨지_않는다() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "djc-detect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let rekordbox = scratch.appending(path: "rekordbox"), home = scratch.appending(path: "home")
        try FileManager.default.createDirectory(at: rekordbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("자리".utf8).write(to: rekordbox.appending(path: "master.db"))

        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let djc = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", Self.denyPgrep, djc.path, "snapshot"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJC_HOME": home.path, "DJC_REKORDBOX_DIR": rekordbox.path, "DJC_LANG": "ko",
        ]) { _, new in new }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus != 0, "\(log)")
        #expect(log.contains("rekordbox가 실행 중입니다"), "\(log)")
        let copies = (FileManager.default.subpaths(atPath: scratch.path) ?? []).filter { $0.hasSuffix(".db") && !$0.hasSuffix("master.db") }
        #expect(copies.isEmpty, "스냅샷을 뜨지 않는다: \(copies)")
    }
}
