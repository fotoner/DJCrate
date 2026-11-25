import AVFoundation
@testable import DJCAdapters
import Foundation
import Testing

/// 실제 덱의 속도 변환 노드를 오프라인으로 렌더한다. 출력 장치와 재생 시계를 사용하지 않는다.
@Suite(.serialized)
struct DeckTempoRenderTests {
    @Test(arguments: [true, false])
    func 템포_8퍼센트의_출력_샘플_수와_음높이(keyLock: Bool) throws {
        let rate = 48_000.0
        let frames = 192_000
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let url = FileManager.default.temporaryDirectory.appending(path: "djc-ramp-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
            input.frameLength = UInt32(frames)
            // 주기 160프레임인 램프(300Hz). 양 채널 모두 채운다.
            for channel in 0..<2 {
                for frame in 0..<frames { input.floatChannelData![channel][frame] = Float(frame % 160) / 160 - 0.5 }
            }
            try file.write(from: input)
        }
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let graph = DeckAudioGraph(engine: engine)
        let file = try AVAudioFile(forReading: url)
        try engine.connectNode(graph.trackNode, to: graph.gainUnit, format: format)
        try engine.connectNode(graph.gainUnit, to: graph.trackMixer, format: format)
        try engine.connectNode(graph.trackMixer, to: graph.subMixer, format: format)
        graph.applyRate(1.08, keyLock: keyLock)
        graph.trackNode.scheduleFile(file, at: nil)
        try engine.start()
        defer { engine.stop() }
        try graph.trackNode.playAudio()
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        var samples: [Float] = []
        for _ in 0..<235 {
            let status = try engine.renderOffline(1024, to: output)
            guard status == .success else { Issue.record("오프라인 렌더 실패 \(status.rawValue)"); return }
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }
        let start = try #require(samples.firstIndex { abs($0) > 0.1 })
        let end = try #require(samples.lastIndex { abs($0) > 0.1 })
        let length = end - start + 1
        // TimePitch의 시작·끝 창 길이(약 20ms)를 허용해도 원속도와 8% 차이를 구분한다.
        #expect(abs(Double(length) - Double(frames) / 1.08) < rate * 0.05)
        // 양 끝 과도구간을 빼고 가운데 1초에 온 주기 수를 센다.
        try #require(samples.count >= 96_000)
        var cycles = 0, negative = false
        for sample in samples[48_000..<96_000] {
            if sample < -0.1 { negative = true }
            if negative && sample > 0.1 { cycles += 1; negative = false }
        }
        let pitch = keyLock ? 300 : 324
        #expect(abs(cycles - pitch) <= 2)
        print("덱 오프라인 렌더 · 키 고정 \(keyLock) · 출력 \(length)프레임 · \(cycles)Hz")
    }
}
