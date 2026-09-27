import DJCDomain
import DJCTestSupport
import Foundation
@testable import RekordboxKit
import Testing

/// 태그(곡 정보)를 rekordbox DB에 쓰기(#1). 음원 파일 태그는 건드리지 않는다.
/// 칸 모양은 rekordbox 7.2.18 실험 두 번에서 본 것이다(docs/rekordbox-internals.md "태그 (곡 정보)"):
/// - 2026-09-26 묶음 2, O-Ku-Ri-Mo-No Sunday!: 제목·아티스트(새 이름)·장르(새 이름)·코멘트
/// - 2026-09-27 "DJC 실험곡 1~5": 정보 패널에서 한 칸씩 저장(세션 1 넣기, 세션 2 비우기)
/// 앱이 쓰는 칸은 `RekordboxWriter.writableTagKeys`뿐이고, 여기서는 규칙을 시험하려고 모든 칸을 열어 쓴다.
@Suite("rekordbox 태그 쓰기")
struct RekordboxTagWriterTests {
    /// 2026-09-25 12:00:00.000 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let stamp = "2026-09-25 12:00:00.000 +00:00"
    static let allKeys = Set(TagFields.Key.allCases)

    func write(_ fixture: RekordboxFixture, tags: [TagDraft], drafts: [CueDraft] = [], keys: Set<TagFields.Key> = allKeys,
               dryRun: Bool = false) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: drafts, grids: [], gains: [:], tags: tags, analysisInputs: [:], to: fixture.database, dryRun: dryRun,
                                  now: now, backups: fixture.backups, shareRoot: fixture.shareRoot,
                                  attachesAnalysis: RekordboxWriter.attachesAnalysis, tagKeys: keys)
    }

    /// 곡 하나(아티스트 "옛 아티스트", 장르 "옛 장르", 앨범 "옛 앨범"(앨범 아티스트 NULL), 실험 곡처럼 상태 0).
    /// `shared`면 같은 이름을 쓰는 다른 곡(501)도 둔다(옛 이름 행이 버려지지 않게, 두 실험처럼).
    func library(shared: Bool = true) throws -> (RekordboxFixture, TrackSpec) {
        let fixture = try RekordboxFixture(localUpdateCount: 2000)
        return try fixture.withConnection {
            try fixture.insert("djmdArtist", ["ID": .text("11"), "Name": .text("옛 아티스트"), "UUID": .text("a-11"), "rb_local_deleted": .int(0),
                                              "rb_local_usn": .int(5)])
            try fixture.insert("djmdGenre", ["ID": .text("21"), "Name": .text("옛 장르"), "UUID": .text("g-21"), "rb_local_deleted": .int(0),
                                             "rb_local_usn": .int(6)])
            try fixture.insert("djmdAlbum", ["ID": .text("31"), "Name": .text("옛 앨범"), "UUID": .text("al-31"), "rb_local_deleted": .int(0),
                                             "rb_local_usn": .int(7)])
            var track = TrackSpec(id: "500", uuid: "track-uuid-500")
            track.title = "옛 제목"
            track.artistID = "11"
            track.albumID = "31"
            track.trackInfoUpdated = "3"
            try fixture.add(track)
            if shared {
                var neighbor = TrackSpec(id: "501", uuid: "track-uuid-501")
                neighbor.artistID = "11"
                neighbor.albumID = "31"
                try fixture.add(neighbor)
            }
            try fixture.execute("UPDATE djmdContent SET rb_data_status = 0, GenreID = '21', Commnt = '', ReleaseYear = 0, ReleaseDate = '', TrackNo = 0 WHERE ID IN ('500', '501')")
            return (fixture, track)
        }
    }

    func draft(_ fixture: RekordboxFixture, _ track: TrackSpec, _ edit: (inout TagFields) -> Void) throws -> TagDraft {
        let db = try fixture.open()
        defer { db.close() }
        let base = try #require(try RekordboxWriter.currentTags(db: db, contentID: track.id))
        var draft = TagDraft(trackUUID: track.uuid, base: base)
        edit(&draft.fields)
        return draft
    }

    func content(_ fixture: RekordboxFixture, _ id: String = "500") throws -> [String: String] {
        try #require(fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(id)]).first)
    }

    // MARK: 막기

    @Test func 규칙을_확인하지_않은_칸은_막고_아무것도_바꾸지_않는다() throws {
        let (fixture, track) = try library()
        let before = try content(fixture)
        let tags = try draft(fixture, track) { $0.title = "새 제목"; $0.albumArtist = "새 앨범 아티스트" }
        let report = try write(fixture, tags: [tags], keys: [.title])
        let blocked = try #require(report.tagBlocked.first)
        #expect(report.tagWritten.isEmpty && blocked.title == "옛 제목")
        #expect(blocked.reason?.contains("앨범 아티스트") == true && blocked.reason?.contains("제목") == false)
        #expect(try content(fixture) == before && fixture.localUpdateCount() == 2000)
    }

    @Test func 앱은_확인한_칸만_연다() throws {
        #expect(RekordboxWriter.writableTagKeys == Self.allKeys)
        let (fixture, track) = try library()
        let title = try draft(fixture, track) { $0.title = "새 제목" }
        let written = try RekordboxWriter.write(drafts: [], tags: [title], to: fixture.database, dryRun: false, now: now,
                                                backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(written.tagWritten.count == 1 && written.tagBlocked.isEmpty)
        let album = try draft(fixture, track) { $0.album = "새 앨범" }
        let albumReport = try RekordboxWriter.write(drafts: [], tags: [album], to: fixture.database, dryRun: false, now: now,
                                                backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(albumReport.tagWritten.count == 1 && albumReport.tagBlocked.isEmpty)
    }

    @Test func 초안을_만든_뒤_rekordbox에서_곡_정보가_바뀌었으면_쓰지_않는다() throws {
        let (fixture, track) = try library()
        let tags = try draft(fixture, track) { $0.comment = "새 코멘트" }
        // rekordbox에서 제목을 고쳤다(초안이 다루지 않는 칸이어도 막는다)
        try fixture.execute("UPDATE djmdContent SET Title = 'rekordbox에서 고친 제목' WHERE ID = '500'")
        let report = try write(fixture, tags: [tags])
        #expect(report.tagBlocked.first?.reason?.contains("rekordbox에서 곡 정보가 바뀌었습니다") == true)
        #expect(try content(fixture)["Commnt"] == "")
    }

    @Test func 초안에_문제가_있으면_막는다() throws {
        let (fixture, track) = try library()
        let cases: [(TagFields) -> TagFields] = [
            { var f = $0; f.title = " "; return f },
            { var f = $0; f.year = "이천"; return f },
            { var f = $0; f.trackNumber = "-3"; return f },
        ]
        for edit in cases {
            let tags = try draft(fixture, track) { $0 = edit($0) }
            let report = try write(fixture, tags: [tags])
            #expect(report.tagWritten.isEmpty && report.tagBlocked.count == 1, "\(tags.fields)")
        }
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test func 발매일이_있는_곡의_연도를_고치거나_비워도_발매일은_그대로다() throws {
        // 2026-09-27 태그 2단계 S3·S4, DJC 실험 태그 날짜: 연도 2012 → 2024 → 0, ReleaseDate 그대로.
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET ReleaseYear = 2012, ReleaseDate = '1968-09-27' WHERE ID = '500'")
        for year in ["2024", "0"] {
            let before = try content(fixture)
            let tags = try draft(fixture, track) { $0.year = year }
            #expect(try write(fixture, tags: [tags]).tagWritten.count == 1)
            let after = try content(fixture)
            #expect(after["ReleaseDate"] == "1968-09-27" && after["ReleaseYear"] == year)
            #expect(Set(after.keys.filter { after[$0] != before[$0] }).isSubset(of: ["ReleaseYear", "TrackInfoUpdated", "rb_local_usn", "updated_at"]))
        }
    }

    @Test func 없는_곡과_지운_곡은_막는다() throws {
        let (fixture, track) = try library()
        let tags = try draft(fixture, track) { $0.title = "새 제목" }
        var missing = tags
        missing.trackUUID = "no-such-track"
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '500'")
        let report = try write(fixture, tags: [missing, tags])
        #expect(report.tagBlocked.map(\.reason) == ["rekordbox 컬렉션에서 곡을 찾지 못했습니다", "rekordbox 컬렉션에서 지운 곡입니다"])
    }

    // MARK: 골든(2026-09-26 묶음 2)

    @Test func 제목_코멘트_새_아티스트_새_장르는_rekordbox_7이_고친_모양과_같다() throws {
        let (fixture, track) = try library()
        let before = try content(fixture)
        let tags = try draft(fixture, track) {
            $0.title = "새 제목"; $0.comment = "TEST"; $0.artist = "새 아티스트"; $0.genre = "test"
        }
        let report = try write(fixture, tags: [tags])
        let outcome = try #require(report.tagWritten.first)
        #expect(outcome.title == "옛 제목" && outcome.fields == ["title", "artist", "genre", "comment"])

        // 새 이름 행: rekordbox가 만든 행과 같은 칸(SearchStr NULL, 상태 0, created_at = updated_at)
        let artist = try #require(fixture.rows("SELECT * FROM djmdArtist WHERE Name = '새 아티스트'").first)
        let genre = try #require(fixture.rows("SELECT * FROM djmdGenre WHERE Name = 'test'").first)
        for row in [artist, genre] {
            for (key, value) in ["rb_data_status": "0", "rb_local_data_status": "0", "rb_local_deleted": "0", "rb_local_synced": "0",
                                 "usn": "NULL", "created_at": stamp, "updated_at": stamp] {
                #expect(row[key] == value, "\(key)")
            }
            #expect(UUID(uuidString: row["UUID"] ?? "") != nil && row["UUID"] == row["UUID"]?.lowercased())
            #expect((UInt32(row["ID"] ?? "") ?? 0) > 0)
        }
        #expect(artist["SearchStr"] == "NULL")
        // 다른 곡도 쓰는 옛 이름 행은 그대로 둔다
        #expect(try fixture.rows("SELECT rb_local_usn FROM djmdArtist WHERE ID = '11'").first?["rb_local_usn"] == "5")
        #expect(try fixture.rows("SELECT rb_local_usn FROM djmdGenre WHERE ID = '21'").first?["rb_local_usn"] == "6")
        // 아티스트를 고치면 그 곡의 앨범 행이 변경 번호·시각을 받는다(NULL 앨범 아티스트는 '', 2026-09-27 실험곡 5)
        let album = try #require(fixture.rows("SELECT quote(AlbumArtistID) AS aa, rb_local_usn, updated_at FROM djmdAlbum WHERE ID = '31'").first)
        #expect(album == ["aa": "''", "rb_local_usn": "2002", "updated_at": stamp])

        // 곡 행은 제자리: 바뀐 칸과 카운터·상태·변경 번호·시각만
        let after = try content(fixture)
        let changed = Set(after.keys.filter { after[$0] != before[$0] })
        #expect(changed == ["Title", "Commnt", "ArtistID", "GenreID", "TrackInfoUpdated", "rb_local_usn", "updated_at"])
        #expect(after["Title"] == "새 제목" && after["Commnt"] == "TEST")
        #expect(after["ArtistID"] == artist["ID"] && after["GenreID"] == genre["ID"])
        #expect(after["rb_data_status"] == "0" && after["updated_at"] == stamp)
        // 변경 번호: 새 이름 행과 앨범 행이 먼저, 곡 행이 마지막(묶음 2: 아티스트 1003475 → 앨범 1003477 → 장르 1003481 → 곡 1003728)
        #expect(artist["rb_local_usn"] == "2001" && genre["rb_local_usn"] == "2003" && after["rb_local_usn"] == "2004")
        #expect(try fixture.localUpdateCount() == 2004)
        // 한 칸에 하나씩(네 칸)
        #expect(after["TrackInfoUpdated"] == "7")
        #expect(try fixture.rows("SELECT typeof(TrackInfoUpdated) AS t FROM djmdContent WHERE ID = '500'").first?["t"] == "text")
    }

    // MARK: 골든(2026-09-27 DJC 실험곡 1~5)

    @Test func 곡_정보_변경_횟수는_바꾼_칸마다_하나씩() throws {
        // rekordbox 정보 패널은 칸마다 저장한다: 실험곡 1(제목·코멘트) '1' → '3', 실험곡 4(장르·작곡가·연도·트랙 번호) '1' → '5'
        let (fixture, track) = try library()
        try fixture.execute("UPDATE djmdContent SET TrackInfoUpdated = '1' WHERE ID = '500'")
        _ = try write(fixture, tags: [try draft(fixture, track) { $0.title = "DJC 실험곡 1 T"; $0.comment = "DJC 코멘트" }])
        #expect(try content(fixture)["TrackInfoUpdated"] == "3")
        _ = try write(fixture, tags: [try draft(fixture, track) {
            $0.genre = "DJC 태그 장르"; $0.composer = "DJC 태그 작곡가"; $0.year = "2024"; $0.trackNumber = "7"
        }])
        let row = try content(fixture)
        #expect(row["TrackInfoUpdated"] == "7" && row["ReleaseYear"] == "2024" && row["TrackNo"] == "7" && row["ReleaseDate"] == "")
        // 앨범 행은 아티스트·앨범을 고칠 때만 번호를 받는다
        #expect(try fixture.rows("SELECT rb_local_usn FROM djmdAlbum WHERE ID = '31'").first?["rb_local_usn"] == "7")
        // NULL(분석 전에 넣은 곡)이면 0에서
        try fixture.execute("UPDATE djmdContent SET TrackInfoUpdated = NULL WHERE ID = '500'")
        _ = try write(fixture, tags: [try draft(fixture, track) { $0.title = "또 새 제목" }])
        #expect(try content(fixture)["TrackInfoUpdated"] == "1")
    }

    @Test func 비우면_장르_0_작곡가_빈_글자_연도_트랙_0이고_버려진_이름_행은_지운다() throws {
        // 세션 2: 실험곡 4 장르·작곡가·연도·트랙 번호 비우기(GenreID '0', ComposerID '', 0, 0, 장르·작곡가 행 삭제), 실험곡 1 코멘트 비우기('')
        let (fixture, track) = try library()
        _ = try write(fixture, tags: [try draft(fixture, track) {
            $0.genre = "DJC 태그 장르"; $0.composer = "DJC 태그 작곡가"; $0.year = "2024"; $0.trackNumber = "7"; $0.comment = "DJC 코멘트"
        }])
        let album = try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'")
        _ = try write(fixture, tags: [try draft(fixture, track) {
            $0.genre = ""; $0.composer = ""; $0.year = ""; $0.trackNumber = "0"; $0.comment = ""
        }])
        let row = try #require(fixture.rows("""
            SELECT quote(GenreID) AS g, quote(ComposerID) AS c, ReleaseYear, TrackNo, quote(Commnt) AS m FROM djmdContent WHERE ID = '500'
            """).first)
        #expect(row == ["g": "'0'", "c": "''", "ReleaseYear": "0", "TrackNo": "0", "m": "''"])
        #expect(try fixture.rows("SELECT * FROM djmdGenre WHERE Name = 'DJC 태그 장르'").isEmpty)
        #expect(try fixture.rows("SELECT * FROM djmdArtist WHERE Name = 'DJC 태그 작곡가'").isEmpty)
        #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'") == album, "앨범 행은 그대로")
        #expect(try content(fixture)["TrackInfoUpdated"] == "13", "3 + 다섯 칸 + 다섯 칸")
    }

    @Test func 아티스트를_바꾸면_버려진_옛_행은_지우고_다른_곡이_쓰는_행은_둔다() throws {
        // 실험곡 2: 아티스트 → 새 이름 A → 새 이름 B. A는 아무 곡도 안 쓰게 되어 지워졌고, 원래 이름은 다른 곡이 써서 남았다.
        let (fixture, track) = try library()
        _ = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 태그 아티스트 A" }])
        let a = try #require(fixture.rows("SELECT ID FROM djmdArtist WHERE Name = 'DJC 태그 아티스트 A'").first?["ID"])
        _ = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "DJC 태그 아티스트 B" }])
        #expect(try fixture.rows("SELECT * FROM djmdArtist WHERE ID = ?", [.text(a)]).isEmpty)
        #expect(try fixture.rows("SELECT * FROM djmdArtist WHERE ID = '11'").count == 1)
        let b = try #require(fixture.rows("SELECT * FROM djmdArtist WHERE Name = 'DJC 태그 아티스트 B'").first)
        #expect(try content(fixture)["ArtistID"] == b["ID"] && content(fixture)["TrackInfoUpdated"] == "5")
        // 다른 곡이 없으면 원래 이름 행도 지운다(같은 규칙)
        let (alone, solo) = try library(shared: false)
        _ = try write(alone, tags: [try draft(alone, solo) { $0.artist = "DJC 태그 아티스트 A" }])
        #expect(try alone.rows("SELECT * FROM djmdArtist WHERE ID = '11'").isEmpty)
    }

    @Test func 이미_있는_이름은_그_행을_쓰고_앨범_행에_변경_번호를_준다() throws {
        // 실험곡 5: 아티스트 → 이미 있는 이름. 새 행 없이 그 ID를 쓰고, 곡의 앨범 행 AlbumArtistID NULL → ''·변경 번호·시각.
        let (fixture, track) = try library()
        try fixture.insert("djmdArtist", ["ID": .text("12"), "Name": .text("있는 이름"), "UUID": .text("a-12"), "rb_local_deleted": .int(0),
                                          "rb_local_usn": .int(8)])
        _ = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "있는 이름"; $0.composer = "있는 이름" }])
        #expect(try fixture.rows("SELECT count(*) AS n FROM djmdArtist").first?["n"] == "2")
        let row = try content(fixture)
        #expect(row["ArtistID"] == "12" && row["ComposerID"] == "12" && row["rb_local_usn"] == "2002")
        let album = try #require(fixture.rows("SELECT quote(AlbumArtistID) AS aa, rb_local_usn FROM djmdAlbum WHERE ID = '31'").first)
        #expect(album == ["aa": "''", "rb_local_usn": "2001"])
        // 앨범 아티스트가 있는 앨범은 그 값을 둔다(묶음 2: AlbumArtistID 그대로, 변경 번호·시각만)
        try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'")
        _ = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "옛 아티스트" }])
        #expect(try fixture.rows("SELECT AlbumArtistID, rb_local_usn FROM djmdAlbum WHERE ID = '31'").first == ["AlbumArtistID": "11", "rb_local_usn": "2003"])
        // 앨범이 없는 곡은 앨범 행을 건드리지 않는다
        try fixture.execute("UPDATE djmdContent SET AlbumID = '' WHERE ID = '500'")
        _ = try write(fixture, tags: [try draft(fixture, track) { $0.artist = "있는 이름" }])
        #expect(try fixture.localUpdateCount() == 2005)
    }

    @Test func 앨범을_비우면_빈_글자이고_버려진_앨범_행은_지우되_앨범_아티스트_행은_둔다() throws {
        // 실험곡 3 세션 2: AlbumID '', 앨범 행 삭제, 앨범 아티스트 행은 남음. 앨범 아티스트도 함께 빈칸.
        let (fixture, track) = try library(shared: false)
        try fixture.insert("djmdArtist", ["ID": .text("13"), "Name": .text("앨범 아티스트"), "UUID": .text("a-13"), "rb_local_deleted": .int(0)])
        try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '13' WHERE ID = '31'")
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.album = "" }])
        #expect(report.tagWritten.first?.fields == ["album"])
        let row = try #require(fixture.rows("SELECT quote(AlbumID) AS al, TrackInfoUpdated FROM djmdContent WHERE ID = '500'").first)
        #expect(row == ["al": "''", "TrackInfoUpdated": "4"])
        #expect(try fixture.rows("SELECT * FROM djmdAlbum WHERE ID = '31'").isEmpty)
        #expect(try fixture.rows("SELECT * FROM djmdArtist WHERE ID = '13'").count == 1)
        // 앨범 아티스트를 함께 비워도 한 번 저장(rekordbox가 함께 비운다)
        let (other, second) = try library(shared: false)
        try other.insert("djmdArtist", ["ID": .text("13"), "Name": .text("앨범 아티스트"), "UUID": .text("a-13"), "rb_local_deleted": .int(0)])
        try other.execute("UPDATE djmdAlbum SET AlbumArtistID = '13' WHERE ID = '31'")
        _ = try write(other, tags: [try draft(other, second) { $0.album = ""; $0.albumArtist = "" }])
        #expect(try content(other)["TrackInfoUpdated"] == "4")
    }

    // MARK: 규칙

    @Test func 숫자_칸은_정수로() throws {
        let (fixture, track) = try library()
        let tags = try draft(fixture, track) { $0.year = "02024"; $0.trackNumber = "7" }
        _ = try write(fixture, tags: [tags])
        let row = try content(fixture)
        #expect(row["ReleaseYear"] == "2024" && row["TrackNo"] == "7")
        #expect(try fixture.rows("SELECT typeof(ReleaseYear) AS y, typeof(TrackNo) AS t FROM djmdContent WHERE ID = '500'").first
            == ["y": "integer", "t": "integer"])
        let cleared = try draft(fixture, track) { $0.year = ""; $0.trackNumber = "" }
        _ = try write(fixture, tags: [cleared])
        #expect(try content(fixture)["ReleaseYear"] == "0" && content(fixture)["TrackNo"] == "0")
    }

    @Test func 큐와_태그를_같은_곡에_쓰면_곡_행이_마지막_번호를_받는다() throws {
        let (fixture, _) = try library()
        var track = TrackSpec(id: "600", uuid: "track-uuid-600")
        track.cues = [.autoCue(at: 1024)]
        try fixture.add(track)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = '600'")
        var cues = CueDraft(trackUUID: track.uuid, rekordboxCues: track.rekordboxCues)
        cues.place(EditableCue(kind: .memory, time: 20.123))
        let tags = try draft(fixture, track) { $0.title = "큐와 태그" }
        let report = try write(fixture, tags: [tags], drafts: [cues])
        #expect(report.written.count == 1 && report.tagWritten.count == 1)
        let record = try #require(fixture.rows("SELECT rb_local_usn FROM contentCue WHERE ContentID = '600'").first)
        #expect(try record["rb_local_usn"] == "2001" && content(fixture, "600")["rb_local_usn"] == "2003")
        #expect(try content(fixture, "600")["Title"] == "큐와 태그" && fixture.localUpdateCount() == 2003)
    }

    @Test func 분석을_붙이는_곡에도_태그를_쓴다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 5000)
        try fixture.add(TrackSpec())   // 라이브러리 공통값
        let url = fixture.audio.appending(path: "tagged.mp3")
        try FileManager.default.copyItem(at: try TestResources.url("mp3-tagged.mp3"), to: url)
        let plan = try TrackAddPlan.make(url: url, tags: try await AudioTags.read(url: url), now: now)
        let added = try RekordboxTrackWriter.add([plan], to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
        let id = try #require(added.added.first?.contentID), uuid = try #require(added.added.first?.uuid)
        let db = try fixture.open()
        let base = try #require(try RekordboxWriter.currentTags(db: db, contentID: id))
        db.close()
        var tags = TagDraft(trackUUID: uuid, base: base)
        tags.fields.title = "분석과 태그"
        let report = try RekordboxWriter.write(
            drafts: [], grids: [GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)])],
            gains: [:], tags: [tags], analysisInputs: [uuid: .init(duration: plan.duration, loudness: -8, peak: 0.9)], to: fixture.database,
            dryRun: false, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot, attachesAnalysis: true, tagKeys: Self.allKeys)
        #expect(report.analysisWritten.count == 1 && report.tagWritten.count == 1)
        // 분석 붙이기가 '1'로 두고 태그가 하나 더(커밋 뒤 검증도 통과해야 한다)
        let row = try content(fixture, id)
        #expect(row["Title"] == "분석과 태그" && row["TrackInfoUpdated"] == "2" && row["Analysed"] == "105")
        #expect(try Int(row["rb_local_usn"] ?? "") == fixture.localUpdateCount(), "곡 행이 마지막 번호")
    }

    @Test func 시험_실행은_쓰고_되돌린다() throws {
        let (fixture, track) = try library()
        let before = try content(fixture)
        let tags = try draft(fixture, track) { $0.title = "새 제목"; $0.artist = "새 아티스트" }
        let report = try write(fixture, tags: [tags], dryRun: true)
        #expect(report.tagWritten.count == 1 && report.backup == nil)
        #expect(try content(fixture) == before && fixture.rows("SELECT * FROM djmdArtist WHERE Name = '새 아티스트'").isEmpty)
    }

    @Test func 백업에_쓴_태그_초안을_두고_되돌리면_rekordbox와_초안을_살린다() throws {
        let (fixture, track) = try library()
        let tags = try draft(fixture, track) { $0.title = "새 제목" }
        let report = try write(fixture, tags: [tags])
        let backup = URL(filePath: try #require(report.backup))
        #expect(RekordboxWriter.tagDrafts(in: backup) == [tags])
        let saved = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        #expect(saved.titles == ["옛 제목"] && saved.report?.tagWritten.count == 1)
        try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups)
        #expect(try content(fixture)["Title"] == "옛 제목")
    }

    @Test func 옛_보고서도_읽는다() throws {
        let old = #"{"outcomes":[{"trackUUID":"u","title":"t","status":"written","removed":0,"added":1}],"dryRun":false,"createdAt":"x"}"#
        let report = try JSONDecoder().decode(RekordboxWriter.Report.self, from: Data(old.utf8))
        #expect(report.tagOutcomes == nil && report.tagWritten.isEmpty && report.written.first?.fields == nil)
    }
}
