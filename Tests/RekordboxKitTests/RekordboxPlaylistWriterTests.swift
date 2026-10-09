import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 재생 목록 쓰기(#38). 기대값은 rekordbox 7.2.18에서 "DJC 실험" 폴더로 직접 한 결과다
/// (2026-09-26 23:36~09-27 00:07 KST, 합성 곡 "DJC 실험곡 1~5", 단계마다 `djc lab playlist-watch`로 떠서 비교).
/// ID·UUID는 무작위라 형식만 본다.
@Suite("rekordbox 재생 목록 쓰기 — 실험으로 확인한 모양")
struct RekordboxPlaylistWriterTests {
    /// 2026-09-25 12:00:00.000 UTC
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let stamp = "2026-09-25 12:00:00.000 +00:00"
    let old = "2026-01-01 00:00:00.000 +00:00"
    let nowMS: Int64 = 1_790_337_600_000

    /// 곡 다섯 개(ID 101~105)와 빈 masterPlaylists6.xml이 있는 라이브러리
    func library(_ playlists: [PlaylistSpec] = []) throws -> RekordboxFixture {
        let fixture = try RekordboxFixture(localUpdateCount: 1000)
        for id in 101...105 { try fixture.add(TrackSpec(id: String(id))) }
        var xml = MasterPlaylistsXMLTests.empty
        for playlist in playlists {
            try fixture.add(playlist)
            var parsed = MasterPlaylistsXML(text: xml)
            try parsed.append(id: playlist.id, parentID: playlist.parentID, isFolder: playlist.isFolder, timestamp: 1_000)
            xml = parsed.text
        }
        try xml.write(to: xmlURL(fixture), atomically: true, encoding: .utf8)
        return fixture
    }

    func xmlURL(_ fixture: RekordboxFixture) -> URL { fixture.root.appending(path: "masterPlaylists6.xml") }

    func xml(_ fixture: RekordboxFixture) throws -> MasterPlaylistsXML { try MasterPlaylistsXML(contentsOf: xmlURL(fixture)) }

    @discardableResult
    func write(_ fixture: RekordboxFixture, _ edits: [PlaylistEdit], dryRun: Bool = false) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: [], playlists: edits, to: fixture.database, dryRun: dryRun, now: now, backups: fixture.backups)
    }

    func row(_ fixture: RekordboxFixture, _ id: String) throws -> [String: String] {
        try #require(try fixture.rows("SELECT * FROM djmdPlaylist WHERE ID = ?", [.text(id)]).first)
    }

    func entries(_ fixture: RekordboxFixture, _ playlistID: String) throws -> [[String: String]] {
        try fixture.rows("SELECT * FROM djmdSongPlaylist WHERE PlaylistID = ? ORDER BY TrackNo", [.text(playlistID)])
    }

    func isUUID(_ text: String?) -> Bool {
        (text ?? "").range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    // MARK: 만들기

    @Test func 새_목록은_부모_맨_위에_생기고_형제는_Seq_순서로_번호를_하나씩_받는다() throws {
        // 단계 5 "DJC 2 빼기": 형제가 있는 폴더에 만들면 번호 하나를 비우고 새 행 → 형제(Seq 순서) → 거울 행, 이름을 붙이면 새 행 번호가 한 번 더 오른다.
        let folder = PlaylistSpec(id: "100", name: "DJC 실험", seq: 1, isFolder: true)
        let a = PlaylistSpec(id: "201", name: "가", parentID: "100", seq: 1)
        let b = PlaylistSpec(id: "202", name: "나", parentID: "100", seq: 2)
        let other = PlaylistSpec(id: "300", name: "맨 위 다른 목록", seq: 2)
        let fixture = try library([folder, a, b, other])

        let report = try write(fixture, [.create(key: "n", name: "새 목록", isFolder: false, parent: .id("100"))])
        let outcome = try #require(report.playlistOutcomes?.first)
        #expect(outcome.status == .written && outcome.name == "새 목록")
        let id = try #require(outcome.playlistID)
        #expect((UInt64(id) ?? 0) >= 1 && (UInt64(id) ?? 0) <= UInt64(UInt32.max))

        let r = try row(fixture, id)
        let expected: [String: String] = [
            "Seq": "1", "Name": "새 목록", "ImagePath": "NULL", "Attribute": "0", "ParentID": "100", "SmartList": "NULL",
            "rb_data_status": "0", "rb_local_data_status": "0", "rb_local_deleted": "0", "rb_local_synced": "0", "usn": "NULL",
            "rb_local_usn": "1006", "created_at": stamp, "updated_at": stamp,
        ]
        for (key, value) in expected { #expect(r[key] == value, "\(key)") }
        #expect(isUUID(r["UUID"]))

        // 형제: Seq +1, 번호는 Seq 순서로 하나씩(1001은 비움, 1002는 새 행이 먼저 받았다가 이름 붙일 때 1006으로)
        let ra = try row(fixture, "201"), rb = try row(fixture, "202")
        #expect(ra["Seq"] == "2" && ra["rb_local_usn"] == "1003" && ra["rb_data_status"] == "257" && ra["usn"] == "20" && ra["updated_at"] == stamp)
        #expect(rb["Seq"] == "3" && rb["rb_local_usn"] == "1004" && rb["rb_data_status"] == "257")
        // 다른 층은 그대로
        let ro = try row(fixture, "300")
        #expect(ro["Seq"] == "2" && ro["rb_local_usn"] == "20" && ro["updated_at"] == old)

        // 거울 행
        let mirror = try #require(try fixture.rows("SELECT * FROM djmdCloudFilterPlaylist WHERE PlaylistUUID = ?", [.text(r["UUID"]!)]).first)
        let mirrorExpected: [String: String] = [
            "Seq": "0", "ParentID": "NULL", "rb_data_status": "0", "rb_local_data_status": "0", "rb_local_deleted": "0",
            "rb_local_synced": "0", "usn": "NULL", "rb_local_usn": "1005", "created_at": stamp, "updated_at": stamp,
        ]
        for (key, value) in mirrorExpected { #expect(mirror[key] == value, "거울 \(key)") }
        #expect(isUUID(mirror["UUID"]) && UInt32(mirror["ID"] ?? "") != nil)
        #expect(try fixture.localUpdateCount() == 1006)

        // XML: 새 NODE를 끝에, 부모 폴더 Timestamp는 지금
        let parsed = try xml(fixture)
        let node = try #require(parsed.nodes.last)
        #expect(node.id == MasterPlaylistsXML.hex(id) && node.parentID == "64" && node.attribute == 0 && node.timestamp == nowMS)
        #expect(node.libType == 0 && node.checkType == 0)
        #expect(parsed.node(id: "100")?.timestamp == nowMS && parsed.node(id: "201")?.timestamp == 1_000)
    }

    @Test func 빈_폴더에_만들면_번호를_비우지_않는다() throws {
        // 단계 3 "DJC 1 넣기"·단계 8 "가1": 형제가 없으면 새 행 → 거울 행 → 이름(비우는 번호 없음)
        let fixture = try library([PlaylistSpec(id: "100", name: "DJC 실험", seq: 1, isFolder: true)])
        let report = try write(fixture, [.create(key: "n", name: "가1", isFolder: false, parent: .id("100"))])
        let id = try #require(report.playlistOutcomes?.first?.playlistID)
        #expect(try row(fixture, id)["rb_local_usn"] == "1003")
        #expect(try fixture.rows("SELECT rb_local_usn FROM djmdCloudFilterPlaylist WHERE PlaylistUUID = ?",
                                 [.text(try row(fixture, id)["UUID"]!)]).first?["rb_local_usn"] == "1002")
        #expect(try fixture.localUpdateCount() == 1003)
    }

    @Test func 맨_위에_폴더를_만들고_그_안에_목록을_만든다() throws {
        // 단계 2 "DJC 실험"(맨 위 폴더) → 단계 3 그 안 목록. 뒤 편집은 new:키로 새 폴더를 가리킨다.
        let fixture = try library([PlaylistSpec(id: "300", name: "있던 목록", seq: 1)])
        let report = try write(fixture, [
            .create(key: "f", name: "DJC 실험", isFolder: true, parent: .root),
            .create(key: "p", name: "DJC 1 넣기", isFolder: false, parent: .new("f")),
        ])
        let folderID = try #require(report.playlistOutcomes?[0].playlistID)
        let playlistID = try #require(report.playlistOutcomes?[1].playlistID)
        let folder = try row(fixture, folderID)
        #expect(folder["Attribute"] == "1" && folder["ParentID"] == "root" && folder["Seq"] == "1")
        #expect(try row(fixture, playlistID)["ParentID"] == folderID)
        #expect(try row(fixture, "300")["Seq"] == "2")
        // 폴더: 비움 1001 · 새 행 1002 · 형제 1003 · 거울 1004 · 이름 1005 / 목록: 새 행 1006 · 거울 1007 · 이름 1008
        #expect(try folder["rb_local_usn"] == "1005" && (try row(fixture, playlistID))["rb_local_usn"] == "1008")
        let nodes = try xml(fixture).nodes
        #expect(nodes.suffix(2).map(\.parentID) == ["0", MasterPlaylistsXML.hex(folderID)] && nodes.suffix(2).map(\.attribute) == [1, 0])
        #expect(try xml(fixture).node(id: folderID)?.timestamp == nowMS)
    }

    // MARK: 이름·옮기기·순서

    @Test func 이름을_바꾸면_그_행의_이름과_번호만_바뀐다() throws {
        // 단계 7 "DJC 5 이름" → "DJC 5 새 이름"
        let fixture = try library([PlaylistSpec(id: "201", name: "DJC 5 이름", seq: 1), PlaylistSpec(id: "202", name: "옆", seq: 2)])
        try write(fixture, [.rename(playlist: .id("201"), name: "DJC 5 새 이름")])
        let r = try row(fixture, "201")
        #expect(r["Name"] == "DJC 5 새 이름" && r["rb_local_usn"] == "1001" && r["rb_data_status"] == "257" && r["updated_at"] == stamp)
        #expect(r["Seq"] == "1" && r["usn"] == "20" && r["created_at"] == old)
        #expect(try row(fixture, "202")["rb_local_usn"] == "20")
        #expect(try fixture.localUpdateCount() == 1001)
        let parsed = try xml(fixture)
        #expect(parsed.node(id: "201")?.timestamp == nowMS && parsed.node(id: "202")?.timestamp == 1_000)
    }

    @Test func 다른_폴더로_옮기면_그_폴더_맨_끝에_붙고_옛_폴더_Seq는_비워_둔다() throws {
        // 단계 8: 폴더 가(가3·가2·가1) → 가2를 폴더 나(나2·나1) 위에 놓음 → 나2·나1·가2, 폴더 가는 Seq 1·3으로 남음
        let fixture = try library([
            PlaylistSpec(id: "10", name: "DJC 폴더 가", seq: 1, isFolder: true), PlaylistSpec(id: "20", name: "DJC 폴더 나", seq: 2, isFolder: true),
            PlaylistSpec(id: "13", name: "가3", parentID: "10", seq: 1), PlaylistSpec(id: "12", name: "가2", parentID: "10", seq: 2),
            PlaylistSpec(id: "11", name: "가1", parentID: "10", seq: 3),
            PlaylistSpec(id: "22", name: "나2", parentID: "20", seq: 1), PlaylistSpec(id: "21", name: "나1", parentID: "20", seq: 2),
        ])
        try write(fixture, [.move(playlist: .id("12"), into: .id("20"))])
        let moved = try row(fixture, "12")
        #expect(moved["ParentID"] == "20" && moved["Seq"] == "3" && moved["rb_local_usn"] == "1001" && moved["rb_data_status"] == "257")
        #expect(try row(fixture, "13")["Seq"] == "1" && (try row(fixture, "11"))["Seq"] == "3" && (try row(fixture, "11"))["rb_local_usn"] == "20")
        #expect(try row(fixture, "21")["rb_local_usn"] == "20" && (try fixture.localUpdateCount()) == 1001)
        // XML: 옮긴 NODE의 ParentId·Timestamp와 새 폴더 Timestamp(옛 폴더는 그대로)
        let parsed = try xml(fixture)
        #expect(parsed.node(id: "12")?.parentID == "14" && parsed.node(id: "12")?.timestamp == nowMS)
        #expect(parsed.node(id: "20")?.timestamp == nowMS && parsed.node(id: "10")?.timestamp == 1_000)
    }

    @Test func 같은_폴더_안에서_순서를_바꾸면_바뀐_행이_새_순서대로_번호를_하나씩_받는다() throws {
        // 단계 9: 다3·다2·다1에서 맨 아래(다1)를 맨 위로 → 다1(1)·다3(2)·다2(3)
        let fixture = try library([
            PlaylistSpec(id: "30", name: "DJC 폴더 다", seq: 1, isFolder: true),
            PlaylistSpec(id: "33", name: "다3", parentID: "30", seq: 1), PlaylistSpec(id: "32", name: "다2", parentID: "30", seq: 2),
            PlaylistSpec(id: "31", name: "다1", parentID: "30", seq: 3),
        ])
        try write(fixture, [.reorder(playlist: .id("31"), index: 0)])
        #expect(try ["31", "33", "32"].map { try row(fixture, $0)["Seq"] } == ["1", "2", "3"])
        #expect(try ["31", "33", "32"].map { try row(fixture, $0)["rb_local_usn"] } == ["1001", "1002", "1003"])
        let parsed = try xml(fixture)
        #expect(parsed.node(id: "31")?.timestamp == nowMS && parsed.node(id: "30")?.timestamp == nowMS && parsed.node(id: "33")?.timestamp == 1_000)
    }

    // MARK: 지우기

    @Test func 목록을_지우면_행_곡_항목_거울이_사라지고_뒤_형제만_한_번호로_당겨진다() throws {
        // 단계 10: 라3·라2·라1에서 라2(곡 2개)를 지움 → 라3(1)·라1(2). 번호 하나를 비우고 당긴 형제가 다음 번호. NODE는 남는다.
        let fixture = try library([
            PlaylistSpec(id: "40", name: "DJC 폴더 라", seq: 1, isFolder: true),
            PlaylistSpec(id: "43", name: "라3", parentID: "40", seq: 1),
            PlaylistSpec(id: "42", name: "라2", parentID: "40", seq: 2, contentIDs: ["101", "102"]),
            PlaylistSpec(id: "41", name: "라1", parentID: "40", seq: 3),
        ])
        let before = try xml(fixture)
        let uuid = try row(fixture, "42")["UUID"]!
        try write(fixture, [.delete(playlist: .id("42"))])
        #expect(try fixture.rows("SELECT ID FROM djmdPlaylist WHERE ID = '42'").isEmpty)
        #expect(try entries(fixture, "42").isEmpty)
        #expect(try fixture.rows("SELECT ID FROM djmdCloudFilterPlaylist WHERE PlaylistUUID = ?", [.text(uuid)]).isEmpty)
        let r1 = try row(fixture, "41")
        #expect(r1["Seq"] == "2" && r1["rb_local_usn"] == "1002" && r1["rb_data_status"] == "257" && r1["updated_at"] == stamp)
        #expect(try row(fixture, "43")["rb_local_usn"] == "20" && (try fixture.localUpdateCount()) == 1002)
        #expect(try xml(fixture) == before)
    }

    @Test func 폴더를_지우면_안에_든_것까지_지우고_뒤_형제가_한_번호로_당겨진다() throws {
        // 단계 11: DJC 폴더 마(맨 위) > 마 안 > 마 목록(곡 2개)을 폴더째 지움 → 나머지 형제 Seq −1, 모두 같은 번호
        let fixture = try library([
            PlaylistSpec(id: "1", name: "DJC 실험", seq: 1, isFolder: true),
            PlaylistSpec(id: "50", name: "DJC 폴더 마", parentID: "1", seq: 1, isFolder: true),
            PlaylistSpec(id: "51", name: "마 안", parentID: "50", seq: 1, isFolder: true),
            PlaylistSpec(id: "52", name: "마 목록", parentID: "51", seq: 1, contentIDs: ["101", "102"]),
            PlaylistSpec(id: "60", name: "옆 1", parentID: "1", seq: 2), PlaylistSpec(id: "61", name: "옆 2", parentID: "1", seq: 3),
        ])
        let report = try write(fixture, [.delete(playlist: .id("50"))])
        #expect(report.playlistOutcomes?.first?.status == .written)
        #expect(try fixture.rows("SELECT ID FROM djmdPlaylist WHERE ID IN ('50', '51', '52')").isEmpty)
        #expect(try fixture.rows("SELECT ID FROM djmdSongPlaylist").isEmpty)
        #expect(try fixture.rows("SELECT ID FROM djmdCloudFilterPlaylist").count == 3)
        #expect(try ["60", "61"].map { try row(fixture, $0)["Seq"] } == ["1", "2"])
        #expect(try ["60", "61"].map { try row(fixture, $0)["rb_local_usn"] } == ["1002", "1002"])
        #expect(try row(fixture, "1")["rb_local_usn"] == "20")
    }

    // MARK: 곡

    @Test func 곡을_넣으면_끝에_붙고_한_번에_넣은_곡은_번호_하나를_같이_받는다() throws {
        // 단계 3: 곡1·곡2·곡3을 한꺼번에(한 번호), 곡4는 따로(다음 번호). 단계 6: 이미 든 곡도 한 번 더 넣는다.
        let fixture = try library([PlaylistSpec(id: "70", name: "DJC 1 넣기", seq: 1, contentIDs: ["101"])])
        try write(fixture, [
            .addTracks(playlist: .id("70"), contentIDs: ["102", "103"]),
            .addTracks(playlist: .id("70"), contentIDs: ["101"]),
        ])
        let rows = try entries(fixture, "70")
        #expect(rows.map { $0["ContentID"] } == ["101", "102", "103", "101"] && rows.map { $0["TrackNo"] } == ["1", "2", "3", "4"])
        #expect(rows.map { $0["rb_local_usn"] } == ["22", "1001", "1001", "1002"])
        let new = rows[1]
        let expected: [String: String] = [
            "PlaylistID": "70", "rb_data_status": "0", "rb_local_data_status": "0", "rb_local_deleted": "0", "rb_local_synced": "0",
            "usn": "NULL", "created_at": stamp, "updated_at": stamp,
        ]
        for (key, value) in expected { #expect(new[key] == value, "\(key)") }
        #expect(isUUID(new["ID"]) && isUUID(new["UUID"]) && new["ID"] != new["UUID"])
        #expect(try rows[0]["updated_at"] == old && (try row(fixture, "70"))["rb_local_usn"] == "20")
        #expect(try xml(fixture).node(id: "70")?.timestamp == nowMS && (try fixture.localUpdateCount()) == 1002)
    }

    @Test func 곡을_빼면_번호_하나를_비우고_남은_곡_전부를_다시_매겨_한_번호로() throws {
        // 단계 4: 곡1~5에서 2·4번째를 뺌 → 1·3·5가 1·2·3, 1번째(자리 그대로)도 번호를 받는다
        let fixture = try library([PlaylistSpec(id: "70", name: "DJC 2 빼기", seq: 1, contentIDs: ["101", "102", "103", "104", "105"])])
        try write(fixture, [.removeTracks(playlist: .id("70"), entries: [.init(trackNo: 2, contentID: "102"), .init(trackNo: 4, contentID: "104")])])
        let rows = try entries(fixture, "70")
        #expect(rows.map { $0["ContentID"] } == ["101", "103", "105"] && rows.map { $0["TrackNo"] } == ["1", "2", "3"])
        #expect(rows.allSatisfy { $0["rb_local_usn"] == "1002" && $0["rb_data_status"] == "257" && $0["updated_at"] == stamp && $0["usn"] == "22" })
        #expect(try fixture.localUpdateCount() == 1002 && (try xml(fixture)).node(id: "70")?.timestamp == nowMS)
    }

    @Test func 곡_순서를_바꾸면_자리가_바뀐_곡만_한_번호를_받는다() throws {
        // 단계 5: 5번째 곡을 1·2번째 사이로 → 1·5·2·3·4. 1번째는 그대로.
        let fixture = try library([PlaylistSpec(id: "70", name: "DJC 3 순서", seq: 1, contentIDs: ["101", "102", "103", "104", "105"])])
        try write(fixture, [.moveTracks(playlist: .id("70"), entries: [.init(trackNo: 5, contentID: "105")], to: 2)])
        let rows = try entries(fixture, "70")
        #expect(rows.map { $0["ContentID"] } == ["101", "105", "102", "103", "104"])
        #expect(rows.map { $0["rb_local_usn"] } == ["22", "1001", "1001", "1001", "1001"])
        #expect(rows[0]["updated_at"] == old && rows[1]["updated_at"] == stamp && rows[1]["rb_data_status"] == "257")
        #expect(try fixture.localUpdateCount() == 1001 && (try xml(fixture)).node(id: "70")?.timestamp == nowMS)
    }

    @Test func 새로_만든_목록에_곡을_넣고_가운데로_옮긴다() throws {
        // 단계 12: rekordbox도 가운데에 놓은 곡을 끝에 붙인다 → 넣은 뒤 옮기기로 가운데 넣기
        let fixture = try library()
        let report = try write(fixture, [
            .create(key: "p", name: "DJC 6 가운데", isFolder: false, parent: .root),
            .addTracks(playlist: .new("p"), contentIDs: ["101", "102", "103"]),
            .addTracks(playlist: .new("p"), contentIDs: ["104"]),
            .moveTracks(playlist: .new("p"), entries: [.init(trackNo: 4, contentID: "104")], to: 2),
        ])
        #expect(report.playlistWritten.count == 4)
        let id = try #require(report.playlistOutcomes?.first?.playlistID)
        #expect(try entries(fixture, id).map { $0["ContentID"] } == ["101", "104", "102", "103"])
    }

    // MARK: 막힘

    @Test func 확인할_수_없는_편집은_막고_나머지는_쓴다() throws {
        let fixture = try library([
            PlaylistSpec(id: "1", name: "폴더", seq: 1, isFolder: true),
            PlaylistSpec(id: "2", name: "안 폴더", parentID: "1", seq: 1, isFolder: true),
            PlaylistSpec(id: "70", name: "목록", seq: 2, contentIDs: ["101", "102"]),
        ])
        let report = try write(fixture, [
            .addTracks(playlist: .id("1"), contentIDs: ["101"]),                                        // 폴더에는 곡을 넣지 못한다
            .addTracks(playlist: .id("70"), contentIDs: ["999"]),                                       // 컬렉션에 없는 곡
            .removeTracks(playlist: .id("70"), entries: [.init(trackNo: 1, contentID: "102")]),          // 그 자리의 곡이 다르다
            .move(playlist: .id("1"), into: .id("2")),                                                  // 제 안으로 옮기기
            .create(key: "x", name: "목록 아래", isFolder: false, parent: .id("70")),                     // 목록 아래에는 만들 수 없다
            .addTracks(playlist: .new("x"), contentIDs: ["101"]),                                       // 막힌 만들기를 가리킴
            .rename(playlist: .id("404"), name: "없음"),
            .rename(playlist: .id("70"), name: ""),
            .rename(playlist: .id("70"), name: "새 이름"),
        ])
        let statuses = report.playlistOutcomes?.map(\.status) ?? []
        #expect(statuses == Array(repeating: .blocked, count: 8) + [.written])
        #expect(report.playlistBlocked.allSatisfy { !($0.reason ?? "").isEmpty })
        #expect(try row(fixture, "70")["Name"] == "새 이름" && (try entries(fixture, "70")).count == 2)
        #expect(try fixture.localUpdateCount() == 1001)
    }

    @Test func 미리_보기는_아무것도_바꾸지_않는다() throws {
        let fixture = try library([PlaylistSpec(id: "70", name: "목록", seq: 1)])
        let before = try xml(fixture)
        let report = try write(fixture, [.create(key: "n", name: "새", isFolder: true, parent: .root)], dryRun: true)
        #expect(report.dryRun && report.backup == nil && report.playlistWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdPlaylist").count == 1)
        #expect(try fixture.localUpdateCount() == 1000)
        #expect(try xml(fixture) == before)
    }

    @Test func masterPlaylists6_xml이_없는_사본에도_DB는_쓴다() throws {
        let fixture = try library()
        try FileManager.default.removeItem(at: xmlURL(fixture))
        let report = try write(fixture, [.create(key: "n", name: "새", isFolder: false, parent: .root)])
        #expect(report.playlistWritten.count == 1 && !FileManager.default.fileExists(atPath: xmlURL(fixture).path))
    }

    // MARK: 되돌리기

    @Test func 되돌리면_DB와_masterPlaylists6_xml이_쓰기_전으로() throws {
        let fixture = try library([PlaylistSpec(id: "70", name: "목록", seq: 1, contentIDs: ["101"])])
        let before = try xml(fixture)
        let edits: [PlaylistEdit] = [.create(key: "n", name: "새", isFolder: false, parent: .root), .rename(playlist: .id("70"), name: "바뀜")]
        let report = try write(fixture, edits)
        let backup = URL(filePath: try #require(report.backup))
        #expect(try xml(fixture) != before)
        // 되돌리면 초안을 살릴 수 있게 편집을 백업 옆에 둔다
        #expect(RekordboxWriter.playlistEdits(in: backup) == edits)
        #expect(RekordboxWriter.backups(in: fixture.backups).first?.titles.contains("바뀜") == true)

        try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups)
        #expect(try fixture.rows("SELECT ID FROM djmdPlaylist").map { $0["ID"] } == ["70"])
        #expect(try row(fixture, "70")["Name"] == "목록" && (try xml(fixture)) == before)
    }

    // MARK: 경계

    @Test func 바뀌는_것이_없는_편집은_쓰지_않는다() throws {
        let fixture = try library([
            PlaylistSpec(id: "1", name: "폴더", seq: 1, isFolder: true),
            PlaylistSpec(id: "70", name: "목록", parentID: "1", seq: 1, contentIDs: ["101", "102"]),
        ])
        let report = try write(fixture, [
            .rename(playlist: .id("70"), name: "목록"),
            .move(playlist: .id("70"), into: .id("1")),
            .reorder(playlist: .id("70"), index: 5),
            .addTracks(playlist: .id("70"), contentIDs: []),
            .removeTracks(playlist: .id("70"), entries: []),
            .moveTracks(playlist: .id("70"), entries: [.init(trackNo: 1, contentID: "101")], to: 1),
        ])
        #expect(report.playlistOutcomes?.map(\.status) == Array(repeating: .unchanged, count: 6))
        #expect(try fixture.localUpdateCount() == 1000 && (try row(fixture, "70"))["updated_at"] == old)
    }

    @Test func 맨_위로_옮기고_맨_위에서_순서를_바꾼다() throws {
        let fixture = try library([
            PlaylistSpec(id: "1", name: "폴더", seq: 1, isFolder: true), PlaylistSpec(id: "2", name: "둘", seq: 2),
            PlaylistSpec(id: "70", name: "목록", parentID: "1", seq: 1),
        ])
        try write(fixture, [.move(playlist: .id("70"), into: .root), .reorder(playlist: .id("70"), index: 0)])
        #expect(try ["70", "1", "2"].map { try row(fixture, $0)["Seq"] } == ["1", "2", "3"])
        #expect(try row(fixture, "70")["ParentID"] == "root")
        let parsed = try xml(fixture)
        #expect(parsed.node(id: "70")?.parentID == "0" && parsed.node(id: "1")?.timestamp == 1_000)
    }

    @Test func 같은_묶음에서_만든_목록을_옮기거나_지운다() throws {
        let fixture = try library([PlaylistSpec(id: "1", name: "폴더", seq: 1, isFolder: true)])
        let report = try write(fixture, [
            .create(key: "a", name: "옮길 것", isFolder: false, parent: .root),
            .move(playlist: .new("a"), into: .id("1")),
            .create(key: "b", name: "지울 것", isFolder: false, parent: .root),
            .addTracks(playlist: .new("b"), contentIDs: ["101"]),
            .delete(playlist: .new("b")),
            .create(key: "a", name: "같은 key", isFolder: false, parent: .root),
        ])
        #expect(report.playlistOutcomes?.map(\.status) == [.written, .written, .written, .written, .written, .blocked])
        let moved = try #require(report.playlistOutcomes?[0].playlistID), deleted = try #require(report.playlistOutcomes?[2].playlistID)
        #expect(try row(fixture, moved)["ParentID"] == "1")
        #expect(try fixture.rows("SELECT ID FROM djmdPlaylist WHERE ID = ?", [.text(deleted)]).isEmpty)
        #expect(try fixture.rows("SELECT ID FROM djmdSongPlaylist").isEmpty && (try fixture.rows("SELECT ID FROM djmdCloudFilterPlaylist")).count == 2)
        // 지운 목록의 NODE도 남는다(rekordbox와 같게)
        let parsed = try xml(fixture)
        #expect(parsed.node(id: moved)?.parentID == "1" && parsed.node(id: deleted) != nil)
    }

    @Test func 마지막_곡까지_빼거나_맨_끝_목록을_지우면_비운_번호만_남는다() throws {
        let fixture = try library([PlaylistSpec(id: "1", name: "하나", seq: 1), PlaylistSpec(id: "70", name: "목록", seq: 2, contentIDs: ["101"])])
        try write(fixture, [.removeTracks(playlist: .id("70"), entries: [.init(trackNo: 1, contentID: "101")])])
        #expect(try entries(fixture, "70").isEmpty && (try fixture.localUpdateCount()) == 1001)
        try write(fixture, [.delete(playlist: .id("70"))])
        #expect(try row(fixture, "1")["rb_local_usn"] == "20" && (try fixture.localUpdateCount()) == 1002)
    }

    @Test func 인텔리전트_목록과_맨_위와_겹친_자리는_막는다() throws {
        let fixture = try library([PlaylistSpec(id: "70", name: "목록", seq: 1, contentIDs: ["101", "102"]), PlaylistSpec(id: "80", name: "스마트", seq: 2)])
        try fixture.execute("UPDATE djmdPlaylist SET Attribute = 4, SmartList = '<NODE/>' WHERE ID = '80'")
        let report = try write(fixture, [
            .rename(playlist: .id("80"), name: "바꿈"),
            .rename(playlist: .root, name: "맨 위"),
            .moveTracks(playlist: .id("70"), entries: [.init(trackNo: 1, contentID: "101"), .init(trackNo: 1, contentID: "101")], to: 2),
            .create(key: "x", name: " ", isFolder: false, parent: .root),
        ])
        #expect(report.playlistOutcomes?.map(\.status) == [.blocked, .blocked, .blocked, .blocked])
        #expect(try fixture.localUpdateCount() == 1000)
    }

    /// 인텔리전트 목록 읽기(#68)를 더해도 쓰기 경로가 인텔리전트 목록을 거르는 방식은 그대로다: 어떤 편집이든 가리키면 막고 DB를 건드리지 않는다.
    @Test func 인텔리전트_목록을_가리키는_편집은_모두_막고_행과_XML을_건드리지_않는다() throws {
        let fixture = try library([PlaylistSpec(id: "20", name: "폴더", seq: 1, isFolder: true),
                                   PlaylistSpec(id: "70", name: "목록", seq: 2, contentIDs: ["101"]),
                                   PlaylistSpec(id: "80", name: "스마트", seq: 3)])
        let condition = "<NODE Id=\"-1\" LogicalOperator=\"1\" AutomaticUpdate=\"0\">"
            + "<CONDITION PropertyName=\"name\" Operator=\"8\" ValueUnit=\"\" ValueLeft=\"가\" ValueRight=\"\"/></NODE>"
        try fixture.execute("UPDATE djmdPlaylist SET Attribute = 4, SmartList = ? WHERE ID = '80'", [.text(condition)])
        let before = try row(fixture, "80"), xmlBefore = try xml(fixture).node(id: "80")
        let counter = try fixture.localUpdateCount()

        let entry = PlaylistEntry(trackNo: 1, contentID: "101")
        let report = try write(fixture, [
            .rename(playlist: .id("80"), name: "바꿈"), .move(playlist: .id("80"), into: .id("20")), .reorder(playlist: .id("80"), index: 0),
            .delete(playlist: .id("80")), .addTracks(playlist: .id("80"), contentIDs: ["101"]),
            .removeTracks(playlist: .id("80"), entries: [entry]), .moveTracks(playlist: .id("80"), entries: [entry], to: 1),
            .create(key: "n", name: "안에", isFolder: false, parent: .id("80")),
        ])
        #expect(report.playlistOutcomes?.map(\.status) == Array(repeating: .blocked, count: 8))
        #expect(try fixture.localUpdateCount() == counter)
        #expect(try row(fixture, "80") == before)
        #expect(try xml(fixture).node(id: "80") == xmlBefore)
        #expect(try entries(fixture, "80").isEmpty)
    }

    @Test func 일반_목록을_고쳐도_인텔리전트_목록의_행과_XML_NODE는_그대로다() throws {
        let fixture = try library([PlaylistSpec(id: "70", name: "목록", seq: 1, contentIDs: ["101"]), PlaylistSpec(id: "80", name: "스마트", seq: 2)])
        try fixture.execute("UPDATE djmdPlaylist SET Attribute = 4, SmartList = '<NODE/>' WHERE ID = '80'")
        let before = try row(fixture, "80"), xmlBefore = try xml(fixture).node(id: "80")
        let report = try write(fixture, [.rename(playlist: .id("70"), name: "새 이름"), .addTracks(playlist: .id("70"), contentIDs: ["102"])])
        #expect(report.playlistOutcomes?.map(\.status) == [.written, .written])
        #expect(try row(fixture, "80") == before)
        #expect(try xml(fixture).node(id: "80") == xmlBefore)
    }

    @Test func 곡_정보_시각과_목록_편집이_섞여도_XML은_하나씩_고친_것과_같다() throws {
        // 곡 정보 쓰기(#173)의 Timestamp는 모아서 한 번에 고친다. 만들기·옮기기와 섞이고 같은 목록이 여러 번·없는 목록이 있어도
        // 변경을 하나씩 적은 결과와 같아야 한다.
        var base = MasterPlaylistsXML(text: MasterPlaylistsXMLTests.empty)
        try base.append(id: "1", parentID: "root", isFolder: true, timestamp: 1_000)
        try base.append(id: "2", parentID: "root", isFolder: false, timestamp: 1_000)
        try base.append(id: "3", parentID: "root", isFolder: false, timestamp: 1_000)
        let changes: [RekordboxWriter.PlaylistXMLChange] = [
            .touch("2"), .append(id: "4", parentID: "1", isFolder: false), .parent(id: "3", to: "1"), .touch("1"), .touch("4"), .touch("2"), .touch("5"),
        ]
        let batched = try RekordboxWriter.applyPlaylistXML(changes, to: base, now: now)
        var sequential = base
        for change in changes {
            switch change {
            case let .append(id, parentID, isFolder): try sequential.append(id: id, parentID: parentID, isFolder: isFolder, timestamp: nowMS)
            case let .touch(id): try sequential.update(id: id, timestamp: nowMS)
            case let .parent(id, parentID): try sequential.update(id: id, parentID: parentID)
            }
        }
        #expect(batched == sequential)
        #expect(batched.node(id: "3")?.timestamp == 1_000 && batched.node(id: "2")?.timestamp == nowMS)
    }

    @Test func 읽지_못하는_masterPlaylists6_xml이면_백업_전에_막는다() throws {
        let fixture = try library()
        try "망가짐".write(to: xmlURL(fixture), atomically: true, encoding: .utf8)
        #expect(throws: DJCError.self) { try write(fixture, [.create(key: "n", name: "새", isFolder: false, parent: .root)]) }
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty)
    }

    // MARK: 초안(#39·#40)

    /// 스냅샷을 읽은 rekordbox 재생 목록 상태(앱이 초안을 쌓을 때 보는 것)
    func layout(_ fixture: RekordboxFixture) throws -> PlaylistLayout {
        PlaylistLayout(rekordbox: try RekordboxLibrary.load(snapshot: fixture.database).playlists)
    }

    @Test func 초안을_만든_뒤_rekordbox에서_바뀐_목록의_편집은_쓰지_않는다() throws {
        let fixture = try library([PlaylistSpec(id: "70", name: "목록", seq: 1, contentIDs: ["101", "102"]),
                                   PlaylistSpec(id: "80", name: "다른 목록", seq: 2, contentIDs: ["103"])])
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("70"), contentIDs: ["104"]), rekordbox: try layout(fixture))
        try draft.append(.rename(playlist: .id("80"), name: "새 이름"), rekordbox: try layout(fixture))
        // 그 뒤 rekordbox에서 목록 70에 곡을 넣었다
        try write(fixture, [.addTracks(playlist: .id("70"), contentIDs: ["105"])])

        let report = try RekordboxWriter.write(drafts: [], playlistDraft: draft, to: fixture.database, dryRun: false, now: now,
                                               backups: fixture.backups)
        #expect(report.playlistOutcomes?.map(\.status) == [.blocked, .written])
        #expect(report.playlistBlocked.first?.name == "목록")
        #expect(report.playlistBlocked.first?.reason == "초안을 만든 뒤 rekordbox에서 이 목록이 바뀌었으니 현재 목록을 비교해 다시 적용하거나 초안을 버리세요.")
        #expect(try entries(fixture, "70").map { $0["ContentID"] } == ["101", "102", "105"])
        #expect(try row(fixture, "80")["Name"] == "새 이름")
        // 백업에는 쓴 편집만 둔다(되돌리면 초안으로 살린다)
        let backup = try #require(report.backup.map { URL(filePath: $0) })
        #expect(RekordboxWriter.playlistEdits(in: backup) == [.rename(playlist: .id("80"), name: "새 이름")])
    }

    @Test func 초안을_얹어_본_모양과_쓴_뒤_다시_읽은_모양이_같다() throws {
        let fixture = try library([
            PlaylistSpec(id: "1", name: "폴더", seq: 1, isFolder: true),
            PlaylistSpec(id: "70", name: "가", parentID: "1", seq: 1, contentIDs: ["101", "102", "103"]),
            PlaylistSpec(id: "71", name: "나", parentID: "1", seq: 2, contentIDs: ["104"]),
            PlaylistSpec(id: "80", name: "다", seq: 2, contentIDs: ["105"]),
            PlaylistSpec(id: "90", name: "지울 폴더", seq: 3, isFolder: true),
            PlaylistSpec(id: "91", name: "안 목록", parentID: "90", seq: 1, contentIDs: ["101"]),
        ])
        let rekordbox = try layout(fixture)
        var draft = PlaylistDraft()
        for edit: PlaylistEdit in [
            .create(key: "f", name: "새 폴더", isFolder: true, parent: .root),
            .create(key: "p", name: "새 목록", isFolder: false, parent: .new("f")),
            .addTracks(playlist: .new("p"), contentIDs: ["101", "102", "103"]),
            .moveTracks(playlist: .new("p"), entries: [.init(trackNo: 3, contentID: "103")], to: 1),
            .addTracks(playlist: .id("70"), contentIDs: ["105"]),
            .removeTracks(playlist: .id("70"), entries: [.init(trackNo: 2, contentID: "102")]),
            .rename(playlist: .id("71"), name: "나2"),
            .move(playlist: .id("80"), into: .id("1")),
            .reorder(playlist: .id("80"), index: 0),
            .delete(playlist: .id("90")),
        ] { try draft.append(edit, rekordbox: rekordbox) }
        let projected = draft.project(onto: rekordbox)
        #expect(projected.ready.count == 10)

        let report = try RekordboxWriter.write(drafts: [], playlistDraft: draft, to: fixture.database, dryRun: false, now: now,
                                               backups: fixture.backups)
        #expect(report.playlistWritten.count == 10)
        // 새 ID를 new:키로 바꿔 비교한다
        var names: [String: String] = [:]
        for (step, outcome) in zip(draft.steps, report.playlistOutcomes ?? []) {
            if case let .create(key, _, _, _) = step.edit, let id = outcome.playlistID { names[id] = "new:\(key)" }
        }
        func shape(_ layout: PlaylistLayout, rename: [String: String] = [:]) -> [String] {
            layout.outline.map { item in
                let id = rename[item.id] ?? item.id, parent = rename[item.parentID] ?? item.parentID
                return "\(id)<\(parent) \(item.name) \(item.entries.map { "\($0.trackNo):\($0.contentID)" })"
            }
        }
        #expect(shape(try layout(fixture), rename: names) == shape(projected.layout))
    }

    @Test func 편집은_JSON_글자_하나로_가리킨다() throws {
        #expect(PlaylistRef("root") == .root && PlaylistRef("123") == .id("123") && PlaylistRef("new:가") == .new("가"))
        #expect([PlaylistRef.root, .id("1"), .new("x")].map(\.description) == ["root", "1", "new:x"])
        let json = #"[{"create":{"key":"f","name":"새 폴더","isFolder":true,"parent":"root"}},{"addTracks":{"playlist":"new:f","contentIDs":["123"]}}]"#
        let edits = try JSONDecoder().decode([PlaylistEdit].self, from: Data(json.utf8))
        #expect(edits == [.create(key: "f", name: "새 폴더", isFolder: true, parent: .root), .addTracks(playlist: .new("f"), contentIDs: ["123"])])
        #expect(try JSONDecoder().decode([PlaylistEdit].self, from: JSONEncoder().encode(edits)) == edits)
        #expect(edits.map(\.playlist) == [.new("f"), .new("f")])
    }
}
