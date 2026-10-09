import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 동기화 상태(256·257)인 곡의 곡 정보 쓰기.
/// - #171(2026-10-01 rekordbox 7.2.18, 실험 곡 "カクシタワタシ", 곡·앨범 상태 256): 코멘트만 바꿔 저장하고 종료한 전후 사본과,
///   같은 곡의 코멘트를 한 번 더 저장한 사본을 칸 단위로 비교했다.
///   첫 저장은 `Commnt`·`TrackInfoUpdated`(+1, 글자)·`rb_data_status` 256 → 257·`rb_local_usn`·`updated_at`만 바뀌었고,
///   클라우드 `usn`·`rb_local_synced`·`rb_local_data_status`와 앨범 행(상태 256)은 그대로였다. 다시 저장하면 상태 257 그대로, +1.
/// - #173(2026-10-04 세션 S1·S2·S3): 정보 패널의 아홉 칸 모두 상태 0과 같은 곡 행 칸에 256 → 257을 더한 모양이다(코멘트 비우기 포함).
/// 0·256·257이 아닌 곡 상태는 막는다.
extension RekordboxTagWriterTests {
    /// 실험 곡과 같은 상태: 곡·앨범 256, `TrackInfoUpdated` '2', 빈 코멘트(''), 클라우드에서 받은 곡이라 `usn`이 있다.
    func syncedLibrary(state: Int = 256, shared: Bool = true) throws -> (RekordboxFixture, TrackSpec) {
        let (fixture, track) = try library(shared: shared)
        try fixture.execute("""
            UPDATE djmdContent SET rb_data_status = ?, TrackInfoUpdated = '2', usn = 363, rb_local_synced = 0, rb_local_data_status = 0
            WHERE ID = '500'
            """, [.int(state)])
        try fixture.execute("UPDATE djmdAlbum SET rb_data_status = 256 WHERE ID = '31'")
        return (fixture, track)
    }

    func changedColumns(_ before: [String: String], _ after: [String: String]) -> Set<String> {
        Set(after.keys.filter { after[$0] != before[$0] })
    }

    // MARK: 골든(#173 2026-10-04 S1·S2)

    @Test(arguments: infoPanelKeys)
    func 동기화된_곡의_칸마다_rekordbox_7이_저장한_모양으로_쓴다(key: TagFields.Key) throws {
        // #173 S1 T01 제목, T02 아티스트 새 이름, T04 앨범 새 이름, T06 장르 새 이름, T08 작곡가 넣기, T09 연도, T10 트랙 번호,
        // T16 코멘트, S2 U01 앨범 아티스트: 곡 행은 그 칸·`TrackInfoUpdated`(+1, 글자)·256 → 257·번호·시각만 바뀐다.
        let (fixture, track) = try syncedLibrary(shared: false)
        for (table, id) in [("djmdArtist", "11"), ("djmdGenre", "21"), ("djmdAlbum", "31")] { try sync(fixture, table, id) }
        let values: [TagFields.Key: String] = [.title: "옛 제목DJC", .artist: "DJC 173 아티스트", .album: "DJC 173 앨범",
                                               .albumArtist: "DJC 173 앨범 아티스트", .genre: "DJC 173 장르", .composer: "DJC 173 작곡가",
                                               .year: "2020", .trackNumber: "99", .comment: "DJC 173 코멘트"]
        let columns: [TagFields.Key: String] = [.title: "Title", .artist: "ArtistID", .album: "AlbumID", .genre: "GenreID",
                                                .composer: "ComposerID", .year: "ReleaseYear", .trackNumber: "TrackNo", .comment: "Commnt"]
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0[key] = values[key] ?? "" }], keys: RekordboxWriter.writableTagKeys)
        #expect(report.tagWritten.first?.fields == [key.rawValue] && report.tagBlocked.isEmpty)
        let after = try content(fixture)
        #expect(changedColumns(before, after) == Set(["TrackInfoUpdated", "rb_data_status", "rb_local_usn", "updated_at"] + [columns[key]].compactMap { $0 }))
        #expect(after["TrackInfoUpdated"] == "3" && after["rb_data_status"] == "257")
        #expect(after["usn"] == "363" && after["rb_local_synced"] == "0" && after["rb_local_data_status"] == "0")
        #expect(try Int(after["rb_local_usn"] ?? "") == fixture.localUpdateCount(), "곡 행이 마지막 번호")
        let db = try fixture.open()
        defer { db.close() }
        #expect(try RekordboxWriter.currentTags(db: db, contentID: track.id)?[key] == values[key])
    }

    @Test(arguments: [256, 257]) func 동기화된_곡의_코멘트를_비우면_빈_글자다(state: Int) throws {
        // #173 S1 T16: 코멘트 지우기 → `Commnt` ''(NULL 아님), +1, 256 → 257.
        let (fixture, track) = try syncedLibrary(state: state)
        try fixture.execute("UPDATE djmdContent SET Commnt = '옛 코멘트' WHERE ID = '500'")
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.comment = "" }], keys: RekordboxWriter.writableTagKeys)
        #expect(report.tagWritten.count == 1)
        let after = try content(fixture)
        #expect(changedColumns(before, after).isSubset(of: ["Commnt", "TrackInfoUpdated", "rb_data_status", "rb_local_usn", "updated_at"]))
        #expect(try fixture.rows("SELECT quote(Commnt) AS c FROM djmdContent WHERE ID = '500'").first?["c"] == "''")
        #expect(after["rb_data_status"] == "257" && after["TrackInfoUpdated"] == "3")
    }

    // MARK: 골든(2026-10-01 カクシタワタシ)

    @Test func 동기화된_곡의_코멘트는_rekordbox_7이_저장한_모양과_같다() throws {
        let (fixture, track) = try syncedLibrary()
        let album = try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'")
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.comment = "DJC 코멘트" }], keys: RekordboxWriter.writableTagKeys)
        #expect(report.tagWritten.first?.fields == ["comment"] && report.tagBlocked.isEmpty)

        // 첫 저장: 256 → 257, 곡 정보 변경 횟수 '2' → '3'(글자), 번호·시각. 나머지 칸과 앨범 행은 그대로.
        let after = try content(fixture)
        #expect(changedColumns(before, after) == ["Commnt", "TrackInfoUpdated", "rb_data_status", "rb_local_usn", "updated_at"])
        #expect(after["Commnt"] == "DJC 코멘트" && after["TrackInfoUpdated"] == "3" && after["rb_data_status"] == "257")
        #expect(after["usn"] == "363" && after["rb_local_synced"] == "0" && after["rb_local_data_status"] == "0" && after["updated_at"] == stamp)
        #expect(try fixture.rows("SELECT typeof(TrackInfoUpdated) AS t FROM djmdContent WHERE ID = '500'").first?["t"] == "text")
        #expect(try Int(after["rb_local_usn"] ?? "") == fixture.localUpdateCount() && fixture.localUpdateCount() == 2001)
        #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'") == album, "앨범 행은 그대로")

        // 다시 저장: 257 그대로, '3' → '4'
        let again = try write(fixture, tags: [try draft(fixture, track) { $0.comment = "DJC 다시" }], keys: RekordboxWriter.writableTagKeys)
        #expect(again.tagWritten.count == 1)
        let repeated = try content(fixture)
        #expect(changedColumns(after, repeated) == ["Commnt", "TrackInfoUpdated", "rb_local_usn"], "같은 시각이라 updated_at은 같은 값")
        #expect(repeated["TrackInfoUpdated"] == "4" && repeated["rb_data_status"] == "257")
        #expect(try Int(repeated["rb_local_usn"] ?? "") == fixture.localUpdateCount() && fixture.localUpdateCount() == 2002)
        #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'") == album)
    }

    @Test func 상태가_257인_곡의_코멘트도_쓰고_상태는_그대로다() throws {
        let (fixture, track) = try syncedLibrary(state: 257)
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.comment = "DJC 코멘트" }], keys: RekordboxWriter.writableTagKeys)
        #expect(report.tagWritten.count == 1)
        let after = try content(fixture)
        #expect(changedColumns(before, after) == ["Commnt", "TrackInfoUpdated", "rb_local_usn", "updated_at"])
        #expect(after["rb_data_status"] == "257" && after["TrackInfoUpdated"] == "3")
    }

    // MARK: 막기

    @Test(arguments: [1, 2, 258, 512]) func 확인하지_않은_동기화_상태는_막는다(state: Int) throws {
        let (fixture, track) = try syncedLibrary(state: state)
        let before = try content(fixture)
        for edit in [{ (f: inout TagFields) in f.comment = "새 코멘트" }, { (f: inout TagFields) in f.title = "새 제목" }] {
            let report = try write(fixture, tags: [try draft(fixture, track, edit)])
            #expect(report.tagWritten.isEmpty && report.tagBlocked.first?.reason?.contains("동기화 상태") == true && report.backup == nil)
        }
        #expect(try content(fixture) == before && fixture.localUpdateCount() == 2000)
    }

    @Test func 동기화된_곡에_큐와_코멘트를_함께_써도_상태는_257이고_곡_행이_마지막_번호다() throws {
        // 큐가 먼저 256 → 257로 올려도 트랜잭션 안의 태그 확인은 257로 통과한다.
        let (fixture, _) = try library()
        var track = TrackSpec(id: "600", uuid: "track-uuid-600")
        track.cues = [.autoCue(at: 1024)]
        try fixture.add(track)
        try fixture.execute("UPDATE djmdContent SET Commnt = '' WHERE ID = '600'")
        var cues = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        cues.place(EditableCue(kind: .memory, time: 20.123))
        let tags = try draft(fixture, track) { $0.comment = "큐와 코멘트" }
        let report = try write(fixture, tags: [tags], drafts: [cues], keys: RekordboxWriter.writableTagKeys)
        #expect(report.written.count == 1 && report.tagWritten.count == 1)
        let row = try content(fixture, "600")
        #expect(row["Commnt"] == "큐와 코멘트" && row["rb_data_status"] == "257" && row["TrackInfoUpdated"] == "2")
        #expect(try Int(row["rb_local_usn"] ?? "") == fixture.localUpdateCount(), "곡 행이 마지막 번호")
    }
}

/// #173 동기화 상태 곡·이름 행의 곡 정보 쓰기(2026-10-04 rekordbox 7.2.18, 세션 S1~S4, 실험 곡은 역할 이름).
/// 이름·앨범 행은 자기 상태로 정해진다: 저장되면 256 → 257, 버려지면 0은 지우고 256·257 앨범은 258·`rb_local_deleted` 1(네 칸만).
/// 동기화 행이 버려졌는지는 살아 있는 곡의 참조로만 센다(S2 U04 앨범, S4 E1 아티스트·E2 장르). 아티스트의 앨범 아티스트 참조는 지운 앨범까지 센다.
extension RekordboxTagWriterTests {
    /// 이름·앨범 행을 클라우드에서 받은 모양으로(상태·`usn`·`rb_local_synced` 1)
    func sync(_ fixture: RekordboxFixture, _ table: String, _ id: String, state: Int = 256) throws {
        try fixture.session { try sync($0, table, id, state: state) }
    }

    /// 한 연결(`RekordboxFixture.session`)에서 여러 행을 동기화 모양으로 만들 때
    func sync(_ session: RekordboxFixture.Session, _ table: String, _ id: String, state: Int = 256) throws {
        try session.execute("UPDATE \(table) SET rb_data_status = ?, usn = 40, rb_local_synced = 1 WHERE ID = ?", [.int(state), .text(id)])
    }

    func row(_ fixture: RekordboxFixture, _ table: String, _ id: String) throws -> [String: String]? {
        try fixture.rows("SELECT * FROM \(table) WHERE ID = ?", [.text(id)]).first
    }

    // MARK: 1. 참조 범위: 동기화 행은 살아 있는 곡만

    @Test func 동기화_아티스트·장르는_지운_곡이_가리켜도_258이다() throws {
        // #173 S4 E1·E2(2026-10-04): 살아 있는 곡은 이 곡 하나뿐이고 지운 곡(262)이 `ArtistID`·`GenreID`로 가리키던 동기화 아티스트·장르도 258이
        // 됐다(네 칸). 지운 곡 행은 그대로이고 258 행을 계속 가리킨다. 앨범(S2 U04)과 같이 동기화 행은 살아 있는 곡 참조만 센다.
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1, rb_data_status = 262 WHERE ID = '501'")
        try sync(fixture, "djmdArtist", "11")
        try sync(fixture, "djmdGenre", "21")
        let artist = try #require(try row(fixture, "djmdArtist", "11")), genre = try #require(try row(fixture, "djmdGenre", "21"))
        let deletedSong = try content(fixture, "501")
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 아티스트"; $0.genre = "DJC 173 장르" }])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        for (before, table, id) in [(artist, "djmdArtist", "11"), (genre, "djmdGenre", "21")] {
            let after = try #require(try row(fixture, table, id))
            #expect(Set(after.keys.filter { after[$0] != before[$0] }) == ["rb_data_status", "rb_local_deleted", "rb_local_usn", "updated_at"], "\(table)")
            #expect(after["rb_data_status"] == "258" && after["rb_local_deleted"] == "1" && after["usn"] == "40", "\(table)")
        }
        #expect(try content(fixture, "501") == deletedSong, "지운 곡 행은 그대로(11·21을 계속 가리킨다)")
    }

    @Test func 지운_곡만_가리키는_257_아티스트·장르는_버려진_것으로_보고_막는다() throws {
        // 살아 있는 곡만 세면 지운 곡만 가리키는 257 아티스트·장르도 버려진다. 257 아티스트·장르를 버리는 규칙은 확인하지 못해 그 초안만 막는다.
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1, rb_data_status = 262 WHERE ID = '501'")
        for (table, edit) in [("djmdArtist", { (f: inout TagFields) in f.artist = "DJC 173 아티스트" }),
                              ("djmdGenre", { (f: inout TagFields) in f.genre = "DJC 173 장르" })] {
            try sync(fixture, table, table == "djmdArtist" ? "11" : "21", state: 257)
            let before = try content(fixture)
            let report = try write(fixture, tags: [try draft(fixture, track, edit)])
            #expect(report.tagWritten.isEmpty && report.tagBlocked.first?.reason?.contains("동기화 아티스트·장르") == true, "\(table)")
            #expect(try content(fixture) == before && fixture.localUpdateCount() == 2000, "\(table)")
        }
    }

    @Test func 지운_앨범의_앨범_아티스트_칸이_가리키는_동기화_아티스트는_남긴다() throws {
        // 지운(258·262) 앨범의 앨범 아티스트 칸만 남은 동기화 아티스트가 버려지는지는 보지 못했다[미확인]. 쓰지 않는 쪽으로, 앨범 아티스트 참조는
        // 지운 앨범까지 세어 남긴다(지운 곡의 참조는 세지 않는다).
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1, rb_data_status = 262 WHERE ID = '501'")
        try fixture.insert("djmdAlbum", ["ID": .text("33"), "Name": .text("DJC 173 지운 앨범"), "AlbumArtistID": .text("11"), "UUID": .text("al-33"),
                                         "rb_local_deleted": .int(1), "rb_data_status": .int(262)])
        try sync(fixture, "djmdArtist", "11")
        let artist = try row(fixture, "djmdArtist", "11")
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 아티스트" }]).tagWritten.count == 1)
        #expect(try row(fixture, "djmdArtist", "11") == artist, "상태·번호 그대로")
    }

    @Test(arguments: [0, 256]) func 지운_곡이_함께_쓰는_앨범의_앨범_아티스트는_동기화_앨범만_제자리에서_고친다(state: Int) throws {
        // #173 S2 U01·U14: 살아 있는 곡 하나와 지운 곡 하나가 쓰는 동기화 앨범의 앨범 아티스트를 rekordbox는 제자리에서 넣고 비웠다.
        // 상태 0 앨범은 예전처럼 지운 곡까지 세어 여러 곡이 쓰는 앨범으로 보고 막는다(상태 0의 근거는 없다).
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1, rb_data_status = 262, ArtistID = '' WHERE ID = '501'")
        try sync(fixture, "djmdAlbum", "31", state: state)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.albumArtist = "DJC 173 앨범 아티스트" }])
        if state == 0 {
            #expect(report.tagWritten.isEmpty && report.backup == nil && report.tagBlocked.first?.reason?.contains("여러 곡") == true)
        } else {
            #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
            let artist = try #require(fixture.rows("SELECT ID FROM djmdArtist WHERE Name = 'DJC 173 앨범 아티스트'").first?["ID"])
            #expect(try row(fixture, "djmdAlbum", "31")?["AlbumArtistID"] == artist && content(fixture)["AlbumID"] == "31")
        }
    }

    @Test func 상태_0인_이름_행은_지운_곡이_가리키면_남긴다() throws {
        // 상태 0 행은 예전처럼 지운 곡까지 센다. 지운 곡이 가리키면 지우지 않아 외래 키가 끊기지 않는다(2026-09-27 규칙).
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1, rb_data_status = 262 WHERE ID = '501'")
        let artist = try row(fixture, "djmdArtist", "11")
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 아티스트" }])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        #expect(try row(fixture, "djmdArtist", "11") == artist, "상태·번호 그대로")
        #expect(try content(fixture, "501")["ArtistID"] == "11")
    }

    @Test(arguments: [0, 256]) func 표시한_동기화_앨범이_가리키는_앨범_아티스트는_남긴다(state: Int) throws {
        // 앨범과 아티스트를 함께 비우면 이 곡만 쓰던 동기화 앨범은 258(삭제 표시)이고 그 앨범 아티스트 칸은 그대로 남는다(S2 U04).
        // 옛 아티스트가 그 앨범의 앨범 아티스트이면 258 앨범도 참조로 센다: 상태 0·동기화 아티스트 모두 그대로 둔다.
        let (fixture, track) = try library(shared: false)
        try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'")
        try sync(fixture, "djmdAlbum", "31")
        try sync(fixture, "djmdArtist", "11", state: state)
        let before = try row(fixture, "djmdArtist", "11")
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 아티스트"; $0.album = "" }])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        #expect(try row(fixture, "djmdAlbum", "31")?["rb_data_status"] == "258")
        #expect(try row(fixture, "djmdArtist", "11") == before)
    }

    // MARK: 2. 버려진 행은 상태대로

    @Test func 동기화된_이름_행이_버려지면_258로_표시하고_4칸만_바꾼다() throws {
        // #173 S1 T02(아티스트 새 이름: 새 행 → 빈 → 앨범 → 옛 아티스트 258 → 곡), S2 U05(장르 비우기 258), U06(작곡가 비우기 258).
        // 258 행은 `rb_data_status`·`rb_local_deleted`·`rb_local_usn`·`updated_at`만 바뀌고 `usn`·`rb_local_synced`는 그대로다.
        let (fixture, track) = try library(shared: false)
        try fixture.insert("djmdArtist", ["ID": .text("14"), "Name": .text("옛 작곡가"), "UUID": .text("a-14"), "rb_local_usn": .int(9)])
        try fixture.execute("UPDATE djmdContent SET ComposerID = '14' WHERE ID = '500'")
        for (table, id) in [("djmdArtist", "11"), ("djmdArtist", "14"), ("djmdGenre", "21")] { try sync(fixture, table, id) }
        let artist = try #require(try row(fixture, "djmdArtist", "11"))
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 아티스트" }])
        #expect(report.tagWritten.count == 1)
        let marked = try #require(try row(fixture, "djmdArtist", "11"))
        #expect(Set(marked.keys.filter { marked[$0] != artist[$0] }) == ["rb_data_status", "rb_local_deleted", "rb_local_usn", "updated_at"])
        #expect(marked["rb_data_status"] == "258" && marked["rb_local_deleted"] == "1" && marked["updated_at"] == stamp)
        #expect(marked["usn"] == "40" && marked["rb_local_synced"] == "1")
        // 번호 순서: 새 아티스트 → 앨범 행 → 옛 아티스트(258) → 곡 행(마지막)
        let fresh = try #require(fixture.rows("SELECT rb_local_usn FROM djmdArtist WHERE Name = 'DJC 173 아티스트'").first?["rb_local_usn"])
        let album = try #require(try row(fixture, "djmdAlbum", "31")?["rb_local_usn"])
        let numbers = try [fresh, album, try #require(marked["rb_local_usn"]), try #require(content(fixture)["rb_local_usn"])].map { Int($0) ?? 0 }
        #expect(numbers == numbers.sorted() && Set(numbers).count == 4)
        #expect(try numbers.last == fixture.localUpdateCount())
        #expect(try content(fixture)["TrackInfoUpdated"] == "4", "저장 한 번")

        // 장르·작곡가 비우기도 같은 쓰기에서 258(rekordbox는 작곡가 행을 다음 아티스트 저장 때 표시했다. 최종 상태는 같다)
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.genre = ""; $0.composer = "" }]).tagWritten.count == 1)
        let last = try Int(content(fixture)["rb_local_usn"] ?? "") ?? 0
        for (table, id) in [("djmdGenre", "21"), ("djmdArtist", "14")] {
            let row = try #require(try row(fixture, table, id))
            #expect(row["rb_data_status"] == "258" && row["rb_local_deleted"] == "1" && row["usn"] == "40", "\(table)")
            #expect((Int(row["rb_local_usn"] ?? "") ?? 0) < last)
        }
        #expect(try last == fixture.localUpdateCount())
    }

    @Test func 상태_0인_이름_행이_버려지면_지운다() throws {
        // 2026-09-27 실험 2(상태 0)와 같다: 아무 곡도 안 쓰는 옛 행은 실제로 지우고 번호를 쓰지 않는다.
        let (fixture, track) = try library(shared: false)
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 아티스트" }]).tagWritten.count == 1)
        #expect(try row(fixture, "djmdArtist", "11") == nil)
        #expect(try content(fixture)["rb_local_usn"] == "2003" && fixture.localUpdateCount() == 2003)
    }

    @Test(arguments: [257, 2, 262]) func 버려질_이름_행이_258로_표시할_수_없는_상태면_그_초안만_막는다(state: Int) throws {
        // 257 아티스트가 버려질 때는 확인하지 못했다(257 앨범만 S4 B2). 그 밖의 상태도 막는다. 버려졌는지는 트랜잭션 안에서 실제로 쓴 뒤
        // 세므로, 그 초안만 SAVEPOINT로 되돌리고(번호도) 막힘으로 보고한다.
        let (fixture, track) = try library(shared: false)
        try sync(fixture, "djmdArtist", "11", state: state)
        let before = try content(fixture), artists = try fixture.rows("SELECT * FROM djmdArtist ORDER BY ID")
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 아티스트" }])
        #expect(report.tagWritten.isEmpty)
        #expect(try fixture.rows("SELECT * FROM djmdArtist ORDER BY ID") == artists, "새 아티스트 행도 되돌린다")
        #expect(report.tagBlocked.first?.reason?.contains("rekordbox에서 직접") == true)
        #expect(try content(fixture) == before && fixture.localUpdateCount() == 2000)
    }

    // MARK: 3·4. 저장되는 앨범 행은 256 → 257, 257은 그대로

    @Test(arguments: [0, 256, 257]) func 아티스트를_고치면_동기화_앨범은_257이고_257_앨범은_그대로다(state: Int) throws {
        // #173 S1 T02·T05(AA NULL → '', 256 → 257), X1·S2 U07(상태 0 곡 + 동기화 앨범도 257), S3 V03(257 앨범은 번호·시각만).
        let (fixture, track) = try library()
        try sync(fixture, "djmdAlbum", "31", state: state)
        let before = try #require(try row(fixture, "djmdAlbum", "31"))
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 아티스트" }]).tagWritten.count == 1)
        let after = try #require(try row(fixture, "djmdAlbum", "31"))
        let expected: Set<String> = state == 256 ? ["AlbumArtistID", "rb_data_status", "rb_local_usn", "updated_at"]
            : ["AlbumArtistID", "rb_local_usn", "updated_at"]
        #expect(Set(after.keys.filter { after[$0] != before[$0] }) == expected)
        #expect(after["rb_data_status"] == String(state == 256 ? 257 : state) && after["AlbumArtistID"] == "")
        #expect(after["usn"] == "40" && after["rb_local_synced"] == "1")
        #expect(try content(fixture)["rb_data_status"] == "0", "상태 0 곡은 그대로")
    }

    @Test func 동기화된_기존_앨범에_붙이면_대상은_257_옛_앨범은_258이다() throws {
        // #173 S2 U02: 대상(이름 유일, AA '', 256)은 상태·번호·시각만, 이 곡만 쓰던 옛 앨범은 258.
        let (fixture, track) = try library(shared: false)
        try sync(fixture, "djmdAlbum", "31")
        try fixture.insert("djmdAlbum", ["ID": .text("32"), "Name": .text("DJC 173 있는 앨범"), "AlbumArtistID": .text(""),
                                         "rb_local_usn": .int(8)])
        try sync(fixture, "djmdAlbum", "32")
        let target = try #require(try row(fixture, "djmdAlbum", "32"))
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.album = "DJC 173 있는 앨범" }]).tagWritten.count == 1)
        let saved = try #require(try row(fixture, "djmdAlbum", "32"))
        #expect(Set(saved.keys.filter { saved[$0] != target[$0] }) == ["rb_data_status", "rb_local_usn", "updated_at"])
        #expect(saved["rb_data_status"] == "257")
        let old = try #require(try row(fixture, "djmdAlbum", "31"))
        #expect(old["rb_data_status"] == "258" && old["rb_local_deleted"] == "1" && old["usn"] == "40")
        // 번호: 대상 앨범 → 옛 앨범(258) → 곡
        let numbers = try [saved["rb_local_usn"], old["rb_local_usn"], content(fixture)["rb_local_usn"]].map { Int($0 ?? "") ?? 0 }
        #expect(try numbers == numbers.sorted() && numbers.last == fixture.localUpdateCount())
        #expect(try content(fixture)["AlbumID"] == "32" && content(fixture)["TrackInfoUpdated"] == "4")
    }

    @Test func 동기화된_앨범의_새_이름은_새_앨범이고_옛_앨범은_258이다() throws {
        // #173 S1 T04: 새 앨범(앨범 아티스트 이어받음, 상태 0), 옛 앨범 258.
        let (fixture, track) = try library(shared: false)
        try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'")
        try sync(fixture, "djmdAlbum", "31")
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.album = "DJC 173 앨범" }]).tagWritten.count == 1)
        let fresh = try #require(fixture.rows("SELECT * FROM djmdAlbum WHERE Name = 'DJC 173 앨범'").first)
        #expect(fresh["AlbumArtistID"] == "11" && fresh["rb_data_status"] == "0" && fresh["usn"] == "NULL")
        #expect(try row(fixture, "djmdAlbum", "31")?["rb_data_status"] == "258")
        #expect(try row(fixture, "djmdArtist", "11")?["rb_local_deleted"] == "0", "곡이 계속 쓰는 아티스트")
    }

    @Test func 동기화된_앨범을_비우면_지운_곡이_가리켜도_258이다() throws {
        // #173 S2 U04: 앨범 비우기. 지운 곡 여럿이 가리키던 동기화 앨범도 258, 그 앨범의 앨범 아티스트 행은 그대로.
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1, rb_data_status = 262 WHERE ID = '501'")
        try fixture.insert("djmdArtist", ["ID": .text("13"), "Name": .text("DJC 173 앨범 아티스트"), "UUID": .text("a-13")])
        try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '13' WHERE ID = '31'")
        try sync(fixture, "djmdAlbum", "31")
        try sync(fixture, "djmdArtist", "13")
        let artist = try row(fixture, "djmdArtist", "13")
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.album = "" }]).tagWritten.count == 1)
        let old = try #require(try row(fixture, "djmdAlbum", "31"))
        #expect(old["rb_data_status"] == "258" && old["rb_local_deleted"] == "1" && old["AlbumArtistID"] == "13")
        #expect(try row(fixture, "djmdArtist", "13") == artist)
        #expect(try fixture.rows("SELECT quote(AlbumID) AS a FROM djmdContent WHERE ID = '500'").first?["a"] == "''")
    }

    @Test func 동기화된_앨범의_앨범_아티스트를_제자리에서_넣고_비운다() throws {
        // #173 S2 U01(AA NULL → 기존 이름, 257), U14(AA → '', 257, 이 앨범만 가리키던 옛 AA 행 258).
        let (fixture, track) = try library(shared: false)
        try fixture.insert("djmdArtist", ["ID": .text("13"), "Name": .text("DJC 173 앨범 아티스트"), "UUID": .text("a-13")])
        try sync(fixture, "djmdAlbum", "31")
        try sync(fixture, "djmdArtist", "13")
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.albumArtist = "DJC 173 앨범 아티스트" }]).tagWritten.count == 1)
        let put = try #require(try row(fixture, "djmdAlbum", "31"))
        #expect(put["AlbumArtistID"] == "13" && put["rb_data_status"] == "257")
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.albumArtist = "" }]).tagWritten.count == 1)
        let cleared = try #require(try row(fixture, "djmdAlbum", "31"))
        #expect(cleared["AlbumArtistID"] == "" && cleared["rb_data_status"] == "257")
        #expect(try row(fixture, "djmdArtist", "13")?["rb_data_status"] == "258")
        #expect(try content(fixture)["TrackInfoUpdated"] == "5" && content(fixture)["AlbumID"] == "31")
    }

    @Test func 버려질_257_앨범도_258로_표시하고_4칸만_바꾼다() throws {
        // #173 S4 B1·B2(2026-10-04): 이 곡만 쓰는 256 앨범(앨범 아티스트 있음)의 곡에서 아티스트를 저장해 앨범이 257이 된 뒤(B1), 앨범 새 이름을
        // 저장하자(B2) 257 옛 앨범이 258·`rb_local_deleted` 1이 됐다. 전(256) → 후(258) 차이는 256 → 258과 같은 네 칸이고 `usn`은 그대로다.
        // `TrackInfoUpdated`는 저장 두 번이라 +2.
        let (fixture, track) = try syncedLibrary(shared: false)
        try fixture.insert("djmdArtist", ["ID": .text("13"), "Name": .text("DJC 173 앨범 아티스트"), "UUID": .text("a-13")])
        try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '13' WHERE ID = '31'")
        try sync(fixture, "djmdAlbum", "31")
        let before = try #require(try row(fixture, "djmdAlbum", "31"))
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 아티스트" }]).tagWritten.count == 1)
        #expect(try row(fixture, "djmdAlbum", "31")?["rb_data_status"] == "257", "B1: 저장된 앨범")
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.album = "DJC 173 앨범 2" }])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        let after = try #require(try row(fixture, "djmdAlbum", "31"))
        #expect(Set(after.keys.filter { after[$0] != before[$0] }) == ["rb_data_status", "rb_local_deleted", "rb_local_usn", "updated_at"])
        #expect(after["rb_data_status"] == "258" && after["rb_local_deleted"] == "1" && after["usn"] == "40" && after["rb_local_synced"] == "1")
        let fresh = try #require(fixture.rows("SELECT * FROM djmdAlbum WHERE Name = 'DJC 173 앨범 2'").first)
        #expect(fresh["AlbumArtistID"] == "13" && fresh["rb_data_status"] == "0")
        let row = try content(fixture)
        #expect(row["AlbumID"] == fresh["ID"] && row["TrackInfoUpdated"] == "4" && row["rb_data_status"] == "257")
        // 번호: 새 앨범 → 옛 앨범(258) → 곡(마지막)
        let numbers = [fresh["rb_local_usn"], after["rb_local_usn"], row["rb_local_usn"]].map { Int($0 ?? "") ?? 0 }
        #expect(try numbers == numbers.sorted() && numbers.last == fixture.localUpdateCount())
    }

    // MARK: 여러 초안을 한 번에

    @Test func 두_초안이_같은_257_아티스트를_떠나면_둘째는_트랜잭션에서_막히고_첫째는_쓴다() throws {
        // 곡 500·501이 함께 쓰는 257 아티스트를 둘 다 떠나면, 첫 초안 뒤에도 아티스트는 501이 쓰고 둘째 초안에서 버려져 막힌다(257 아티스트·장르
        // 버리기는 확인하지 못했다). 백업 전 확인은 초안마다 시작 DB로 따로 보아 둘 다 통과하고, 트랜잭션 안의 확인(앞 초안을 쓴 DB)이 기준이다.
        // 둘째는 막힘으로 보고하고 첫째는 쓴다. 미리 보기(시험 실행)와 실제 쓰기의 결과가 같다.
        let (fixture, track) = try library()
        try sync(fixture, "djmdArtist", "11", state: 257)
        let neighbor = TrackSpec(id: "501", uuid: "track-uuid-501")
        let drafts = [try draft(fixture, track) { $0.artist = "DJC 173 아티스트 가" }, try draft(fixture, neighbor) { $0.artist = "DJC 173 아티스트 나" }]
        let db = try fixture.open()
        let checked = try RekordboxWriter.checkTagDrafts(drafts, db: db, writable: Self.allKeys)
        db.close()
        #expect(checked.passed.count == 2 && checked.blocked.isEmpty)
        let preview = try write(fixture, tags: drafts, dryRun: true)
        #expect(preview.tagWritten.map(\.trackUUID) == [track.uuid] && preview.tagBlocked.map(\.trackUUID) == [neighbor.uuid])
        let report = try write(fixture, tags: drafts)
        #expect(report.tagWritten.map(\.trackUUID) == [track.uuid] && report.tagBlocked.map(\.trackUUID) == [neighbor.uuid])
        #expect(report.tagBlocked.first?.reason?.contains("동기화 아티스트·장르") == true)
        #expect(try row(fixture, "djmdArtist", "11")?["rb_data_status"] == "257" && content(fixture, "501")["ArtistID"] == "11")
    }

    @Test func 앞_초안이_버린_이름을_뒤_초안이_다시_쓰면_새_행을_만든다() throws {
        // 앞 초안이 버린 동기화 아티스트(258)는 살아 있는 행이 아니므로 뒤 초안의 같은 이름은 새 행이다. 확인과 쓰기 모두 통과한다.
        let (fixture, track) = try library(shared: false)
        try sync(fixture, "djmdArtist", "11")
        var neighbor = TrackSpec(id: "502", uuid: "track-uuid-502")
        neighbor.artistID = "12"
        try fixture.insert("djmdArtist", ["ID": .text("12"), "Name": .text("DJC 173 다른 아티스트"), "UUID": .text("a-12")])
        try fixture.add(neighbor)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = '502'")
        let drafts = [try draft(fixture, track) { $0.artist = "DJC 173 아티스트" }, try draft(fixture, neighbor) { $0.artist = "옛 아티스트" }]
        let db = try fixture.open()
        let checked = try RekordboxWriter.checkTagDrafts(drafts, db: db, writable: Self.allKeys)
        db.close()
        #expect(checked.passed.count == 2 && checked.blocked.isEmpty)
        let report = try write(fixture, tags: drafts)
        #expect(report.tagWritten.count == 2)
        #expect(try row(fixture, "djmdArtist", "11")?["rb_data_status"] == "258")
        let fresh = try #require(fixture.rows("SELECT ID FROM djmdArtist WHERE Name = '옛 아티스트' AND rb_local_deleted = 0").first?["ID"])
        #expect(try fresh != "11" && content(fixture, "502")["ArtistID"] == fresh)
    }

    // MARK: 7. 앨범과 아티스트를 함께 고치면 앨범 먼저

    /// 곡 행·앨범·아티스트 표를 ID·UUID·번호 값·시각 없이(외래 키는 이름으로) 비교할 모양
    func canonical(_ fixture: RekordboxFixture) throws -> [String] {
        let track = try fixture.rows("""
            SELECT c.Title, a.Name AS artist, al.Name AS album, aa.Name AS albumArtist, c.TrackInfoUpdated, c.rb_data_status, c.usn
            FROM djmdContent c LEFT JOIN djmdArtist a ON a.ID = c.ArtistID LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID
            LEFT JOIN djmdArtist aa ON aa.ID = al.AlbumArtistID WHERE c.ID = '500'
            """).map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }
        let albums = try fixture.rows("""
            SELECT al.Name, aa.Name AS albumArtist, quote(al.AlbumArtistID) IS 'NULL' AS nullArtist, al.rb_data_status, al.rb_local_deleted,
                al.usn, al.rb_local_synced FROM djmdAlbum al LEFT JOIN djmdArtist aa ON aa.ID = al.AlbumArtistID
            """).map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }.sorted()
        let artists = try fixture.rows("SELECT Name, rb_data_status, rb_local_deleted, usn FROM djmdArtist")
            .map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }.sorted()
        return track + albums + artists
    }

    @Test(arguments: [false, true]) func 앨범과_아티스트를_함께_바꾸면_앨범을_먼저_저장한_결과와_같다(existingAlbum: Bool) throws {
        // #173 명세 4.2-7: 아티스트를 먼저 쓰면 이 곡만 쓰는 동기화 앨범이 257이 됐다가 버려져 막힌다. rekordbox에서 앨범 → 아티스트 순으로
        // 저장한 결과(S1 T04 새 앨범·S2 U02 기존 앨범 → 옛 앨범 258, 그 뒤 S1 T02 아티스트 → 바뀐 앨범을 저장)와 같아야 한다.
        func prepared() throws -> (RekordboxFixture, TrackSpec) {
            let (fixture, track) = try syncedLibrary(shared: false)
            for (table, id) in [("djmdArtist", "11"), ("djmdAlbum", "31")] { try sync(fixture, table, id) }
            if existingAlbum {
                try fixture.insert("djmdAlbum", ["ID": .text("32"), "Name": .text("DJC 173 앨범"), "AlbumArtistID": .text(""), "UUID": .text("al-32")])
                try sync(fixture, "djmdAlbum", "32")
            }
            return (fixture, track)
        }
        let (together, track) = try prepared()
        let report = try write(together, tags: [try draft(together, track) { $0.album = "DJC 173 앨범"; $0.artist = "DJC 173 아티스트" }])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        let (oneByOne, same) = try prepared()
        #expect(try write(oneByOne, tags: [try draft(oneByOne, same) { $0.album = "DJC 173 앨범" }]).tagWritten.count == 1)
        #expect(try write(oneByOne, tags: [try draft(oneByOne, same) { $0.artist = "DJC 173 아티스트" }]).tagWritten.count == 1)
        #expect(try canonical(together) == canonical(oneByOne))
        #expect(try row(together, "djmdAlbum", "31")?["rb_data_status"] == "258" && row(together, "djmdArtist", "11")?["rb_data_status"] == "258")
        // 곡이 옮겨 간 앨범이 아티스트 저장의 번호를 받고, 곡 행이 마지막 번호다
        let album = try #require(together.rows("SELECT rb_local_usn FROM djmdAlbum WHERE Name = 'DJC 173 앨범'").first?["rb_local_usn"])
        #expect(try (Int(album) ?? 0) < (Int(content(together)["rb_local_usn"] ?? "") ?? 0))
        #expect(try Int(content(together)["rb_local_usn"] ?? "") == together.localUpdateCount())
    }

    @Test func 다른_곡이_쓰는_동기화_이름_행은_그대로_둔다() throws {
        // #173 S1 T03·X1: 다른 곡도 쓰는 옛 아티스트는 그대로, S1 T06·T07: 다른 곡도 쓰는 옛 장르는 그대로.
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET GenreID = '21' WHERE ID = '501'")
        try sync(fixture, "djmdArtist", "11")
        try sync(fixture, "djmdGenre", "21")
        let artist = try row(fixture, "djmdArtist", "11"), genre = try row(fixture, "djmdGenre", "21")
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 아티스트"; $0.genre = "DJC 173 장르" }]).tagWritten.count == 1)
        #expect(try row(fixture, "djmdArtist", "11") == artist && row(fixture, "djmdGenre", "21") == genre)
    }
}
