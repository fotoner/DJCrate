import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

@Suite("변속 경계 보존")
struct MultiTempoBoundaryTests {
    func fixture(firstBPM: Double = 120, first: Double = 500, firstCount: Int = 3, secondStart: Double = 1700,
                 secondBPM: Double = 300) throws -> (RekordboxFixture, TrackSpec, GridDraft) {
        let fixture = try RekordboxFixture()
        var track = TrackSpec(uuid: "12345678-1111-2222-3333-444444444444")
        track.fileType = 11
        track.bpm100 = Int(firstBPM * 100)
        track.folderPath = try AudioFixture.wav(seconds: 49, in: fixture.audio).path
        track.analysisDataPath = "/PIONEER/USBANLZ/123/45678-1111-2222-3333-444444444444/ANLZ0000.DAT"
        try fixture.add(track)
        let thirdStart = secondStart + 50 * 60000 / secondBPM
        let beats = AnlzBuilder.beats(bpm: firstBPM, first: first, count: firstCount)
            + AnlzBuilder.beats(bpm: secondBPM, first: secondStart, count: 50)
            + AnlzBuilder.beats(bpm: 100, first: thirdStart, count: Int((49000 - thirdStart) / 600) + 1)
        let dat = AnlzBuilder.dat(beats: beats)
        try fixture.putAnalysis(for: track, dat: dat, ext: AnlzBuilder.file([BeatGridTags.pqt2([], unknown: 0)]))
        try fixture.addContentFile(for: track, hash: "합성 해시", size: dat.count)
        return (fixture, track, GridDraft(trackUUID: track.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: track))))
    }

    @Test func 뒤쪽_BPM_편집은_앞_구간의_경계_직전_박을_보존한다() throws {
        let (fixture, track, original) = try fixture()
        var draft = original
        draft.setBPM(101, at: 20)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        let output = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(output.beats.contains { $0.time == 1.5 && $0.bpm == 120 })
    }

    @Test func 전체_10ms_이동은_경계_직전_박을_보존한다() throws {
        let (fixture, track, original) = try fixture()
        var draft = original
        draft.shift(by: 0.010)
        #expect(draft.grid(duration: 49).beats.contains { $0.time == 1.51 })
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        let output = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(output.beats.contains { $0.time == 1.51 && $0.bpm == 120 })
    }

    @Test func 전체를_뒤로_옮기면_첫_박_앞도_곡_시작까지_채운다() throws {
        // PR #131 검토(2026-09-28): 원본 박을 보존하면서 곡 앞 채움이 빠졌다. 기대값은 보존 전 코드(9557294)가 같은 초안으로 쓴 결과다.
        let (fixture, track, original) = try fixture(first: 200)
        let dat = fixture.analysisURL(for: track), ext = fixture.analysisURL(for: track, ext: "EXT")
        let oldExt = try Data(contentsOf: ext)
        var draft = original
        draft.shift(by: 0.4)
        #expect(draft.grid(duration: 49).beats.first?.time == 0.1)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        try #require(report.gridWritten.count == 1)
        let expected = [BeatGridTags.Beat(number: 4, bpm100: 12000, time: 100)] + AnlzBuilder.beats(bpm: 120, first: 600, count: 3)
            + AnlzBuilder.beats(bpm: 300, first: 2100, count: 50) + AnlzBuilder.beats(bpm: 100, first: 12100, count: 62)
        #expect(try #require(AnlzFile(url: dat).tag("PQTZ")).bytes == BeatGridTags.pqtz(expected))
        #expect(try Data(contentsOf: ext) == oldExt)
    }

    @Test func 박_번호만_바꿔도_경계_직전_박의_시각을_보존한다() throws {
        let (fixture, track, original) = try fixture()
        var draft = original
        draft.segments[0].firstBeatNumber = 2
        #expect(draft.grid(duration: 49).beats.contains { $0.time == 1.5 && $0.number == 4 })
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        let output = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(output.beats.contains { $0.time == 1.5 && $0.number == 4 })
    }

    @Test func 늦춘_경계의_가까운_새_박은_생성하지_않는다() throws {
        let (fixture, track, original) = try fixture()
        var draft = original
        draft.segments[1].start = 2.09
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        let output = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(output.beats.contains { $0.time == 1.5 })
        #expect(!output.beats.contains { $0.time == 2.0 })
    }

    @Test func 음수_이동은_음원_밖_박을_쓰지_않는다() throws {
        let (fixture, track, original) = try fixture()
        var draft = original
        draft.shift(by: -2.010)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        let output = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(output.beats.allSatisfy { $0.time >= 0 })
        #expect(output.beats.filter { $0.time == 0 }.count <= 1)
    }

    @Test func 정확히_마이너스_1ms가_된_원본_박은_제외한다() throws {
        let (fixture, track, original) = try fixture()
        var draft = original
        draft.shift(by: -0.501)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        let output = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(output.beats.first?.time == 0.499)
        #expect(!output.beats.contains { $0.time == 0 })
    }

    @Test func 구간_삭제는_다른_원본_구간의_박을_잘못_가져오지_않는다() throws {
        let (fixture, track, original) = try fixture()
        var draft = original
        draft.removeTempoChange(at: 1)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        let output = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(output.beats.contains { $0.time == 1.5 && $0.bpm == 120 })
        #expect(!output.beats.contains { $0.bpm == 300 })
    }

    @Test func 역산_BPM이_원본_칸과_조금_달라도_원본_앵커를_인정한다() throws {
        let (fixture, track, original) = try fixture(firstBPM: 130, firstCount: 9, secondStart: 5000)
        #expect(original.base[0].bpm != 130)
        var draft = original
        draft.setBPM(101, at: 20)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        let output = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(output.beats.contains { $0.time == 0.5 && $0.bpm == 130 })
    }

    @Test func 첫_구간의_박이_모두_사라지면_쓰기를_막는다() throws {
        let (fixture, track, original) = try fixture(firstCount: 1, secondStart: 800, secondBPM: 200)
        let dat = fixture.analysisURL(for: track), before = try Data(contentsOf: dat)
        var draft = original
        draft.setBPM(90, at: 0.5)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.isEmpty)
        #expect(report.gridBlocked.first?.reason?.contains("박") == true)
        #expect(try Data(contentsOf: dat) == before)
        #expect(try fixture.rows("SELECT BPM FROM djmdContent").first?["BPM"] == "12000")
    }

    @Test func 원래_한_박인_짧은_구간은_다른_구간을_고칠_때_보존한다() throws {
        let (fixture, track, original) = try fixture(firstCount: 1, secondStart: 800, secondBPM: 200)
        var draft = original
        draft.setBPM(101, at: 20)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.count == 1)
        let output = try BeatGrid.load(anlz: fixture.analysisURL(for: track))
        #expect(output.beats.first?.time == 0.5 && output.beats.first?.bpm == 120)
    }

    @Test func 새_곡_분석도_첫_구간_앵커_소실을_막는다() throws {
        let (fixture, track, _) = try fixture()
        let analysis = RekordboxTrackWriter.Analysis(segments: [
            .init(start: 0.5, bpm: 90, firstBeatNumber: 1),
            .init(start: 0.8, bpm: 200, firstBeatNumber: 1),
        ], loudness: nil, peak: 0)
        let ready = try RekordboxTrackWriter.prepare(path: track.folderPath, fileName: "합성.wav", duration: 49,
                                                      uuid: track.uuid, analysis: analysis, share: fixture.shareRoot)
        #expect(ready.blocked?.contains("첫 박") == true)
        #expect(ready.files.isEmpty)
    }

    @Test func 이웃_구간의_1ms_옆_박은_빈_첫_구간을_채운_것으로_보지_않는다() throws {
        let segments = [GridSegment(start: 0.5, bpm: 90, firstBeatNumber: 1),
                        GridSegment(start: 0.501, bpm: 200, firstBeatNumber: 1)]
        let generated = RekordboxGridWriter.generate(segments: segments, duration: 49, preserving: [:])
        #expect(generated.counts[0] == 0 && generated.counts[1] > 8)
        #expect(RekordboxGridWriter.hasEmptyVisibleSegment(segments: segments, counts: generated.counts, duration: 49))
        let (fixture, track, original) = try fixture(firstCount: 1, secondStart: 501, secondBPM: 200)
        var draft = original
        draft.setBPM(90, at: 0.5)
        let report = try RekordboxWriter.write(drafts: [], grids: [draft], to: fixture.database, dryRun: false,
                                               backups: fixture.backups, shareRoot: fixture.shareRoot)
        #expect(report.gridWritten.isEmpty)
        #expect(report.gridBlocked.first?.reason?.contains("첫 박") == true)
        #expect(try BeatGrid.load(anlz: fixture.analysisURL(for: track)).beats.first?.bpm == 120)
    }
}
