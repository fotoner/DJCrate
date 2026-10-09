import DJCDomain
@testable import DJCAnalysis
import Foundation
import Testing

@Suite("곡 음량")
struct LoudnessTests {
    func sine(frequency: Double, amplitudeDB: Double, seconds: Double, rate: Double) -> [Float] {
        let amplitude = pow(10, amplitudeDB / 20)
        return (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    func measure(_ channels: [[Float]], rate: Double) -> Loudness {
        let pointers = channels.map { channel in channel.withUnsafeBufferPointer { $0 } }
        return withExtendedLifetime(channels) { Loudness.measure(channels: pointers, sampleRate: rate) }
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func EBU_기준_사인파는_마이너스23_LUFS(rate: Double) throws {
        // EBU Tech 3341: 1kHz 스테레오 사인, 각 채널 −23dBFS → −23.0 LUFS(±0.1)
        let tone = sine(frequency: 1000, amplitudeDB: -23, seconds: 20, rate: rate)
        let result = measure([tone, tone], rate: rate)
        let lufs = try #require(result.integrated)
        #expect(abs(lufs - -23) < 0.1, "측정값 \(lufs)")
        #expect(abs(result.peak - -23) < 0.05)
        #expect(result.clippedRuns == 0)
    }

    @Test func 조용한_구간은_게이트로_빠진다() throws {
        // −20dBFS 10초 + −80dBFS 10초: 절대 게이트(−70)로 뒤쪽이 빠져 −20 부근이어야 한다.
        let rate = 48_000.0
        let loud = sine(frequency: 1000, amplitudeDB: -20, seconds: 10, rate: rate)
        let quiet = sine(frequency: 1000, amplitudeDB: -80, seconds: 10, rate: rate)
        let tone = loud + quiet
        let lufs = try #require(measure([tone, tone], rate: rate).integrated)
        #expect(abs(lufs - -20) < 0.2, "측정값 \(lufs)")
    }

    @Test func 무음과_클리핑() {
        let rate = 44_100.0
        #expect(measure([[Float](repeating: 0, count: 44_100)], rate: rate).integrated == nil)
        var clipped = sine(frequency: 100, amplitudeDB: 6, seconds: 1, rate: rate)   // 풀스케일을 넘는 사인
        for i in clipped.indices { clipped[i] = min(max(clipped[i], -1), 1) }
        let result = measure([clipped, clipped], rate: rate)
        #expect(result.clippedRuns >= 100, "클리핑 흔적 \(result.clippedRuns)")
        #expect(result.isHot)
    }

    @Test func 오토게인과_피크_보호() {
        let quiet = Loudness(integrated: -16, peak: -1, clippedRuns: 0)
        #expect(quiet.autoGain(target: -10, peakProtection: false) == 6)
        #expect(abs(quiet.autoGain(target: -10, peakProtection: true) - 0.7) < 1e-9, "피크 −1dBFS면 +0.7dB까지만")
        let loud = Loudness(integrated: -6, peak: 0, clippedRuns: 0)
        #expect(loud.autoGain(target: -10, peakProtection: true) == -4)
        #expect(Loudness(integrated: nil, peak: -120, clippedRuns: 0).autoGain(target: -10, peakProtection: true) == 0)
        let overs = Loudness(integrated: -12, peak: 1.28, clippedRuns: 0)   // AAC 디코딩 오버
        #expect(overs.autoGain(target: -10, peakProtection: true) == 0, "조용한 곡을 피크 때문에 깎지는 않는다")
    }

    /// 음량 캐시(`loudness.json`)를 옛 파일 그대로 읽게: DJCDomain으로 옮긴 뒤에도(#167) JSON이 옮기기 전과 같다.
    @Test func 음량_JSON은_옮기기_전과_같다() throws {
        let fixed = #"[{"clippedRuns":3,"integrated":-7.25,"peak":0.5},{"clippedRuns":0,"peak":-120}]"#
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let values = [Loudness(integrated: -7.25, peak: 0.5, clippedRuns: 3), Loudness(integrated: nil, peak: -120, clippedRuns: 0)]
        #expect(String(decoding: try encoder.encode(values), as: UTF8.self) == fixed)
        let decoded = try JSONDecoder().decode([Loudness].self, from: Data(fixed.utf8))
        #expect(decoded == values)
    }
}
