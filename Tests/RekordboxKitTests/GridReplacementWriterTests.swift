import DJCDomain
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("대체 그리드 쓰기 기준")
struct GridReplacementWriterTests {
    @Test func 내부_박이_바뀐_대체_초안은_계획_시점에도_막는다() throws {
        let folder = try TemporaryFolder()
        var beats = AnlzBuilder.beats(bpm: 120, first: 500, count: 100)
        beats[2].time += 3
        let track = try makeTrack(in: folder, beats: beats)
        let source = try BeatGrid.load(anlz: analysisURL(track, in: folder))
        var draft = GridDraft(trackUUID: track.uuid, grid: source)
        draft.segments = [.init(start: 0.25, bpm: 128, firstBeatNumber: 1)]
        let approved = try #require(draft.approvingReplacement(of: source, duration: 60))
        let normalPlan = try plan(approved, track: track, in: folder)
        #expect(!normalPlan.beats.isEmpty)
        beats[2].time -= 1
        try putAnalysis(track, beats: beats, in: folder)
        let changed = try BeatGrid.load(anlz: analysisURL(track, in: folder))
        #expect(GridDraft.segments(from: changed) == approved.base)
        let before = try Data(contentsOf: analysisURL(track, in: folder))
        #expect(throws: RekordboxGridWriter.Blocked.self) { try plan(approved, track: track, in: folder) }
        #expect(try Data(contentsOf: analysisURL(track, in: folder)) == before)
    }

    func plan(_ draft: GridDraft, track: TrackSpec, in folder: TemporaryFolder) throws -> RekordboxGridWriter.Plan {
        try RekordboxGridWriter.plan(draft: draft, title: track.title, analysisDataPath: track.analysisDataPath,
                                    rekordboxBPM100: track.bpm100, audioPath: track.folderPath, shareRoot: share(folder))
    }

    // 계획은 분석 파일·음원만 읽어 DB 없이 임시 폴더에 둔다.

    func share(_ folder: TemporaryFolder) -> URL { folder.url.appending(path: "share") }

    func analysisURL(_ track: TrackSpec, in folder: TemporaryFolder) -> URL {
        share(folder).appending(path: String((track.analysisDataPath ?? "").drop(while: { $0 == "/" })))
    }

    func putAnalysis(_ track: TrackSpec, beats: [BeatGridTags.Beat], in folder: TemporaryFolder) throws {
        let url = analysisURL(track, in: folder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AnlzBuilder.dat(beats: beats).write(to: url)
        try AnlzBuilder.ext(beats: beats).write(to: url.deletingPathExtension().appendingPathExtension("EXT"))
    }

    func makeTrack(in folder: TemporaryFolder, beats: [BeatGridTags.Beat]) throws -> TrackSpec {
        var track = TrackSpec(uuid: "a1b2c3d4-0000-1111-2222-333344445555")
        track.fileType = 11
        track.bpm100 = 12800
        track.folderPath = try AudioFixture.wav(seconds: 60, in: folder.url).path
        track.analysisDataPath = RekordboxGridWriterTests().analysisPath
        try putAnalysis(track, beats: beats, in: folder)
        return track
    }
}
