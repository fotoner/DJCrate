import AVFoundation
import DJCDomain
import Foundation

extension AudioLab {
    struct WaveformProbeSegment: Codable {
        var start: Double
        var duration: Double
        var frequency: Double
        var amplitude: Double
    }

    /// 자동으로 rekordbox에 곡을 넣지 않는다. WAV와 구간 명세만 새 폴더에 만든다.
    static func waveformProbe(_ args: [String]) async throws {
        guard let out = value(after: "--out", in: args) else { throw UsageError() }
        let suite = value(after: "--suite", in: args) ?? (args.contains("--suite") ? "" : "1")
        guard ["1", "2"].contains(suite) else { throw UsageError() }
        let folder = URL(filePath: out), fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { throw DJCError.invalidAnalysisFile("기존 파일을 덮어쓰지 않도록 새 실험 폴더를 지정하세요") }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if suite == "2" {
            try waveformProbe2(folder: folder)
            return
        }
        let rate = 44_100.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        var manifest: [String: [WaveformProbeSegment]] = [:]
        // 각 소리 앞뒤 2초의 무음으로 필터·포락선의 잔향을 분리한다.
        let frequency = [60.0, 150, 300, 1000, 2500, 8000, 16000].enumerated().map { index, hz in
            WaveformProbeSegment(start: 2 + Double(index) * 4, duration: 2, frequency: hz, amplitude: 0.5)
        }
        var amplitude: [WaveformProbeSegment] = [], envelope: [WaveformProbeSegment] = []
        for hz in [60.0, 1000, 8000] {
            for level in [1.0 / 64, 1.0 / 16, 0.25, 0.5, 1] {
                amplitude.append(WaveformProbeSegment(start: 2 + Double(amplitude.count) * 4, duration: 2, frequency: hz, amplitude: level))
            }
            for duration in [0.01, 0.1, 1] {
                envelope.append(WaveformProbeSegment(start: 2 + Double(envelope.count) * 3, duration: duration, frequency: hz, amplitude: 0.5))
            }
        }
        for (name, segments) in [("probe-frequency", frequency), ("probe-amplitude", amplitude), ("probe-envelope", envelope)] {
            let duration = segments.last!.start + segments.last!.duration + 2
            let frames = AVAudioFrameCount((duration * rate).rounded())
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channels = buffer.floatChannelData else {
                throw DJCError.invalidAnalysisFile("실험 음원 버퍼를 만들 수 없어 다른 앱을 닫고 다시 실행하세요")
            }
            buffer.frameLength = frames
            for ch in 0..<2 { channels[ch].update(repeating: 0, count: Int(frames)) }
            for segment in segments {
                let start = Int((segment.start * rate).rounded()), count = Int((segment.duration * rate).rounded())
                for i in 0..<count {
                    let value = Float(segment.amplitude * sin(2 * .pi * segment.frequency * Double(i) / rate))
                    for ch in 0..<2 { channels[ch][start + i] = value }
                }
            }
            let file = try AVAudioFile(forWriting: folder.appending(path: name + ".wav"), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            manifest[name + ".wav"] = segments
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appending(path: "segments.json"), options: .withoutOverwriting)
        print("합성 WAV 3개(44.1kHz·16비트·동일한 좌우 채널)와 구간 명세를 만들었습니다")
        print("rekordbox에서 이 WAV만 추가·분석하고, 분석 설정을 기록한 뒤 rekordbox를 종료하세요")
        print("djc snapshot 후 waveform-eval --title probe- --limit 3 --copy-to <새 사본 폴더> --out <결과.json>으로 비교하세요")
        print("분석 사본을 확보하면 rekordbox 컬렉션에서 실험용 probe- 곡 3개만 제거하세요")
    }
}
