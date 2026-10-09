import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 곡의 키 쓰기(#5, `musicalKey`): `djmdContent.KeyID`에 `djmdKey` 줄의 ID(글자)를 넣는다.
/// 규칙은 rekordbox 7.2.18 실험에서 확인했다(docs/rekordbox-internals.md "태그 (곡 정보)"):
/// - 2026-10-04 묶음 2(분석 안 된 상태 0 시험 곡): S1 키 넣기 '0' → 8A 줄(`TrackInfoUpdated` NULL → '1'), S3 바꾸기 8A → 6A('3' → '4'),
///   S4 지우기 6A → '0'(글자, ''·NULL 아님, +1). 곡 행만 고치고 `djmdKey`·다른 표는 그대로다.
/// - 2026-10-04 #173 S1 T13(동기화 256, 키 2B → 5A)·S2 U10(키 지우기): 같은 칸 + `TrackInfoUpdated` +1 + `rb_data_status` 256 → 257.
/// DJCrate는 음원 파일의 키 태그(TKEY)를 쓰지 않는다(#5 결정: 음원은 읽기만 한다).
/// 고르는 줄: 살아 있는(`rb_local_deleted` 0) 줄 가운데 `ScaleName`이 같은 줄이 하나일 때만. 없거나 둘 이상이거나 삭제 표시 줄뿐이면 막는다.
extension RekordboxTagWriterTests {
    /// 실험 라이브러리 모양의 `djmdKey`: 같은 조성이 Camelot·음이름 두 표기로 따로 있고(8A·Am) 옛 표기 일부는 삭제 표시다(Am·Gm, 262).
    /// 살아 있는 옛 표기 줄(Em)도 있다. `ID`는 글자다.
    static let keyRows: [(id: String, name: String, deleted: Int)] = [
        ("1486464042", "8A", 0), ("3730904205", "6A", 0), ("1010000005", "5A", 0), ("1010000102", "2B", 0),
        ("4052093496", "Gm", 1), ("4052093497", "Am", 1), ("4052093498", "Em", 0),
    ]

    static func keyID(_ name: String) -> String { keyRows.first { $0.name == name }!.id }

    /// 키 줄을 넣은 라이브러리. `state`가 0이면 분석 안 된 시험 곡(`TrackInfoUpdated` NULL, `Analysed` 0)처럼, 아니면 동기화 곡(`syncedLibrary`)이다.
    func keyLibrary(state: Int = 0, key: String? = nil, shared: Bool = true) throws -> (RekordboxFixture, TrackSpec) {
        let (fixture, track) = state == 0 ? try library(shared: shared) : try syncedLibrary(state: state, shared: shared)
        for row in Self.keyRows {
            try fixture.insert("djmdKey", ["ID": .text(row.id), "ScaleName": .text(row.name), "Seq": .int(1), "UUID": .text("k-\(row.id)"),
                                           "rb_data_status": .int(row.deleted == 1 ? 262 : 256), "rb_local_deleted": .int(row.deleted),
                                           "rb_local_usn": .int(157_637)])
        }
        let id = key.map(Self.keyID) ?? "0"
        if state == 0 {
            try fixture.execute("UPDATE djmdContent SET Analysed = 0, TrackInfoUpdated = NULL, KeyID = ? WHERE ID = '500'", [.text(id)])
        } else {
            try fixture.execute("UPDATE djmdContent SET KeyID = ? WHERE ID = '500'", [.text(id)])
        }
        return (fixture, track)
    }

    /// `djmdContent`와 변경 카운터 말고 모든 표(`djmdKey` 포함)의 내용. 픽스처 연결 하나로 읽는다(제품 연결은 열 때마다 키를 풀어 느리다).
    func otherTables(_ fixture: RekordboxFixture) throws -> [String: [[String: String]]] {
        try fixture.session { db in
            let names = try db.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").compactMap { $0["name"] }
            var tables: [String: [[String: String]]] = [:]
            for name in names where name != "djmdContent" && name != "agentRegistry" {
                tables[name] = try db.rows("SELECT * FROM \(name) ORDER BY rowid")
            }
            return tables
        }
    }

    func rawKey(_ fixture: RekordboxFixture, _ id: String = "500") throws -> (value: String, type: String) {
        let row = try #require(fixture.rows("SELECT quote(KeyID) AS v, typeof(KeyID) AS t FROM djmdContent WHERE ID = ?", [.text(id)]).first)
        return (row["v"] ?? "", row["t"] ?? "")
    }

    // MARK: 골든 — 상태 0 (묶음 2 S1·S3·S4)

    @Test func 분석_안_된_상태_0_곡의_키_넣기_바꾸기_지우기는_rekordbox_7이_저장한_모양과_같다() throws {
        let (fixture, track) = try keyLibrary()
        let keys = try fixture.rows("SELECT * FROM djmdKey ORDER BY ID")
        let others = try otherTables(fixture)
        let baseColumns: Set<String> = ["KeyID", "TrackInfoUpdated", "rb_local_usn", "updated_at"]

        // S1 넣기: '0' → 8A 줄의 ID(글자), TrackInfoUpdated NULL → '1'(글자). 분석 칸·상태는 그대로.
        var before = try content(fixture)
        #expect(before["TrackInfoUpdated"] == "NULL" && before["KeyID"] == "0")
        var report = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "8A" }])
        #expect(report.tagWritten.first?.fields == ["musicalKey"] && report.tagBlocked.isEmpty)
        var after = try content(fixture)
        #expect(changedColumns(before, after) == baseColumns)
        #expect(after["KeyID"] == Self.keyID("8A") && after["TrackInfoUpdated"] == "1" && after["rb_data_status"] == "0")
        #expect(after["Analysed"] == "0" && after["AnalysisUpdated"] == before["AnalysisUpdated"] && after["updated_at"] == stamp)
        #expect(try rawKey(fixture) == ("'\(Self.keyID("8A"))'", "text"))
        #expect(try fixture.rows("SELECT typeof(TrackInfoUpdated) AS t FROM djmdContent WHERE ID = '500'").first?["t"] == "text")
        #expect(try Int(after["rb_local_usn"] ?? "") == fixture.localUpdateCount() && fixture.localUpdateCount() == 2001)

        // S3 바꾸기: 8A → 6A, '3' → '4'(rekordbox S2에서 같은 값을 두 번 저장해 '3'이었다)
        try fixture.execute("UPDATE djmdContent SET TrackInfoUpdated = '3' WHERE ID = '500'")
        before = try content(fixture)
        report = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "6A" }])
        #expect(report.tagWritten.count == 1)
        after = try content(fixture)
        #expect(changedColumns(before, after) == ["KeyID", "TrackInfoUpdated", "rb_local_usn"], "같은 시각이라 updated_at은 같은 값")
        #expect(after["KeyID"] == Self.keyID("6A") && after["TrackInfoUpdated"] == "4")

        // S4 지우기: '0'(글자, ''·NULL 아님), +1
        before = after
        report = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "" }])
        #expect(report.tagWritten.count == 1)
        after = try content(fixture)
        #expect(changedColumns(before, after) == ["KeyID", "TrackInfoUpdated", "rb_local_usn"])
        #expect(try rawKey(fixture) == ("'0'", "text") && after["TrackInfoUpdated"] == "5")
        #expect(try fixture.localUpdateCount() == 2003)

        // djmdKey와 다른 표는 한 줄도 바뀌지 않는다
        #expect(try fixture.rows("SELECT * FROM djmdKey ORDER BY ID") == keys)
        #expect(try otherTables(fixture) == others)
    }

    // MARK: 골든 — 동기화 곡 (#173 S1 T13·S2 U10)

    @Test(arguments: [256, 257]) func 동기화된_곡의_키_바꾸기와_지우기는_rekordbox_7이_저장한_모양과_같다(state: Int) throws {
        let (fixture, track) = try keyLibrary(state: state, key: "2B")
        let keys = try fixture.rows("SELECT * FROM djmdKey ORDER BY ID")
        let others = try otherTables(fixture)
        let stateColumn: Set<String> = state == 256 ? ["rb_data_status"] : []

        // T13: 2B → 5A, '2' → '3', 256 → 257(257은 그대로)
        var before = try content(fixture)
        var report = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "5A" }])
        #expect(report.tagWritten.first?.fields == ["musicalKey"] && report.tagBlocked.isEmpty)
        var after = try content(fixture)
        #expect(changedColumns(before, after) == Set(["KeyID", "TrackInfoUpdated", "rb_local_usn", "updated_at"]).union(stateColumn))
        #expect(after["KeyID"] == Self.keyID("5A") && after["TrackInfoUpdated"] == "3" && after["rb_data_status"] == "257")
        #expect(after["usn"] == "363" && after["rb_local_synced"] == "0" && after["rb_local_data_status"] == "0", "클라우드 칸은 그대로")
        #expect(try Int(after["rb_local_usn"] ?? "") == fixture.localUpdateCount())

        // U10: 지우기 → '0'(글자), +1, 상태는 이미 257
        before = after
        report = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "" }])
        #expect(report.tagWritten.count == 1)
        after = try content(fixture)
        #expect(changedColumns(before, after).isSubset(of: ["KeyID", "TrackInfoUpdated", "rb_local_usn", "updated_at"]))
        #expect(try rawKey(fixture) == ("'0'", "text") && after["TrackInfoUpdated"] == "4" && after["rb_data_status"] == "257")

        #expect(try fixture.rows("SELECT * FROM djmdKey ORDER BY ID") == keys)
        #expect(try otherTables(fixture) == others)
    }

    @Test func 키와_다른_칸을_함께_고치면_칸마다_한_번_저장한_것과_같다() throws {
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        try fixture.execute("UPDATE djmdContent SET TrackInfoUpdated = '5' WHERE ID = '500'")
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.title = "새 제목"; $0.musicalKey = "5A" }])
        #expect(report.tagWritten.first?.fields == ["title", "musicalKey"])
        let row = try content(fixture)
        #expect(row["Title"] == "새 제목" && row["KeyID"] == Self.keyID("5A") && row["TrackInfoUpdated"] == "7" && row["rb_data_status"] == "257")
        #expect(try Int(row["rb_local_usn"] ?? "") == fixture.localUpdateCount())
    }

    // MARK: 막기

    /// 쓰기는 초안 문제(`TagDraft.issues`)로 막는다. DB와 상관없는 이름은 DB 없이 본다(#167).
    @Test func Camelot_이름이_아닌_키는_초안_문제다() {
        for name in ["C", "8a", "13A", "0A", "키"] {
            var draft = TagDraft(trackUUID: "u", base: TagFields())
            draft.fields.musicalKey = name
            #expect(draft.issues.contains { $0.contains("1A~12B") }, "\(name)")
        }
    }

    /// DB 행 상태가 특별한 이름만 쓰기로 본다. 이름 규칙(소문자·범위 밖·다른 글자)은 위 시험과 `MusicalKeyTagTests`가 본다(#167).
    @Test(arguments: ["Am", "Em", "Gm"]) func Camelot_스물네_이름이_아니면_막는다(name: String) throws {
        // "Am"·"Gm": 삭제 표시 줄, "Em": 살아 있는 옛 표기 줄(화면 표기와 같은 이름도 살아 있는 줄도 아니라 고르지 않는다)
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        let before = try content(fixture), keys = try otherTables(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = name }])
        #expect(report.tagWritten.isEmpty && report.backup == nil)
        let reason = try #require(report.tagBlocked.first?.reason)
        #expect(reason.contains("1A~12B"))
        #expect(try content(fixture) == before && otherTables(fixture) == keys && fixture.localUpdateCount() == 2000)
    }

    @Test func 키_목록에_없는_이름은_할_일과_함께_막는다() throws {
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "12B" }])
        #expect(report.tagWritten.isEmpty && report.backup == nil)
        let reason = try #require(report.tagBlocked.first?.reason)
        #expect(reason.contains("12B") && reason.contains("없습니다") && reason.contains("rekordbox에서"))
        #expect(try content(fixture) == before)
    }

    @Test func 살아_있는_줄이_둘_이상이면_막는다() throws {
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        try fixture.insert("djmdKey", ["ID": .text("1486464043"), "ScaleName": .text("8A"), "UUID": .text("k-dup"), "rb_local_deleted": .int(0)])
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "8A" }])
        #expect(report.tagWritten.isEmpty && report.backup == nil)
        let reason = try #require(report.tagBlocked.first?.reason)
        #expect(reason.contains("8A") && reason.contains("둘 이상") && reason.contains("rekordbox에서"))
        #expect(try content(fixture) == before)
    }

    @Test func 삭제_표시_줄만_있으면_막는다() throws {
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        try fixture.execute("UPDATE djmdKey SET rb_local_deleted = 1, rb_data_status = 262 WHERE ScaleName = '8A'")
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "8A" }])
        #expect(report.tagWritten.isEmpty && report.backup == nil)
        let reason = try #require(report.tagBlocked.first?.reason)
        #expect(reason.contains("8A") && reason.contains("삭제 표시") && reason.contains("rekordbox에서"))
        #expect(try content(fixture) == before)
    }

    @Test func 삭제_표시_줄과_살아_있는_줄이_섞이면_살아_있는_줄을_쓴다() throws {
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        try fixture.insert("djmdKey", ["ID": .text("1486464044"), "ScaleName": .text("8A"), "UUID": .text("k-old"), "rb_data_status": .int(262),
                                       "rb_local_deleted": .int(1)])
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "8A" }]).tagWritten.count == 1)
        #expect(try content(fixture)["KeyID"] == Self.keyID("8A"))
    }

    @Test func 막힌_키_초안은_같은_쓰기의_다른_곡을_막지_않는다() throws {
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        let neighbor = TrackSpec(id: "501", uuid: "track-uuid-501")
        let tags = [try draft(fixture, track) { $0.musicalKey = "12B" }, try draft(fixture, neighbor) { $0.title = "이웃 새 제목" }]
        let report = try write(fixture, tags: tags)
        #expect(report.tagBlocked.map(\.trackUUID) == [track.uuid] && report.tagWritten.map(\.trackUUID) == [neighbor.uuid])
        #expect(try content(fixture)["KeyID"] == Self.keyID("2B") && content(fixture, "501")["Title"] == "이웃 새 제목")
    }

    @Test func 키_줄을_바꾸는_쓰기도_djmdKey를_고치는_초안은_없다() throws {
        // 어느 경우에도 djmdKey를 더하거나 고치지 않는다(규칙을 확인한 것은 곡 행뿐이다)
        let (fixture, track) = try keyLibrary()
        let keys = try fixture.rows("SELECT * FROM djmdKey ORDER BY ID")
        for name in ["8A", "6A", "", "5A", "2B"] { _ = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = name }]) }
        _ = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "12B" }])
        #expect(try fixture.rows("SELECT * FROM djmdKey ORDER BY ID") == keys)
    }

    // MARK: 읽기: 기준값은 ScaleName이다

    @Test func 키가_가리키는_줄이_삭제_표시이거나_없어도_읽는_그대로_기준이_되어_다른_칸은_쓴다() throws {
        // 라이브러리 읽기(`LEFT JOIN djmdKey`)는 삭제 표시 줄을 거르지 않는다. 같은 규칙이라 초안이 어긋나 막히지 않는다.
        for (id, expected) in [(Self.keyID("Gm"), "Gm"), (Self.keyID("Em"), "Em"), ("999999", ""), ("0", ""), ("", "")] {
            let (fixture, track) = try keyLibrary(state: 256)
            try fixture.execute("UPDATE djmdContent SET KeyID = ? WHERE ID = '500'", [.text(id)])
            let db = try fixture.open()
            #expect(try RekordboxWriter.currentTags(db: db, contentID: track.id)?.musicalKey == expected, "\(id)")
            db.close()
            let report = try write(fixture, tags: [try draft(fixture, track) { $0.title = "새 제목" }])
            #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty, "\(id)")
            #expect(try rawKey(fixture) == ("'\(id)'", "text"), "키를 안 고친 쓰기는 KeyID를 그대로 둔다")
        }
        // KeyID가 NULL이어도 같다
        let (fixture, track) = try keyLibrary(state: 256)
        try fixture.execute("UPDATE djmdContent SET KeyID = NULL WHERE ID = '500'")
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.title = "새 제목" }]).tagWritten.count == 1)
        #expect(try rawKey(fixture).value == "NULL")
    }

    @Test func 옛_표기_키를_가진_곡도_Camelot_줄로_바꿀_수_있다() throws {
        let (fixture, track) = try keyLibrary(state: 256, key: "Em")
        let tags = try draft(fixture, track) { $0.musicalKey = "8A" }
        #expect(tags.base.musicalKey == "Em")
        #expect(try write(fixture, tags: [tags]).tagWritten.count == 1)
        #expect(try content(fixture)["KeyID"] == Self.keyID("8A"))
    }

    @Test func 키를_고친_초안은_그_사이_rekordbox에서_키가_바뀌었으면_쓰지_않는다() throws {
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        let tags = try draft(fixture, track) { $0.musicalKey = "5A" }
        try fixture.execute("UPDATE djmdContent SET KeyID = ? WHERE ID = '500'", [.text(Self.keyID("6A"))])
        let report = try write(fixture, tags: [tags])
        #expect(report.tagWritten.isEmpty && report.tagBlocked.first?.reason?.contains("rekordbox에서 곡 정보가 바뀌었습니다") == true)
        #expect(try content(fixture)["KeyID"] == Self.keyID("6A"))
    }

    // MARK: 옛 초안

    /// 키 칸이 없던 때의 초안 JSON(칸 아홉 개)
    func legacyDraft(title: String = "새 제목") throws -> TagDraft {
        let fields = { (title: String) in
            #"{"title":"\#(title)","artist":"옛 아티스트","album":"옛 앨범","albumArtist":"","genre":"옛 장르","composer":"","year":"","trackNumber":"","comment":""}"#
        }
        let json = #"{"trackUUID":"track-uuid-500","base":\#(fields("옛 제목")),"fields":\#(fields(title))}"#
        return try JSONDecoder().decode(TagDraft.self, from: Data(json.utf8))
    }

    @Test(arguments: [0, 256, 257]) func 키_칸이_없던_옛_초안은_키가_있는_곡에서도_막히지_않고_키를_그대로_둔다(state: Int) throws {
        let (fixture, _) = try keyLibrary(state: state, key: "5A")
        let tags = try legacyDraft()
        #expect(tags.base.musicalKey == "" && tags.changedKeys == [.title])
        let before = try content(fixture)
        let report = try write(fixture, tags: [tags])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty, "\(report.tagBlocked.map(\.reason))")
        let after = try content(fixture)
        #expect(after["Title"] == "새 제목" && after["KeyID"] == before["KeyID"])
        // 커밋 뒤 다시 읽은 곡 정보도 키는 그대로다(쓰기 안의 검증과 커밋 뒤 검증이 모두 통과했다)
        let db = try fixture.open()
        defer { db.close() }
        #expect(try RekordboxWriter.currentTags(db: db, contentID: "500")?.musicalKey == "5A")
    }

    @Test func 키를_안_고친_초안은_그_사이_rekordbox에서_키가_바뀌어도_쓴다() throws {
        // 키 칸은 이 초안이 쓰지 않으므로 기준을 비교하지 않는다(다른 칸은 예전처럼 비교한다)
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        let tags = try draft(fixture, track) { $0.comment = "새 코멘트" }
        try fixture.execute("UPDATE djmdContent SET KeyID = ? WHERE ID = '500'", [.text(Self.keyID("6A"))])
        #expect(try write(fixture, tags: [tags]).tagWritten.count == 1)
        #expect(try content(fixture)["KeyID"] == Self.keyID("6A") && content(fixture)["Commnt"] == "새 코멘트")
        // 다른 칸이 바뀌었으면 여전히 막는다
        let again = try draft(fixture, track) { $0.comment = "또 코멘트" }
        try fixture.execute("UPDATE djmdContent SET Title = '바뀐 제목' WHERE ID = '500'")
        #expect(try write(fixture, tags: [again]).tagBlocked.count == 1)
    }

    @Test func 백업에_둔_키_칸_없는_옛_초안도_읽는다() throws {
        // 백업의 `tag-drafts/`는 `try?`로 읽는다. 옛 파일이 조용히 사라지면 되돌려도 초안이 돌아오지 않는다.
        let backup = FileManager.default.temporaryDirectory.appending(path: "djc-key-backup-\(UUID().uuidString)")
        let folder = backup.appending(path: "tag-drafts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backup) }
        let legacy = try legacyDraft()
        let json = #"{"trackUUID":"track-uuid-500","base":{"title":"옛 제목","artist":"옛 아티스트","album":"옛 앨범","albumArtist":"","genre":"옛 장르","composer":"","year":"","trackNumber":"","comment":""},"fields":{"title":"새 제목","artist":"옛 아티스트","album":"옛 앨범","albumArtist":"","genre":"옛 장르","composer":"","year":"","trackNumber":"","comment":""}}"#
        try Data(json.utf8).write(to: folder.appending(path: "track-uuid-500.json"))
        #expect(RekordboxWriter.tagDrafts(in: backup) == [legacy])
    }

    // MARK: 다시 읽기 확인

    @Test func 쓴_뒤_KeyID_칸_자체를_다시_읽어_확인한다() throws {
        // ScaleName 조인으로는 '0'·''·NULL이 모두 키 없음이라 구별하지 못한다. 지우기는 '0'(글자)이어야 한다.
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        let tags = try draft(fixture, track) { $0.musicalKey = "" }
        _ = try write(fixture, tags: [tags])
        let db = try fixture.open()
        defer { db.close() }
        let usn = try #require(Int(try content(fixture)["rb_local_usn"] ?? ""))
        var expectation = RekordboxWriter.TagExpectation(contentID: "500", fields: try #require(try RekordboxWriter.currentTags(db: db, contentID: "500")),
                                                         trackInfoUpdated: "3", contentUSN: usn, dataStatus: 257, keyID: "0")
        try RekordboxWriter.verifyTags(db: db, expectation)
        for tampered in ["''", "NULL", "'1486464042'"] {
            try db.execute("UPDATE djmdContent SET KeyID = \(tampered) WHERE ID = '500'")
            #expect(throws: DJCError.self, "\(tampered)") { try RekordboxWriter.verifyTags(db: db, expectation) }
        }
        try db.execute("UPDATE djmdContent SET KeyID = '0' WHERE ID = '500'")
        expectation.keyID = "1486464042"
        #expect(throws: DJCError.self) { try RekordboxWriter.verifyTags(db: db, expectation) }
    }

    // MARK: 호환 확인

    @Test func 쓰기_전_확인은_djmdKey의_세_칸이_있어야_한다() throws {
        #expect(RekordboxCompatibility.requiredColumns["djmdKey"] == ["ID", "ScaleName", "rb_local_deleted"])
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        let before = try content(fixture)
        let tags = try draft(fixture, track) { $0.comment = "새 코멘트" }
        try fixture.execute("ALTER TABLE djmdKey RENAME COLUMN ScaleName TO ScaleName2")
        #expect(throws: DJCError.self) { try write(fixture, tags: [tags]) }
        #expect(try content(fixture) == before)
    }

    // MARK: 여러 칸 = 하나씩 (키가 든 조합 몇 개만)

    @Test(arguments: [(TagFields.Key.title, 0), (.comment, 256), (.genre, 0), (.artist, 256), (.year, 257)])
    func 키와_다른_칸을_한_번에_쓴_결과는_하나씩_쓴_결과와_같다(other: TagFields.Key, state: Int) throws {
        // 열 칸 조합 전체(156가지)는 시간이 길어 늘리지 않는다. 키는 곡 행의 한 칸이라 이름 행에 닿지 않는 대표 조합만 본다.
        let values: [TagFields.Key: String] = [.title: "새 제목", .comment: "새 코멘트", .genre: "새 장르", .artist: "새 아티스트", .year: "2020"]
        let edit: (inout TagFields) -> Void = { $0[other] = values[other] ?? ""; $0.musicalKey = "5A" }
        let (together, track) = try keyLibrary(state: state, key: "2B")
        let (oneByOne, same) = try keyLibrary(state: state, key: "2B")
        #expect(try write(together, tags: [try draft(together, track, edit)]).tagWritten.count == 1)
        for key in [other, .musicalKey] {
            let step = try draft(oneByOne, same) { $0[key] = key == .musicalKey ? "5A" : (values[other] ?? "") }
            #expect(try write(oneByOne, tags: [step]).tagWritten.count == 1)
        }
        let columns = "Title, Commnt, ReleaseYear, KeyID, TrackInfoUpdated, rb_data_status"
        #expect(try together.rows("SELECT \(columns) FROM djmdContent WHERE ID = '500'") == oneByOne.rows("SELECT \(columns) FROM djmdContent WHERE ID = '500'"))
        #expect(try releaseState(together) == releaseState(oneByOne))
        #expect(try otherTables(together)["djmdKey"] == otherTables(oneByOne)["djmdKey"])
    }
}

/// 키 저장과 재생 목록 XML(`masterPlaylists6.xml` Timestamp).
/// S5 K1(2026-10-04, rekordbox 7.2.18): 동기화 곡의 키 3B → 5A 저장이 `KeyID`·`TrackInfoUpdated` '6' → '7'·256 → 257을 고치고, 그 곡이 든
/// 목록의 Timestamp도 곡 행 `updated_at` 약 15ms 뒤 시각으로 고쳤다[확인]. 정보 패널 아홉 칸(#173)과 같은 규칙이다.
/// 어느 칸이 XML을 고치는지는 `RekordboxWriter.playlistXMLTagKeys` 한 곳이다.
extension RekordboxTagWriterTests {
    @Test func 키만_고친_초안도_곡이_든_목록의_Timestamp를_쓴_시각으로_고친다() throws {
        // S5 K1: 곡 하나, 살아 있는 목록 하나. 다른 목록·부모 폴더는 그대로.
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        let url = try withPlaylists(fixture, [
            PlaylistSpec(id: "100", name: "폴더", seq: 1, isFolder: true),
            PlaylistSpec(id: "201", name: "곡이 든 목록", parentID: "100", seq: 1, contentIDs: ["500"]),
            PlaylistSpec(id: "202", name: "다른 곡 목록", seq: 2, contentIDs: ["501"]),
        ])
        let before = try Data(contentsOf: url)
        let tags = try draft(fixture, track) { $0.musicalKey = "5A" }
        // 미리 보기는 XML을 건드리지 않는다
        #expect(try write(fixture, tags: [tags], dryRun: true).tagWritten.count == 1)
        #expect(try Data(contentsOf: url) == before)
        #expect(try write(fixture, tags: [tags]).tagWritten.count == 1)
        let after = try timestamps(url)
        #expect(after[MasterPlaylistsXML.hex("201") ?? ""] == nowMS)
        for id in ["100", "202"] { #expect(after[MasterPlaylistsXML.hex(id) ?? ""] == 1_000, "\(id)") }
        #expect(try content(fixture)["KeyID"] == Self.keyID("5A"))
        // 지우기도 같다
        try before.write(to: url)
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "" }]).tagWritten.count == 1)
        #expect(try timestamps(url)[MasterPlaylistsXML.hex("201") ?? ""] == nowMS)
    }

    @Test func 키만_고친_곡이_어느_목록에도_없으면_XML을_읽지도_고치지도_않는다() throws {
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        try Data("망가짐".utf8).write(to: url)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "5A" }])
        #expect(report.tagWritten.count == 1 && report.tagBlocked.isEmpty)
        #expect(try Data(contentsOf: url) == Data("망가짐".utf8))
    }

    @Test func 목록에_든_곡의_키_초안은_XML이_깨져_있으면_다른_칸처럼_막는다() throws {
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        try fixture.add(PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"]))
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        try Data("망가짐".utf8).write(to: url)
        let before = try content(fixture)
        let report = try write(fixture, tags: [try draft(fixture, track) { $0.musicalKey = "5A" }])
        #expect(report.tagWritten.isEmpty && report.backup == nil)
        #expect(report.tagBlocked.first?.reason?.contains("masterPlaylists6.xml") == true)
        #expect(try content(fixture) == before && fixture.localUpdateCount() == 2000)
        #expect(try Data(contentsOf: url) == Data("망가짐".utf8))
    }

    @Test func 키와_다른_칸을_함께_고친_초안도_XML을_고친다() throws {
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        let url = try withPlaylists(fixture, [PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: ["500"])])
        #expect(try write(fixture, tags: [try draft(fixture, track) { $0.comment = "새 코멘트"; $0.musicalKey = "5A" }]).tagWritten.count == 1)
        #expect(try timestamps(url)[MasterPlaylistsXML.hex("201") ?? ""] == nowMS)
    }

    @Test func 한_쓰기에서_키를_고친_곡과_다른_칸을_고친_곡의_목록이_모두_고쳐진다() throws {
        // 곡 500(키, 목록 201) + 곡 501(제목, 목록 202): 두 목록 모두 고치고, 곡이 안 든 목록 203은 그대로다
        let (fixture, track) = try keyLibrary(state: 256, key: "2B")
        let neighbor = TrackSpec(id: "501", uuid: "track-uuid-501")
        let url = try withPlaylists(fixture, [
            PlaylistSpec(id: "201", name: "키", seq: 1, contentIDs: ["500"]),
            PlaylistSpec(id: "202", name: "제목", seq: 2, contentIDs: ["501"]),
            PlaylistSpec(id: "203", name: "아무도 안 고침", seq: 3, contentIDs: []),
        ])
        let tags = [try draft(fixture, track) { $0.musicalKey = "5A" }, try draft(fixture, neighbor) { $0.title = "이웃 새 제목" }]
        #expect(try write(fixture, tags: tags).tagWritten.count == 2)
        let after = try timestamps(url)
        #expect(after[MasterPlaylistsXML.hex("201") ?? ""] == nowMS && after[MasterPlaylistsXML.hex("202") ?? ""] == nowMS)
        #expect(after[MasterPlaylistsXML.hex("203") ?? ""] == 1_000)
    }

    @Test func XML을_고치는_칸의_집합은_한_곳에_있고_키도_든다() {
        // 평점·곡 색(#65)도 R65(2026-10-09)에서 확인해 모든 칸이 고친다
        #expect(RekordboxWriter.playlistXMLTagKeys == Set(TagFields.Key.allCases))
        #expect(RekordboxWriter.playlistXMLTagKeys.contains(.musicalKey))
    }
}
