import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 2026-09-27 태그 2단계: DJC 실험곡 1~5·DJC 실험 태그 날짜·중복 A/B, rekordbox 7.2.18.
/// 사본 S0~S5에서 확인한 칸만 연다. 공유 값 변경·동명 앨범 선택은 닫아 둔다. 동기화 상태(256·257) 곡·앨범은 #173(RekordboxTagSyncedTests).
extension RekordboxTagWriterTests {
    @Test(arguments: [false, true]) func 아티스트를_비우면_빈_문자열이고_미참조_행만_지운다(shared: Bool) throws {
        // S2 실험곡 2(미참조 삭제), S5 실험곡 1(공유 이름 보존).
        let (fixture, track) = try library(shared: shared)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "" }])
        #expect(report.tagWritten.count == 1)
        #expect(try content(fixture)["ArtistID"] == "" && content(fixture)["TrackInfoUpdated"] == "4")
        #expect(try fixture.rows("SELECT ID FROM djmdArtist WHERE ID = '11'").count == (shared ? 1 : 0))
        #expect(try fixture.rows("SELECT ID FROM djmdArtist WHERE Name = ''").isEmpty)
        #expect(try fixture.rows("SELECT AlbumArtistID, rb_local_usn FROM djmdAlbum WHERE ID = '31'").first
            == ["AlbumArtistID": "", "rb_local_usn": "2001"])
    }

    @Test(arguments: [false, true]) func 새_앨범의_빈_아티스트는_NULL이_아니고_현재_아티스트를_보존한다(hasArtist: Bool) throws {
        // S1 실험곡 3·S2 실험곡 1(빈 값), S4 실험곡 5·S5 실험곡 4(아티스트 있음).
        let (fixture, track) = try library()
        if hasArtist { try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'") }
        let original = try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'")
        let tags = try draft(fixture, track) { $0.album = "DJC 태그2 새 앨범" }
        #expect(try write(fixture, tags: [tags]).tagWritten.count == 1)
        let album = try #require(fixture.rows("SELECT * FROM djmdAlbum WHERE Name = 'DJC 태그2 새 앨범'").first)
        #expect(album["AlbumArtistID"] == (hasArtist ? "11" : ""))
        #expect(album["Compilation"] == "0" && album["ImagePath"] == "NULL" && album["SearchStr"] == "NULL")
        #expect(album["rb_data_status"] == "0" && album["rb_local_usn"] == "2001" && album["updated_at"] == stamp)
        #expect(try content(fixture)["AlbumID"] == album["ID"] && content(fixture)["TrackInfoUpdated"] == "4")
        #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'") == original)
    }

    @Test(arguments: [false, true]) func 기존_앨범을_붙이면_같은_행을_저장한다(hasArtist: Bool) throws {
        // S1 실험곡 4: 실험곡 3이 만든 앨범에 붙임. 같은 이름이 하나이며 앨범 아티스트가 같을 때만 연다.
        let (fixture, track) = try library()
        if hasArtist { try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'") }
        try fixture.insert("djmdAlbum", ["ID": .text("32"), "Name": .text("있는 앨범"), "AlbumArtistID": hasArtist ? .text("11") : .null])
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.album = "있는 앨범" }]).tagWritten.count == 1)
        #expect(try content(fixture)["AlbumID"] == "32")
        #expect(try fixture.rows("SELECT AlbumArtistID, rb_local_usn, updated_at FROM djmdAlbum WHERE ID = '32'").first
            == ["AlbumArtistID": hasArtist ? "11" : "", "rb_local_usn": "2001", "updated_at": stamp])
    }

    @Test func 단독_앨범_아티스트는_같은_행에서_바꾸고_미참조_이름을_지운다() throws {
        // S2·S3 실험곡 3에서 같은 행 수정·미참조 아티스트 삭제, S5에서 남은 한 곡도 같은 규칙.
        let (fixture, track) = try library(shared: false)
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.albumArtist = "새 앨범 아티스트" }]).tagWritten.count == 1)
        let artist = try #require(fixture.rows("SELECT ID FROM djmdArtist WHERE Name = '새 앨범 아티스트'").first?["ID"])
        #expect(try content(fixture)["AlbumID"] == "31" && content(fixture)["TrackInfoUpdated"] == "4")
        #expect(try fixture.rows("SELECT AlbumArtistID, rb_local_usn FROM djmdAlbum WHERE ID = '31'").first
            == ["AlbumArtistID": artist, "rb_local_usn": "2002"])
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.albumArtist = "" }]).tagWritten.count == 1)
        #expect(try fixture.rows("SELECT AlbumArtistID FROM djmdAlbum WHERE ID = '31'").first?["AlbumArtistID"] == "")
        #expect(try fixture.rows("SELECT ID FROM djmdArtist WHERE ID = ?", [.text(artist)]).isEmpty)
    }

    @Test func 다른_앨범이_쓰는_앨범_아티스트는_비워도_지우지_않는다() throws {
        // S5 실험곡 3: 실험곡 4의 다른 앨범이 공유 B를 계속 참조한다.
        let (fixture, track) = try library(shared: false)
        try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'")
        try fixture.insert("djmdAlbum", ["ID": .text("32"), "Name": .text("다른 앨범"), "AlbumArtistID": .text("11")])
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.albumArtist = "" }]).tagWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdArtist WHERE ID = '11'").count == 1)
    }

    @Test func 공유_앨범_아티스트는_막고_다른_곡도_보존한다() throws {
        let (fixture, track) = try library()
        let before = try fixture.rows("SELECT * FROM djmdAlbum")
        for value in ["새 아티스트", ""] {
            try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'")
            let tags = try draft(fixture, track) { $0.albumArtist = value }
            let report = try write(fixture, tags: [tags])
            #expect(report.tagBlocked.first?.reason?.contains("여러 곡") == true && report.backup == nil)
        }
        #expect(try content(fixture, "501")["TrackInfoUpdated"] == "1")
        #expect(try fixture.rows("SELECT rb_local_usn FROM djmdAlbum").first?["rb_local_usn"] == before.first?["rb_local_usn"])
    }

    @Test func 동명_앨범과_다른_앨범_아티스트에_붙이기는_막는다() throws {
        let (fixture, track) = try library(shared: false)
        try fixture.insert("djmdAlbum", ["ID": .text("32"), "Name": .text("있는 앨범"), "AlbumArtistID": .text("11")])
        let mismatch = try draft(fixture, track) { $0.album = "있는 앨범" }
        #expect(try write(fixture, tags: [mismatch]).tagBlocked.first?.reason?.contains("앨범 아티스트") == true)
        try fixture.insert("djmdAlbum", ["ID": .text("33"), "Name": .text("있는 앨범"), "AlbumArtistID": .text("")])
        #expect(try write(fixture, tags: [mismatch]).tagBlocked.first?.reason?.contains("같은 이름") == true)
        try fixture.insert("djmdAlbum", ["ID": .text("34"), "Name": .text("옛 앨범"), "AlbumArtistID": .text("")])
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.albumArtist = "새 아티스트" }]).tagBlocked.count == 1)
        let orphan = try draft(fixture, track) { $0.album = ""; $0.albumArtist = "새 아티스트" }
        #expect(try write(fixture, tags: [orphan]).tagBlocked.count == 1)
        let combined = try draft(fixture, track) { $0.album = "새 앨범"; $0.albumArtist = "새 아티스트" }
        #expect(try write(fixture, tags: [combined]).tagBlocked.count == 1)
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test func 실험하지_않은_곡과_앨범_상태는_백업_전에_막는다() throws {
        let (fixture, track) = try library()
        // 곡 상태는 0·256·257만 확인했다(#171·#173, RekordboxTagSyncedTests)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 258 WHERE ID = '500'")
        let title = try write(fixture, tags: [try draft(fixture, track) { $0.title = "새 제목" }]).tagBlocked.first?.reason
        #expect(title?.contains("동기화 상태") == true)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = '500'")
        // 앨범 상태는 0·256·257만 확인했다(#173 S1~S3). 그 밖의 상태는 막는다.
        try fixture.execute("UPDATE djmdAlbum SET rb_data_status = 2 WHERE ID = '31'")
        for key in [TagFields.Key.artist, .album, .albumArtist] {
            let tags = try draft(fixture, track) { $0[key] = "새 값" }
            #expect(try write(fixture, tags: [tags]).tagBlocked.first?.reason?.contains("상태") == true)
        }
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test func 여러_곡에_같은_앨범을_붙여도_마지막_앨범_번호로_검증한다() throws {
        let (fixture, track) = try library()
        let neighbor = TrackSpec(id: "501", uuid: "track-uuid-501")
        let drafts = try [track, neighbor].map { item in try draft(fixture, item) { $0.album = "새 앨범" } }
        let report = try write(fixture, tags: drafts)
        #expect(report.tagWritten.count == 2)
        #expect(try content(fixture)["AlbumID"] == content(fixture, "501")["AlbumID"])
        #expect(try fixture.rows("SELECT ID FROM djmdAlbum WHERE ID = '31'").isEmpty)
    }

    @Test func 아티스트와_앨범을_함께_바꿔_옛_앨범이_지워져도_검증한다() throws {
        let (fixture, track) = try library(shared: false)
        let tags = try draft(fixture, track) { $0.artist = "새 아티스트"; $0.album = "새 앨범" }
        #expect(try write(fixture, tags: [tags]).tagWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdAlbum WHERE ID = '31'").isEmpty)
    }
    @Test func 막힌_태그만_있어도_재생_목록_초안은_반영한다() throws {
        let (fixture, track) = try library()
        let tags = try draft(fixture, track) { $0.albumArtist = "공유 앨범 변경" }
        var playlists = PlaylistDraft()
        try playlists.append(.create(key: "new", name: "새 목록", isFolder: false, parent: .root), rekordbox: PlaylistLayout())
        let report = try RekordboxWriter.write(drafts: [], tags: [tags], playlistDraft: playlists, to: fixture.database,
                                               dryRun: false, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.tagBlocked.count == 1 && report.playlistWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdPlaylist WHERE Name = '새 목록'").count == 1)
    }

    @Test func 막힌_태그와_변경_없는_큐의_결과를_함께_남긴다() throws {
        let (fixture, track) = try library()
        let tags = try draft(fixture, track) { $0.albumArtist = "공유 앨범 변경" }
        let cue = CueDraft(trackUUID: track.uuid)
        let report = try write(fixture, tags: [tags], drafts: [cue])
        #expect(report.tagBlocked.count == 1 && report.outcomes.first?.status == .unchanged)
        #expect(report.backup == nil)
    }

    // MARK: 동명 앨범(#173 S2 U13·S3 V02·S4 C·D·F, 2026-10-04)

    /// 곡 500의 앨범을 같은 이름 앨범 둘 중 하나로 둔다. `mine`이 곡 500의 앨범, `other`는 곡 502가 쓰는 같은 이름 앨범.
    /// 앨범 아티스트(16 "DJC 173 AA 가", 17 "DJC 173 AA 나")와 바꿀 아티스트(15 "DJC 173 기존")도 넣는다.
    func sameNameAlbums(_ fixture: RekordboxFixture, mine: (artist: CipherDatabase.Value, created: String),
                        other: (artist: CipherDatabase.Value, created: String)) throws {
        for (id, name) in [("15", "DJC 173 기존"), ("16", "DJC 173 AA 가"), ("17", "DJC 173 AA 나")] {
            try fixture.insert("djmdArtist", ["ID": .text(id), "Name": .text(name), "UUID": .text("a-\(id)")])
        }
        try fixture.insert("djmdAlbum", ["ID": .text("41"), "Name": .text("DJC 173 중복 앨범"), "AlbumArtistID": mine.artist,
                                         "UUID": .text("al-41"), "rb_local_usn": .int(8), "created_at": .text(mine.created)])
        try fixture.insert("djmdAlbum", ["ID": .text("42"), "Name": .text("DJC 173 중복 앨범"), "AlbumArtistID": other.artist,
                                         "UUID": .text("al-42"), "rb_local_usn": .int(9), "created_at": .text(other.created)])
        var neighbor = TrackSpec(id: "502", uuid: "track-uuid-502")
        neighbor.albumID = "42"
        try fixture.add(neighbor)
        try fixture.execute("UPDATE djmdContent SET AlbumID = '41' WHERE ID = '500'")
    }

    @Test func 동명_앨범인_곡의_아티스트를_바꾸면_같은_이름의_새_앨범으로_옮긴다() throws {
        // S3 V02: 상태 0 곡, 앨범 아티스트가 있는 나중에 만든 앨범(이 곡만 씀). 같은 이름의 새 앨범(앨범 아티스트 이어받음, 상태 0)으로
        // 옮기고, 옛 앨범은 쓰는 곡이 없어 지운다. `TrackInfoUpdated` +1. 다른 같은 이름 앨범은 그대로.
        let (fixture, track) = try library()
        try sameNameAlbums(fixture, mine: (.text("16"), "2026-02-01 00:00:00.000 +00:00"), other: (.text("17"), "2025-01-01 00:00:00.000 +00:00"))
        let other = try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '42'")
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 기존" }])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        let row = try content(fixture)
        let fresh = try #require(fixture.rows("SELECT * FROM djmdAlbum WHERE ID = ?", [.text(row["AlbumID"] ?? "")]).first)
        #expect(!["41", "42"].contains(fresh["ID"]) && fresh["Name"] == "DJC 173 중복 앨범" && fresh["AlbumArtistID"] == "16")
        for (key, value) in ["ImagePath": "NULL", "SearchStr": "NULL", "Compilation": "0", "rb_data_status": "0", "rb_local_data_status": "0",
                             "rb_local_deleted": "0", "rb_local_synced": "0", "usn": "NULL", "created_at": stamp, "updated_at": stamp] {
            #expect(fresh[key] == value, "\(key)")
        }
        #expect(fresh["UUID"] != "al-41" && fresh["UUID"] == fresh["UUID"]?.lowercased())
        #expect(row["ArtistID"] == "15" && row["TrackInfoUpdated"] == "4" && row["rb_data_status"] == "0")
        #expect(try fixture.rows("SELECT ID FROM djmdAlbum WHERE ID = '41'").isEmpty, "옛 앨범은 상태 0이라 지운다")
        #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '42'") == other)
        // 번호: 새 앨범 → 곡 행
        #expect(try fresh["rb_local_usn"] == "2001" && row["rb_local_usn"] == "2002" && fixture.localUpdateCount() == 2002)
    }

    @Test func 동명_앨범_중_먼저_만든_앨범_아티스트_없는_동기화_앨범의_곡도_새_앨범으로_옮기고_옛_앨범은_그대로다() throws {
        // S2 U13: 동기화 곡, 가장 먼저 만든 같은 이름 앨범(앨범 아티스트 NULL, 256, 다른 곡도 씀) → 새 앨범(앨범 아티스트 '', 상태 0).
        // 옛 앨범은 저장하지 않아 모든 칸 그대로. rekordbox는 `TrackInfoUpdated`를 +2 했지만 저장 두 번으로 본다(S3 V02는 +1).
        let (fixture, track) = try syncedLibrary()
        try sameNameAlbums(fixture, mine: (.null, "2025-01-01 00:00:00.000 +00:00"), other: (.text("17"), "2026-02-01 00:00:00.000 +00:00"))
        try sync(fixture, "djmdAlbum", "41")
        try fixture.execute("UPDATE djmdContent SET AlbumID = '41' WHERE ID = '501'")
        let old = try fixture.rows("SELECT * FROM djmdAlbum WHERE ID IN ('41', '42') ORDER BY ID")
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 기존" }]).tagWritten.count == 1)
        let row = try content(fixture)
        let fresh = try #require(fixture.rows("SELECT * FROM djmdAlbum WHERE ID = ?", [.text(row["AlbumID"] ?? "")]).first)
        #expect(fresh["Name"] == "DJC 173 중복 앨범" && fresh["AlbumArtistID"] == "" && fresh["rb_data_status"] == "0")
        #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID IN ('41', '42') ORDER BY ID") == old)
        #expect(row["TrackInfoUpdated"] == "3" && row["rb_data_status"] == "257")
    }

    @Test(arguments: [256, 257]) func 동명_앨범의_옛_앨범이_동기화_앨범이면_256·257_모두_258이다(state: Int) throws {
        // 옛 앨범 버리기는 상태대로: 256(#173 S4 F, 2026-10-04: 이 곡만 쓰던 옛 앨범 → 258)과 257(S4 B2: 257 앨범이 버려지면 256과 같은
        // 네 칸) 모두 258·삭제 표시다.
        let (fixture, track) = try library()
        try sameNameAlbums(fixture, mine: (.text("16"), "2026-02-01 00:00:00.000 +00:00"), other: (.text("17"), "2025-01-01 00:00:00.000 +00:00"))
        try sync(fixture, "djmdAlbum", "41", state: state)
        let before = try #require(try row(fixture, "djmdAlbum", "41"))
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 기존" }])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        let after = try #require(try row(fixture, "djmdAlbum", "41"))
        #expect(Set(after.keys.filter { after[$0] != before[$0] }) == ["rb_data_status", "rb_local_deleted", "rb_local_usn", "updated_at"])
        #expect(after["rb_data_status"] == "258" && after["rb_local_deleted"] == "1" && after["usn"] == "40")
    }

    @Test(arguments: ["''", "'16'"]) func 동명_앨범_중_먼저_만든_행의_곡도_새_앨범으로_옮긴다(artist: String) throws {
        // #173 S4 C(2026-10-04): 곡의 앨범이 같은 이름 앨범 중 rowid·만든 시각·ID 어느 순서로도 첫 행이고 앨범 아티스트도 있었는데(동기화, 다른 곡도
        // 씀) 같은 이름의 새 앨범(앨범 아티스트 이어받음, 상태 0)으로 옮겼다. 옛 앨범은 저장하지 않아 그대로다. "먼저 만든 같은 이름 행의 앨범
        // 아티스트를 비교해 같으면 다시 쓴다"는 가설은 C·D·S3 V02로 버렸다. 만든 시각이 같아도 같다.
        for created in ["2025-01-01 00:00:00.000 +00:00", "2026-02-01 00:00:00.000 +00:00"] {
            let (fixture, track) = try syncedLibrary()
            try sameNameAlbums(fixture, mine: (.null, "2025-01-01 00:00:00.000 +00:00"), other: (.text("17"), created))
            try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = \(artist) WHERE ID = '41'")
            try sync(fixture, "djmdAlbum", "41")
            try fixture.execute("UPDATE djmdContent SET AlbumID = '41' WHERE ID = '501'")
            let old = try fixture.rows("SELECT * FROM djmdAlbum WHERE ID IN ('41', '42') ORDER BY ID")
            let report = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 173 기존" }])
            #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
            let row = try content(fixture)
            let fresh = try #require(fixture.rows("SELECT * FROM djmdAlbum WHERE ID = ?", [.text(row["AlbumID"] ?? "")]).first)
            #expect(!["41", "42"].contains(fresh["ID"]) && fresh["Name"] == "DJC 173 중복 앨범")
            #expect(fresh["AlbumArtistID"] == (artist == "''" ? "" : "16") && fresh["rb_data_status"] == "0" && fresh["usn"] == "NULL")
            #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID IN ('41', '42') ORDER BY ID") == old, "옛 앨범·다른 같은 이름 앨범 그대로")
            #expect(row["ArtistID"] == "15" && row["TrackInfoUpdated"] == "3" && row["rb_data_status"] == "257")
            // 번호: 새 앨범 → 곡 행(마지막)
            let numbers = [fresh["rb_local_usn"], row["rb_local_usn"]].map { Int($0 ?? "") ?? 0 }
            #expect(try numbers == numbers.sorted() && numbers.last == fixture.localUpdateCount())
        }
    }

    @Test func 동명_앨범인_곡의_아티스트를_비우면_앨범_아티스트_빈_글자인_새_앨범으로_옮긴다() throws {
        // #173 S4 D(2026-10-04): 같은 이름 앨범 둘 중 곡의 앨범(앨범 아티스트 NULL, 동기화, 다른 곡도 씀)인 곡의 아티스트를 비우자, 바꾸기와 같은
        // 규칙으로 새 앨범(앨범 아티스트 '', 상태 0)으로 옮겼다. 곡의 `ArtistID`는 ''(글자)다. 옛 앨범과 다른 곡도 쓰는 옛 아티스트는 그대로다.
        let (fixture, track) = try syncedLibrary()
        try sameNameAlbums(fixture, mine: (.null, "2025-01-01 00:00:00.000 +00:00"), other: (.text("17"), "2026-02-01 00:00:00.000 +00:00"))
        try sync(fixture, "djmdAlbum", "41")
        try sync(fixture, "djmdArtist", "11")
        try fixture.execute("UPDATE djmdContent SET AlbumID = '41' WHERE ID = '501'")
        let old = try fixture.rows("SELECT * FROM djmdAlbum WHERE ID IN ('41', '42') ORDER BY ID"), artist = try row(fixture, "djmdArtist", "11")
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "" }])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        let song = try content(fixture)
        #expect(try fixture.rows("SELECT quote(ArtistID) AS a FROM djmdContent WHERE ID = '500'").first?["a"] == "''")
        let fresh = try #require(fixture.rows("SELECT *, quote(AlbumArtistID) AS aa FROM djmdAlbum WHERE ID = ?", [.text(song["AlbumID"] ?? "")]).first)
        #expect(!["41", "42"].contains(fresh["ID"]) && fresh["Name"] == "DJC 173 중복 앨범" && fresh["aa"] == "''" && fresh["rb_data_status"] == "0")
        #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID IN ('41', '42') ORDER BY ID") == old, "옛 앨범 그대로")
        #expect(try row(fixture, "djmdArtist", "11") == artist, "다른 곡도 쓰는 옛 아티스트 그대로")
        #expect(song["TrackInfoUpdated"] == "3" && song["rb_data_status"] == "257")
        // 이름이 유일한 앨범의 곡은 그대로 비우고 앨범을 제자리에서 저장한다
        let (unique, other) = try library()
        #expect(try write(unique, tags: [try draft(unique, other) { $0.artist = "" }]).tagWritten.count == 1)
        #expect(try content(unique)["AlbumID"] == "31")
    }

    /// 곡 500·502와 이름·앨범 행을 ID·UUID·번호 값·시각 없이(외래 키는 이름으로) 비교할 모양
    func sameNameState(_ fixture: RekordboxFixture) throws -> [String] {
        func lines(_ sql: String) throws -> [String] {
            try fixture.rows(sql).map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }.sorted()
        }
        return try lines("""
            SELECT c.ID, a.Name AS artist, al.Name AS album, aa.Name AS albumArtist, quote(al.AlbumArtistID) AS aaID, al.rb_data_status AS albumState,
                c.TrackInfoUpdated, c.rb_data_status FROM djmdContent c LEFT JOIN djmdArtist a ON a.ID = c.ArtistID
            LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID LEFT JOIN djmdArtist aa ON aa.ID = al.AlbumArtistID WHERE c.ID IN ('500', '502')
            """) + lines("""
            SELECT al.Name, aa.Name AS albumArtist, quote(al.AlbumArtistID) AS aaID, al.rb_data_status, al.rb_local_deleted, quote(al.usn) AS usn
            FROM djmdAlbum al LEFT JOIN djmdArtist aa ON aa.ID = al.AlbumArtistID
            """) + lines("SELECT Name, rb_data_status, rb_local_deleted FROM djmdArtist")
    }

    @Test(arguments: [0, 256]) func 앞_초안이_같은_이름_앨범을_하나로_줄이면_뒤_초안은_새_앨범으로_옮기지_않는다(state: Int) throws {
        // 새 앨범으로 옮길지는 초안마다 트랜잭션 안에서 앞 초안을 쓴 DB로 정한다(백업 전 확인은 시작 DB로 본다). 첫 초안이 곡 500을 다른 앨범으로
        // 옮겨 같은 이름 앨범 41이 버려지면 이름이 하나뿐이 되어, 둘째 초안(곡 502의 아티스트)은 rekordbox에서 차례로 저장한 것처럼 앨범 42를 제자리에서
        // 저장한다(S3 V01: 이름이 유일하면 갈라지지 않는다). 한 번에 쓴 결과와 하나씩 쓴 결과가 같다.
        func prepared() throws -> (RekordboxFixture, [TagDraft]) {
            let (fixture, track) = try library()
            try sameNameAlbums(fixture, mine: (.text("16"), "2026-02-01 00:00:00.000 +00:00"), other: (.text("17"), "2025-01-01 00:00:00.000 +00:00"))
            try fixture.execute("UPDATE djmdContent SET rb_data_status = ? WHERE ID IN ('500', '502')", [.int(state)])
            for id in ["41", "42"] { try sync(fixture, "djmdAlbum", id, state: state) }
            let neighbor = TrackSpec(id: "502", uuid: "track-uuid-502")
            return (fixture, [try draft(fixture, track) { $0.album = "DJC 173 다른 앨범" }, try draft(fixture, neighbor) { $0.artist = "DJC 173 기존" }])
        }
        let (together, drafts) = try prepared()
        let report = try write(together, tags: drafts)
        #expect(report.tagWritten.count == 2 && report.tagBlocked.isEmpty)
        #expect(try content(together, "502")["AlbumID"] == "42", "옮기지 않는다")
        let saved = try #require(try row(together, "djmdAlbum", "42"))
        #expect(saved["AlbumArtistID"] == "17" && saved["rb_data_status"] == String(state == 256 ? 257 : 0) && saved["rb_local_usn"] != "9")
        #expect(try together.rows("SELECT ID FROM djmdAlbum WHERE Name = 'DJC 173 중복 앨범' AND rb_local_deleted = 0").map { $0["ID"] } == ["42"])
        let (oneByOne, steps) = try prepared()
        for step in steps { #expect(try write(oneByOne, tags: [step]).tagWritten.count == 1) }
        #expect(try sameNameState(together) == sameNameState(oneByOne))
    }

    // MARK: 앨범 조건은 앞 초안을 쓴 DB로 정한다(한 번에 쓴 결과 = 하나씩 쓴 결과)

    /// 곡들과 앨범·아티스트 행을 ID·UUID·번호 값·시각 없이(외래 키는 이름으로) 비교할 모양
    func albumBatchState(_ fixture: RekordboxFixture, tracks: [String]) throws -> [String] {
        func lines(_ sql: String) throws -> [String] {
            try fixture.rows(sql).map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }.sorted()
        }
        let ids = tracks.map { "'\($0)'" }.joined(separator: ", ")
        return try lines("""
            SELECT c.ID, al.Name AS album, aa.Name AS albumArtist, al.rb_data_status AS albumState, c.TrackInfoUpdated, c.rb_data_status
            FROM djmdContent c LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID LEFT JOIN djmdArtist aa ON aa.ID = al.AlbumArtistID
            WHERE c.ID IN (\(ids))
            """) + lines("""
            SELECT al.Name, aa.Name AS albumArtist, al.rb_data_status, al.rb_local_deleted, quote(al.usn) AS usn
            FROM djmdAlbum al LEFT JOIN djmdArtist aa ON aa.ID = al.AlbumArtistID
            """) + lines("SELECT Name, rb_data_status, rb_local_deleted FROM djmdArtist")
    }

    @Test(arguments: [0, 256]) func 앞_초안이_같은_이름_앨범을_하나로_줄이면_뒤_초안은_그_앨범에_붙일_수_있다(state: Int) throws {
        // 같은 이름 앨범이 둘(41·42)이라 시작 DB로는 "같은 이름의 앨범이 여럿"이지만, 첫 초안이 곡 500을 다른 앨범으로 옮겨 41이 버려지면 이름이
        // 하나뿐이다. 하나씩 쓰면 둘째 초안(곡 503의 앨범)이 앨범 42에 붙으므로 한 번에 써도 같다(백업 전 확인이 시작 DB로 둘째를 막지 않는다).
        func prepared() throws -> (RekordboxFixture, [TagDraft]) {
            let (fixture, track) = try library()
            try sameNameAlbums(fixture, mine: (.text("16"), "2026-02-01 00:00:00.000 +00:00"), other: (.null, "2025-01-01 00:00:00.000 +00:00"))
            let third = TrackSpec(id: "503", uuid: "track-uuid-503")
            try fixture.add(third)
            try fixture.execute("UPDATE djmdContent SET rb_data_status = ? WHERE ID IN ('500', '502', '503')", [.int(state)])
            for id in ["41", "42"] { try sync(fixture, "djmdAlbum", id, state: state) }
            return (fixture, [try draft(fixture, track) { $0.album = "DJC 173 다른 앨범" }, try draft(fixture, third) { $0.album = "DJC 173 중복 앨범" }])
        }
        let (together, drafts) = try prepared()
        let report = try write(together, tags: drafts)
        #expect(report.tagWritten.count == 2 && report.tagBlocked.isEmpty)
        #expect(try content(together, "503")["AlbumID"] == "42")
        let (oneByOne, steps) = try prepared()
        for step in steps { #expect(try write(oneByOne, tags: [step]).tagWritten.count == 1) }
        #expect(try albumBatchState(together, tracks: ["500", "502", "503"]) == albumBatchState(oneByOne, tracks: ["500", "502", "503"]))
    }

    /// 앨범 31을 곡 500·501이 함께 쓴다. 첫 초안은 곡 501의 `first`(아티스트면 앨범을 저장하고, 앨범이면 옮긴다), 둘째는 곡 500의 앨범 아티스트.
    func sharedAlbumLibrary(state: Int, first: TagFields.Key) throws -> (RekordboxFixture, [TagDraft]) {
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET rb_data_status = ? WHERE ID IN ('500', '501')", [.int(state)])
        try sync(fixture, "djmdAlbum", "31", state: state)
        let neighbor = TrackSpec(id: "501", uuid: "track-uuid-501")
        return (fixture, [try draft(fixture, neighbor) { $0[first] = first == .album ? "DJC 173 새 앨범" : "DJC 173 새 아티스트" },
                          try draft(fixture, track) { $0.albumArtist = "DJC 173 앨범 아티스트" }])
    }

    @Test(arguments: [0, 256]) func 앞_초안이_앨범을_쓰는_곡을_줄이면_뒤_초안은_그_앨범의_앨범_아티스트를_바꿀_수_있다(state: Int) throws {
        // 앨범 31을 곡 500·501이 함께 써서 시작 DB로는 "여러 곡이 쓰는 앨범"이지만, 첫 초안이 곡 501을 다른 앨범으로 옮기면 500 하나뿐이다.
        // 하나씩 쓰면 둘째 초안이 앨범 31의 앨범 아티스트를 제자리에서 바꾸므로 한 번에 써도 같다.
        let (together, drafts) = try sharedAlbumLibrary(state: state, first: .album)
        let report = try write(together, tags: drafts)
        #expect(report.tagWritten.count == 2 && report.tagBlocked.isEmpty)
        let (oneByOne, steps) = try sharedAlbumLibrary(state: state, first: .album)
        for step in steps { #expect(try write(oneByOne, tags: [step]).tagWritten.count == 1) }
        #expect(try albumBatchState(together, tracks: ["500", "501"]) == albumBatchState(oneByOne, tracks: ["500", "501"]))
    }

    @Test(arguments: [0, 256]) func 앞_초안이_앨범을_쓰는_곡을_그대로_두면_뒤_초안은_트랜잭션에서_막히고_앞_초안은_쓴다(state: Int) throws {
        // 앞 초안(곡 501의 아티스트)은 앨범 31을 저장할 뿐 쓰는 곡을 줄이지 않는다. 둘째의 앨범 아티스트는 하나씩 써도 막히므로(여러 곡이 쓰는
        // 앨범) 한 번에 쓸 때도 같은 이유로 막히고 첫째는 쓴다. 결정이 트랜잭션으로 옮겨 갔을 뿐 막힘이 풀리지는 않는다.
        let (together, drafts) = try sharedAlbumLibrary(state: state, first: .artist)
        let report = try write(together, tags: drafts)
        #expect(report.tagWritten.map(\.trackUUID) == ["track-uuid-501"] && report.tagBlocked.map(\.trackUUID) == ["track-uuid-500"])
        #expect(report.tagBlocked.first?.reason?.contains("여러 곡") == true && report.backup != nil)
        let (oneByOne, steps) = try sharedAlbumLibrary(state: state, first: .artist)
        #expect(try write(oneByOne, tags: [steps[0]]).tagWritten.count == 1)
        #expect(try write(oneByOne, tags: [steps[1]]).tagBlocked.first?.reason?.contains("여러 곡") == true)
        #expect(try albumBatchState(together, tracks: ["500", "501"]) == albumBatchState(oneByOne, tracks: ["500", "501"]))
    }

    @Test func 백업_전_확인은_첫_앨범_초안만_시작_DB로_앨범_조건을_보고_합치기가_있으면_모두_트랜잭션에_맡긴다() throws {
        let (fixture, drafts) = try sharedAlbumLibrary(state: 0, first: .artist)
        func check(_ tags: [TagDraft], mergesPending: Bool = false) throws -> (passed: Int, blocked: Int) {
            let db = try fixture.open()
            defer { db.close() }
            let checked = try RekordboxWriter.checkTagDrafts(tags, db: db, writable: Self.allKeys, mergesPending: mergesPending)
            return (checked.passed.count, checked.blocked.count)
        }
        // 첫 앨범 초안은 시작 DB로 다 본다(하나뿐인 초안이 백업 없이 막히는 것은 그대로)
        #expect(try check([drafts[1]]) == (0, 1))
        // 앞 초안(곡 501의 아티스트)이 앨범을 바꿀 수 있으면 뒤 초안의 앨범 조건은 트랜잭션에서 정한다
        #expect(try check(drafts) == (2, 0))
        // 제목만 고치는 앞 초안은 앨범을 바꾸지 않으므로 뒤 초안은 그대로 막는다
        let titleOnly = try draft(fixture, TrackSpec(id: "501", uuid: "track-uuid-501")) { $0.title = "DJC 173 제목" }
        #expect(try check([titleOnly, drafts[1]]) == (1, 1))
        // 합치기가 있으면 곡·앨범 행이 먼저 바뀌므로 첫 초안도 트랜잭션에 맡긴다
        #expect(try check([drafts[1]], mergesPending: true) == (1, 0))
    }

    @Test func 앨범_상태가_NULL이어도_검증된_상태로_보지_않는다() throws {
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdAlbum SET rb_data_status = NULL WHERE ID = '31'")
        let tags = try draft(fixture, track) { $0.artist = "새 아티스트" }
        #expect(try write(fixture, tags: [tags]).tagBlocked.first?.reason?.contains("상태") == true)
    }

}
