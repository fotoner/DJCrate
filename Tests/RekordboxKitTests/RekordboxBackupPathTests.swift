import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

@Suite("백업 복원 경로 검증")
struct RekordboxBackupPathTests {
    let relative = "PIONEER/USBANLZ/abc/def/ANLZ0000.DAT"

    func setup(parent: URL = FileManager.default.temporaryDirectory) throws -> (RekordboxFixture, URL, URL) {
        let fixture = try RekordboxFixture(parent: parent)
        var track = TrackSpec(id: "1", uuid: "abcdef")
        track.analysisDataPath = "/" + relative
        track.imagePath = "/PIONEER/Artwork/abc/def/artwork.jpg"
        try fixture.add(track)
        let backup = try RekordboxWriter.makeBackup(of: fixture.database, in: fixture.backups, now: .now, label: "write")
        try fixture.execute("UPDATE agentRegistry SET int_1 = 2000 WHERE registry_id = 'localUpdateCount'")
        let target = fixture.shareRoot.appending(path: relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("현재".utf8).write(to: target)
        try FileManager.default.createDirectory(at: backup.appending(path: "anlz"), withIntermediateDirectories: true)
        try Data("백업".utf8).write(to: backup.appending(path: "anlz/0.DAT"))
        try Data("백업".utf8).write(to: backup.appending(path: "anlz/1.DAT"))
        return (fixture, backup, target)
    }

    func manifest(_ values: [String: String], _ backup: URL) throws {
        try JSONEncoder().encode(values).write(to: backup.appending(path: "anlz/manifest.json"))
    }

    func createdFiles(_ paths: [String], in backup: URL, name: String) throws {
        let data: Data
        if name == "report.json" {
            var report = RekordboxWriter.Report(outcomes: [], backup: nil, dryRun: false, createdAt: "test")
            report.createdFiles = paths
            data = try JSONEncoder().encode(report)
        } else {
            var report = RekordboxTrackWriter.Report(dryRun: false)
            report.createdFiles = paths
            data = try JSONEncoder().encode(report)
        }
        try data.write(to: backup.appending(path: name))
    }

    func refused(_ fixture: RekordboxFixture, _ backup: URL) throws {
        #expect(throws: DJCError.self) {
            try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups)
        }
        #expect(try fixture.localUpdateCount() == 2000)
        #expect(RekordboxWriter.backups(in: fixture.backups).count == 1)
    }

    @Test(arguments: ["manifest", "report.json", "track-report.json"])
    func 루트_밖_경로는_DB와_파일을_건드리기_전에_막는다(_ metadata: String) throws {
        let (fixture, backup, _) = try setup()
        let outside = fixture.root.appending(path: "ANLZ0000.DAT")
        let original = Data("보존".utf8)
        try original.write(to: outside)
        if metadata == "manifest" {
            try manifest(["0.DAT": outside.path], backup)
        } else {
            try createdFiles([outside.path], in: backup, name: metadata)
        }
        try refused(fixture, backup)
        #expect(try Data(contentsOf: outside) == original)
    }

    @Test(arguments: ["PIONEER/USBANLZ/abc/../def/ANLZ0000.DAT", "PIONEER/USBANLZ/abc/def/other.DAT", "PIONEER/Artwork/a/notes.txt", "PIONEER/USBANLZ-other/a/ANLZ0000.DAT"])
    func 이동이나_예상_밖_형식은_막는다(_ path: String) throws {
        let (fixture, backup, _) = try setup()
        try manifest(["0.DAT": path], backup)
        try refused(fixture, backup)
    }

    @Test(arguments: ["target", "parent", "root", "share", "source", "source-parent"])
    func 심볼릭_링크를_통한_복원은_막는다(_ kind: String) throws {
        let (fixture, backup, target) = try setup()
        let fm = FileManager.default
        let link: URL
        switch kind {
        case "target": link = target
        case "parent": link = target.deletingLastPathComponent()
        case "root": link = fixture.shareRoot.appending(path: "PIONEER/USBANLZ")
        case "share": link = fixture.shareRoot
        case "source": link = backup.appending(path: "anlz/0.DAT")
        default: link = backup.appending(path: "anlz")
        }
        try manifest(["0.DAT": target.path], backup)
        let moved = fixture.root.appending(path: "moved")
        try fm.moveItem(at: link, to: moved)
        try fm.createSymbolicLink(at: link, withDestinationURL: moved)
        try refused(fixture, backup)
    }

    @Test(arguments: ["../master.db", "/absolute", "missing.DAT"])
    func 백업_원본도_백업_폴더의_일반_파일이어야_한다(_ source: String) throws {
        let (fixture, backup, target) = try setup()
        try manifest([source: target.path], backup)
        try refused(fixture, backup)
    }

    @Test(arguments: ["manifest", "report", "both"])
    func 중복_대상은_막는다(_ kind: String) throws {
        let (fixture, backup, target) = try setup()
        try manifest(kind == "manifest" ? ["0.DAT": target.path, "1.DAT": target.path] : ["0.DAT": target.path], backup)
        if kind != "manifest" {
            if kind == "report" { try manifest([:], backup) }
            try createdFiles(kind == "report" ? [target.path, target.path] : [target.path], in: backup, name: "report.json")
        }
        try refused(fixture, backup)
    }

    @Test(arguments: [false, true])
    func 상대_경로와_루트_안의_옛_절대_경로를_복원한다(_ legacy: Bool) throws {
        let (fixture, backup, target) = try setup()
        try manifest(["0.DAT": legacy ? target.path : relative], backup)
        let saved = try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups)
        #expect(try Data(contentsOf: target) == Data("백업".utf8))
        let savedManifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: saved.appending(path: "anlz/manifest.json")))
        #expect(Array(savedManifest.values) == [relative])
        _ = try RekordboxWriter.restore(saved, to: fixture.database, backups: fixture.backups)
        #expect(try Data(contentsOf: target) == Data("현재".utf8))
    }

    @Test(arguments: ["anlz/manifest.json", "report.json", "track-report.json"])
    func 손상된_메타데이터를_무시하고_복원하지_않는다(_ name: String) throws {
        let (fixture, backup, _) = try setup()
        try Data("{".utf8).write(to: backup.appending(path: name))
        try refused(fixture, backup)
    }

    @Test(arguments: ["master.db", "masterPlaylists6.xml"])
    func 고정_이름의_백업도_심볼릭_링크면_복원_전에_막는다(_ name: String) throws {
        let (fixture, backup, _) = try setup()
        let source = fixture.root.appending(path: "source")
        let link = backup.appending(path: name)
        if name == "master.db" { try FileManager.default.moveItem(at: link, to: source) }
        else { try Data("합성 XML".utf8).write(to: source) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        try refused(fixture, backup)
    }

    @Test(arguments: ["report.json", "track-report.json"])
    func 상대_경로로_만든_파일을_지우고_다시_살릴_수_있다(_ name: String) throws {
        let (fixture, backup, target) = try setup()
        try createdFiles([relative], in: backup, name: name)
        let saved = try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let paths = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: saved.appending(path: "anlz/manifest.json")))
        #expect(Array(paths.values) == [relative])
        _ = try RekordboxWriter.restore(saved, to: fixture.database, backups: fixture.backups)
        #expect(try Data(contentsOf: target) == Data("현재".utf8))
    }

    @Test func 새_그리드_백업에는_상대_경로만_남긴다() throws {
        let fixture = try RekordboxFixture()
        let result = try RekordboxBackupTests().writeAll(fixture)
        let backup = URL(filePath: try #require(result.report.backup))
        let paths = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: backup.appending(path: "anlz/manifest.json")))
        #expect(!paths.isEmpty && paths.values.allSatisfy { $0.hasPrefix("PIONEER/USBANLZ/") })
    }
}
