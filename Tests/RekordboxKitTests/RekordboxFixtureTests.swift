import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

@Suite("합성 DB 준비")
struct RekordboxFixtureTests {
    @Test func 곡_준비는_큐_삽입에_실패하면_함께_취소한다() throws {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(id: "1")
        let cue = CueSpec(id: "duplicate", inMsec: 1000)
        track.cues = [cue, cue]
        #expect(throws: (any Error).self) { try fixture.add(track) }
        #expect(try fixture.rows("SELECT ID FROM djmdContent").isEmpty)
        #expect(try fixture.rows("SELECT ID FROM djmdCue").isEmpty)

        track.cues = [cue]
        try fixture.add(track)
        #expect(try fixture.rows("SELECT ID FROM djmdCue").count == 1)
    }

    @Test func 재생_목록_준비는_거울_행에_실패하면_함께_취소한다() throws {
        let fixture = try RekordboxFixture()
        try fixture.execute("""
            CREATE TRIGGER reject_fixture_playlist BEFORE INSERT ON djmdCloudFilterPlaylist
            BEGIN SELECT RAISE(ABORT, '합성 실패'); END
            """)
        let playlist = PlaylistSpec(id: "1", name: "시험 목록", seq: 1, contentIDs: ["track-1"])
        #expect(throws: (any Error).self) { try fixture.add(playlist) }
        #expect(try fixture.rows("SELECT ID FROM djmdPlaylist").isEmpty)
        #expect(try fixture.rows("SELECT ID FROM djmdSongPlaylist").isEmpty)

        try fixture.execute("DROP TRIGGER reject_fixture_playlist")
        try fixture.add(playlist)
        #expect(try fixture.rows("SELECT ContentID FROM djmdSongPlaylist").first?["ContentID"] == "track-1")
    }

    // MARK: 템플릿 복사·픽스처 연결(#167 CI 시간)

    /// 구조만 있는 DB는 프로세스마다 한 번 만들어 복사하고, 픽스처가 행을 넣고 읽는 연결은 원시 키로 열어 키 유도를 건너뛴다.
    /// 제품 연결(문자열 키)로도 같은 파일을 읽어야 한다.
    @Test func 복사한_픽스처는_제품_연결로_열리고_서로_독립이다() throws {
        let first = try RekordboxFixture(), second = try RekordboxFixture(localUpdateCount: 7)
        let track = try first.add(TrackSpec())
        try first.add(PlaylistSpec(name: "목록", seq: 1, contentIDs: [track.id]))
        let db = try CipherDatabase(path: first.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        #expect(try db.scalarInt("SELECT count(*) FROM djmdContent") == 1)
        #expect(try db.scalarInt("SELECT count(*) FROM djmdSongPlaylist") == 1)
        #expect(try first.rows("SELECT ID FROM djmdContent").map { $0["ID"] } == [track.id])
        #expect(try second.rows("SELECT ID FROM djmdContent").isEmpty)
        #expect(try first.localUpdateCount() == 1000 && second.localUpdateCount() == 7)
        #expect(try first.rows("SELECT DBID, DBVersion FROM djmdProperty") == [["DBID": "1", "DBVersion": "6000"]])
        #expect(first.passphraseFallbacks == 0 && second.passphraseFallbacks == 0, "픽스처 연결은 원시 키로 열린다")
    }

    @Test func 제품이_쓴_뒤에도_픽스처_연결로_읽는다() throws {
        let fixture = try RekordboxFixture()
        let track = try fixture.add(TrackSpec())
        let report = try RekordboxWriter.write(drafts: [WriteGuardTests().draft(track)], to: fixture.database, dryRun: false,
                                               backups: fixture.backups)
        #expect(report.written.count == 1)
        #expect(try fixture.rows("SELECT ContentID FROM djmdCue").map { $0["ContentID"] } == [track.id])
        #expect(fixture.passphraseFallbacks == 0)
    }
}
