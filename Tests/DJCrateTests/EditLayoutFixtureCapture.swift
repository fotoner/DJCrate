import AVFoundation
import Foundation
import RekordboxFixtures
import Testing

/// 편집 창 화면 확인용 합성 라이브러리(`--edit-layout=light|dark`): 128 BPM 3분짜리 합성 곡 하나(구간마다 악기가 달라
/// 파형에 모양이 난다), 그리드 분석 파일, 핫큐·메모리 큐. 실데이터는 쓰지 않는다.
/// `DJC_EDIT_LAYOUT_FIXTURE=<폴더> swift test --filter EditLayoutFixtureCapture`
struct EditLayoutFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_EDIT_LAYOUT_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_EDIT_LAYOUT_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        let bpm = 128.0, first = 0.35, seconds = 180.0
        let audio = try Self.song(bpm: bpm, first: first, seconds: seconds, to: fixture.audio.appending(path: "edit-layout.wav"))
        var track = TrackSpec(id: "1")
        track.title = "편집 화면 시험"
        track.folderPath = root.appending(path: "audio/\(audio.lastPathComponent)").path
        track.fileType = 11
        track.length = Int(seconds)
        track.analysisDataPath = "/PIONEER/USBANLZ/edit1/ANLZ0000.DAT"
        let bar = { (n: Int) in Int(((first + Double(n - 1) * 240 / bpm) * 1000).rounded()) }
        track.cues = [CueSpec(kind: 0, inMsec: bar(1)), CueSpec(kind: 0, inMsec: bar(33)), CueSpec(kind: 0, inMsec: bar(73)),
                      CueSpec(kind: 1, inMsec: bar(17)), CueSpec(kind: 2, inMsec: bar(41))]
        try fixture.add(track)
        let beats = AnlzBuilder.beats(bpm: bpm, first: first * 1000, count: Int((seconds - first) * bpm / 60) + 1)
        try fixture.putAnalysis(for: track, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }

    /// 킥(매 박)·하이햇(엇박)·베이스·패드를 구간마다 다르게 섞은 스테레오 WAV
    static func song(bpm: Double, first: Double, seconds: Double, rate: Double = 44_100, to url: URL) throws -> URL {
        let beat = 60 / bpm
        let frames = Int(seconds * rate)
        var left = [Float](repeating: 0, count: frames)
        var noise: UInt32 = 0x1234_5678
        for i in 0..<frames {
            let t = Double(i) / rate
            let position = t - first
            let barNumber = position < 0 ? 0 : Int(position / (4 * beat)) + 1
            let inBeat = position < 0 ? position + beat : position.truncatingRemainder(dividingBy: beat)
            let breakdown = (33...40).contains(barNumber)
            let drop = (41...72).contains(barNumber)
            var value = 0.0
            if !breakdown, barNumber >= 1 {
                // 킥: 55Hz로 떨어지는 짧은 사인
                value += 0.8 * sin(2 * .pi * (55 + 90 * exp(-inBeat * 30)) * inBeat) * exp(-inBeat * 9)
                // 하이햇: 엇박에 짧은 잡음
                let offbeat = inBeat - beat / 2
                if offbeat >= 0, offbeat < 0.04 {
                    noise = noise &* 1_664_525 &+ 1_013_904_223
                    value += (drop ? 0.35 : 0.22) * (Double(noise >> 8) / Double(1 << 24) - 0.5) * exp(-offbeat * 80)
                }
            }
            if barNumber >= 17, !breakdown, barNumber <= 72 {
                value += (drop ? 0.35 : 0.22) * sin(2 * .pi * 110 * t) * (1 - exp(-inBeat * 40)) * exp(-inBeat * 3)
            }
            if breakdown || drop {
                value += (breakdown ? 0.25 : 0.12) * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 554 * t) + sin(2 * .pi * 659 * t)) / 3
            }
            left[i] = Float(max(-0.95, min(0.95, value)))
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        left.withUnsafeBufferPointer { samples in
            buffer.floatChannelData![0].update(from: samples.baseAddress!, count: frames)
            buffer.floatChannelData![1].update(from: samples.baseAddress!, count: frames)
        }
        try file.write(from: buffer)
        return url
    }
}
