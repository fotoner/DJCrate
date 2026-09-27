import DJCTestSupport
import Foundation
import Testing

@Suite("합성 DB 준비")
struct RekordboxFixtureTests {
    @Test func 연결은_묶음_안에서만_재사용하고_직접_열면_새로_연다() throws {
        let fixture = try RekordboxFixture()
        let count = try fixture.withConnection {
            try fixture.execute("CREATE TEMP TABLE connection_probe (value INTEGER)")
            try fixture.execute("INSERT INTO connection_probe VALUES (1)")
            let fresh = try fixture.open()
            defer { fresh.close() }
            #expect(try fresh.scalarInt("SELECT count(*) FROM sqlite_temp_master WHERE name = 'connection_probe'") == 0)
            return try fixture.withConnection { try fixture.rows("SELECT value FROM connection_probe").count }
        }
        #expect(count == 1)
        #expect(try fixture.rows("SELECT name FROM sqlite_temp_master WHERE name = 'connection_probe'").isEmpty)
    }

    @Test func 묶음이_실패해도_연결을_닫는다() throws {
        let fixture = try RekordboxFixture()
        #expect(throws: FixtureError.self) {
            try fixture.withConnection {
                try fixture.execute("CREATE TEMP TABLE connection_probe (value INTEGER)")
                throw FixtureError("합성 실패")
            }
        }
        try fixture.withConnection { () throws -> Void in
            #expect(try fixture.rows("SELECT name FROM sqlite_temp_master WHERE name = 'connection_probe'").isEmpty)
        }
    }

    @Test func 묶음_뒤_교체된_DB를_새로_읽는다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 1000)
        let replacement = try RekordboxFixture(localUpdateCount: 2000)
        #expect(try fixture.withConnection { try fixture.localUpdateCount() } == 1000)
        try FileManager.default.removeItem(at: fixture.database)
        try FileManager.default.copyItem(at: replacement.database, to: fixture.database)
        #expect(try fixture.withConnection { try fixture.localUpdateCount() } == 2000)
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test(arguments: [false, true]) func 곡_준비는_큐_삽입에_실패하면_함께_취소한다(reuse: Bool) throws {
        let fixture = try RekordboxFixture()
        let check = { () throws -> Void in
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
        if reuse { try fixture.withConnection(check) } else { try check() }
    }

    @Test(arguments: [false, true]) func 재생_목록_준비는_거울_행에_실패하면_함께_취소한다(reuse: Bool) throws {
        let fixture = try RekordboxFixture()
        let check = { () throws -> Void in
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
        if reuse { try fixture.withConnection(check) } else { try check() }
    }
}
