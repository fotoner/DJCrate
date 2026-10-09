import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

/// rekordbox 7.2.18, 2026-09-28 「DJC 다구간 BPM 실험 B 중간 구간」.
/// 숫자는 편집 결과의 칸에서 옮기고, DB·음원·ANLZ는 모두 합성한다.
@Suite("변속곡 그리드 쓰기")
struct MultiTempoGridWriterTests {
    func fixture(middleBPM: Double = 150, lastStart: Double = 29294) throws -> (RekordboxFixture, TrackSpec, GridDraft) {
        let fixture = try RekordboxFixture(localUpdateCount: 700)
        var track = TrackSpec(uuid: "a1b2c3d4-0000-1111-2222-333344445555")
        track.fileType = 11
        track.bpm100 = 12000
        track.length = 49
        track.analysisUpdated = "7"
        track.trackInfoUpdated = "4"
        track.folderPath = try AudioFixture.wav(seconds: 49, in: fixture.audio).path
        track.analysisDataPath = "/PIONEER/USBANLZ/a1b/2c3d4-0000-1111-2222-333344445555/ANLZ0000.DAT"
        try fixture.add(track)
        let beats = AnlzBuilder.beats(bpm: 120, first: 494, count: 32)
            + AnlzBuilder.beats(bpm: middleBPM, first: 16494.5, count: 32)
            + AnlzBuilder.beats(bpm: 100, first: lastStart, count: 33)
        let dat = AnlzBuilder.dat(beats: beats)
        try fixture.putAnalysis(for: track, dat: dat, ext: AnlzBuilder.file([BeatGridTags.pqt2([], unknown: 0)]))
        try fixture.addContentFile(for: track, hash: "그리드 편집 전 해시", size: dat.count)
        return (fixture, track, GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track))))
    }

    @Test func 중간_BPM과_다음_경계를_고쳐도_DB는_보존하고_97박을_쓴다() throws {
        let (fixture, track, original) = try fixture()
        let before = try fixture.rows("SELECT * FROM djmdContent") + fixture.rows("SELECT * FROM contentFile")
        var draft = original
        draft.setBPM(151, at: 16.494)
        draft.segments[2].start = 29.305
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        let written = try AnlzFile(url: fixture.analysisURL(for: track))
        let actual = try #require(written.tag("PQTZ")).bytes
        let expected = AnlzBuilder.beats(bpm: 120, first: 494, count: 32)
            + AnlzBuilder.beats(bpm: 151, first: 16494.5, count: 32)
            + AnlzBuilder.beats(bpm: 100, first: 29305, count: 33)
        #expect(actual == BeatGridTags.pqtz(expected))
        #expect(try fixture.rows("SELECT * FROM djmdContent") + fixture.rows("SELECT * FROM contentFile") == before)
        #expect(try fixture.localUpdateCount() == 700)
    }

    /// #207: 박 사이에 넣은 변속 지점은 새 쓰기 규칙 없이 위 경계 대체 규칙(실험 B)으로 박이 된다.
    @Test func 박_사이에_넣은_변속_지점은_경계_대체_규칙으로_쓴다() throws {
        let (fixture, track, original) = try fixture()
        var draft = original
        let added = draft.addTempoChange(at: 8.6, duration: 49)   // 120 BPM 8.494초 박에서 0.106초 뒤
        try #require(added)
        let beats = RekordboxGridWriter.beats(segments: draft.segments, duration: 49)
        #expect(beats.filter { $0.wholeMs >= 7900 && $0.wholeMs <= 9200 }.map(\.wholeMs) == [7994, 8600, 9100])
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        let written = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(written.beats.contains { abs($0.time - 8.6) < 0.001 && $0.number == 1 })
        #expect(!written.beats.contains { abs($0.time - 8.494) < 0.001 })
    }

    @Test func 다구간_박_생성은_rekordbox의_경계_대체와_일치한다() {
        let beats = RekordboxGridWriter.beats(segments: [
            .init(start: 0.4945, bpm: 120, firstBeatNumber: 1),
            .init(start: 16.4945, bpm: 151, firstBeatNumber: 1),
            .init(start: 29.3055, bpm: 100, firstBeatNumber: 1),
        ], duration: 49)
        #expect(beats.count == 97)
        #expect(beats[63].wholeMs == 28812)
        #expect(beats[64].wholeMs == 29305)
        #expect(beats[63].number == 4 && beats[64].number == 1)
    }

    @Test func 첫_구간까지_바꾸면_대표_BPM과_곡_정보만_바꾼다() throws {
        // 같은 곡의 별도 BPM 입력창 실험: 120/151/100 → 121/152/101.
        let (fixture, track, original) = try fixture(middleBPM: 151, lastStart: 29305)
        let files = try fixture.rows("SELECT * FROM contentFile")
        var draft = original
        draft.segments = [
            .init(start: 0.494, bpm: 121, firstBeatNumber: 1),
            .init(start: 16.362, bpm: 152, firstBeatNumber: 1),
            .init(start: 28.994, bpm: 101, firstBeatNumber: 1),
        ]
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        let content = try #require(fixture.rows("SELECT * FROM djmdContent").first)
        #expect(content["BPM"] == "12100")
        #expect(content["AnalysisUpdated"] == "7" && content["TrackInfoUpdated"] == "5")
        #expect(content["rb_data_status"] == "257")
        #expect(try fixture.rows("SELECT * FROM contentFile") == files)
        #expect(try fixture.localUpdateCount() == 701)
        let actual = try #require(AnlzFile(url: fixture.analysisURL(for: track)).tag("PQTZ")).bytes
        let expected = AnlzBuilder.beats(bpm: 121, first: 494.5, count: 32)
            + AnlzBuilder.beats(bpm: 152, first: 16362.5, count: 32)
            + AnlzBuilder.beats(bpm: 101, first: 28994.5, count: 34)
        #expect(actual == BeatGridTags.pqtz(expected))
    }

    @Test func 다구간_BPM_미리_보기는_불변이고_쓴_뒤에는_되돌릴_수_있다() throws {
        let (fixture, track, original) = try fixture()
        var draft = original
        draft.setBPM(151, at: 16.494)
        let dat = fixture.analysisURL(for: track), ext = fixture.analysisURL(for: track, ext: "EXT")
        let oldDat = try Data(contentsOf: dat), oldExt = try Data(contentsOf: ext)
        let preview = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: true,
                                                backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(preview.gridWritten.count == 1 && preview.backup == nil)
        #expect(try Data(contentsOf: dat) == oldDat && Data(contentsOf: ext) == oldExt)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        #expect(try Data(contentsOf: dat) != oldDat)
        let backup = URL(filePath: try #require(report.backup))
        _ = try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups)
        #expect(try Data(contentsOf: dat) == oldDat && Data(contentsOf: ext) == oldExt)
        #expect(RekordboxWriter.gridDrafts(in: backup) == [draft])
    }

    @Test func 다구간도_초안_이후_그리드가_바뀌면_쓰지_않는다() throws {
        let (fixture, track, original) = try fixture()
        var draft = original
        draft.setBPM(151, at: 16.494)
        let dat = fixture.analysisURL(for: track)
        let changed = AnlzBuilder.dat(beats: AnlzBuilder.beats(bpm: 140, first: 100, count: 100))
        try changed.write(to: dat)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.isEmpty)
        #expect(report.gridBlocked.first?.reason?.contains("초안을 만든 뒤") == true)
        #expect(try Data(contentsOf: dat) == changed)
    }

    @Test func 마지막_BPM만_바꾸면_앞_구간의_박은_ms까지_그대로다() throws {
        let (fixture, track, original) = try fixture(middleBPM: 151, lastStart: 29305)
        let dat = fixture.analysisURL(for: track)
        let before = try BeatGrid.load(anlz: dat).beats
        var draft = original
        draft.setBPM(101, at: 30)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        #expect(try BeatGrid.load(anlz: dat).beats.prefix(64) == before.prefix(64))
    }

    @Test func 같은_시각에_겹친_변속_지점은_쓰지_않는다() throws {
        let (fixture, track, original) = try fixture()
        let dat = fixture.analysisURL(for: track), before = try Data(contentsOf: dat)
        var draft = original
        draft.segments.insert(draft.segments[1], at: 1)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.isEmpty && report.gridBlocked.count == 1)
        #expect(try Data(contentsOf: dat) == before)
    }

    @Test func 다음_경계를_늦추면_기존_박은_보존하고_그_뒤만_늘인다() throws {
        let (fixture, track, original) = try fixture(middleBPM: 151, lastStart: 29305)
        let dat = fixture.analysisURL(for: track), before = try BeatGrid.load(anlz: dat).beats
        var draft = original
        draft.segments[2].start = 30.305
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        let after = try BeatGrid.load(anlz: dat).beats
        #expect(after.prefix(64) == before.prefix(64))
        #expect(after.filter { $0.time > 29 && $0.time < 30.3 }.count == 3)
    }

    @Test func 다음_경계를_앞당기면_가까운_원본_박도_대체한다() throws {
        let (fixture, track, original) = try fixture(middleBPM: 151, lastStart: 29305)
        var draft = original
        draft.segments[2].start = 28.900
        #expect(!draft.grid(duration: 49).beats.contains { $0.time == 28.812 })
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        let output = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(!output.beats.contains { $0.time == 28.812 })
        #expect(output.beats.contains { $0.time == 28.415 })
    }

    @Test(arguments: [Double.nan, .infinity, 0, 655.36, 999])
    func PQTZ에_들어가지_않는_BPM은_앱_종료_없이_거부한다(bpm: Double) throws {
        let (fixture, track, original) = try fixture()
        var draft = original
        draft.segments[0].bpm = bpm
        #expect(throws: RekordboxGridWriter.Blocked.self) {
            try RekordboxGridWriter.plan(draft: draft, title: track.title, analysisDataPath: track.analysisDataPath,
                                        rekordboxBPM100: track.bpm100, audioPath: track.folderPath, shareRoot: fixture.shareRoot)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_MULTI_GRID_FIXTURE"] != nil))
    func 앱_쓰기_자가_시험용_변속곡_사본을_만든다() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_MULTI_GRID_FIXTURE"] else { return }
        let (fixture, track, original) = try fixture()
        let root = URL(filePath: path)
        let db = try fixture.open()
        try db.run("UPDATE djmdContent SET FolderPath = ? WHERE ID = ?", [.text(root.appending(path: "audio/silence.wav").path), .text(track.id)])
        db.close()
        try fixture.add(PlaylistSpec(id: "1001", name: "합성 변속곡", seq: 1, contentIDs: [track.id]))
        try FileManager.default.copyItem(at: fixture.root, to: root)
        var draft = original
        draft.setBPM(151, at: 16.494)
        draft.segments[2].start = 29.305
        let drafts = root.appending(path: "djc-home/grid-drafts")
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: drafts.appending(path: "\(track.uuid).json"))
    }
}
