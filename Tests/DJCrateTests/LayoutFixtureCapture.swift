import DJCTestKit
import Foundation
import RekordboxFixtures
import Testing

struct LayoutFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_LAYOUT_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_LAYOUT_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        let audio = try AudioFixture.wav(seconds: 200, in: fixture.audio)
        for index in 1...12 {
            var track = TrackSpec(id: String(index))
            track.title = "레이아웃 시험 \(index)"
            track.folderPath = root.appending(path: "audio/\(audio.lastPathComponent)").path
            track.fileType = 11
            track.analysisDataPath = "/PIONEER/USBANLZ/test\(index)/ANLZ0000.DAT"
            track.cues = (0..<8).map { slot in
                var cue = CueSpec(kind: slot + 1, inMsec: 27_877 + slot * 10_000)
                cue.comment = "시험 큐 이름 \(slot)"
                return cue
            }
            track.cues[1].outMsec = track.cues[1].inMsec + 4000
            track.cues[1].activeLoop = 1
            track.cues[1].beatLoopSize = 8 << 16 | 1
            try fixture.add(track)
            let beats = AnlzBuilder.beats(bpm: 128, first: 0, count: 420)
            try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        }
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }
}
