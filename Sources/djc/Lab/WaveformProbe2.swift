import AVFoundation
import DJCDomain
import Foundation

extension AudioLab {
    struct WaveformProbe2Segment: Codable, Equatable {
        var label: String
        var startFrame: Int
        var frameCount: Int
        var frequencies: [Double]
        var amplitudes: [Double]
    }

    struct WaveformProbe2Track: Codable {
        var name: String
        var sampleRate: Int
        var frameCount: Int
        var segments: [WaveformProbe2Segment]
    }

    /// #13 두 번째 실험. 샘플로 반올림한 실제 시작·끝을 남겨 150Hz 칸 경계와 비교한다.
    static func waveformProbe2Tracks() -> [WaveformProbe2Track] {
        var tracks: [WaveformProbe2Track] = []
        for rate in [44_100, 48_000] {
            func segment(_ label: String, _ start: Double, _ duration: Double, _ hz: [Double], _ levels: [Double]) -> WaveformProbe2Segment {
                .init(label: label, startFrame: Int((start * Double(rate)).rounded()),
                      frameCount: Int((duration * Double(rate)).rounded()), frequencies: hz, amplitudes: levels)
            }
            func add(_ name: String, _ segments: [WaveformProbe2Segment], duration: Double? = nil) {
                let end = segments.map { $0.startFrame + $0.frameCount }.max() ?? 0
                tracks.append(.init(name: "probe2-\(name)-\(rate)", sampleRate: rate,
                                    frameCount: duration.map { Int(($0 * Double(rate)).rounded()) } ?? end + 2 * rate,
                                    segments: segments))
            }
            for (name, frequencies) in [
                ("low", Array(stride(from: 100, through: 350, by: 25))),
                ("mid", Array(stride(from: 500, through: 3000, by: 100))),
                ("high", Array(stride(from: 8000, through: 20000, by: 1000))),
            ] {
                add("boundary-" + name, frequencies.enumerated().map { index, hz in
                    segment("\(hz)Hz", 2 + Double(index) * 4, 2, [Double(hz)], [0.5])
                })
            }
            var mix: [WaveformProbe2Segment] = []
            for pair in [[150.0, 300], [1000.0, 2500], [2500.0, 8000]] {
                for ratio in [0.0, 0.125, 0.25, 0.5, 0.75, 1] {
                    // 합계 진폭을 고정해 클리핑과 전체 레벨 변화를 피한다.
                    let first = 0.5 / (1 + ratio)
                    mix.append(segment("\(pair[0])+\(pair[1])Hz 비율 \(ratio)", 2 + Double(mix.count) * 4, 2,
                                       pair, [first, first * ratio]))
                }
            }
            add("mix", mix)
            var amplitude: [WaveformProbe2Segment] = []
            for hz in [1000.0, 2500, 8000, 12000, 16000] {
                for level in [1.0 / 256, 1.0 / 128, 1.0 / 64, 1.0 / 32, 1.0 / 16, 0.125, 0.25, 0.5, 0.75, 1] {
                    amplitude.append(segment("\(hz)Hz 진폭 \(level)", 2 + Double(amplitude.count) * 4, 2, [hz], [level]))
                }
            }
            add("amplitude", amplitude)
            let base = [60.0, 1000, 8000].enumerated().map { index, hz in
                segment("\(hz)Hz 기준", 2 + Double(index) * 4, 2, [hz], [0.25])
            }
            // 큰 소리·반복은 원본의 뒷무음을 대체해 곡 길이까지 함께 바뀌지 않게 한다.
            add("normalize-base", base, duration: 32)
            add("normalize-silence", base, duration: 42)
            add("normalize-loud", base + [segment("큰 소리", 20, 2, [1000], [1])], duration: 32)
            let repeated = base.map { part in
                var copy = part
                copy.startFrame += 12 * rate
                copy.label += " 반복"
                return copy
            }
            add("normalize-repeat", base + repeated, duration: 32)
            var bursts: [WaveformProbe2Segment] = []
            for hz in [60.0, 1000, 8000] {
                for duration in [0.001, 0.002, 0.005, 0.01, 0.02, 0.033, 0.05, 0.1] {
                    for phase in [0.0, 0.25, 0.5, 0.75] {
                        // 44.1kHz의 ¼칸(73.5샘플)이 초 단위 덧셈 오차로 흔들리지 않게 따로 반올림한다.
                        let startFrame = 2 * rate + bursts.count * (rate / 2) + Int((Double(rate) / 150 * phase).rounded())
                        bursts.append(segment("\(hz)Hz \(duration * 1000)ms 칸 위상 \(phase)", Double(startFrame) / Double(rate), duration, [hz], [0.5]))
                    }
                }
            }
            add("burst", bursts)
        }
        return tracks
    }

    static func writeWaveformProbe2(_ track: WaveformProbe2Track, to folder: URL) throws {
        let url = folder.appending(path: track.name + ".wav")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw DJCError.invalidAnalysisFile("기존 음원을 덮어쓰지 않도록 새 실험 폴더를 지정하세요")
        }
        let rate = Double(track.sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let frames = AVAudioFrameCount(track.frameCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channels = buffer.floatChannelData else {
            throw DJCError.invalidAnalysisFile("실험 음원 버퍼를 만들 수 없어 다른 앱을 닫고 다시 실행하세요")
        }
        buffer.frameLength = frames
        for ch in 0..<2 { channels[ch].update(repeating: 0, count: track.frameCount) }
        for part in track.segments {
            for i in 0..<part.frameCount {
                var sample = 0.0
                for (hz, amplitude) in zip(part.frequencies, part.amplitudes) {
                    sample += amplitude * sin(2 * .pi * hz * Double(i) / rate)
                }
                for ch in 0..<2 { channels[ch][part.startFrame + i] = Float(sample) }
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    static func waveformProbe2(folder: URL) throws {
        let tracks = waveformProbe2Tracks()
        for track in tracks { try writeWaveformProbe2(track, to: folder) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tracks).write(to: folder.appending(path: "segments.json"), options: .withoutOverwriting)
        print("합성 WAV \(tracks.count)개(44.1/48kHz·16비트·동일한 좌우 채널)와 샘플 단위 구간 명세를 만들었습니다")
        print("rekordbox에서 probe2- 곡만 분석하고 종료한 뒤 스냅샷과 분석 사본을 보존하세요")
        print("waveform-eval --title probe2- --limit \(tracks.count) --copy-to <새 사본 폴더> --dump-to <새 덤프 폴더> --out <결과.json>으로 비교하세요")
    }
}
