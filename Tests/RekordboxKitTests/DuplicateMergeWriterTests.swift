import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 큐·목록·삭제의 기존 골든 규칙을 한 트랜잭션으로 조합한다.
/// 목록: 2026-09-26~27 rekordbox 7.2.18, 합성 "DJC 실험곡 1~5"의 끝에 넣기·순서 바꾸기 규칙.
@Suite("중복 곡 합치기 쓰기")
struct DuplicateMergeWriterTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_MERGE_FIXTURE"] != nil))
    func 합성_화면_확인용_사본() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_MERGE_FIXTURE"] else { return }
        let fixture = try fixture()
        let root = URL(filePath: path)
        try fixture.insert("djmdArtist", ["ID": .text("1"), "Name": .text("합성 아티스트"), "UUID": .text("artist-1"), "rb_local_deleted": .int(0)])
        let db = try fixture.open()
        try db.run("UPDATE djmdContent SET ArtistID = '1', Title = '합성 중복 곡' WHERE ID IN ('100', '200')", [])
        for id in ["100", "200", "300"] {
            try db.run("UPDATE djmdContent SET FolderPath = ? WHERE ID = ?", [.text(root.appending(path: "audio/\(id).wav").path), .text(id)])
        }
        db.close()
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }

    /// 곡 셋은 모두 동기화 상태 0이다(곡 빼기·합치기 규칙은 상태 0 곡으로만 확인했다, #196). `statuses`로 곡마다 바꾼다.
    func fixture(statuses: [String: Int] = [:]) throws -> RekordboxFixture {
        let fixture = try RekordboxFixture()
        for id in ["100", "200", "300"] {
            var track = TrackSpec(id: id, uuid: "u" + id)
            track.dataStatus = statuses[id] ?? 0
            track.fileType = 11; track.length = 30
            track.folderPath = try AudioFixture.wav(seconds: 30, in: fixture.audio, name: id + ".wav").path
            if id == "200" { track.cues = [CueSpec(kind: 0, inMsec: 1250), CueSpec(kind: 1, inMsec: 5000)] }
            try fixture.add(track)
        }
        var playlist = PlaylistSpec(id: "500", name: "합성 목록", seq: 1)
        playlist.contentIDs = ["300", "200", "300"]
        try fixture.add(playlist)
        return fixture
    }

    func draft(_ fixture: RekordboxFixture) throws -> DuplicateMergeDraft {
        try RekordboxWriter.prepareMerge(keeping: "100", removing: ["200"], snapshot: fixture.database)
    }

    func write(_ fixture: RekordboxFixture, _ draft: DuplicateMergeDraft, dryRun: Bool = false) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: [], merges: [draft], to: fixture.database, dryRun: dryRun,
                                 backups: fixture.backups, shareRoot: fixture.shareRoot)
    }

    @Test func 큐_목록_삭제를_함께_쓰고_백업으로_모두_되돌린다() throws {
        let fixture = try fixture()
        let tables = ["djmdContent", "djmdCue", "contentCue", "djmdSongPlaylist"]
        let before = try tables.map { try fixture.rows("SELECT * FROM \($0) ORDER BY ID") }
        let merge = try draft(fixture)
        let report = try write(fixture, merge)
        #expect(report.mergeWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdContent ORDER BY ID").map { $0["ID"] } == ["100", "300"])
        #expect(try fixture.rows("SELECT ContentID FROM djmdSongPlaylist ORDER BY TrackNo").map { $0["ContentID"] } == ["300", "100", "300"])
        #expect(try fixture.rows("SELECT Kind, InMsec FROM djmdCue WHERE ContentID = '100' ORDER BY InMsec") ==
                [["Kind": "0", "InMsec": "1250"], ["Kind": "1", "InMsec": "5000"]])
        let backup = URL(filePath: try #require(report.backup))
        #expect(RekordboxWriter.mergeDrafts(in: backup) == [merge])
        _ = try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups)
        #expect(try tables.map { try fixture.rows("SELECT * FROM \($0) ORDER BY ID") } == before)
    }

    @Test func 시험실행과_삭제차단은_큐도_목록도_그대로_둔다() throws {
        let fixture = try fixture()
        let merge = try draft(fixture)
        let before = try fixture.rows("SELECT * FROM djmdCue ORDER BY ID")
        #expect(try write(fixture, merge, dryRun: true).mergeWritten.count == 1)
        #expect(try fixture.rows("SELECT * FROM djmdCue ORDER BY ID") == before)
        try fixture.insert("djmdSongMyTag", ["ID": .text("1"), "MyTagID": .text("1"), "ContentID": .text("200")])
        let report = try write(fixture, merge)
        #expect(report.mergeBlocked.count == 1)
        #expect(report.backup == nil)
        #expect(report.mergeBlocked[0].reason?.contains("djmdSongMyTag") == true)
        #expect(try fixture.rows("SELECT * FROM djmdCue ORDER BY ID") == before)
        #expect(try fixture.rows("SELECT ContentID FROM djmdSongPlaylist ORDER BY TrackNo").map { $0["ContentID"] } == ["300", "200", "300"])
    }

    @Test func 초안뒤_큐나_재생목록이_바뀌면_묶음전체를_막는다() throws {
        for sql in ["UPDATE djmdCue SET InMsec = 1500 WHERE ContentID = '200'", "UPDATE djmdSongPlaylist SET ContentID = '100' WHERE TrackNo = 1"] {
            let fixture = try fixture()
            let merge = try draft(fixture)
            let db = try fixture.open()
            try db.execute(sql); db.close()
            let report = try write(fixture, merge)
            #expect(report.mergeBlocked.count == 1)
            #expect(try fixture.rows("SELECT ID FROM djmdContent").count == 3)
        }
    }

    @Test func 삭제중_실패하면_앞서쓴_큐와_목록도_롤백한다() throws {
        let fixture = try fixture()
        let merge = try draft(fixture)
        let before = try fixture.rows("SELECT * FROM djmdSongPlaylist ORDER BY ID")
        let db = try fixture.open()
        try db.execute("CREATE TRIGGER stop_merge BEFORE DELETE ON djmdContent BEGIN SELECT RAISE(ABORT, 'merge test'); END")
        db.close()
        #expect(throws: (any Error).self) { try write(fixture, merge) }
        #expect(try fixture.rows("SELECT * FROM djmdSongPlaylist ORDER BY ID") == before)
        #expect(try fixture.rows("SELECT ID FROM djmdCue WHERE ContentID = '100'").isEmpty)
        #expect(try fixture.localUpdateCount() == 1000)
    }

    @Test func 분석파일도_함께_백업하고_삭제와_복원을_검증한다() throws {
        let fixture = try fixture()
        let path = "/PIONEER/USBANLZ/u20/0/ANLZ0000.DAT"
        let dat = try #require(RekordboxShare.analysisURL(path, root: fixture.shareRoot))
        try FileManager.default.createDirectory(at: dat.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("합성 분석 파일".utf8)
        try bytes.write(to: dat)
        let db = try fixture.open()
        try db.run("UPDATE djmdContent SET AnalysisDataPath = ? WHERE ID = '200'", [.text(path)])
        db.close()
        let report = try write(fixture, draft(fixture))
        #expect(report.mergeWritten.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dat.path))
        _ = try RekordboxWriter.restore(URL(filePath: try #require(report.backup)), to: fixture.database, backups: fixture.backups)
        #expect(try Data(contentsOf: dat) == bytes)
    }

    @Test func 다른곡과_공유한_분석폴더는_남기고_DB만_합친다() throws {
        let fixture = try fixture()
        let path = "/PIONEER/USBANLZ/u20/0/ANLZ0000.DAT"
        let db = try fixture.open()
        try db.run("UPDATE djmdContent SET AnalysisDataPath = ? WHERE ID IN ('100', '200')", [.text(path)])
        db.close()
        let report = try write(fixture, draft(fixture))
        #expect(report.mergeWritten.count == 1 && report.mergeWritten.first?.reason != nil)
        #expect(try fixture.rows("SELECT ID FROM djmdContent").count == 2)
        #expect(try fixture.rows("SELECT ID FROM djmdCue WHERE ContentID = '100'").count == 2)
    }

    @Test func 같은곡_다른초안이나_목록초안과_겹치면_합치기는_막는다() throws {
        let fixture = try fixture()
        let merge = try draft(fixture)
        var cue = CueDraft(trackUUID: "u100")
        cue.place(.init(kind: .memory, time: 2))
        let report = try RekordboxWriter.write(drafts: [cue], merges: [merge], to: fixture.database, dryRun: false, backups: fixture.backups)
        #expect(report.mergeBlocked.count == 1 && report.written.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdContent").count == 3)
    }

    @Test func 별개_태그가_사전검사에서_막혀도_합치기는_반영한다() throws {
        let fixture = try fixture()
        let merge = try draft(fixture)
        let db = try fixture.open()
        let base = try #require(try RekordboxWriter.currentTags(db: db, contentID: "300"))
        db.close()
        var tag = TagDraft(trackUUID: "u300", base: base)
        tag.fields.title = "태그 초안"
        try fixture.execute("UPDATE djmdContent SET Title = '바뀐 제목' WHERE ID = '300'")
        let report = try RekordboxWriter.write(drafts: [], tags: [tag], merges: [merge], to: fixture.database,
                                              dryRun: false, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.tagBlocked.count == 1)
        #expect(report.mergeWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdContent").count == 2)
    }

    @Test func 음원이_바뀌거나_없어지면_삭제하지_않는다() throws {
        let fixture = try fixture()
        let merge = try draft(fixture)
        let wav = fixture.audio.appending(path: "200.wav")
        let handle = try FileHandle(forWritingTo: wav)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        #expect(try write(fixture, merge).mergeBlocked.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdContent").count == 3)
    }

    @Test func rekordbox_실행중과_오래된_구조는_백업전에_막는다() throws {
        let fixture = try fixture()
        let merge = try draft(fixture)
        let guardRunning = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        #expect(throws: DJCError.self) {
            try RekordboxWriter.write(drafts: [], merges: [merge], to: fixture.database, dryRun: false, backups: fixture.backups, guard: guardRunning)
        }
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty)
    }

    @Test func 같은_목록의_서로다른_중복묶음을_한번에_합친다() throws {
        let fixture = try fixture()
        var track = TrackSpec(id: "400", uuid: "u400")
        track.dataStatus = 0
        track.fileType = 11; track.length = 30
        track.folderPath = try AudioFixture.wav(seconds: 30, in: fixture.audio, name: "400.wav").path
        try fixture.add(track)
        let a = try draft(fixture)
        let b = try RekordboxWriter.prepareMerge(keeping: "400", removing: ["300"], snapshot: fixture.database)
        let report = try RekordboxWriter.write(drafts: [], merges: [a, b], to: fixture.database, dryRun: false, backups: fixture.backups)
        #expect(report.mergeWritten.count == 2)
        #expect(try fixture.rows("SELECT ContentID FROM djmdSongPlaylist ORDER BY TrackNo").map { $0["ContentID"] } == ["400", "100"])
    }

    @Test func 분석경로가_음원폴더를_가리켜도_음원은_지우지_않는다() throws {
        let fixture = try fixture()
        let folder = fixture.shareRoot.appending(path: "audio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = try AudioFixture.wav(seconds: 30, in: folder, name: "source.wav")
        let before = try Data(contentsOf: wav)
        let db = try fixture.open()
        try db.run("UPDATE djmdContent SET AnalysisDataPath = '/audio/ANLZ0000.DAT', FolderPath = ? WHERE ID = '200'", [.text(wav.path)])
        db.close()
        let report = try write(fixture, draft(fixture))
        #expect(report.mergeWritten.count == 1 && report.mergeWritten.first?.reason != nil)
        #expect(FileManager.default.fileExists(atPath: wav.path))
        if FileManager.default.fileExists(atPath: wav.path) { #expect(try Data(contentsOf: wav) == before) }
    }
}
