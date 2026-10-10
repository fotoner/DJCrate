import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 동기화 상태 곡 빼기·합치기 막기(#196).
/// rekordbox 7.2.18은 동기화한 곡을 지울 때 행을 지우지 않고 삭제 표시(`rb_local_deleted` 1, 상태 258 → 클라우드 처리 뒤 262)로 남긴다.
/// 곡 빼기·합치기 규칙은 상태 0 시험 곡으로만 실험했으므로, 상태가 0이 아닌 곡·행이 걸리면 묶음 3 실험(세션 D3)으로 규칙을 확인하기 전까지 막는다.
/// 뒤 순번을 당기는 행(`syncedRenumberReason`)과 확인하지 않은 `djmdRecommendLike`도 같은 이유로 막는다.
@Suite("동기화 상태 곡 빼기·합치기 막기")
struct SyncedTrackRemovalTests {
    let writer = RekordboxTrackWriterTests()
    let merge = DuplicateMergeWriterTests()

    static let tables = ["djmdContent", "djmdCue", "contentCue", "contentFile", "djmdMixerParam", "djmdSongPlaylist", "djmdSongHistory",
                         "djmdArtist", "djmdAlbum", "djmdPlaylist"]

    func snapshot(_ fixture: RekordboxFixture) throws -> [[[String: String]]] {
        try Self.tables.map { try fixture.rows("SELECT * FROM \($0) ORDER BY ID") }
    }

    func setStatus(_ fixture: RekordboxFixture, _ table: String, _ column: String, _ id: String, _ status: Int) throws {
        try fixture.execute("UPDATE \(table) SET rb_data_status = ? WHERE \(column) = ?", [.int(status), .text(id)])
    }

    // MARK: 곡 빼기

    /// 0이 아니면 모두 같은 판정(`isSynced`: `ifnull(rb_data_status, 1) != 0`)이라 동기화를 마친 곡(256)과 삭제 처리 뒤 상태(262)만 본다.
    @Test(arguments: [256, 262])
    func 동기화_상태_곡은_빼지_않고_행도_파일도_번호도_그대로_둔다(_ status: Int) throws {
        let (fixture, a, _) = try writer.deleteFixture()
        try setStatus(fixture, "djmdContent", "ID", a.id, status)
        let before = try snapshot(fixture)
        let report = try writer.delete(fixture, [a.id])
        let outcome = try #require(report.deleted.first)
        #expect(outcome.written == false && outcome.reason == RekordboxTrackWriter.syncedTrackReason)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 2000)
        #expect(report.removedFiles.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/USBANLZ/aaa/00000-0000-4000-8000-000000000001/ANLZ0000.DAT").path))
        #expect(FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/Artwork/aaa/00000-0000-4000-8000-000000000001/artwork.jpg").path))
    }

    /// 한 요청에 섞여 있어도 곡마다 막는다. 막힌 곡이 먼저여도 변경 번호는 지운 곡 몫만 쓴다(단독 삭제 골든과 같은 수치).
    @Test func 같은_요청의_상태_0_곡은_그대로_지운다() throws {
        let (fixture, a, b) = try writer.deleteFixture()
        let bBefore = try fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(b.id)])
        let report = try writer.delete(fixture, [b.id, a.id])
        #expect(report.deleted.map(\.written) == [false, true])
        #expect(report.deleted.first?.reason == RekordboxTrackWriter.syncedTrackReason)
        #expect(try fixture.rows("SELECT ID FROM djmdContent ORDER BY ID").map { $0["ID"] } == [b.id])
        #expect(try fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(b.id)]) == bBefore)
        for table in ["djmdSongPlaylist", "djmdSongHistory"] {
            let entry = try #require(try fixture.rows("SELECT TrackNo, rb_local_usn, updated_at FROM \(table) WHERE ContentID = ?", [.text(b.id)]).first)
            #expect(entry == ["TrackNo": "1", "rb_local_usn": "2001", "updated_at": writer.stamp], "\(table)")
        }
        #expect(try fixture.localUpdateCount() == 2001)
        #expect(report.finalUpdateCount == 2001)
        #expect(report.removedFiles.count == 3)
    }

    @Test func 미리_보기도_같은_이유로_막고_아무것도_바꾸지_않는다() throws {
        let (fixture, a, b) = try writer.deleteFixture()
        let before = try snapshot(fixture)
        let report = try RekordboxTrackWriter.delete(contentIDs: [b.id, a.id], from: fixture.database, shareRoot: fixture.shareRoot,
                                                     dryRun: true, now: writer.now, backups: fixture.backups)
        #expect(report.deleted.map(\.written) == [false, true])
        #expect(report.deleted[0].reason == RekordboxTrackWriter.syncedTrackReason && report.deleted[0].contentID == b.id)
        #expect(report.backup == nil && report.removedFiles.isEmpty)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 2000)
    }

    /// 딸린 행 표는 한 목록(`ownRowTables`)을 같은 판정으로 돈다. 목록 전체는 아래 시험이, DB 판정은 처음과 끝 표가 본다.
    @Test(arguments: ["djmdCue", "djmdSongHistory"])
    func 상태_0_곡도_딸린_행이_동기화_상태면_막는다(_ table: String) throws {
        let (fixture, a, _) = try writer.deleteFixture()
        try setStatus(fixture, table, "ContentID", a.id, 256)
        let before = try snapshot(fixture)
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == false && report.deleted.first?.reason == RekordboxTrackWriter.syncedRowsReason)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test func 곡과_함께_지우는_딸린_행_표_여섯을_모두_본다() {
        #expect(RekordboxTrackWriter.ownRowTables == ["djmdCue", "contentCue", "contentFile", "djmdMixerParam", "djmdSongPlaylist", "djmdSongHistory"])
    }

    /// 지우는 앨범·아티스트 행이 동기화 상태이면(상태 0 곡이 동기화된 기존 아티스트·앨범을 쓰는 건 흔하다) 곡도 막는다.
    /// 256·257은 같은 갈래(0이 아니면 동기화 행)라 행마다 한 상태만 쓴다(조합 6 → 3).
    @Test(arguments: [((table: "djmdAlbum", id: "10"), 256), ((table: "djmdArtist", id: "1"), 257), ((table: "djmdArtist", id: "3"), 256)])
    func 이_곡만_쓰던_앨범_아티스트_행이_동기화_상태면_막는다(_ row: (table: String, id: String), _ status: Int) throws {
        let (fixture, a, _) = try writer.deleteFixture()
        try setStatus(fixture, row.table, "ID", row.id, status)
        let before = try snapshot(fixture)
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == false && report.deleted.first?.reason == RekordboxTrackWriter.syncedOrphanReason)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test func 다른_곡이_쓰는_동기화_아티스트는_지우지_않으니_막지_않는다() throws {
        let (fixture, a, _) = try writer.deleteFixture()
        try setStatus(fixture, "djmdArtist", "ID", "2", 256)
        let shared = try fixture.rows("SELECT * FROM djmdArtist WHERE ID = '2'")
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == true)
        #expect(try fixture.rows("SELECT * FROM djmdArtist WHERE ID = '2'") == shared)
    }

    /// 앨범은 남는 곡이 쓰면 지우지 않는다. 그 앨범이 동기화 행이어도 막을 이유가 없다.
    @Test func 남는_곡이_같은_동기화_앨범을_쓰면_막지_않는다() throws {
        let (fixture, a, b) = try writer.deleteFixture()
        try setStatus(fixture, "djmdAlbum", "ID", "10", 256)
        try fixture.execute("UPDATE djmdContent SET AlbumID = '10' WHERE ID = ?", [.text(b.id)])
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == true)
        #expect(try fixture.rows("SELECT ID, rb_data_status FROM djmdAlbum") == [["ID": "10", "rb_data_status": "256"]])
    }

    // MARK: 뒤 순번 당기기

    /// 곡을 빼면 같은 목록·이력의 뒤 항목 순번을 당긴다. 동기화 항목(256)을 고치면 플레이리스트 편집(`touchEntry`)처럼 257로 올린다.
    /// 0·257은 그대로다(사용자 정책: 동기화 데이터를 DJCrate가 고친 행은 257).
    /// 목록·이력은 같은 당기기를 지나 상태 셋을 두 표에 나눠 쓴다(조합 6 → 3).
    @Test(arguments: [("djmdSongPlaylist", (before: 0, after: 0)), ("djmdSongHistory", (before: 256, after: 257)),
                      ("djmdSongPlaylist", (before: 257, after: 257))])
    func 순번을_당기는_뒤_항목은_256만_257로_올린다(_ table: String, _ status: (before: Int, after: Int)) throws {
        let (fixture, a, b) = try writer.deleteFixture()
        try setStatus(fixture, table, "ContentID", b.id, status.before)
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == true)
        let entry = try #require(try fixture.rows("SELECT TrackNo, rb_data_status, rb_local_usn FROM \(table) WHERE ContentID = ?", [.text(b.id)]).first)
        #expect(entry == ["TrackNo": "1", "rb_data_status": "\(status.after)", "rb_local_usn": "2001"], "\(table)")
    }

    /// 쓰기 트랜잭션 안 검증이 끝난 뒤(변경 카운터를 올리는 순간) 당긴 행을 어긋나게 한다. 커밋 뒤 다시 읽어 순번·상태를 기대와 비교하므로
    /// 백업으로 되돌리고 되돌렸다고 알려야 한다(곡 행·딸린 행·파일 모두 쓰기 전).
    @Test(arguments: zip(["djmdSongPlaylist", "djmdSongHistory"], ["TrackNo = TrackNo + 5", "rb_data_status = 256"]))
    func 커밋_뒤_당긴_행의_순번이나_상태가_기대와_다르면_백업으로_되돌리고_그렇게_알린다(_ table: String, _ tamper: String) throws {
        let (fixture, a, b) = try writer.deleteFixture()
        try setStatus(fixture, table, "ContentID", b.id, 256)
        try RekordboxRestoreFailureTests().tamperOnCommit(fixture, "UPDATE \(table) SET \(tamper) WHERE ContentID = '\(b.id)'")
        let before = try snapshot(fixture)
        let error = try #require(throws: DJCError.self) { try writer.delete(fixture, [a.id]) }
        guard case let .writeRolledBack(reason) = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(reason.contains("순번"), "\(reason)")
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 2000)
        #expect(FileManager.default.fileExists(atPath: fixture.shareRoot.appending(path: "PIONEER/USBANLZ/aaa/00000-0000-4000-8000-000000000001/ANLZ0000.DAT").path))
    }

    /// 한 요청에서 여러 곡을 빼면 뒤 항목은 곡마다 한 번씩, 모두 두 번 당겨진다(기대는 곡마다 덮어쓰지 않고 이어 가야 한다).
    @Test(arguments: ["djmdSongPlaylist", "djmdSongHistory"])
    func 한_요청에서_여러_곡을_빼면_뒤_항목은_곡마다_당겨진_자리에서_256만_257로_올린다(_ table: String) throws {
        let (fixture, a, _) = try writer.deleteFixture()
        let list = table == "djmdSongPlaylist" ? "PlaylistID" : "HistoryID"
        var middle = TrackSpec(id: "400"), last = TrackSpec(id: "300")
        middle.dataStatus = 0; last.dataStatus = 0
        try fixture.add(middle); try fixture.add(last)
        for (track, trackNo, status) in [(middle, 3, 0), (last, 4, 256)] {
            try fixture.insert(table, ["ID": .text("x-\(track.id)"), list: .text("L"), "ContentID": .text(track.id), "TrackNo": .int(trackNo),
                                       "UUID": .text("ux-\(track.id)"), "rb_local_deleted": .int(0), "rb_data_status": .int(status), "rb_local_usn": .int(5)])
        }
        let report = try writer.delete(fixture, [a.id, middle.id])
        #expect(report.deleted.map(\.written) == [true, true])
        #expect(try fixture.rows("SELECT ContentID, TrackNo, rb_data_status, rb_local_usn FROM \(table) WHERE \(list) = 'L' ORDER BY TrackNo") ==
                [["ContentID": "200", "TrackNo": "1", "rb_data_status": "0", "rb_local_usn": "2001"],
                 ["ContentID": "300", "TrackNo": "2", "rb_data_status": "257", "rb_local_usn": "2002"]], "\(table)")
        #expect(try fixture.localUpdateCount() == 2002)
    }

    func insertDeletedMarked(_ fixture: RekordboxFixture, table: String, list: String, trackNo: Int) throws {
        let column = table == "djmdSongPlaylist" ? "PlaylistID" : "HistoryID"
        try fixture.insert(table, ["ID": .text("gone-\(list)-\(trackNo)"), column: .text(list), "ContentID": .text("999"), "TrackNo": .int(trackNo),
                                   "UUID": .text("ug-\(list)-\(trackNo)"), "rb_local_deleted": .int(1), "rb_data_status": .int(262), "rb_local_usn": .int(5)])
    }

    /// 지운 표시(`rb_local_deleted` 1)가 남은 행을 순번 당기기가 건드리면 어떻게 되는지 모른다. 그 곡을 막는다.
    @Test(arguments: ["djmdSongPlaylist", "djmdSongHistory"])
    func 뒤_순번에_지운_표시된_행이_있으면_막고_아무것도_바꾸지_않는다(_ table: String) throws {
        let (fixture, a, _) = try writer.deleteFixture()
        try insertDeletedMarked(fixture, table: table, list: "L", trackNo: 3)
        let before = try snapshot(fixture)
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == false && report.deleted.first?.reason == RekordboxTrackWriter.syncedRenumberReason)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 2000)
    }

    /// 순번을 당기지 않는 자리(같은 번호 이하, 다른 목록)의 지운 표시 행은 상관없다.
    @Test(arguments: ["djmdSongPlaylist", "djmdSongHistory"])
    func 앞_순번이나_다른_목록의_지운_표시된_행은_막지_않고_그대로_둔다(_ table: String) throws {
        let (fixture, a, _) = try writer.deleteFixture()
        try insertDeletedMarked(fixture, table: table, list: "L", trackNo: 1)
        try insertDeletedMarked(fixture, table: table, list: "M", trackNo: 5)
        let marked = try fixture.rows("SELECT * FROM \(table) WHERE rb_local_deleted = 1 ORDER BY ID")
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == true)
        #expect(try fixture.rows("SELECT * FROM \(table) WHERE rb_local_deleted = 1 ORDER BY ID") == marked)
    }

    /// 막힌 곡은 변경 번호를 가져가지 않는다: 같은 요청의 다른 곡은 단독 삭제와 같은 번호를 받는다.
    @Test func 순번_때문에_막힌_곡이_먼저여도_다른_곡의_변경_번호는_밀리지_않는다() throws {
        let (fixture, a, _) = try writer.deleteFixture()
        var c = TrackSpec(id: "300")
        c.dataStatus = 0
        try fixture.add(c)
        try fixture.insert("djmdSongPlaylist", ["ID": .text("c-entry"), "PlaylistID": .text("M"), "ContentID": .text(c.id), "TrackNo": .int(1),
                                                "UUID": .text("uc"), "rb_local_deleted": .int(0), "rb_local_usn": .int(5)])
        try insertDeletedMarked(fixture, table: "djmdSongPlaylist", list: "M", trackNo: 2)
        let report = try writer.delete(fixture, [c.id, a.id])
        #expect(report.deleted.map(\.written) == [false, true])
        #expect(report.deleted.first?.reason == RekordboxTrackWriter.syncedRenumberReason)
        #expect(try fixture.rows("SELECT ID FROM djmdContent ORDER BY ID").map { $0["ID"] }.contains(c.id))
        #expect(try fixture.localUpdateCount() == 2001)
        #expect(report.finalUpdateCount == 2001)
    }

    // MARK: djmdRecommendLike

    func insertRecommendLike(_ fixture: RekordboxFixture, _ id: String, _ first: String, _ second: String) throws {
        try fixture.insert("djmdRecommendLike", ["ID": .text(id), "ContentID1": .text(first), "ContentID2": .text(second), "LikeRate": .int(1),
                                                 "UUID": .text("u-\(id)"), "rb_local_deleted": .int(0)])
    }

    /// 확인하지 않은 표라 `ContentID1`·`ContentID2` 어느 쪽에 걸려도 곡을 지우지 않는다(안 막으면 지운 곡을 가리키는 행이 남는다).
    @Test(arguments: [(first: "100", second: "999"), (first: "999", second: "100")])
    func 추천_좋아요_표가_가리키는_곡은_지우지_않는다(_ pair: (first: String, second: String)) throws {
        let (fixture, a, _) = try writer.deleteFixture()
        try insertRecommendLike(fixture, "r1", pair.first, pair.second)
        let before = try snapshot(fixture) + [fixture.rows("SELECT * FROM djmdRecommendLike")]
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == false && report.deleted.first?.reason?.contains("djmdRecommendLike") == true)
        #expect(try snapshot(fixture) + [fixture.rows("SELECT * FROM djmdRecommendLike")] == before)
        #expect(try fixture.localUpdateCount() == 2000)
    }

    @Test func 다른_곡만_가리키는_추천_좋아요_행은_막지_않는다() throws {
        let (fixture, a, b) = try writer.deleteFixture()
        try insertRecommendLike(fixture, "r1", b.id, "999")
        let report = try writer.delete(fixture, [a.id])
        #expect(report.deleted.first?.written == true)
        #expect(try fixture.rows("SELECT ID FROM djmdRecommendLike").count == 1)
    }

    // MARK: 합치기

    /// 남길 곡과 뺄 곡 이름이 달라야 막은 이유가 뺄 곡을 가리키는지 알 수 있다.
    func namedFixture(statuses: [String: Int] = [:]) throws -> RekordboxFixture {
        let fixture = try merge.fixture(statuses: statuses)
        try fixture.execute("UPDATE djmdContent SET Title = '남길 곡' WHERE ID = '100'")
        try fixture.execute("UPDATE djmdContent SET Title = '뺄 곡' WHERE ID = '200'")
        return fixture
    }

    /// 합치기가 막힌 이유: 지울 원본의 이름을 앞에 적는다.
    func sourceReason(_ reason: String, title: String = "뺄 곡") -> String {
        RekordboxWriter.mergeSourceReason(reason, title: title)
    }

    func insertHistory(_ fixture: RekordboxFixture, id: String, contentID: String, trackNo: Int, status: Int = 0, deleted: Int = 0) throws {
        try fixture.insert("djmdSongHistory", ["ID": .text(id), "HistoryID": .text("H"), "ContentID": .text(contentID), "TrackNo": .int(trackNo),
                                               "UUID": .text("u-\(id)"), "rb_data_status": .int(status), "rb_local_deleted": .int(deleted),
                                               "rb_local_usn": .int(5)])
    }

    func expectBlockedDraft(_ fixture: RekordboxFixture, reason expected: String) {
        do {
            _ = try merge.draft(fixture)
            Issue.record("막혀야 합니다")
        } catch let blocked as DuplicateMerge.Blocked {
            #expect(blocked.reason == expected)
        } catch {
            Issue.record("다른 오류: \(error)")
        }
    }

    @Test func 동기화_상태_원본이_있으면_합치기_초안을_만들지_않는다() throws {
        let fixture = try namedFixture(statuses: ["200": 256])
        expectBlockedDraft(fixture, reason: sourceReason(RekordboxTrackWriter.syncedTrackReason))
    }

    /// 이유는 남길 곡이 아니라 지울 원본을 가리켜야 한다(남길 곡을 빼야 하는 것처럼 읽히지 않게). 쓰기 보고의 제목은 남길 곡이다.
    @Test func 막은_이유는_뺄_원본의_이름을_적는다() throws {
        let fixture = try namedFixture()
        let draft = try merge.draft(fixture)
        try setStatus(fixture, "djmdContent", "ID", "200", 256)
        let report = try merge.write(fixture, draft)
        let blocked = try #require(report.mergeBlocked.first)
        #expect(blocked.title == "남길 곡")
        let reason = try #require(blocked.reason)
        #expect(reason == sourceReason(RekordboxTrackWriter.syncedTrackReason))
        #expect(reason.contains("‘뺄 곡’") && !reason.contains("남길 곡"))
    }

    @Test(arguments: [256, 257])
    func 초안을_만든_뒤_원본이_동기화되면_쓰기에서_막고_아무것도_바꾸지_않는다(_ status: Int) throws {
        let fixture = try namedFixture()
        let draft = try merge.draft(fixture)
        try setStatus(fixture, "djmdContent", "ID", "200", status)
        let before = try snapshot(fixture)
        let report = try merge.write(fixture, draft)
        #expect(report.mergeWritten.isEmpty && report.mergeBlocked.count == 1)
        let blocked = try #require(report.mergeBlocked.first)
        #expect(blocked.reason == sourceReason(RekordboxTrackWriter.syncedTrackReason))
        #expect(report.backup == nil)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 1000)
    }

    /// 남는 곡이 동기화 곡이어도 합칠 수 있다: 큐·재생 목록 편집은 동기화 상태를 256 → 257로 올리는 검증된 쓰기 경로를 쓴다.
    @Test func 남는_곡이_동기화_상태여도_합치고_남는_곡은_257이_된다() throws {
        let fixture = try merge.fixture(statuses: ["100": 256])
        let report = try merge.write(fixture, try merge.draft(fixture))
        #expect(report.mergeWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdContent ORDER BY ID").map { $0["ID"] } == ["100", "300"])
        #expect(try fixture.rows("SELECT rb_data_status FROM djmdContent WHERE ID = '100'") == [["rb_data_status": "257"]])
        #expect(try fixture.rows("SELECT Kind, InMsec FROM djmdCue WHERE ContentID = '100' ORDER BY InMsec").count == 2)
    }

    @Test func 원본만_쓰던_동기화_아티스트가_있으면_합치기_초안을_만들지_않는다() throws {
        let fixture = try namedFixture()
        try fixture.insert("djmdArtist", ["ID": .text("1"), "Name": .text("동기화"), "UUID": .text("a1"), "rb_local_deleted": .int(0), "rb_data_status": .int(256)])
        try fixture.execute("UPDATE djmdContent SET ArtistID = '1' WHERE ID = '200'")
        expectBlockedDraft(fixture, reason: sourceReason(RekordboxTrackWriter.syncedOrphanReason))
        // 남는 곡도 그 아티스트를 쓰면 아티스트 행은 지우지 않으니 막지 않는다
        try fixture.execute("UPDATE djmdContent SET ArtistID = '1' WHERE ID = '100'")
        _ = try merge.draft(fixture)
    }

    /// 원본 둘이 함께 쓰던 동기화 아티스트는 둘 다 빠지면 아무도 안 쓴다. 곡 하나씩 보면 놓치므로 함께 빠지는 곡을 같이 센다.
    @Test func 원본_둘이_함께_쓰던_동기화_아티스트도_합치기_초안에서_막는다() throws {
        let fixture = try merge.fixture()
        try fixture.insert("djmdArtist", ["ID": .text("1"), "Name": .text("동기화"), "UUID": .text("a1"), "rb_local_deleted": .int(0), "rb_data_status": .int(257)])
        try fixture.execute("UPDATE djmdContent SET ArtistID = '1' WHERE ID IN ('200', '300')")
        #expect(throws: DuplicateMerge.Blocked.self) {
            try RekordboxWriter.prepareMerge(keeping: "100", removing: ["200", "300"], snapshot: fixture.database)
        }
    }

    /// 원본의 재생 목록 항목도 합치기가 지운다(목록 편집이 먼저 빼지만 동기화 항목을 빼는 규칙은 확인하지 못했다). 다른 딸린 행과 같이 사전 검사가 본다.
    @Test(arguments: ["djmdSongPlaylist", "djmdSongHistory"])
    func 원본의_재생_목록_이력_항목이_동기화_상태이면_합치기_초안을_만들지_않는다(_ table: String) throws {
        let fixture = try namedFixture()
        if table == "djmdSongHistory" { try insertHistory(fixture, id: "h1", contentID: "200", trackNo: 1) }
        try setStatus(fixture, table, "ContentID", "200", 256)
        expectBlockedDraft(fixture, reason: sourceReason(RekordboxTrackWriter.syncedRowsReason))
    }

    @Test(arguments: zip(["djmdSongPlaylist", "djmdSongHistory"], [256, 257]))
    func 초안을_만든_뒤_원본의_항목이_동기화되면_쓰기_전에_막고_아무것도_바꾸지_않는다(_ table: String, _ status: Int) throws {
        let fixture = try namedFixture()
        if table == "djmdSongHistory" { try insertHistory(fixture, id: "h1", contentID: "200", trackNo: 1) }
        let draft = try merge.draft(fixture)
        try setStatus(fixture, table, "ContentID", "200", status)
        let before = try snapshot(fixture)
        let report = try merge.write(fixture, draft)
        #expect(report.mergeWritten.isEmpty && report.mergeBlocked.count == 1)
        let blocked = try #require(report.mergeBlocked.first)
        #expect(blocked.reason == sourceReason(RekordboxTrackWriter.syncedRowsReason))
        #expect(report.backup == nil)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 1000)
    }

    /// 다른 딸린 행(여기서는 파일 행)이 동기화 상태이면 원본 목록 항목과 마찬가지로 쓰기 전에 막는다.
    @Test func 원본의_다른_딸린_행이_동기화_상태이면_쓰기_전에_막고_아무것도_바꾸지_않는다() throws {
        let fixture = try namedFixture()
        let draft = try merge.draft(fixture)
        var source = TrackSpec(id: "200")
        source.dataStatus = 256
        try fixture.addContentFile(for: source, hash: "h", size: 1)
        let before = try snapshot(fixture)
        let report = try merge.write(fixture, draft)
        #expect(report.mergeWritten.isEmpty && report.mergeBlocked.count == 1)
        let blocked = try #require(report.mergeBlocked.first)
        #expect(blocked.reason == sourceReason(RekordboxTrackWriter.syncedRowsReason))
        #expect(report.backup == nil)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 1000)
    }

    /// 묶음마다 따로 본다: 막힌 묶음만 빠지고 나머지는 그대로 쓴다.
    @Test func 두_묶음_중_원본의_목록_항목이_동기화된_묶음만_막고_나머지는_쓴다() throws {
        let fixture = try namedFixture()
        for id in ["400", "500"] {
            var track = TrackSpec(id: id, uuid: "u" + id)
            track.dataStatus = 0; track.fileType = 11; track.length = 30
            track.folderPath = try AudioFixture.wav(seconds: 30, in: fixture.audio, name: id + ".wav").path
            try fixture.add(track)
        }
        try fixture.add(PlaylistSpec(id: "600", name: "다른 목록", seq: 2, contentIDs: ["500"]))
        let first = try merge.draft(fixture)
        let second = try RekordboxWriter.prepareMerge(keeping: "400", removing: ["500"], snapshot: fixture.database)
        try setStatus(fixture, "djmdSongPlaylist", "ContentID", "200", 256)
        let report = try RekordboxWriter.write(drafts: [], merges: [first, second], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.mergeWritten.count == 1 && report.mergeBlocked.count == 1)
        let blocked = try #require(report.mergeBlocked.first)
        #expect(blocked.reason == sourceReason(RekordboxTrackWriter.syncedRowsReason))
        #expect(try fixture.rows("SELECT ID FROM djmdContent ORDER BY ID").map { $0["ID"] } == ["100", "200", "300", "400"])
        #expect(try fixture.rows("SELECT ContentID FROM djmdSongPlaylist WHERE PlaylistID = '600'").map { $0["ContentID"] } == ["400"])
        #expect(try fixture.rows("SELECT ContentID FROM djmdSongPlaylist WHERE PlaylistID = '500' ORDER BY TrackNo").map { $0["ContentID"] } == ["300", "200", "300"])
    }

    // MARK: 합치기: 뒤 순번 당기기

    /// 합치기도 원본의 이력 항목을 지우며 같은 이력의 뒤 순번을 당긴다(재생 목록은 목록 편집이 살아 있는 행만 다시 매긴다).
    @Test func 원본의_이력_뒤에_지운_표시된_행이_있으면_합치기_초안을_만들지_않는다() throws {
        let fixture = try namedFixture()
        try insertHistory(fixture, id: "h1", contentID: "200", trackNo: 1)
        try insertHistory(fixture, id: "h2", contentID: "999", trackNo: 2, status: 262, deleted: 1)
        expectBlockedDraft(fixture, reason: sourceReason(RekordboxTrackWriter.syncedRenumberReason))
    }

    /// 257 → 257은 곡 빼기의 같은 상태 표(`순번을_당기는_뒤_항목은_256만_257로_올린다`)가 본다.
    @Test(arguments: [(before: 0, after: 0), (before: 256, after: 257)])
    func 합치면_원본_이력_뒤_항목의_순번을_당기고_256만_257로_올린다(_ status: (before: Int, after: Int)) throws {
        let fixture = try merge.fixture()
        try insertHistory(fixture, id: "h1", contentID: "200", trackNo: 1)
        try insertHistory(fixture, id: "h2", contentID: "300", trackNo: 2, status: status.before)
        let report = try merge.write(fixture, try merge.draft(fixture))
        #expect(report.mergeWritten.count == 1)
        #expect(try fixture.rows("SELECT TrackNo, rb_data_status FROM djmdSongHistory WHERE ContentID = '300'")
                == [["TrackNo": "1", "rb_data_status": "\(status.after)"]])
        #expect(try fixture.rows("SELECT ID FROM djmdSongHistory WHERE ContentID = '200'").isEmpty)
    }

    /// 같은 재생 목록에서 원본(상태 0) 옆에 동기화 항목(256)이 있어도 합치기를 막지 않는다. 원본 항목은 상태 0이라 검증된 목록 편집
    /// (지운 몫으로 남은 항목을 모두 다시 매기고 256 → 257)이 쓰고, 옆 항목은 자리가 같아도 257이 된다.
    @Test func 원본_옆에_동기화_항목이_있는_재생_목록도_합치고_옆_항목은_257이_된다() throws {
        let fixture = try merge.fixture()
        try setStatus(fixture, "djmdSongPlaylist", "ContentID", "300", 256)
        let draft = try merge.draft(fixture)
        let report = try merge.write(fixture, draft)
        #expect(report.mergeWritten.count == 1 && report.mergeBlocked.isEmpty)
        #expect(try fixture.rows("SELECT ContentID, TrackNo, rb_data_status FROM djmdSongPlaylist WHERE PlaylistID = '500' ORDER BY TrackNo") ==
                [["ContentID": "300", "TrackNo": "1", "rb_data_status": "257"],
                 ["ContentID": "100", "TrackNo": "2", "rb_data_status": "0"],
                 ["ContentID": "300", "TrackNo": "3", "rb_data_status": "257"]])
        #expect(try fixture.rows("SELECT ID FROM djmdContent ORDER BY ID").map { $0["ID"] } == ["100", "300"])
    }

    /// 합치기도 커밋 뒤 다시 읽어 원본 이력 뒤 항목의 순번·상태를 기대와 비교한다.
    @Test(arguments: ["TrackNo = TrackNo + 5", "rb_data_status = 256"])
    func 합치기_커밋_뒤_당긴_이력_항목이_기대와_다르면_백업으로_되돌리고_그렇게_알린다(_ tamper: String) throws {
        let fixture = try merge.fixture()
        try insertHistory(fixture, id: "h1", contentID: "200", trackNo: 1)
        try insertHistory(fixture, id: "h2", contentID: "300", trackNo: 2, status: 256)
        let draft = try merge.draft(fixture)
        try RekordboxRestoreFailureTests().tamperOnCommit(fixture, "UPDATE djmdSongHistory SET \(tamper) WHERE ContentID = '300'")
        let before = try snapshot(fixture)
        let error = try #require(throws: DJCError.self) { try merge.write(fixture, draft) }
        guard case let .writeRolledBack(reason) = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(reason.contains("순번"), "\(reason)")
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 1000)
    }

    /// 한 번에 쓰는 두 묶음이 같은 이력의 뒤 항목을 차례로 당긴다: 기대는 묶음마다 따로 두지 않고 이어 가야 한다.
    @Test func 두_묶음이_같은_이력의_뒤_항목을_차례로_당겨도_합친_자리를_기대한다() throws {
        let fixture = try merge.fixture()
        for id in ["400", "500"] {
            var track = TrackSpec(id: id, uuid: "u" + id)
            track.dataStatus = 0; track.fileType = 11; track.length = 30
            track.folderPath = try AudioFixture.wav(seconds: 30, in: fixture.audio, name: id + ".wav").path
            try fixture.add(track)
        }
        try insertHistory(fixture, id: "h1", contentID: "200", trackNo: 1)
        try insertHistory(fixture, id: "h2", contentID: "500", trackNo: 2)
        try insertHistory(fixture, id: "h3", contentID: "300", trackNo: 3, status: 256)
        let first = try merge.draft(fixture)
        let second = try RekordboxWriter.prepareMerge(keeping: "400", removing: ["500"], snapshot: fixture.database)
        let report = try RekordboxWriter.write(drafts: [], merges: [first, second], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.mergeWritten.count == 2 && report.mergeBlocked.isEmpty)
        #expect(try fixture.rows("SELECT ContentID, TrackNo, rb_data_status FROM djmdSongHistory WHERE HistoryID = 'H' ORDER BY TrackNo") ==
                [["ContentID": "300", "TrackNo": "1", "rb_data_status": "257"]])
    }

    // MARK: 합치기: djmdRecommendLike

    @Test(arguments: [(first: "200", second: "999"), (first: "999", second: "200")])
    func 추천_좋아요_표가_가리키는_원본은_합치기_초안을_만들지_않는다(_ pair: (first: String, second: String)) throws {
        let fixture = try namedFixture()
        try insertRecommendLike(fixture, "r1", pair.first, pair.second)
        do {
            _ = try merge.draft(fixture)
            Issue.record("막혀야 합니다")
        } catch let blocked as DuplicateMerge.Blocked {
            #expect(blocked.reason.contains("djmdRecommendLike") && blocked.reason.contains("‘뺄 곡’"))
        }
    }

    @Test(arguments: [(first: "200", second: "999"), (first: "999", second: "200")])
    func 초안을_만든_뒤_추천_좋아요_행이_원본을_가리키면_쓰기_전에_막는다(_ pair: (first: String, second: String)) throws {
        let fixture = try namedFixture()
        let draft = try merge.draft(fixture)
        try insertRecommendLike(fixture, "r1", pair.first, pair.second)
        let before = try snapshot(fixture)
        let report = try merge.write(fixture, draft)
        #expect(report.mergeWritten.isEmpty && report.mergeBlocked.count == 1)
        let blocked = try #require(report.mergeBlocked.first)
        #expect(blocked.reason?.contains("djmdRecommendLike") == true)
        #expect(report.backup == nil)
        #expect(try snapshot(fixture) == before)
        #expect(try fixture.localUpdateCount() == 1000)
    }

    @Test func 남는_곡이나_다른_곡만_가리키는_추천_좋아요_행은_합치기를_막지_않는다() throws {
        let fixture = try merge.fixture()
        try insertRecommendLike(fixture, "r1", "100", "300")
        let report = try merge.write(fixture, try merge.draft(fixture))
        #expect(report.mergeWritten.count == 1)
        #expect(try fixture.rows("SELECT ID FROM djmdRecommendLike").count == 1)
    }
}
