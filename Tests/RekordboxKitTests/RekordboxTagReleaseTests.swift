import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 버려질 옛 이름·앨범 행은 트랜잭션 안에서 곡·앨범·새 이름 행을 실제로 쓴 뒤 실제 참조 수로 정한다(#173 3차 리뷰).
/// 미리 계산한 참조가 실제 쓰기와 어긋나 쓰기 전체가 되돌려지던 문제(앨범 아티스트와 아티스트를 같은 새 이름으로)를 다시 보지 않게 하고,
/// "여러 칸을 한 번에 쓴 결과 = 같은 칸을 하나씩 저장한 결과"(rekordbox 정보 패널은 칸마다 저장한다)를 칸 조합마다 본다.
extension RekordboxTagWriterTests {
    // MARK: probe: 한 곡짜리 앨범의 앨범 아티스트가 곡의 아티스트일 때 둘을 같은 새 이름으로

    @Test(arguments: [0, 256]) func 앨범_아티스트와_아티스트를_같은_새_이름으로_바꿔도_옛_아티스트를_정리하고_큐·그리드는_그대로_쓴다(state: Int) throws {
        let (fixture, track) = try library(shared: false)
        try fixture.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'")
        try fixture.execute("UPDATE djmdContent SET rb_data_status = ? WHERE ID = '500'", [.int(state)])
        for (table, id) in [("djmdArtist", "11"), ("djmdAlbum", "31")] { try sync(fixture, table, id, state: state) }
        // 같은 쓰기의 큐(곡 600)와 그리드(분석 파일이 있는 곡)
        var cued = TrackSpec(id: "600", uuid: "track-uuid-600")
        cued.cues = [.autoCue(at: 1024)]
        try fixture.add(cued)
        var cues = CueDraft(trackUUID: cued.uuid, rekordboxCues: cued.rekordboxCues)
        cues.place(EditableCue(kind: .memory, time: 20.123))
        let (gridTrack, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        var grid = GridDraft(trackUUID: gridTrack.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: gridTrack)))
        grid.setBPM(130, at: 0)
        let tags = try draft(fixture, track) { $0.artist = "PROBE Z"; $0.albumArtist = "PROBE Z" }
        let report = try RekordboxWriter.write(drafts: [cues], grids: [grid], gains: [:], tags: [tags], analysisInputs: [:], to: fixture.database,
                                               dryRun: false, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot,
                                               attachesAnalysis: false, tagKeys: Self.allKeys)
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        #expect(report.written.count == 1 && report.gridWritten.count == 1, "같은 쓰기의 큐·그리드는 되돌려지지 않는다")
        let probe = try #require(fixture.rows("SELECT ID FROM djmdArtist WHERE Name = 'PROBE Z'").first?["ID"])
        #expect(try content(fixture)["ArtistID"] == probe && row(fixture, "djmdAlbum", "31")?["AlbumArtistID"] == probe)
        let old = try row(fixture, "djmdArtist", "11")
        if state == 0 {
            #expect(old == nil, "상태 0 옛 아티스트는 지운다")
        } else {
            #expect(old?["rb_data_status"] == "258" && old?["rb_local_deleted"] == "1", "동기화 옛 아티스트는 258")
        }
        #expect(try fixture.rows("SELECT count(*) AS n FROM djmdCue WHERE ContentID = '600'").first?["n"] == "2")
    }

    // MARK: 이름 행 상태·참조 칸

    @Test func 이름_행_상태는_없음·지움·상태_없음·값을_구분한다() throws {
        let (fixture, _) = try library()
        let db = try fixture.open()
        defer { db.close() }
        #expect(try RekordboxWriter.liveNameState(db, table: .album, id: "31") == .live(status: 0))
        #expect(try RekordboxWriter.liveNameState(db, table: .artist, id: "11") == .live(status: 0))
        #expect(try RekordboxWriter.liveNameState(db, table: .genre, id: "없는 ID") == .missing)
        try fixture.execute("UPDATE djmdAlbum SET rb_data_status = 256 WHERE ID = '31'")
        try fixture.execute("UPDATE djmdArtist SET rb_data_status = NULL WHERE ID = '11'")
        try fixture.execute("UPDATE djmdGenre SET rb_local_deleted = 1 WHERE ID = '21'")
        #expect(try RekordboxWriter.liveNameState(db, table: .album, id: "31") == .live(status: 256))
        #expect(try RekordboxWriter.liveNameState(db, table: .artist, id: "11") == .live(status: nil))
        #expect(try RekordboxWriter.liveNameState(db, table: .genre, id: "21") == .missing, "이미 지운 행은 없는 것과 같다")
    }

    @Test func 곡_행이_이름을_가리키는_칸은_표마다_정해져_있다() {
        #expect(RekordboxTrackWriter.contentReferenceColumns(table: .artist) == ["ArtistID", "ComposerID", "OrgArtistID", "RemixerID"])
        #expect(RekordboxTrackWriter.contentReferenceColumns(table: .album) == ["AlbumID"])
        #expect(RekordboxTrackWriter.contentReferenceColumns(table: .genre) == ["GenreID"])
    }

    // MARK: 여러 칸을 한 번에 쓴 결과 = 하나씩 저장한 결과

    /// 칸 조합 하나: 바꿀 칸(둘 이상), 값 종류(새 이름·있는 이름·비우기), 곡·이름·앨범 행 상태(0·256)
    struct ReleaseCombination: Sendable, CustomTestStringConvertible {
        var keys: [TagFields.Key]
        var kind: String
        var state: Int
        var testDescription: String { "\(keys.map(\.rawValue).joined(separator: "+")) \(kind) \(state)" }
    }

    /// 아티스트·앨범 아티스트·앨범·작곡가는 아티스트 표와 앨범 표의 같은 행을 나눠 쓰고 서로 버리는 순서에 얽히므로(앨범 아티스트와 아티스트를 같은
    /// 새 이름으로, 앨범을 옮기며 앨범 아티스트 놓기 …) 둘 이상의 모든 조합을 본다. 장르는 자기 표만 쓰는 칸이라 얽히지 않는다: 앨범 행·아티스트 행
    /// 옆에서 변경 번호 순서가 어긋나지 않는지 앨범·아티스트와의 짝과 다섯 칸 모두만 본다. 칸마다 새 이름·있는 이름·비우기 × 상태 0·256.
    /// 평소에는 칸 묶음 × 값 종류를 모두 보고 상태는 짝 조합(pairwise)으로 고른다: 칸 묶음마다 상태 0·256이 다 나오고, 값 종류마다도 두 상태가
    /// 다 나온다(84 → 42가지, #167 CI 시간). 열 칸 전체 조합 × 값 종류 × 상태(156가지)는 `DJC_FULL_RELEASE_COMBINATIONS=1`로 돌린다(#194).
    /// 키·코멘트 비우기와의 조합은 `RekordboxTagKeyTests`의 키 짝과 `RekordboxTagSyncedTests`(코멘트 비우기)가 따로 본다.
    static let releaseCombinations: [ReleaseCombination] = {
        let fields: [TagFields.Key] = [.album, .albumArtist, .artist, .genre, .composer]
        let full = ProcessInfo.processInfo.environment["DJC_FULL_RELEASE_COMBINATIONS"] == "1"
        var subsets: [[TagFields.Key]] = []
        for mask in 1..<(1 << fields.count) where mask.nonzeroBitCount >= 2 {
            let keys = fields.indices.filter { mask & (1 << $0) != 0 }.map { fields[$0] }
            let related = keys.filter { $0 != .genre }
            let genrePair = keys.contains(.genre) && (keys.count == fields.count || (keys.count == 2 && (related == [.album] || related == [.artist])))
            if full || (related.count >= 2 && !keys.contains(.genre)) || genrePair { subsets.append(keys) }
        }
        let kinds = ["new", "existing", "clear"]
        return subsets.enumerated().flatMap { index, keys in
            kinds.enumerated().flatMap { kindIndex, kind in
                (full ? [0, 256] : [(index + kindIndex) % 2 == 0 ? 0 : 256]).map { ReleaseCombination(keys: keys, kind: kind, state: $0) }
            }
        }
    }()

    @Test func 줄인_조합도_칸_묶음과_값_종류마다_두_상태를_모두_본다() {
        let combinations = Self.releaseCombinations
        let subsets = Set(combinations.map(\.keys))
        for keys in subsets { #expect(Set(combinations.filter { $0.keys == keys }.map(\.state)) == [0, 256], "\(keys)") }
        for kind in ["new", "existing", "clear"] { #expect(Set(combinations.filter { $0.kind == kind }.map(\.state)) == [0, 256]) }
        #expect(Set(combinations.map { "\($0.keys) \($0.kind)" }).count == subsets.count * 3, "칸 묶음 × 값 종류는 모두")
    }

    /// 곡 500(아티스트 11 = 앨범 31의 앨범 아티스트, 작곡가 14, 장르 21, 한 곡짜리 앨범 31)과 붙일 수 있는 있는 이름
    /// (아티스트 12, 장르 22, "있는 이름"일 때만 앨범 아티스트가 같은 앨범 32: 그 앨범이 아티스트 11을 계속 가리키므로 다른 값 종류에서는
    /// 두지 않아 11이 버려지는 경우도 본다). 곡·이름·앨범 행은 모두 `state`.
    func releaseLibrary(state: Int, kind: String) throws -> (RekordboxFixture, TrackSpec) {
        let (fixture, track) = try library(shared: false)
        // 조합마다 두 번 준비하므로 연결 하나로 쓴다(연결을 열 때마다 SQLCipher 키 유도가 든다)
        try fixture.session { db in
            try db.insert("djmdArtist", ["ID": .text("12"), "Name": .text("있는 아티스트"), "UUID": .text("a-12")])
            try db.insert("djmdArtist", ["ID": .text("14"), "Name": .text("옛 작곡가"), "UUID": .text("a-14")])
            try db.insert("djmdGenre", ["ID": .text("22"), "Name": .text("있는 장르"), "UUID": .text("g-22")])
            if kind == "existing" {
                try db.insert("djmdAlbum", ["ID": .text("32"), "Name": .text("있는 앨범"), "AlbumArtistID": .text("11"), "UUID": .text("al-32")])
                try sync(db, "djmdAlbum", "32", state: state)
            }
            try db.execute("UPDATE djmdAlbum SET AlbumArtistID = '11' WHERE ID = '31'")
            try db.execute("UPDATE djmdContent SET ComposerID = '14', rb_data_status = ? WHERE ID = '500'", [.int(state)])
            for (table, id) in [("djmdArtist", "11"), ("djmdArtist", "12"), ("djmdArtist", "14"), ("djmdGenre", "21"), ("djmdGenre", "22"),
                                ("djmdAlbum", "31")] {
                try sync(db, table, id, state: state)
            }
        }
        return (fixture, track)
    }

    func value(_ key: TagFields.Key, kind: String) -> String {
        switch kind {
        case "new": [.album: "DJC 173 새 앨범", .genre: "DJC 173 새 장르"][key] ?? "DJC 173 새 이름"
        case "existing": [.album: "있는 앨범", .genre: "있는 장르"][key] ?? "있는 아티스트"
        default: ""
        }
    }

    /// 번호 값·시각·ID·UUID 없이 비교할 모양(곡 행, 살아 있거나 258인 이름·앨범 행). 외래 키는 가리키는 이름으로.
    func releaseState(_ fixture: RekordboxFixture) throws -> [String] {
        try fixture.session { try releaseState($0) }
    }

    func releaseState(_ session: RekordboxFixture.Session) throws -> [String] {
        /// 외래 키 칸을 NULL·빈 글자·'0'·가리키는 이름으로
        func named(_ column: String, _ name: String) -> String {
            "CASE WHEN \(column) IS NULL THEN '(NULL)' WHEN \(column) = '' THEN '(빈)' WHEN \(column) = '0' THEN '(0)' ELSE ifnull(\(name), '(없음)') END"
        }
        func lines(_ sql: String, _ prefix: String) throws -> [String] {
            try session.rows(sql).map { row in prefix + " " + row.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }.sorted()
        }
        let track = try lines("""
            SELECT c.Title, c.TrackInfoUpdated, c.rb_data_status, \(named("c.ArtistID", "a.Name")) AS artist, \(named("c.ComposerID", "cp.Name")) AS composer,
                \(named("c.GenreID", "g.Name")) AS genre, \(named("c.AlbumID", "al.Name")) AS album, al.rb_data_status AS albumState
            FROM djmdContent c LEFT JOIN djmdArtist a ON a.ID = c.ArtistID LEFT JOIN djmdArtist cp ON cp.ID = c.ComposerID
            LEFT JOIN djmdGenre g ON g.ID = c.GenreID LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID WHERE c.ID = '500'
            """, "곡")
        let common = "t.Name, t.rb_data_status, t.rb_local_deleted, quote(t.usn) AS usn, t.rb_local_synced"
        return track + (try lines("SELECT \(common) FROM djmdArtist t", "아티스트")) + (try lines("SELECT \(common) FROM djmdGenre t", "장르"))
            + (try lines("""
                SELECT \(common), \(named("t.AlbumArtistID", "aa.Name")) AS albumArtist FROM djmdAlbum t LEFT JOIN djmdArtist aa ON aa.ID = t.AlbumArtistID
                """, "앨범"))
    }

    @Test(arguments: releaseCombinations) func 여러_칸을_한_번에_쓴_결과는_칸마다_하나씩_쓴_결과와_같다(combination: ReleaseCombination) throws {
        let keys = combination.keys, kind = combination.kind
        let (together, track) = try releaseLibrary(state: combination.state, kind: kind)
        let report = try write(together, tags: [try draft(together, track) { fields in for key in keys { fields[key] = value(key, kind: kind) } }])
        // 앨범과 앨범 아티스트를 함께 바꾸는 것은(비우기 말고) 한 칸씩 쓰라고 막는다(규칙 미확인). 하나씩 쓰면 쓸 수 있으므로 비교하지 않는다.
        if keys.contains(.album), keys.contains(.albumArtist), kind != "clear" {
            #expect(report.tagWritten.isEmpty && report.tagBlocked.first?.reason?.contains("한 칸씩") == true)
            return
        }
        let (oneByOne, same) = try releaseLibrary(state: combination.state, kind: kind)
        var blocked = false
        for key in keys {
            let step = try draft(oneByOne, same) { $0[key] = value(key, kind: kind) }
            guard step.hasChanges else { continue }   // 앨범을 비우면 앨범 아티스트도 함께 비워진다
            let stepReport = try write(oneByOne, tags: [step])
            if !stepReport.tagBlocked.isEmpty { blocked = true; break }
        }
        #expect(report.tagBlocked.isEmpty == !blocked, "막히면 양쪽이 같이 막힌다")
        guard !blocked else { return }
        #expect(report.tagWritten.count == 1)
        #expect(try releaseState(together) == releaseState(oneByOne))
    }
}
