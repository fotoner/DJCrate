import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// 커밋 뒤 확인·분석 파일 쓰기가 실패했을 때: 백업으로 되돌렸는지, 되돌리지도 못했는지를 다른 오류로 알린다.
/// 쓰기 코드는 그대로 두고 실패는 밖에서 일으킨다(변경 카운터를 올릴 때 도는 트리거, 잠근 폴더).
@Suite("rekordbox 쓰기 실패 뒤 복원")
struct RekordboxRestoreFailureTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)

    /// 트랜잭션 안 검증이 끝난 뒤(변경 카운터를 올리는 순간) `sql`을 돈다. 커밋 뒤 다시 읽으면 쓴 것과 달라져 있다.
    func tamperOnCommit(_ fixture: RekordboxFixture, _ sql: String) throws {
        try fixture.execute("CREATE TRIGGER djc_test_tamper AFTER UPDATE OF int_1 ON agentRegistry BEGIN \(sql); END")
    }

    /// 폴더를 잠근다(안에 쓰거나 지울 수 없게). 끝나면 `unlock`으로 풀어야 픽스처가 지워진다.
    func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
    }

    func unlock(_ fixture: RekordboxFixture) {
        let fm = FileManager.default
        let all = [fixture.root] + (fm.enumerator(at: fixture.root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
        for url in all where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// 복원이 임시로 쓰는 자리(`master.db.djc-restore`)에 지울 수 없는 폴더를 두어 백업 복원을 막는다.
    func blockRestore(_ fixture: RekordboxFixture) throws {
        let blocker = URL(filePath: fixture.database.path + ".djc-restore")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appending(path: "keep"))
        try lock(blocker)
    }

    /// 쓰기가 건드리는 표
    func state(_ fixture: RekordboxFixture) throws -> [[String: String]] {
        try ["djmdContent", "djmdCue", "contentCue", "contentFile", "djmdMixerParam", "agentRegistry"]
            .flatMap { try fixture.rows("SELECT * FROM \($0) ORDER BY 1") }
    }

    func cueDraft(_ fixture: RekordboxFixture) throws -> CueDraft {
        let track = try fixture.add(TrackSpec())
        var draft = CueDraft(trackUUID: track.uuid)
        draft.place(EditableCue(kind: .memory, time: 30))
        return draft
    }

    func writeCue(_ fixture: RekordboxFixture, _ draft: CueDraft) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: [draft], to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
    }

    // MARK: 큐 쓰기

    @Test func 커밋_전에_확인이_실패하면_쓰지_않았다고_알린다() throws {
        let fixture = try RekordboxFixture()
        let draft = try cueDraft(fixture)
        // 카운터를 올린 직전에 한 번 더 올려 두면 트랜잭션 안에서 카운터가 맞지 않는다
        try tamperOnCommit(fixture, "UPDATE agentRegistry SET int_1 = int_1 + 1 WHERE registry_id = 'localUpdateCount'")
        let before = try state(fixture)
        let error = try #require(throws: DJCError.self) { try writeCue(fixture, draft) }
        guard case let .writeVerificationFailed(reason) = error else { Issue.record("커밋 전 실패가 아님: \(error)"); return }
        #expect(reason == "변경 카운터가 맞지 않습니다")
        #expect(error.description == "쓴 결과가 의도와 달라 rekordbox에 쓰지 않았습니다: 변경 카운터가 맞지 않습니다")
        #expect(try state(fixture) == before)
    }

    @Test func 커밋_뒤_확인이_실패하면_백업으로_되돌리고_그렇게_알린다() throws {
        let fixture = try RekordboxFixture()
        let draft = try cueDraft(fixture)
        try tamperOnCommit(fixture, "UPDATE contentCue SET rb_cue_count = rb_cue_count + 100")
        let before = try state(fixture)
        let error = try #require(throws: DJCError.self) { try writeCue(fixture, draft) }
        guard case let .writeRolledBack(reason) = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(reason.hasPrefix("큐 기록의 개수·변경 번호가 다릅니다"), "머리말 없이 사유만")
        #expect(error.description.hasPrefix("쓴 결과를 확인하지 못해 쓰기 전 백업으로 되돌렸습니다: 큐 기록의"))
        #expect(try state(fixture) == before)
    }

    @Test func 커밋_뒤_확인도_복원도_실패하면_복원_실패로_알리고_되돌릴_명령을_준다() throws {
        let fixture = try RekordboxFixture()
        defer { unlock(fixture) }
        let draft = try cueDraft(fixture)
        try tamperOnCommit(fixture, "UPDATE contentCue SET rb_cue_count = rb_cue_count + 100")
        let before = try state(fixture)
        try blockRestore(fixture)
        let error = try #require(throws: DJCError.self) { try writeCue(fixture, draft) }
        guard case let .restoreFailed(reason, restoreError, backup, database) = error else {
            Issue.record("복원 실패 오류가 아님: \(error)")
            return
        }
        #expect(reason.hasPrefix("큐 기록의 개수·변경 번호가 다릅니다") && !restoreError.isEmpty)
        #expect(database == fixture.database.path, "사본 DB는 --db로 되돌린다")
        #expect(FileManager.default.fileExists(atPath: URL(filePath: backup).appending(path: "master.db").path))
        #expect(error.description.contains("rekordbox를 켜지 말고"))
        #expect(error.description.contains("djc rekordbox-restore --backup '\(backup)' --db '\(fixture.database.path)'"))
        #expect(try state(fixture) != before, "복원하지 못했으니 쓴 상태 그대로")

        // 앱의 '되돌리기…'는 가장 최근 쓰기 백업을 고른다(`ReflectionCoordinator.startRestoreLatest`): 바로 이 백업이고,
        // 보고서가 없어 그 뒤 바뀌었는지 모를 뿐 막히지 않는다. 되돌리면 쓰기 전으로 돌아온다.
        let writes = RekordboxWriter.backups(in: fixture.backups).filter(\.isWrite)
        let latest = try #require(writes.first)
        #expect(latest.url.lastPathComponent == URL(filePath: backup).lastPathComponent && latest.finalUpdateCount == nil)
        unlock(fixture)
        _ = try RekordboxWriter.restore(latest.url, to: fixture.database, now: now.addingTimeInterval(60), backups: fixture.backups)
        #expect(try state(fixture) == before)
    }

    // MARK: 그리드 파일

    func gridDraft(_ fixture: RekordboxFixture) throws -> (GridDraft, TrackSpec) {
        let (track, _) = try RekordboxGridWriterTests().makeTrack(fixture)
        var grid = GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track)))
        grid.setBPM(130, at: 0)
        return (grid, track)
    }

    func writeGrid(_ fixture: RekordboxFixture, _ grid: GridDraft) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: [], grids: [grid], to: fixture.database, dryRun: false, now: now,
                                  backups: fixture.backups, shareRoot: fixture.shareRoot)
    }

    @Test func 그리드_파일을_못_쓰면_큐_없이_DB만_바꾼_쓰기도_되돌린다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        defer { unlock(fixture) }
        let (grid, track) = try gridDraft(fixture)
        let before = try state(fixture)
        let dat = try Data(contentsOf: fixture.analysisURL(for: track))
        try lock(fixture.analysisURL(for: track).deletingLastPathComponent())
        let error = try #require(throws: DJCError.self) { try writeGrid(fixture, grid) }
        guard case .writeRolledBack = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(try state(fixture) == before, "곡 BPM·파일 행도 쓰기 전으로")
        #expect(try Data(contentsOf: fixture.analysisURL(for: track)) == dat)
    }

    @Test func 그리드_파일도_DB도_되돌리지_못하면_복원_실패() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        defer { unlock(fixture) }
        let (grid, track) = try gridDraft(fixture)
        try lock(fixture.analysisURL(for: track).deletingLastPathComponent())
        try blockRestore(fixture)
        let error = try #require(throws: DJCError.self) { try writeGrid(fixture, grid) }
        guard case let .restoreFailed(_, restoreError, backup, _) = error else { Issue.record("복원 실패 오류가 아님: \(error)"); return }
        #expect(restoreError.contains("master.db"))
        #expect(FileManager.default.fileExists(atPath: URL(filePath: backup).appending(path: "anlz/manifest.json").path),
                "분석 파일 원본도 백업에 있어 명령 하나로 되돌린다")
    }

    // MARK: BPM·게인만 쓴 쓰기 (#135)

    /// 곡 BPM이 바뀌는 그리드(단일 템포) 쓰기가 고치는 칸. 트랜잭션 안 확인 뒤 하나씩 바꿔 두면 커밋 뒤 다시 읽기가 잡아야 한다.
    static let gridTampers = [
        "UPDATE djmdContent SET BPM = BPM + 1",
        "UPDATE djmdContent SET TrackInfoUpdated = TrackInfoUpdated || '0'",
        "UPDATE djmdContent SET AnalysisUpdated = AnalysisUpdated || '0'",
        "UPDATE djmdContent SET rb_data_status = 256",
        "UPDATE djmdContent SET rb_local_usn = rb_local_usn - 1",
        "UPDATE djmdContent SET updated_at = '2000-01-01 00:00:00.000 +00:00'",
        "UPDATE contentFile SET Hash = 'x'",
        "UPDATE contentFile SET Size = Size + 1",
        "UPDATE contentFile SET rb_local_usn = rb_local_usn - 1",
    ]

    @Test(arguments: gridTampers)
    func BPM만_바꾼_그리드도_커밋_뒤_다시_읽어_다르면_되돌린다(tamper: String) throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, track) = try gridDraft(fixture)
        let dat = try Data(contentsOf: fixture.analysisURL(for: track))
        try tamperOnCommit(fixture, tamper)
        let before = try state(fixture)
        let error = try #require(throws: DJCError.self) { try writeGrid(fixture, grid) }
        guard case let .writeRolledBack(reason) = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(reason.hasPrefix("곡 BPM 확인 실패"))
        #expect(try state(fixture) == before)
        #expect(try Data(contentsOf: fixture.analysisURL(for: track)) == dat, "분석 파일은 DB를 확인한 뒤에 쓴다")
    }

    @Test func 다구간_첫_BPM만_바꾼_그리드도_커밋_뒤_다시_읽어_다르면_되돌린다() throws {
        let (fixture, track, original) = try MultiTempoGridWriterTests().fixture(middleBPM: 151, lastStart: 29305)
        var grid = original
        grid.segments[0].bpm = 121
        let dat = try Data(contentsOf: fixture.analysisURL(for: track))
        try tamperOnCommit(fixture, "UPDATE djmdContent SET TrackInfoUpdated = '99'")
        let before = try state(fixture)
        let error = try #require(throws: DJCError.self) { try writeGrid(fixture, grid) }
        guard case let .writeRolledBack(reason) = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(reason.hasPrefix("곡 BPM 확인 실패"))
        #expect(try state(fixture) == before)
        #expect(try Data(contentsOf: fixture.analysisURL(for: track)) == dat)
    }

    func gains(_ fixture: RekordboxFixture) throws -> [String: Double] {
        var track = TrackSpec()
        track.gain = (high: 16256, low: 0)   // 선형 1.0
        try fixture.add(track)
        return [track.uuid: -3]
    }

    func writeGains(_ fixture: RekordboxFixture, _ gains: [String: Double]) throws -> RekordboxWriter.Report {
        try RekordboxWriter.write(drafts: [], gains: gains, to: fixture.database, dryRun: false, now: now, backups: fixture.backups)
    }

    @Test(arguments: [
        "UPDATE djmdMixerParam SET GainHigh = GainHigh + 1",
        "UPDATE djmdMixerParam SET GainLow = GainLow + 1",
        "UPDATE djmdMixerParam SET rb_data_status = 256",
        "UPDATE djmdMixerParam SET rb_local_usn = rb_local_usn - 1",
        "UPDATE djmdMixerParam SET updated_at = '2000-01-01 00:00:00.000 +00:00'",
    ])
    func 게인만_쓴_쓰기도_커밋_뒤_다시_읽어_다르면_되돌린다(tamper: String) throws {
        let fixture = try RekordboxFixture()
        let gains = try gains(fixture)
        try tamperOnCommit(fixture, tamper)
        let before = try state(fixture)
        let error = try #require(throws: DJCError.self) { try writeGains(fixture, gains) }
        guard case let .writeRolledBack(reason) = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(reason.hasPrefix("오토게인 확인 실패"))
        #expect(try state(fixture) == before)
    }

    @Test func 게인만_쓴_쓰기가_커밋_뒤_확인도_복원도_실패하면_복원_실패() throws {
        let fixture = try RekordboxFixture()
        defer { unlock(fixture) }
        let gains = try gains(fixture)
        try tamperOnCommit(fixture, "UPDATE djmdMixerParam SET GainHigh = GainHigh + 1")
        try blockRestore(fixture)
        let error = try #require(throws: DJCError.self) { try writeGains(fixture, gains) }
        guard case let .restoreFailed(reason, restoreError, _, database) = error else { Issue.record("복원 실패 오류가 아님: \(error)"); return }
        #expect(reason.hasPrefix("오토게인 확인 실패") && restoreError.contains("master.db"))
        #expect(database == fixture.database.path)
    }

    @Test(arguments: ["UPDATE djmdContent SET BPM = BPM + 1 WHERE AnalysisDataPath IS NOT NULL",
                      "UPDATE djmdMixerParam SET GainHigh = GainHigh + 1"])
    func 큐와_함께_쓴_BPM·게인도_커밋_뒤_다시_읽는다(tamper: String) throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, _) = try gridDraft(fixture)
        let cue = try cueDraft(fixture)
        let gains = try gains(fixture)
        try tamperOnCommit(fixture, tamper)
        let before = try state(fixture)
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.write(drafts: [cue], grids: [grid], gains: gains, to: fixture.database, dryRun: false, now: now,
                                      backups: fixture.backups, shareRoot: fixture.shareRoot)
        }
        guard case .writeRolledBack = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(try state(fixture) == before)
    }

    /// 한 곡에 큐·BPM·태그·게인을 함께 쓰면 곡 행을 여러 번 고친다. 커밋 뒤 확인은 마지막 값(태그가 올린 곡 정보 횟수·번호)을 봐야 한다.
    @Test func 한_곡의_큐·BPM·태그·게인을_함께_써도_커밋_뒤_확인을_통과한다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, track) = try gridDraft(fixture)
        // 태그 쓰기를 확인한 상태(0)로 둔다
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(track.id)])
        try fixture.insert("djmdMixerParam", ["ID": .text("mp-\(track.id)"), "ContentID": .text(track.id), "GainHigh": .int(16256),
                                              "GainLow": .int(0), "rb_data_status": .int(256), "rb_local_deleted": .int(0), "rb_local_usn": .int(12)])
        var cue = CueDraft(trackUUID: track.uuid)
        cue.place(EditableCue(kind: .memory, time: 30))
        let db = try fixture.open()
        let base = try #require(try RekordboxWriter.currentTags(db: db, contentID: track.id))
        db.close()
        var tags = TagDraft(trackUUID: track.uuid, base: base)
        tags.fields.title = "새 제목"
        let report = try RekordboxWriter.write(drafts: [cue], grids: [grid], gains: [track.uuid: -3], tags: [tags], analysisInputs: [:],
                                               to: fixture.database, dryRun: false, now: now, backups: fixture.backups,
                                               shareRoot: fixture.shareRoot, attachesAnalysis: false)
        #expect(report.written.count == 1 && report.gridWritten.count == 1 && report.gainWritten.count == 1 && report.tagWritten.count == 1)
        let row = try #require(fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(track.id)]).first)
        #expect(row["BPM"] == "13000" && row["Title"] == "새 제목")
        #expect(row["AnalysisUpdated"] == "2" && row["TrackInfoUpdated"] == "3", "그리드 +1, 태그 +1")
        #expect(try Int(row["rb_local_usn"] ?? "") == fixture.localUpdateCount(), "곡 행이 마지막 번호")
    }

    /// 동기화 상태(256)인 곡의 코멘트(#171): 큐·BPM·게인과 함께 써도 상태는 257이고 커밋 뒤 확인을 통과한다.
    @Test func 동기화된_곡의_큐·BPM·코멘트·게인을_함께_써도_커밋_뒤_확인을_통과한다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let (grid, track) = try gridDraft(fixture)
        try fixture.execute("UPDATE djmdContent SET Commnt = '' WHERE ID = ?", [.text(track.id)])
        try fixture.insert("djmdMixerParam", ["ID": .text("mp-\(track.id)"), "ContentID": .text(track.id), "GainHigh": .int(16256),
                                              "GainLow": .int(0), "rb_data_status": .int(256), "rb_local_deleted": .int(0), "rb_local_usn": .int(12)])
        var cue = CueDraft(trackUUID: track.uuid)
        cue.place(EditableCue(kind: .memory, time: 30))
        let tags = try syncedCommentDraft(fixture, track)
        let report = try RekordboxWriter.write(drafts: [cue], grids: [grid], gains: [track.uuid: -3], tags: [tags], analysisInputs: [:],
                                               to: fixture.database, dryRun: false, now: now, backups: fixture.backups,
                                               shareRoot: fixture.shareRoot, attachesAnalysis: false)
        #expect(report.written.count == 1 && report.gridWritten.count == 1 && report.gainWritten.count == 1 && report.tagWritten.count == 1)
        let row = try #require(fixture.rows("SELECT * FROM djmdContent WHERE ID = ?", [.text(track.id)]).first)
        #expect(row["Commnt"] == "새 코멘트" && row["rb_data_status"] == "257" && row["TrackInfoUpdated"] == "3", "그리드 +1, 태그 +1")
        #expect(try Int(row["rb_local_usn"] ?? "") == fixture.localUpdateCount(), "곡 행이 마지막 번호")
    }

    /// 태그 쓰기가 새로 고치는 동기화 상태도 커밋 뒤 다시 읽어 다르면 되돌린다(#171).
    @Test(arguments: ["UPDATE djmdContent SET rb_data_status = 256", "UPDATE djmdContent SET Commnt = 'x'"])
    func 동기화된_곡의_코멘트도_커밋_뒤_다시_읽어_다르면_되돌린다(tamper: String) throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let track = try fixture.add(TrackSpec())
        try fixture.execute("UPDATE djmdContent SET Commnt = '' WHERE ID = ?", [.text(track.id)])
        let tags = try syncedCommentDraft(fixture, track)
        try tamperOnCommit(fixture, tamper)
        let before = try state(fixture)
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.write(drafts: [], tags: [tags], to: fixture.database, dryRun: false, now: now,
                                      backups: fixture.backups, shareRoot: fixture.shareRoot)
        }
        guard case .writeRolledBack = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(try state(fixture) == before)
    }

    /// 곡 정보를 쓰면 그 곡이 든 목록의 masterPlaylists6.xml도 고친다(#173). XML을 적지 못하면 커밋한 곡 정보도 백업으로 되돌린다.
    /// XML 파일에만 "지우기 거부" ACL을 걸어 원자적 쓰기(바꿔 넣기)만 실패하게 한다(DB 복원과 백업 권한은 그대로 된다).
    @Test func XML을_적지_못하면_곡_정보_쓰기도_되돌린다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let track = try fixture.add(TrackSpec())
        try fixture.execute("UPDATE djmdContent SET Commnt = '' WHERE ID = ?", [.text(track.id)])
        let playlist = try fixture.add(PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: [track.id]))
        var parsed = MasterPlaylistsXML(text: MasterPlaylistsXMLTests.empty)
        try parsed.append(id: playlist.id, parentID: playlist.parentID, isFolder: false, timestamp: 1_000)
        let xml = fixture.root.appending(path: "masterPlaylists6.xml")
        try parsed.text.write(to: xml, atomically: true, encoding: .utf8)
        // XML Timestamp를 고치는 칸(제목)
        var tags = try syncedCommentDraft(fixture, track)
        tags.fields.comment = tags.base.comment
        tags.fields.title = "새 제목"
        let before = try state(fixture), xmlBefore = try Data(contentsOf: xml)
        try acl(["+a", "everyone deny delete", xml.path])
        defer { try? acl(["-R", "-N", fixture.root.path]) }
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.write(drafts: [], tags: [tags], to: fixture.database, dryRun: false, now: now,
                                      backups: fixture.backups, shareRoot: fixture.shareRoot)
        }
        guard case .writeRolledBack = error else { Issue.record("되돌림 오류가 아님: \(error)"); return }
        #expect(try state(fixture) == before)
        #expect(try Data(contentsOf: xml) == xmlBefore)
    }

    /// 되돌릴 때 masterPlaylists6.xml은 DB를 되살린 뒤에만 되살린다(#173 3차 리뷰). XML은 원자적으로 써서 반쯤 쓰인 상태가 없으므로,
    /// DB 복원이 실패하면 XML도 지금 상태로 두어 재생 목록 구조가 DB와 어긋나지 않게 한다. 쓰기 실패 뒤 되돌리기와 "쓰기 전으로 복원…"이 같다.
    @Test func DB_복원이_실패하면_XML은_건드리지_않아_DB와_같은_상태로_남는다() throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        let track = try fixture.add(TrackSpec())
        let playlist = try fixture.add(PlaylistSpec(id: "201", name: "목록", seq: 1, contentIDs: [track.id]))
        var parsed = MasterPlaylistsXML(text: MasterPlaylistsXMLTests.empty)
        try parsed.append(id: playlist.id, parentID: playlist.parentID, isFolder: false, timestamp: 1_000)
        let xml = fixture.root.appending(path: "masterPlaylists6.xml")
        try parsed.text.write(to: xml, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: xml)
        var tags = try syncedCommentDraft(fixture, track)
        tags.fields.comment = tags.base.comment
        tags.fields.title = "새 제목"
        let report = try RekordboxWriter.write(drafts: [], tags: [tags], to: fixture.database, dryRun: false, now: now,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        let backup = URL(filePath: try #require(report.backup))
        let written = try Data(contentsOf: xml)
        #expect(written != original, "곡 정보 쓰기가 XML Timestamp를 고쳤다")
        try blockRestore(fixture)
        defer { unlock(fixture) }
        #expect(throws: (any Error).self) { try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups) }
        #expect(try Data(contentsOf: xml) == written, "DB를 되살리지 못했으면 XML도 쓴 뒤 그대로(DB와 같은 때)")
        // 쓰기 실패 뒤 되돌리기 경로(restoreFiles 직접)도 같다
        #expect(throws: (any Error).self) { try RekordboxWriter.restoreFiles(from: backup, to: fixture.database) }
        #expect(try Data(contentsOf: xml) == written)
    }

    /// XML을 적은 뒤 다시 읽은 것이 적은 것과 어긋나면, DB를 되돌리기 전에 원본 XML부터 다시 쓴다(dev 재생 목록 쓰기 #38과 같은 순서).
    /// 그래서 DB 복원이 실패해도 XML은 원본으로 돌아온다. 다시 읽기만 시험에서 바꿔 어긋남을 만든다.
    @Test(arguments: [false, true]) func 다시_읽기가_적은_것과_어긋나면_XML은_원본으로_돌아온다(blocksDatabase: Bool) throws {
        let fixture = try RekordboxFixture(localUpdateCount: 900)
        _ = try fixture.add(TrackSpec())
        let url = fixture.root.appending(path: "masterPlaylists6.xml")
        var original = MasterPlaylistsXML(text: MasterPlaylistsXMLTests.empty)
        try original.append(id: "201", parentID: "root", isFolder: false, timestamp: 1_000)
        try original.text.write(to: url, atomically: true, encoding: .utf8)
        let backup = try RekordboxWriter.makeBackup(of: fixture.database, in: fixture.backups, now: now, label: "write")
        var updated = original
        updated.touch(ids: ["201"], timestamp: 2_000)
        if blocksDatabase { try blockRestore(fixture) }
        defer { unlock(fixture) }
        let error = try #require(throws: DJCError.self) {
            try RekordboxWriter.writePlaylistXML(updated, original: original, to: url, database: fixture.database, backup: backup, live: false,
                                                 read: { _ in original })
        }
        #expect(try MasterPlaylistsXML(contentsOf: url) == original, "원본 XML로")
        switch error {
        case .writeRolledBack: #expect(!blocksDatabase)
        case let .restoreFailed(_, restoreError, _, _): #expect(blocksDatabase && restoreError.contains("master.db"))
        default: Issue.record("되돌림 오류가 아님: \(error)")
        }
    }

    func acl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError("chmod \(arguments.joined(separator: " ")) 실패") }
    }

    /// 픽스처 곡(상태 256)의 코멘트만 고친 초안
    func syncedCommentDraft(_ fixture: RekordboxFixture, _ track: TrackSpec) throws -> TagDraft {
        let db = try fixture.open()
        let base = try #require(try RekordboxWriter.currentTags(db: db, contentID: track.id))
        db.close()
        var tags = TagDraft(trackUUID: track.uuid, base: base)
        tags.fields.comment = "새 코멘트"
        return tags
    }

    // MARK: 곡 넣기

    func addWithAnalysis(_ fixture: RekordboxFixture, now: Date) async throws -> RekordboxTrackWriter.Report {
        let p = try await RekordboxTrackWriterTests().plan("mp3-tagged.mp3")
        let analysis = RekordboxTrackWriter.Analysis(segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], loudness: -8, peak: 0.9)
        return try RekordboxTrackWriter.add([p], analyses: [p.path: analysis], to: fixture.database, shareRoot: fixture.shareRoot,
                                            dryRun: false, now: now, backups: fixture.backups)
    }

    @Test func 곡을_넣은_뒤_분석_파일을_못_쓰면_되돌리고_복원도_못하면_따로_알린다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        defer { unlock(fixture) }
        try fixture.add(TrackSpec())
        let usbanlz = fixture.shareRoot.appending(path: "PIONEER/USBANLZ")
        try FileManager.default.createDirectory(at: usbanlz, withIntermediateDirectories: true)
        try lock(usbanlz)
        let before = try state(fixture)

        let rolledBack = await #expect(throws: DJCError.self) { try await addWithAnalysis(fixture, now: now) }
        guard case .writeRolledBack? = rolledBack else { Issue.record("되돌림 오류가 아님: \(String(describing: rolledBack))"); return }
        #expect(try state(fixture) == before)

        try blockRestore(fixture)
        let failed = await #expect(throws: DJCError.self) { try await addWithAnalysis(fixture, now: now.addingTimeInterval(1)) }
        guard case let .restoreFailed(_, _, backup, database)? = failed else { Issue.record("복원 실패 오류가 아님: \(String(describing: failed))"); return }
        #expect(backup.hasSuffix("-add"))
        let writes = RekordboxWriter.backups(in: fixture.backups).filter(\.isWrite)
        #expect(writes.first?.url.lastPathComponent == URL(filePath: backup).lastPathComponent, "앱 '되돌리기…'가 고르는 백업")
        #expect(database == fixture.database.path)
    }

    @Test func 곡을_넣은_뒤_다시_읽기가_실패해도_복원_성공과_실패를_가른다() async throws {
        let fixture = try RekordboxFixture(localUpdateCount: 3000)
        defer { unlock(fixture) }
        try fixture.add(TrackSpec())   // 라이브러리 기기 정보를 읽을 곡
        try tamperOnCommit(fixture, "UPDATE djmdContent SET Title = Title || ' (바뀜)'")
        let p = try await RekordboxTrackWriterTests().plan("mp3-tagged.mp3")
        let before = try state(fixture)
        let add = { (at: Date) in try RekordboxTrackWriter.add([p], to: fixture.database, dryRun: false, now: at, backups: fixture.backups) }

        let rolledBack = try #require(throws: DJCError.self) { try add(now) }
        guard case let .writeRolledBack(reason) = rolledBack else { Issue.record("되돌림 오류가 아님: \(rolledBack)"); return }
        #expect(reason.contains("행이 넣은 값과 다릅니다"))
        #expect(try state(fixture) == before)

        try blockRestore(fixture)
        let failed = try #require(throws: DJCError.self) { try add(now.addingTimeInterval(1)) }
        guard case .restoreFailed = failed else { Issue.record("복원 실패 오류가 아님: \(failed)"); return }
    }

    // MARK: 문구

    @Test func 복원_실패_문구는_라이브_DB면_live로_되돌리게_한다() {
        let error = DJCError.restoreFailed(reason: "무결성 검사 실패: x", restoreError: "master.db: 권한 없음",
                                           backup: "/Users/a/Application Support/DJCrate/rekordbox-backups/2026-09-26T120000-write", database: nil)
        let lines = error.description.components(separatedBy: "\n")
        #expect(lines.first == "쓴 결과를 확인하지 못했고 백업으로 자동 복원도 하지 못했습니다. rekordbox 라이브러리(master.db)와 분석 파일이 어떤 상태인지 알 수 없습니다.")
        #expect(lines.contains("rekordbox를 켜지 말고 먼저 쓰기 전 백업으로 되돌리세요: "
                               + "djc rekordbox-restore --backup '/Users/a/Application Support/DJCrate/rekordbox-backups/2026-09-26T120000-write' --live"))
        #expect(lines.contains("확인 실패: 무결성 검사 실패: x") && lines.contains("복원 실패: master.db: 권한 없음"))
        #expect(DJCError.restoreCommand(backup: "/b/it's", database: "/c d/master.db") == #"djc rekordbox-restore --backup '/b/it'\''s' --db '/c d/master.db'"#)
    }

    @Test func 사유만_넘겨_머리말이_두_번_붙지_않는다() {
        #expect(DJCError.reason(of: DJCError.writeVerificationFailed("곡의 변경 번호가 다릅니다")) == "곡의 변경 번호가 다릅니다")
        #expect(DJCError.reason(of: DJCError.writeRolledBack("무결성 검사 실패")) == "무결성 검사 실패")
        #expect(DJCError.reason(of: DJCError.writeRefused("rekordbox가 켜져 있습니다")) == "rekordbox에 쓰지 않았습니다: rekordbox가 켜져 있습니다")
        let file = DJCError.reason(of: CocoaError(.fileWriteNoPermission))
        #expect(!file.isEmpty && !file.contains("NSCocoaErrorDomain"), "파일 오류는 UserInfo 덤프가 아니라 문장으로")
    }
}
