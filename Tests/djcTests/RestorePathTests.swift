import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

@Suite("CLI 백업 복원 경로")
struct RestorePathTests {
    @Test(arguments: [false, true])
    func CLI_share도_공통_검사를_거쳐_사본과_라이브의_혼용을_막는다(_ symbolic: Bool) throws {
        let fixture = try RekordboxFixture(), live = try RekordboxFixture()
        let backup = try RekordboxWriter.makeBackup(of: fixture.database, in: fixture.backups, now: .now, label: "write")
        try fixture.execute("UPDATE agentRegistry SET int_1 = 2000 WHERE registry_id = 'localUpdateCount'")
        let alias = fixture.root.appending(path: "share-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: live.shareRoot)
        let share = symbolic ? alias : live.shareRoot
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["rekordbox-restore", "--backup", backup.path, "--db", fixture.database.path, "--share", share.path]
        let home = fixture.root.appending(path: "home")
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJC_HOME": home.path, "DJC_REKORDBOX_DIR": live.root.path, "DJC_LANG": "ko",
        ]) { _, new in new }
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
        #expect(text.contains("사본 DB에 라이브 share를 사용할 수 없습니다"))
        #expect(try fixture.localUpdateCount() == 2000)
        #expect(try live.localUpdateCount() == 1000)
        let backups = home.appending(path: "rekordbox-backups")
        if FileManager.default.fileExists(atPath: backups.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func 지정한_share만_복원하고_바깥_경로는_DB도_바꾸지_않는다(_ malicious: Bool) throws {
        let fixture = try RekordboxFixture()
        let relative = "PIONEER/USBANLZ/abc/def/ANLZ0000.DAT"
        var track = TrackSpec(id: "1", uuid: "abcdef")
        track.analysisDataPath = "/" + relative
        try fixture.add(track)
        let share = fixture.root.appending(path: "separate-share")
        let target = share.appending(path: relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("현재".utf8).write(to: target)
        let backup = try RekordboxWriter.makeBackup(of: fixture.database, in: fixture.backups, now: .now, label: "write")
        try fixture.execute("UPDATE agentRegistry SET int_1 = 2000 WHERE registry_id = 'localUpdateCount'")
        let folder = backup.appending(path: "anlz")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("백업".utf8).write(to: folder.appending(path: "0.DAT"))
        try JSONEncoder().encode(["0.DAT": malicious ? fixture.root.appending(path: "ANLZ0000.DAT").path : relative])
            .write(to: folder.appending(path: "manifest.json"))
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["rekordbox-restore", "--backup", backup.path, "--db", fixture.database.path, "--share", share.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJC_HOME": fixture.root.appending(path: "home").path, "DJC_REKORDBOX_DIR": fixture.root.path, "DJC_LANG": "ko",
        ]) { _, new in new }
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == (malicious ? 1 : 0))
        #expect(text.contains(malicious ? "복원할 수 없습니다" : "되돌림 완료"))
        #expect(try fixture.localUpdateCount() == (malicious ? 2000 : 1000))
        #expect(try Data(contentsOf: target) == Data((malicious ? "현재" : "백업").utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: relative).path))
    }
}
