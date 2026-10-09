import DJCTestKit
import Foundation
import RekordboxFixtures
import Testing

struct AsyncGuidanceFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_ASYNC_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_ASYNC_FIXTURE"] else { return }
        try Self.make(in: URL(filePath: path))
    }

    static func make(in directory: URL) throws {
        let root = directory.resolvingSymlinksInPath()
        let temporary = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        try #require(root.path.hasPrefix(temporary + "/") || root.path.hasPrefix("/private/tmp/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try RekordboxFixture(), destination = root.appending(path: "rekordbox")
        for index in 1...2 {
            var spec = TrackSpec(id: String(index), uuid: "async-fixture-\(index)")
            spec.title = index == 1 ? "합성 곡 · 변경 없음" : "합성 곡 · 음원 읽기 실패"
            spec.length = 20
            let audio = try AudioFixture.wav(seconds: 20, in: fixture.audio, name: "sample-\(index).wav")
            if index == 2 { try Data((try Data(contentsOf: audio)).prefix(20)).write(to: audio) }
            spec.folderPath = destination.appending(path: "audio/\(audio.lastPathComponent)").path
            if index == 1 { spec.analysisDataPath = "/PIONEER/USBANLZ/async1/ANLZ0000.DAT" }
            try fixture.add(spec)
            if index == 1 {
                let beats = AnlzBuilder.beats(bpm: 120, first: 0, count: 41)
                try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
            }
        }
        try FileManager.default.copyItem(at: fixture.root, to: destination)
    }
}
