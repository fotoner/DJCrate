import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

@Suite("곡 삭제 파일 경계")
struct RekordboxDeletionFilesTests {
    let uuid = "abc00000-0000-4000-8000-000000000001"
    var relative: String { "/PIONEER/USBANLZ/\(uuid.prefix(3))/\(uuid.dropFirst(3))/ANLZ0000.DAT" }

    func setup(path: String? = nil) throws -> (RekordboxFixture, URL) {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "100", uuid: uuid)
        track.dataStatus = 0
        let audio = try AudioFixture.wav(seconds: 1, in: fixture.audio)
        track.folderPath = audio.path
        track.analysisDataPath = path ?? relative
        try fixture.add(track)
        return (fixture, audio)
    }

    func delete(_ fixture: RekordboxFixture) throws -> RekordboxTrackWriter.Report {
        try RekordboxTrackWriter.delete(contentIDs: ["100"], from: fixture.database, shareRoot: fixture.shareRoot,
                                        dryRun: false, backups: fixture.backups)
    }

    @Test func 음원폴더나_UUID와_다른_분석폴더는_파일을_남기고_DB만_뺀다() throws {
        for path in ["/../audio/ANLZ0000.DAT", "/PIONEER/USBANLZ/aaa/bbbb/ANLZ0000.DAT"] {
            let (fixture, audio) = try setup(path: path)
            let dat = try #require(RekordboxShare.analysisURL(path, root: fixture.shareRoot))
            try FileManager.default.createDirectory(at: dat.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: dat)
            let bytes = try Data(contentsOf: audio)
            let report = try delete(fixture)
            #expect(report.deleted.first?.written == true)
            #expect(report.deleted.first?.reason == "분석 파일을 지우지 않음(경로가 예상과 다름)")
            #expect(FileManager.default.fileExists(atPath: audio.path))
            if FileManager.default.fileExists(atPath: audio.path) { #expect(try Data(contentsOf: audio) == bytes) }
            #expect(FileManager.default.fileExists(atPath: dat.path))
            #expect(try fixture.rows("SELECT ID FROM djmdContent").isEmpty)
        }
    }

    @Test func 심볼릭링크는_따라가지_않는다() throws {
        let (fixture, audio) = try setup()
        let folder = try #require(RekordboxShare.analysisURL(relative, root: fixture.shareRoot)).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: fixture.audio)
        let report = try delete(fixture)
        #expect(report.deleted.first?.written == true && report.deleted.first?.reason != nil)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func 허용한_파일만_지우고_섞인_파일과_폴더는_남긴다() throws {
        let (fixture, _) = try setup()
        let folder = try #require(RekordboxShare.analysisURL(relative, root: fixture.shareRoot)).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let allowed = ["ANLZ0000.DAT", "ANLZ0000.EXT", "ANLZ0000.2EX", "ANLZ0000.3EX"]
        let others = ["song.wav", "notes.txt", "other.DAT"]
        for name in allowed + others { try Data([1]).write(to: folder.appending(path: name)) }
        let report = try delete(fixture)
        #expect(report.deleted.first?.reason == nil && report.removedFiles.count == 4)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == others.sorted())
        _ = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, backups: fixture.backups)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == (allowed + others).sorted())
    }

    @Test func 예전_백업의_잘못된_manifest로_음원을_덮어쓰지_않는다() throws {
        let (fixture, audio) = try setup()
        let bytes = try Data(contentsOf: audio)
        let report = try delete(fixture)
        let backup = URL(filePath: try #require(report.backup))
        let folder = backup.appending(path: "anlz")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("음원이 아닌 잘못된 백업".utf8).write(to: folder.appending(path: "0.wav"))
        try JSONEncoder().encode(["0.wav": audio.path]).write(to: folder.appending(path: "manifest.json"))
        #expect(throws: DJCError.self) { try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups) }
        #expect(try Data(contentsOf: audio) == bytes)
    }

    @Test func 예전_백업의_createdFiles에_음원이_있어도_지우지_않는다() throws {
        let (fixture, audio) = try setup()
        let bytes = try Data(contentsOf: audio)
        var report = try delete(fixture)
        let backup = URL(filePath: try #require(report.backup))
        report.createdFiles = [audio.path]
        // 외부에서 조작한 옛 보고서는 저장 경로 검증을 거치지 않는다.
        try JSONEncoder().encode(report).write(to: backup.appending(path: "track-report.json"))
        #expect(throws: DJCError.self) { try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups) }
        #expect(FileManager.default.fileExists(atPath: audio.path))
        if FileManager.default.fileExists(atPath: audio.path) { #expect(try Data(contentsOf: audio) == bytes) }
    }

    @Test func 허용한_파일이_심볼릭링크여도_원본을_건드리지_않는다() throws {
        let (fixture, audio) = try setup()
        let dat = try #require(RekordboxShare.analysisURL(relative, root: fixture.shareRoot))
        try FileManager.default.createDirectory(at: dat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dat, withDestinationURL: audio)
        let bytes = try Data(contentsOf: audio)
        let report = try delete(fixture)
        #expect(report.deleted.first?.written == true && report.deleted.first?.reason != nil)
        #expect(try Data(contentsOf: audio) == bytes)
        #expect(try dat.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test func manifest의_UUID_모양이_맞아도_다른_share에는_쓰지_않는다() throws {
        let (fixture, _) = try setup()
        let report = try delete(fixture)
        let backup = URL(filePath: try #require(report.backup))
        let outside = try #require(RekordboxShare.analysisURL(relative, root: fixture.root.appending(path: "outside")))
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: outside)
        let folder = backup.appending(path: "anlz")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([2]).write(to: folder.appending(path: "0.DAT"))
        try JSONEncoder().encode(["0.DAT": outside.path]).write(to: folder.appending(path: "manifest.json"))
        #expect(throws: DJCError.self) { try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups) }
        #expect(try Data(contentsOf: outside) == Data([1]))
    }
}
