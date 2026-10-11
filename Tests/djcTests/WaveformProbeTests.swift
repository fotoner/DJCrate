import AVFoundation
import Foundation
import Testing
@testable import djc

/// 두 번째 파형 합성 실험(`djc lab waveform-probe`)의 출력 안전: 있는 WAV를 덮지 않고, 잘못된 인자는 폴더를 만들기 전에 거부한다
@Suite("두 번째 파형 합성 실험")
struct WaveformProbeTests {
    @Test func WAV는_명세대로_무음과_혼합을_쓰고_덮어쓰지_않는다() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "probe-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = AudioLab.WaveformProbe2Track(name: "probe2-test", sampleRate: 48_000, frameCount: 1000, segments: [
            .init(label: "혼합", startFrame: 320, frameCount: 480, frequencies: [1000, 2500], amplitudes: [0.25, 0.125])
        ])
        try AudioLab.writeWaveformProbe2(track, to: root)
        let url = root.appending(path: "probe2-test.wav")
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 1000 && file.processingFormat.sampleRate == 48_000)
        #expect(file.processingFormat.channelCount == 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1000))
        try file.read(into: buffer)
        let channels = try #require(buffer.floatChannelData)
        for i in 0..<1000 {
            let t = Double(i - 320) / 48_000
            let expected = (320..<800).contains(i) ? 0.25 * sin(2 * .pi * 1000 * t) + 0.125 * sin(2 * .pi * 2500 * t) : 0
            #expect(abs(Double(channels[0][i]) - expected) < 1.0 / 32768)
            #expect(channels[0][i] == channels[1][i])
        }
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try AudioLab.writeWaveformProbe2(track, to: root) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func 잘못된_묶음은_출력_폴더를_만들기_전에_거부한다() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "probe-test-\(UUID())")
        for suffix in [["--suite", "3"], ["--suite"]] {
            await #expect(throws: (any Error).self) {
                try await AudioLab.waveformProbe(["waveform-probe", "--out", root.path] + suffix)
            }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }
}
