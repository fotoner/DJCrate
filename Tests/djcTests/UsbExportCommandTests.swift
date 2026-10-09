import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing
@testable import djc

/// `djc usb-export` 인자·출력과 lab `usb-rebuild` 경로 제한
@Suite("USB 내보내기 명령")
struct UsbExportCommandTests {
    @Test("인자: 볼륨·사본·share·목록(여러 번)·곡·형식·시각·드라이 런·확인")
    func parsesArguments() throws {
        let request = try UsbCommands.exportRequest([
            "usb-export", "--volume", "/tmp/v", "--db", "/tmp/m.db", "--share", "/tmp/share", "--playlist", "11", "--playlist", "12",
            "--tracks", "101, 102", "--formats", "onelibrary", "--naming", "identifier", "--dry-run", "--confirm", "DJCTEST",
            "--verify-audio", "--settings", "/tmp/settings",
            "--snapshot-time", "2026-09-27T11:41:08Z",
        ])
        #expect(request.volume == "/tmp/v" && request.database == "/tmp/m.db" && request.share == "/tmp/share")
        #expect(request.playlists == ["11", "12"] && request.tracks == ["101", "102"])
        #expect(request.formats == [.oneLibrary])
        #expect(request.dryRun && request.verifyAudio)
        #expect(request.confirmName == "DJCTEST")
        #expect(request.settingsFolder == "/tmp/settings")
        #expect(request.snapshotTime == "2026-09-27T11:41:08Z")

        let minimal = try UsbCommands.exportRequest(["usb-export", "--volume", "/tmp/v", "--tracks", "101"])
        #expect(minimal.formats == UsbFormat.defaultSet && minimal.database == nil && minimal.share == nil)
        #expect(!minimal.dryRun && minimal.snapshotTime == nil && minimal.settingsFolder == nil)
        #expect(try UsbCommands.exportRequest(["usb-export", "--volume", "/v", "--tracks", "1", "--formats", "device"]).formats
            == [.deviceLibrary])
        #expect(try UsbCommands.exportRequest(["usb-export", "--volume", "/v", "--tracks", "1", "--formats", "device,onelibrary"]).formats
            == UsbFormat.defaultSet)
    }

    @Test("잘못된 인자는 사용법")
    func rejectsBadArguments() {
        for args in [
            ["usb-export", "--tracks", "1"],
            ["usb-export", "--volume", "/v"],
            ["usb-export", "--volume", "/v", "--tracks", "1", "--naming", "rekordbox"],
            ["usb-export", "--volume", "/v", "--tracks", "1", "--formats", "xml"],
            ["usb-export", "--volume", "/v", "--tracks", "1", "--unknown"],
            ["usb-export", "--volume", "/v", "--playlist"],
            ["usb-export", "--volume", "/v", "--tracks", "1", "--snapshot-time"],
            ["usb-export", "--volume", "/v", "--tracks", "1", "--allow-provisional", "cueVariant"],
        ] {
            #expect(throws: UsageError.self) { try UsbCommands.exportRequest(args) }
        }
    }

    @Test("라이브 master.db는 열지 않고 할 일과 함께 거부한다")
    func refusesLiveDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-usbexport-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let live = folder.appending(path: "rekordbox"), volume = folder.appending(path: "volume"), home = folder.appending(path: "home")
        for url in [live, volume, home] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let master = live.appending(path: "master.db")
        let original = Data("열면 안 되는 합성 파일".utf8)
        try original.write(to: master)
        let result = try run(["usb-export", "--volume", volume.path, "--db", master.path, "--share", live.appending(path: "share").path,
                              "--tracks", "1", "--snapshot-time", "2026-09-27T11:41:08Z"],
                             environment: ["DJC_REKORDBOX_DIR": live.path, "DJC_HOME": home.path])
        #expect(result.status == 1)
        #expect(result.stderr.contains("liveDatabase"))
        #expect(result.stderr.contains("라이브 master.db는 열 수 없습니다"))
        #expect(try Data(contentsOf: master) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: volume.path).isEmpty)
    }

    @Test("요약 줄: 첫 줄은 스냅샷 시각, 곡 제목·경로는 찍지 않는다")
    func summaryLinesWithoutTitles() throws {
        let env = try ExportEnv(tracks: 2)
        let session = env.session()
        let report = try session.write(selection: .tracks(["101", "102"]), options: ExportEnv.options { $0.dryRun = true },
                                       progress: { _ in }, isCancelled: { false })
        let lines = UsbCommands.exportLines(preview: try #require(session.lastPreview), report: report)
        #expect(lines.first == "스냅샷 시각: explicit")
        let text = lines.joined(separator: "\n")
        #expect(text.contains("내보낼 곡 2"))
        #expect(text.contains("막힌 곡 0"))
        for secret in ["합성 곡", "합성 아티스트", "track101", env.usb.usbURL.path, "Contents/"] { #expect(!text.contains(secret)) }
        // 드라이 런에는 꺼내기 안내를 붙이지 않고, 쓴 뒤에만 붙인다
        #expect(!text.contains("diskutil eject"))
        let written = try session.write(selection: .tracks(["101", "102"]), options: ExportEnv.options(), progress: { _ in },
                                        isCancelled: { false })
        let writtenLines = UsbCommands.exportLines(preview: try #require(session.lastPreview), report: written)
        #expect(writtenLines.last?.contains("diskutil eject") == true)
    }

    @Test("lab usb-rebuild: 출력 폴더가 임시 폴더 밖이면 만들지 않고 거부한다")
    func rebuildRefusesOutputOutsideScratch() async throws {
        let usb = UsbTreeFixture()
        defer { usb.remove() }
        let outside = NSHomeDirectory() + "/djc-usb-rebuild-\(UUID().uuidString)"
        await #expect(throws: UsbError.self) { try await UsbExportLab.usbRebuild(["usb-rebuild", usb.base.path, outside]) }
        #expect(!FileManager.default.fileExists(atPath: outside))
        await #expect(throws: UsageError.self) { try await UsbExportLab.usbRebuild(["usb-rebuild", usb.base.path]) }
    }

    @Test("lab usb-rebuild: 내보낸 USB의 DB 셋을 새 내보내기 모양으로 다시 만들면 모델 차이가 없다")
    func rebuildMatchesExport() async throws {
        let env = try ExportEnv(tracks: 3)
        try env.local.local.addPlaylist(id: "900", name: "합성 목록", seq: 1, contentIDs: ["101", "103"])
        _ = try env.session().write(selection: .playlists(["900"]), options: ExportEnv.options(), progress: { _ in },
                                    isCancelled: { false })
        let output = env.usb.folder.appending(path: "rebuilt")
        try await UsbExportLab.usbRebuild(["usb-rebuild", env.usb.usbURL.path, output.path])
        let lines = try UsbExportLab.rebuildDifferences(env.usb.usbURL, output)
        #expect(lines == 0)
        #expect(FileManager.default.fileExists(atPath: output.appending(path: UsbLayout.oneLibrary).path))
        #expect(FileManager.default.fileExists(atPath: output.appending(path: UsbLayout.exportPdb).path))
        #expect(!FileManager.default.fileExists(atPath: output.appending(path: "Contents").path))
    }

    func run(_ arguments: [String], environment: [String: String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map { root.appending(path: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment.merging(["DJC_LANG": "ko"]) { a, _ in a }) { _, new in new }
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile(), err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

/// 합성 로컬 라이브러리와 USB 흉내 하나(세션 규칙은 DJCStorageTests의 `UsbExportSessionTests`가 본다).
/// 명령 출력·lab 재구성 시험이 세션을 한 번 돌려 볼 때만 쓴다.
final class ExportEnv {
    let usb = UsbChangeSetFixture()
    let local: UsbExportFixture

    init(tracks: Int) throws {
        local = try UsbExportFixture()
        for index in 0..<tracks {
            try local.addTrack(id: String(101 + index), artist: ("1", "합성 아티스트"), album: ("30", "합성 앨범"))
        }
    }

    deinit { usb.remove() }

    func session() -> UsbExportSession {
        UsbExportSession(database: local.database, share: local.share, root: usb.usbURL,
                         guard: usb.writeGuard(gate: FakeUsbVolume.gate(), protectedRoots: []),
                         paths: usb.paths, engine: .live(fileSystem: usb.fileSystem()), device: .testing(),
                         localCopies: usb.home.appending(path: "usb-snapshots"), now: { Date() })
    }

    static func options(_ configure: (inout UsbExportOptions) -> Void = { _ in }) -> UsbExportOptions {
        var options = UsbExportOptions()
        options.snapshotTime = "2100-01-01T00:00:00Z"
        configure(&options)
        return options
    }
}
