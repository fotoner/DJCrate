import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// CLI 쓰기 전 정리(R22): 앱이 쓴 뒤 정리 전에 멈춰 미정리 목록이 남았을 때, CLI가 같은 대상에 `--live`로 쓰면 그 정리가 먼저 된다.
/// 그래서 앱이 이미 쓴 초안을 CLI가 다시 쓰지 않는다. 합성 사본을 `DJC_REKORDBOX_DIR`로 준다(이 Mac의 라이브러리를 건드리지 않는다)
@Suite("CLI 쓰기 전 정리")
struct CLICleanupBeforeWriteTests {
    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    func run(_ args: [String], fixture: RekordboxFixture, home: URL) throws -> Output {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/debug/djc", ".build/out/Products/Debug/djc"]
        let executable = try #require(candidates.map { root.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = executable
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJC_LANG": "ko",
            "DJC_HOME": home.path,
            "DJC_REKORDBOX_DIR": fixture.root.path,
        ]) { _, new in new }
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile(), stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }

    @Test func 정리_전에_CLI로_같은_대상에_쓰면_정리가_먼저_되어_쓴_초안을_다시_쓰지_않는다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "101", uuid: "track-101")
        track.cues = [CueSpec(id: "original", inMsec: 1000)]
        try fixture.add(track)
        let home = fixture.root.appending(path: "home", directoryHint: .isDirectory)
        // 앱이 이 초안을 이미 썼고(판이 같은 초안), 정리 전에 멈춰 미정리 목록만 남았다
        let saved = try run(["draft", "cue", "101", "--time", "12.5", "--db", fixture.database.path], fixture: fixture, home: home)
        try #require(saved.status == 0, "\(saved.stderr)")
        let key = DraftKey(.cue, "track-101")
        let stamp = try #require(DraftStampStore.stamp(key, home: home))
        let list = DraftCleanupList(operationID: "op-app", target: try RekordboxWriteLocks.key(fixture.database), draftHome: home.path,
                                    backupFolder: "w1", written: [WrittenDraft(key: key, revision: stamp.revision, contentHash: stamp.contentHash)])
        let backups = home.appending(path: "rekordbox-backups", directoryHint: .isDirectory)
        let file = DraftCleanupList.url(backups: backups, operationID: list.operationID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DraftCleanupList.encoder.encode(list).write(to: file)
        let draft = home.appending(path: "cue-drafts/track-101.json")
        #expect(FileManager.default.fileExists(atPath: draft.path))

        let output = try run(["cue-write", "--live"], fixture: fixture, home: home)
        #expect(!FileManager.default.fileExists(atPath: draft.path), "쓴 판의 초안을 먼저 지웠다: \(output.stdout)\(output.stderr)")
        #expect(!FileManager.default.fileExists(atPath: file.path), "정리를 마치고 목록을 지웠다")
        #expect(output.status == 0 && output.stdout.contains("저장한 곡 0"), "\(output.stdout)\(output.stderr)")
    }
}
