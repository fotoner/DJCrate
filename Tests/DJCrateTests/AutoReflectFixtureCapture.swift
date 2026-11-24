import AVFoundation
import Foundation
import RekordboxFixtures
import Testing

/// 자동 저장 사본 자가 테스트(`--auto-reflect-selftest=<save|two-process|kill-detect>`, R18)용 합성 라이브러리.
/// - 곡 301 "자동 저장 소리 시험": 2분짜리 연속 사인(440Hz, 끊김 없는 신호), 120 BPM 그리드 분석 파일. `save`가 덱에서 틀고 평점을 바꿔 저장한다
/// - 곡 302·303 "자동 저장 시험 둘·셋": 두 프로세스·강제 종료 시험이 하나씩 평점을 바꾼다
/// - 곡 401~460 "자동 저장 대량 NN": ⌘Q 저장 자가 테스트(`--quit-wait-selftest`)의 대량 유예(M곡 이상)에 쓴다(음원은 시험 재료 mp3)
/// 평점은 모두 0이다. 실데이터는 쓰지 않는다.
/// `DJC_AUTO_REFLECT_FIXTURE=<없는 임시 폴더> scripts/check.sh --quick --filter AutoReflectFixtureCapture` → 그 폴더를 `DJC_REKORDBOX_DIR`로
/// 준다(`--db`는 주지 않는다: 명시한 사본은 쓰기 대상이 아니라서 자가 테스트로 보지 않는다).
struct AutoReflectFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_AUTO_REFLECT_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_AUTO_REFLECT_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        let bpm = 120.0, seconds = 120.0
        for (index, title) in ["자동 저장 소리 시험", "자동 저장 시험 둘", "자동 저장 시험 셋"].enumerated() {
            let name = "auto-reflect-\(index + 1).wav"
            _ = try Self.sine(seconds: index == 0 ? seconds : 20, to: fixture.audio.appending(path: name))
            var track = TrackSpec(id: String(301 + index))
            track.title = title
            track.folderPath = root.appending(path: "audio/\(name)").path
            track.fileType = 11
            track.length = index == 0 ? Int(seconds) : 20
            track.bpm100 = Int(bpm * 100)
            track.analysisDataPath = "/PIONEER/USBANLZ/auto\(index + 1)/ANLZ0000.DAT"
            try fixture.add(track)
            let length = Double(track.length)
            let beats = AnlzBuilder.beats(bpm: bpm, first: 0, count: Int(length * bpm / 60))
            try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        }
        for index in 1...60 {
            var track = TrackSpec(id: String(400 + index))
            track.title = String(format: "자동 저장 대량 %02d", index)
            try fixture.add(track)
        }
        try fixture.execute("UPDATE djmdContent SET Rating = 0")
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "share/PIONEER/USBANLZ"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }

    /// 끊김 없는 연속 신호: 440Hz 사인(진폭 0.3) 스테레오 16비트 WAV
    static func sine(seconds: Double, rate: Double = 44_100, to url: URL) throws -> URL {
        let frames = Int(seconds * rate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let value = Float(0.3 * sin(2 * .pi * 440 * Double(i) / rate))
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        try file.write(from: buffer)
        return url
    }
}
