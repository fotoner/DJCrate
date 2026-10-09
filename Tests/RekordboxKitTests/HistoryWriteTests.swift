import DJCDomain
import DJCTestKit
import RekordboxFixtures
import Foundation
@testable import RekordboxKit
import Testing

/// USB 기기 재생 기록을 rekordbox Histories에 넣기(#43). 기대값은 2026-10-09 rekordbox 7.2.19 실험에서 본 행이다: EXPORT 모드에서
/// USB "SEUNGMOOK 001"의 곡 1개 기록(곡 エクストラ・マジック・アワー)을 rekordbox가 자동으로 가져온 전후 스냅샷을 `djc lab db-diff`로 비교했다
/// (docs/rekordbox-internals.md "재생 기록").
/// 기록·항목의 ID·UUID는 난수라 시험에서 정해 주고 모양을 본다. 쓰기 관문(`writesHistories`)을 닫은 경우는 시험이 닫아서 본다.
@Suite("rekordbox 재생 기록 쓰기 — USB 기록 가져오기 실험으로 확인한 모양")
struct HistoryWriteTests {
    /// 2026-10-09 05:47:14 UTC = 14:47:14 KST(실험에서 기록을 가져온 초)
    let now = Date(timeIntervalSince1970: 1_791_524_834)
    let stamp = "2026-10-09 05:47:14.000 +00:00"
    static let seoul = TimeZone(identifier: "Asia/Seoul")!
    /// 실험 전 변경 카운터(실험 뒤 월 폴더가 308558을 받았다)
    static let startCount = 308_557
    /// 실험 곡
    static let track = "44330620"

    // MARK: 준비

    func folder(_ id: String, _ name: String, parent: String, seq: Int, deleted: Int = 0) -> [String: CipherDatabase.Value] {
        ["ID": .text(id), "Seq": .int(seq), "Name": .text(name), "Attribute": .int(1), "ParentID": .text(parent),
         "DateCreated": .text("2026-01-11 17:26:54"), "UUID": .text(id), "rb_data_status": .int(0), "rb_local_deleted": .int(deleted),
         "rb_local_usn": .int(300_000 + seq)]
    }

    func history(_ id: String, _ name: String, parent: String, seq: Int, deleted: Int = 0) -> [String: CipherDatabase.Value] {
        ["ID": .text(id), "Seq": .int(seq), "Name": .text(name), "Attribute": .int(0), "ParentID": .text(parent),
         "DateCreated": .text("2026-08-01 23:12:27"), "UUID": .text(UUID().uuidString.lowercased()), "rb_data_status": .int(0),
         "rb_local_deleted": .int(deleted), "rb_local_usn": .int(303_009 + seq)]
    }

    /// 실험 전 라이브러리 모양(읽기 전용 조사와 같은 모양): 연 폴더 2020…2026(root 안 Seq 1…7), 2026 아래 월 폴더 1·6·8월(Seq 1·2·3)과
    /// 8월의 기록 셋("HISTORY 2026-08-01", "(1)", "(2)"). 곡: 실험 곡(상태 0, DJPlayCount 0, TrackInfoUpdated '3'), 501(상태 0, 두 카운터 NULL),
    /// 502(지운 곡), 503(동기화 곡 256), 504(상태 0).
    func library(years: ClosedRange<Int> = 2020...2026, months: [Int] = [1, 6, 8],
                 extra: (RekordboxFixture.Session) throws -> Void = { _ in }) throws -> RekordboxFixture {
        let fixture = try RekordboxFixture(localUpdateCount: Self.startCount)
        for (id, status) in [(Self.track, 0), ("501", 0), ("502", 0), ("503", 256), ("504", 0)] {
            var track = TrackSpec(id: id, uuid: "uuid-\(id)")
            track.title = id == Self.track ? "エクストラ・マジック・アワー" : "합성 곡 \(id)"
            track.trackInfoUpdated = "3"
            track.dataStatus = status
            try fixture.add(track)
        }
        try fixture.session { db in
            try db.execute("UPDATE djmdContent SET DJPlayCount = 0 WHERE ID = ?", [.text(Self.track)])
            try db.execute("UPDATE djmdContent SET DJPlayCount = 0 WHERE ID IN ('501', '503', '504')")
            try db.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '502'")
            for (offset, year) in years.enumerated() {
                try db.insert("djmdHistory", folder(String(year), String(year), parent: "root", seq: offset + 1))
            }
            for (offset, month) in months.enumerated() {
                try db.insert("djmdHistory", folder(String(format: "2026%02d", month), String(month), parent: "2026", seq: offset + 1))
            }
            for (offset, name) in ["HISTORY 2026-08-01", "HISTORY 2026-08-01 (1)", "HISTORY 2026-08-01 (2)"].enumerated() {
                let id = String(1_960_492 + offset)
                try db.insert("djmdHistory", history(id, name, parent: "202608", seq: offset + 1))
                try db.insert("djmdSongHistory", ["ID": .text(UUID().uuidString.lowercased()), "HistoryID": .text(id), "ContentID": .text("501"),
                                                  "TrackNo": .int(1), "UUID": .text(UUID().uuidString.lowercased()), "rb_local_deleted": .int(0)])
            }
            try extra(db)
        }
        return fixture
    }

    /// 기록 ID는 차례로, UUID는 "00000000-0000-4000-8000-00000000000n"(소문자 v4 모양)으로 정한다.
    func environment(ids: [String]) -> RekordboxWriter.HistoryEnvironment {
        var ids = ids[...]
        var count = 0
        return RekordboxWriter.HistoryEnvironment(timeZone: Self.seoul, historyID: { ids.popFirst() ?? String(UInt32.random(in: 1_000_000_000...UInt32.max)) },
                                                  uuid: {
                                                      count += 1
                                                      return "00000000-0000-4000-8000-" + String(format: "%012d", count)
                                                  })
    }

    func experiment(_ contentIDs: [String] = [Self.track], name: String = "HISTORY 2026-10-09", id: String = "usbhistory-test",
                    date: Date? = nil) -> HistoryImport {
        HistoryImport(id: id, name: name, dateCreated: date ?? now, contentIDs: contentIDs)
    }

    @discardableResult
    func write(_ fixture: RekordboxFixture, _ histories: [HistoryImport], drafts: [CueDraft] = [], tags: [TagDraft] = [], dryRun: Bool = false,
               opens: Bool = true, ids: [String] = ["2063847119"]) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: drafts, grids: [], gains: [:], tags: tags, analysisInputs: [:], histories: histories, to: fixture.database,
                                  dryRun: dryRun, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot,
                                  attachesAnalysis: RekordboxWriter.attachesAnalysis, writesHistories: opens,
                                  historyEnvironment: environment(ids: ids))
    }

    func row(_ fixture: RekordboxFixture, _ table: String, _ id: String) throws -> [String: String] {
        try #require(try fixture.rows("SELECT * FROM \(table) WHERE ID = ?", [.text(id)]).first)
    }

    func content(_ fixture: RekordboxFixture, _ id: String = Self.track) throws -> [String: String] {
        try row(fixture, "djmdContent", id)
    }

    /// 기록 표·곡 표 전체와 변경 카운터
    func state(_ fixture: RekordboxFixture) throws -> [[[String: String]]] {
        let histories = try fixture.rows("SELECT * FROM djmdHistory ORDER BY ID")
        let entries = try fixture.rows("SELECT * FROM djmdSongHistory ORDER BY ID")
        let contents = try fixture.rows("SELECT * FROM djmdContent ORDER BY ID")
        let count = try fixture.localUpdateCount()
        return [histories, entries, contents, [["count": String(count)]]]
    }

    func backups(_ fixture: RekordboxFixture) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: fixture.backups.path)) ?? []
    }

    func isUUID(_ text: String?) -> Bool {
        (text ?? "").range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    // MARK: 실험 재현

    @Test func 실험처럼_월_폴더_기록_항목을_넣고_곡의_재생_횟수를_올린다() throws {
        let fixture = try library()
        let xmlURL = fixture.root.appending(path: "masterPlaylists6.xml")
        try MasterPlaylistsXMLTests.empty.write(to: xmlURL, atomically: true, encoding: .utf8)
        let xmlBefore = try Data(contentsOf: xmlURL)
        let before = try content(fixture)
        let oldHistories = try fixture.rows("SELECT * FROM djmdHistory ORDER BY ID")
        let oldEntries = try fixture.rows("SELECT * FROM djmdSongHistory ORDER BY ID")
        let others = try fixture.rows("SELECT * FROM djmdContent WHERE ID != ? ORDER BY ID", [.text(Self.track)])

        let report = try write(fixture, [experiment()])
        #expect(report.historyOutcomes == [RekordboxWriter.HistoryOutcome(id: "usbhistory-test", name: "HISTORY 2026-10-09", historyID: "2063847119",
                                                                          status: .written, reason: nil, entries: 1, skipped: 0)])
        #expect(report.backup != nil && report.finalUpdateCount == 308_561)

        // 월 폴더: ID "yyyyMM", 이름 월 숫자, 2026 안 다음 번호(1·6·8월 다음 4), UUID = ID, DateCreated는 기록과 같은 로컬 시각
        #expect(try row(fixture, "djmdHistory", "202610") == [
            "ID": "202610", "Seq": "4", "Name": "10", "Attribute": "1", "ParentID": "2026", "DateCreated": "2026-10-09 14:47:14", "UUID": "202610",
            "rb_data_status": "0", "rb_local_data_status": "0", "rb_local_deleted": "0", "rb_local_synced": "0", "usn": "NULL",
            "rb_local_usn": "308558", "created_at": stamp, "updated_at": stamp,
        ])
        // 기록: 숫자 ID, 월 폴더 안 첫 자리, UUID 소문자 v4
        let history = try row(fixture, "djmdHistory", "2063847119")
        #expect(isUUID(history["UUID"]))
        #expect(history.filter { $0.key != "UUID" } == [
            "ID": "2063847119", "Seq": "1", "Name": "HISTORY 2026-10-09", "Attribute": "0", "ParentID": "202610",
            "DateCreated": "2026-10-09 14:47:14", "rb_data_status": "0", "rb_local_data_status": "0", "rb_local_deleted": "0",
            "rb_local_synced": "0", "usn": "NULL", "rb_local_usn": "308559", "created_at": stamp, "updated_at": stamp,
        ])
        // 항목: ID·UUID 둘 다 소문자 v4(서로 다름), TrackNo 1
        let entry = try #require(try fixture.rows("SELECT * FROM djmdSongHistory WHERE HistoryID = '2063847119'").first)
        #expect(isUUID(entry["ID"]) && isUUID(entry["UUID"]) && entry["ID"] != entry["UUID"] && entry["UUID"] != history["UUID"])
        #expect(entry.filter { $0.key != "ID" && $0.key != "UUID" } == [
            "HistoryID": "2063847119", "ContentID": Self.track, "TrackNo": "1", "rb_data_status": "0", "rb_local_data_status": "0",
            "rb_local_deleted": "0", "rb_local_synced": "0", "usn": "NULL", "rb_local_usn": "308560", "created_at": stamp, "updated_at": stamp,
        ])
        #expect(try fixture.rows("SELECT count(*) AS n FROM djmdSongHistory WHERE HistoryID = '2063847119'") == [["n": "1"]])

        // 곡 행: DJPlayCount 0 → 1(정수), TrackInfoUpdated '3' → '4'(글자), 변경 번호·시각만. 상태 0은 그대로
        let after = try content(fixture)
        #expect(Set(before.keys.filter { before[$0] != after[$0] }) == ["DJPlayCount", "TrackInfoUpdated", "rb_local_usn", "updated_at"])
        #expect(after["DJPlayCount"] == "1" && after["TrackInfoUpdated"] == "4" && after["rb_local_usn"] == "308561" && after["updated_at"] == stamp)
        #expect(after["rb_data_status"] == "0")
        #expect(try fixture.rows("SELECT typeof(DJPlayCount) AS plays, typeof(TrackInfoUpdated) AS info FROM djmdContent WHERE ID = ?",
                                 [.text(Self.track)]) == [["plays": "integer", "info": "text"]])
        // 변경 번호: 월 폴더 → 기록 → 항목 → 곡 행, 마지막 번호가 카운터
        #expect(try fixture.localUpdateCount() == 308_561)

        // 그 밖의 행과 masterPlaylists6.xml은 그대로
        #expect(try fixture.rows("SELECT * FROM djmdHistory WHERE ID NOT IN ('202610', '2063847119') ORDER BY ID") == oldHistories)
        #expect(try fixture.rows("SELECT * FROM djmdSongHistory WHERE HistoryID != '2063847119' ORDER BY ID") == oldEntries)
        #expect(try fixture.rows("SELECT * FROM djmdContent WHERE ID != ? ORDER BY ID", [.text(Self.track)]) == others)
        #expect(try Data(contentsOf: xmlURL) == xmlBefore)

        // 다시 읽으면 연 › 월 폴더 아래 기록이다
        let loaded = try #require(try RekordboxLibrary.load(snapshot: fixture.database).histories.first { $0.id == "2063847119" })
        #expect(loaded.folderNames == ["2026", "10"] && loaded.seq == 1 && loaded.entries.map(\.contentID) == [Self.track])
    }

    // MARK: 관문

    @Test func 쓰기를_열기_전에는_모두_막고_DB와_백업을_건드리지_않는다() throws {
        let fixture = try library()
        let bytes = try Data(contentsOf: fixture.database)
        let report = try write(fixture, [experiment(), experiment(["501"], id: "other")], opens: false)
        #expect(report.historyOutcomes?.map(\.id) == ["usbhistory-test", "other"])
        for outcome in report.historyOutcomes ?? [] {
            #expect(outcome.status == .blocked && outcome.historyID == nil && outcome.entries == 0 && outcome.skipped == 0)
            #expect(outcome.reason?.contains("보존") == true, "\(outcome.reason ?? "")")
        }
        #expect(report.historyOutcomes?.first?.name == "HISTORY 2026-10-09")
        #expect(report.backup == nil && report.finalUpdateCount == nil)
        #expect(try Data(contentsOf: fixture.database) == bytes)
        #expect(backups(fixture).isEmpty)
    }

    @Test func 관문이_닫혀도_다른_초안은_평소처럼_쓴다() throws {
        let fixture = try library()
        let histories = try fixture.rows("SELECT * FROM djmdHistory ORDER BY ID")
        var cue = CueDraft(trackUUID: "uuid-\(Self.track)", rekordboxCues: [])
        cue.place(EditableCue(kind: .memory, time: 10))
        let report = try write(fixture, [experiment()], drafts: [cue], opens: false)
        #expect(report.written.count == 1 && report.historyBlocked.count == 1 && report.backup != nil)
        #expect(try fixture.rows("SELECT * FROM djmdHistory ORDER BY ID") == histories)
        #expect(try content(fixture)["DJPlayCount"] == "0")
    }

    @Test func 앱_진입은_writesHistories를_따른다() throws {
        let fixture = try library()
        let before = try state(fixture)
        let report = try RekordboxWriter.write(drafts: [], histories: [experiment()], to: fixture.database, dryRun: true, now: now,
                                               backups: fixture.backups)
        let expected: RekordboxWriter.HistoryOutcome.Status = RekordboxWriter.writesHistories ? .written : .blocked
        #expect(report.historyOutcomes?.first?.status == expected)
        #expect(try state(fixture) == before)
    }

    // MARK: 이름·폴더

    @Test func 같은_이름의_살아_있는_기록이_있으면_가장_작은_빈_번호를_붙인다() throws {
        // rekordbox가 한 번에 가져온 기록 셋이 "HISTORY 2026-08-01", "(1)", "(2)"였다(실제 라이브러리, 읽기만). 지운 기록의 이름은 빈 것으로 본다.
        let fixture = try library(months: [1, 6, 8, 10]) { db in
            try db.insert("djmdHistory", history("1001", "HISTORY 2026-10-09", parent: "202610", seq: 1))
            try db.insert("djmdHistory", history("1002", "HISTORY 2026-10-09 (2)", parent: "202610", seq: 2))
            try db.insert("djmdHistory", history("1003", "HISTORY 2026-10-09 (1)", parent: "202610", seq: 3, deleted: 1))
        }
        let month = try row(fixture, "djmdHistory", "202610")
        // 이미 " (n)"이 붙은 이름이 겹치면 번호를 떼고 다시 매긴다("… (1) (1)"이 되지 않게)
        let report = try write(fixture, [experiment(id: "a"), experiment(["501"], id: "b"), experiment(["504"], name: "HISTORY 2026-10-09 (1)", id: "c")],
                               ids: ["2063847119", "2063847120", "2063847121"])
        #expect(report.historyOutcomes?.map(\.name) == ["HISTORY 2026-10-09 (1)", "HISTORY 2026-10-09 (3)", "HISTORY 2026-10-09 (4)"])
        #expect(report.historyOutcomes?.map(\.historyID) == ["2063847119", "2063847120", "2063847121"])
        // 있던 월 폴더 안 다음 번호(지운 행은 세지 않는다). 있던 폴더 행은 고치지 않는다(실제 라이브러리의 월 폴더는 updated_at = created_at)
        #expect(try fixture.rows("SELECT ID, Seq, ParentID FROM djmdHistory WHERE ID IN ('2063847119', '2063847120', '2063847121') ORDER BY ID") == [
            ["ID": "2063847119", "Seq": "3", "ParentID": "202610"], ["ID": "2063847120", "Seq": "4", "ParentID": "202610"],
            ["ID": "2063847121", "Seq": "5", "ParentID": "202610"],
        ])
        #expect(try row(fixture, "djmdHistory", "202610") == month)
        // 실험으로 확인하지 않은 같은 곡의 여러 기록은 따로 차단하므로 서로 다른 곡으로 이름 규칙을 본다.
        let after = try content(fixture)
        #expect(after["DJPlayCount"] == "1" && after["TrackInfoUpdated"] == "4")
        #expect(try fixture.localUpdateCount() == Self.startCount + 9)
    }

    @Test func 한_번에_가져온_같은_날_기록은_월_폴더를_한_번만_만들고_이름에_번호를_붙인다() throws {
        let fixture = try library()
        let report = try write(fixture, [experiment(id: "a"), experiment(["501"], id: "b")], ids: ["2063847119", "2063847120"])
        #expect(report.historyOutcomes?.map(\.name) == ["HISTORY 2026-10-09", "HISTORY 2026-10-09 (1)"])
        #expect(try fixture.rows("SELECT ID FROM djmdHistory WHERE ParentID = '2026' ORDER BY Seq") == [
            ["ID": "202601"], ["ID": "202606"], ["ID": "202608"], ["ID": "202610"],
        ])
        #expect(try fixture.rows("SELECT ID, Seq, ParentID FROM djmdHistory WHERE ID IN ('2063847119', '2063847120') ORDER BY ID") == [
            ["ID": "2063847119", "Seq": "1", "ParentID": "202610"], ["ID": "2063847120", "Seq": "2", "ParentID": "202610"],
        ])
    }

    @Test func 확인하지_않은_새_연_폴더는_백업_전에_막는다() throws {
        let fixture = try library()
        let before = try state(fixture)
        let date = Date(timeIntervalSince1970: 1_798_731_000)
        let report = try write(fixture, [experiment(name: "HISTORY 2027-01-01", date: date)])
        #expect(report.historyWritten.isEmpty && report.historyBlocked.first?.reason?.contains("연 폴더") == true)
        #expect(report.backup == nil && backups(fixture).isEmpty)
        #expect(try state(fixture) == before)
    }

    @Test func 확인하지_않은_NULL_재생_횟수는_백업_전에_막는다() throws {
        let fixture = try library()
        try fixture.execute("UPDATE djmdContent SET DJPlayCount = NULL WHERE ID = '501'")
        let before = try state(fixture)
        let report = try write(fixture, [experiment(["501"])])
        #expect(report.historyWritten.isEmpty && report.historyBlocked.first?.reason?.contains("재생 횟수") == true)
        #expect(report.backup == nil && backups(fixture).isEmpty)
        #expect(try state(fixture) == before)
    }

    @Test func 같은_곡이_여러_기록에_들면_그_기록들을_백업_전에_막는다() throws {
        let fixture = try library()
        let before = try state(fixture)
        let report = try write(fixture, [experiment(id: "a"), experiment(id: "b")])
        #expect(report.historyWritten.isEmpty && report.historyBlocked.count == 2)
        #expect(report.historyBlocked.allSatisfy { $0.reason?.contains("여러 기록") == true })
        #expect(report.backup == nil && backups(fixture).isEmpty)
        #expect(try state(fixture) == before)
    }

    @Test(arguments: [false, true])
    func 쓰기_대상의_같은_ID가_다른_곡이면_원본_식별로_막는다(_ dryRun: Bool) throws {
        let fixture = try library()
        try fixture.execute("UPDATE djmdContent SET MasterSongID = '900', FileNameL = 'other.mp3', FolderPath = '/synthetic/other.mp3' WHERE ID = ?", [.text(Self.track)])
        var history = experiment()
        history.expectedLibraryID = "1"
        history.trackIdentities = [.init(contentID: Self.track, masterDbId: Int64(RekordboxFixture.masterDBID)!, masterContentId: 800, fileName: "original.mp3")]
        let before = try state(fixture)
        let report = try write(fixture, [history], dryRun: dryRun)
        #expect(report.historyBlocked.first?.reason?.contains("원본") == true)
        #expect(report.backup == nil && backups(fixture).isEmpty)
        #expect(try state(fixture) == before)
    }

    @Test func 다른_컬렉션으로_바뀐_쓰기_대상은_막는다() throws {
        let fixture = try library()
        var history = experiment()
        history.expectedLibraryID = "old-library"
        let before = try state(fixture)
        let report = try write(fixture, [history])
        #expect(report.historyBlocked.first?.reason?.contains("라이브러리") == true)
        #expect(report.backup == nil)
        #expect(try state(fixture) == before)
    }

    @Test(arguments: [false, true])
    func 최신_대상에_이미_같은_기록이_있으면_다시_쓰거나_재생_횟수를_올리지_않는다(_ dryRun: Bool) throws {
        let fixture = try library(months: [1, 6, 8, 10]) { db in
            var existing = history("1234567", "HISTORY 2026-10-09", parent: "202610", seq: 1)
            existing["DateCreated"] = .text("2026-10-09 14:00:00")
            try db.insert("djmdHistory", existing)
            try db.insert("djmdSongHistory", ["ID": .text("existing-entry"), "HistoryID": .text("1234567"), "ContentID": .text(Self.track),
                                              "TrackNo": .int(1), "rb_local_deleted": .int(0)])
        }
        let before = try state(fixture)
        let report = try write(fixture, [experiment()], dryRun: dryRun)
        #expect(report.historyOutcomes?.first?.status == .unchanged && report.historyOutcomes?.first?.historyID == "1234567")
        #expect(report.backup == nil && backups(fixture).isEmpty)
        #expect(try state(fixture) == before)
    }

    @Test func 컬렉션에_없는_곡은_빼고_TrackNo를_1부터_다시_매긴다() throws {
        let fixture = try library()
        let report = try write(fixture, [experiment(["999", Self.track, "502", "501"])])
        let outcome = try #require(report.historyOutcomes?.first)
        #expect(outcome.status == .written && outcome.entries == 2 && outcome.skipped == 2)
        #expect(try fixture.rows("SELECT ContentID, TrackNo, rb_local_usn FROM djmdSongHistory WHERE HistoryID = '2063847119' ORDER BY TrackNo") == [
            ["ContentID": Self.track, "TrackNo": "1", "rb_local_usn": "308560"], ["ContentID": "501", "TrackNo": "2", "rb_local_usn": "308561"],
        ])
        // 곡 행은 처음 나온 순서로 번호를 받는다.
        #expect(try fixture.rows("""
            SELECT ID, DJPlayCount, TrackInfoUpdated, rb_local_usn FROM djmdContent WHERE ID IN (?, '501') ORDER BY rb_local_usn
            """, [.text(Self.track)]) == [
            ["ID": Self.track, "DJPlayCount": "1", "TrackInfoUpdated": "4", "rb_local_usn": "308562"],
            ["ID": "501", "DJPlayCount": "1", "TrackInfoUpdated": "4", "rb_local_usn": "308563"],
        ])
        #expect(try content(fixture, "502")["DJPlayCount"] == "NULL")
    }

    // MARK: 막기

    enum Refused: String, CaseIterable, Sendable {
        case 반복_곡, 동기화_곡, 컬렉션_곡_없음, 빈_이름, 같은_기록_두_번
    }

    @Test(arguments: Refused.allCases)
    func 확인하지_않은_모양의_기록은_막고_백업도_뜨지_않는다(_ refused: Refused) throws {
        let fixture = try library()
        let before = try state(fixture)
        let histories: [HistoryImport], keyword: String
        switch refused {
        // 같은 곡을 두 번 튼 기록은 rekordbox가 DJPlayCount를 몇 올리는지 보지 못했다
        case .반복_곡: histories = [experiment([Self.track, "501", Self.track])]; keyword = "두 번"
        // 실험 곡은 상태 0이었다
        case .동기화_곡: histories = [experiment([Self.track, "503"])]; keyword = "동기화"
        case .컬렉션_곡_없음: histories = [experiment(["999", "502"])]; keyword = "컬렉션"
        case .빈_이름: histories = [experiment(name: "  ")]; keyword = "이름"
        // 같은 보존 기록을 두 번 넘기면 뒤의 것을 막는다(앞의 것은 반복 곡이라 막힌다: 둘 다 막혀 백업이 없다)
        case .같은_기록_두_번: histories = [experiment([Self.track, Self.track]), experiment([Self.track, Self.track])]; keyword = "한 번에 두 번"
        }
        let report = try write(fixture, histories)
        let outcome = try #require(report.historyOutcomes?.last)
        #expect(outcome.status == .blocked && outcome.historyID == nil && outcome.reason?.contains(keyword) == true, "\(outcome.reason ?? "")")
        #expect(report.historyWritten.isEmpty && report.backup == nil)
        #expect(try state(fixture) == before)
        #expect(backups(fixture).isEmpty)
    }

    enum Slot: String, CaseIterable, Sendable {
        case 월_자리에_기록, 지운_월_폴더, 다른_부모의_월_폴더, 지운_연_폴더, 연_자리에_기록, 연_폴더_없는_월_폴더
    }

    @Test(arguments: Slot.allCases)
    func 연_월_폴더_자리에_맞지_않는_행이_있으면_막는다(_ slot: Slot) throws {
        let fixture = try library(years: slot == .연_폴더_없는_월_폴더 || slot == .연_자리에_기록 ? 2020...2025 : 2020...2026) { db in
            switch slot {
            case .월_자리에_기록: try db.insert("djmdHistory", history("202610", "합성 기록", parent: "202608", seq: 4))
            case .지운_월_폴더: try db.insert("djmdHistory", folder("202610", "10", parent: "2026", seq: 4, deleted: 1))
            case .다른_부모의_월_폴더: try db.insert("djmdHistory", folder("202610", "10", parent: "2025", seq: 1))
            case .지운_연_폴더: try db.execute("UPDATE djmdHistory SET rb_local_deleted = 1 WHERE ID = '2026'")
            case .연_자리에_기록: try db.insert("djmdHistory", history("2026", "합성 기록", parent: "202608", seq: 4))
            case .연_폴더_없는_월_폴더: try db.insert("djmdHistory", folder("202610", "10", parent: "2026", seq: 4))
            }
        }
        let before = try state(fixture)
        let report = try write(fixture, [experiment()])
        let outcome = try #require(report.historyOutcomes?.first)
        #expect(outcome.status == .blocked && outcome.reason?.contains("Histories") == true, "\(outcome.reason ?? "")")
        #expect(try state(fixture) == before)
        #expect(backups(fixture).isEmpty)
    }

    @Test func 날짜를_만들_수_없으면_막는다() throws {
        let fixture = try library()
        let report = try write(fixture, [experiment(date: Date(timeIntervalSince1970: .infinity)),
                                         experiment(id: "far", date: Date(timeIntervalSince1970: 400_000_000_000))])
        #expect(report.historyOutcomes?.map(\.status) == [.blocked, .blocked])
        #expect(report.historyOutcomes?.allSatisfy { $0.reason?.contains("날짜") == true } == true)
    }

    // MARK: 다른 초안과 함께

    @Test func 입력_전에_빠진_짝_없는_곡도_제외_수에_남긴다() throws {
        let fixture = try library()
        var history = experiment([Self.track, "999"])
        history.skippedBeforeMatching = 2
        let report = try write(fixture, [history], dryRun: true)
        #expect(report.historyWritten.first?.entries == 1 && report.historyWritten.first?.skipped == 3)
    }

    @Test func 미리_보기는_이름과_항목_수만_알리고_DB를_되돌린다() throws {
        let fixture = try library()
        let before = try state(fixture)
        let report = try write(fixture, [experiment([Self.track, "999"])], dryRun: true)
        #expect(report.historyOutcomes == [RekordboxWriter.HistoryOutcome(id: "usbhistory-test", name: "HISTORY 2026-10-09", historyID: nil,
                                                                          status: .written, reason: nil, entries: 1, skipped: 1)])
        #expect(report.dryRun && report.backup == nil)
        #expect(try state(fixture) == before)
        #expect(backups(fixture).isEmpty)
    }

    @Test func 같은_곡의_큐_초안과_함께_쓰면_곡_행의_마지막_번호는_기록_쪽이다() throws {
        let fixture = try library()
        var cue = CueDraft(trackUUID: "uuid-\(Self.track)", rekordboxCues: [])
        cue.place(EditableCue(kind: .memory, time: 10))
        // 커밋 뒤 큐 검증이 곡 행 번호를 기록 쪽 번호로 보지 않으면 되돌려진다(writeRolledBack)
        let report = try write(fixture, [experiment()], drafts: [cue])
        #expect(report.written.count == 1 && report.historyWritten.count == 1)
        let after = try content(fixture)
        let count = try fixture.localUpdateCount()
        #expect(after["DJPlayCount"] == "1" && after["TrackInfoUpdated"] == "4" && after["rb_local_usn"] == String(count))
        #expect(try fixture.rows("SELECT count(*) AS n FROM djmdCue WHERE ContentID = ?", [.text(Self.track)]) == [["n": "1"]])
    }

    @Test func 같은_곡의_태그_초안과_함께면_그_기록만_막고_태그와_다른_기록은_쓴다() throws {
        let fixture = try library()
        let db = try fixture.open()
        let base = try #require(try RekordboxWriter.currentTags(db: db, contentID: Self.track))
        db.close()
        var tag = TagDraft(trackUUID: "uuid-\(Self.track)", base: base)
        tag.fields.title = "합성 새 제목"
        let report = try write(fixture, [experiment(), experiment(["501"], id: "other")], tags: [tag])
        #expect(report.tagWritten.count == 1)
        let blocked = try #require(report.historyOutcomes?.first)
        #expect(blocked.status == .blocked && blocked.reason?.contains("곡 정보") == true, "\(blocked.reason ?? "")")
        #expect(report.historyOutcomes?.last?.status == .written && report.historyOutcomes?.last?.historyID == "2063847119")
        let after = try content(fixture)
        #expect(after["Title"] == "합성 새 제목" && after["DJPlayCount"] == "0" && after["TrackInfoUpdated"] == "4")
        #expect(try content(fixture, "501")["DJPlayCount"] == "1")
    }

    @Test func 같은_곡의_합치기와_함께면_그_기록만_막고_합치기와_다른_기록은_쓴다() throws {
        // 합치기 묶음: 100을 남기고 200을 뺀다(곡 셋 모두 상태 0, 기록 폴더 없음)
        let merge = DuplicateMergeWriterTests()
        let fixture = try merge.fixture()
        try fixture.session { db in
            try db.insert("djmdHistory", folder("2026", "2026", parent: "root", seq: 1))
            try db.execute("UPDATE djmdContent SET DJPlayCount = 0 WHERE ID IN ('100', '200', '300')")
        }
        let draft = try merge.draft(fixture)
        let report = try RekordboxWriter.write(drafts: [], grids: [], gains: [:], analysisInputs: [:], merges: [draft],
                                               histories: [experiment(["200"]), experiment(["300"], id: "other")], to: fixture.database,
                                               dryRun: false, now: now, backups: fixture.backups, shareRoot: fixture.shareRoot,
                                               attachesAnalysis: RekordboxWriter.attachesAnalysis, writesHistories: true,
                                               historyEnvironment: environment(ids: ["2063847119"]))
        #expect(report.mergeWritten.count == 1)
        #expect(report.historyOutcomes?.map(\.status) == [.blocked, .written])
        #expect(report.historyOutcomes?.first?.reason?.contains("합치기") == true, "\(report.historyOutcomes?.first?.reason ?? "")")
        // 연 폴더는 미리 있고 새 월 폴더만 만든다.
        #expect(try fixture.rows("SELECT ID, Seq, ParentID FROM djmdHistory WHERE Attribute = 1 ORDER BY ID") == [
            ["ID": "2026", "Seq": "1", "ParentID": "root"], ["ID": "202610", "Seq": "1", "ParentID": "2026"],
        ])
        #expect(try fixture.rows("SELECT DJPlayCount, TrackInfoUpdated FROM djmdContent WHERE ID = '300'") == [["DJPlayCount": "1", "TrackInfoUpdated": "2"]])
    }

    @Test func 기록_ID는_겹치거나_모양이_맞지_않는_후보를_다시_뽑는다() throws {
        // 1960492는 이미 있는 기록, 123456은 월 폴더 ID 길이, 0123456789는 앞이 0, 12a4567은 숫자가 아니다
        let fixture = try library()
        let report = try write(fixture, [experiment()], ids: ["1960492", "123456", "0123456789", "12a4567", "2063847119"])
        #expect(report.historyWritten.map(\.historyID) == ["2063847119"])
    }

    // MARK: 커밋 뒤 확인

    @Test(arguments: ["UPDATE djmdContent SET DJPlayCount = 7 WHERE ID = '44330620'",
                      "UPDATE djmdHistory SET Name = '바뀐 이름' WHERE ID = '2063847119'",
                      "UPDATE djmdHistory SET Seq = 9 WHERE ID = '202610'",
                      "DELETE FROM djmdSongHistory WHERE HistoryID = '2063847119'"])
    func 커밋_뒤_다시_읽은_기록이_쓴_것과_다르면_백업으로_되돌린다(_ tamper: String) throws {
        let fixture = try library()
        try RekordboxRestoreFailureTests().tamperOnCommit(fixture, tamper)
        let before = try state(fixture)
        let error = try #require(throws: DJCError.self) { try write(fixture, [experiment()]) }
        guard case let .writeRolledBack(reason) = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(reason.contains("재생 기록"), "\(reason)")
        #expect(try state(fixture) == before)
    }

    // MARK: 보고서

    @Test func 옛_보고서는_기록_결과_없이_읽고_새_보고서는_기록_결과를_잇는다() throws {
        let old = try JSONDecoder().decode(RekordboxWriter.Report.self,
                                           from: Data(#"{"outcomes":[],"dryRun":false,"createdAt":"2026-10-09T05:47:14.000+00:00"}"#.utf8))
        #expect(old.historyOutcomes == nil && old.historyWritten.isEmpty && old.historyBlocked.isEmpty)
        var report = old
        report.historyOutcomes = [RekordboxWriter.HistoryOutcome(id: "a", name: "HISTORY 2026-10-09", historyID: "2063847119", status: .written,
                                                                 reason: nil, entries: 1, skipped: 0)]
        let decoded = try JSONDecoder().decode(RekordboxWriter.Report.self, from: JSONEncoder().encode(report))
        #expect(decoded.historyOutcomes == report.historyOutcomes)
    }
}
