import DJCDomain
import Accelerate
import Foundation

/// 곡 음량 재기: ITU-R BS.1770-4 통합 음량(LUFS)과 샘플 피크, 원본 클리핑 흔적(값은 DJCDomain `Loudness`, #167).
///
/// K-가중 필터(고역 셸빙 + 저역 차단 2단 바이쿼드)를 거친 신호를 100ms 조각으로 평균제곱하고, 400ms 블록(75% 겹침)으로
/// 묶어 절대 게이트(−70 LUFS)와 상대 게이트(−10 LU)를 적용한다. 필터 계수는 libebur128과 같은 식으로 샘플레이트마다 구한다.
extension Loudness {
    /// 채널별 PCM(같은 길이)으로 잰다. 채널 가중치는 모두 1(스테레오·모노).
    public static func measure(channels: [UnsafeBufferPointer<Float>], sampleRate: Double) -> Loudness {
        let frames = channels.map(\.count).min() ?? 0
        let step = Int((sampleRate * 0.1).rounded())
        guard frames > 0, step > 0, !channels.isEmpty else { return Loudness(integrated: nil, peak: -120, clippedRuns: 0) }
        let pieces = frames / step
        var power = [Double](repeating: 0, count: pieces)
        var peak: Float = 0
        var clipped = 0
        var filtered = [Float](repeating: 0, count: frames)
        guard let setup = vDSP_biquad_CreateSetup(kWeighting(sampleRate: sampleRate), 2) else {
            return Loudness(integrated: nil, peak: -120, clippedRuns: 0)
        }
        defer { vDSP_biquad_DestroySetup(setup) }

        for channel in channels {
            guard let base = channel.baseAddress else { continue }
            var delay = [Float](repeating: 0, count: 2 * 2 + 2)
            vDSP_biquad(setup, &delay, base, 1, &filtered, 1, vDSP_Length(frames))
            filtered.withUnsafeBufferPointer { f in
                for i in 0..<pieces {
                    var sum: Float = 0
                    vDSP_svesq(f.baseAddress! + i * step, 1, &sum, vDSP_Length(step))
                    power[i] += Double(sum) / Double(step)
                }
            }
            var channelPeak: Float = 0
            vDSP_maxmgv(base, 1, &channelPeak, vDSP_Length(frames))
            peak = max(peak, channelPeak)
            if channelPeak >= 0.9999 {
                var run = 0
                for i in 0..<frames {
                    if abs(base[i]) >= 0.9999 {
                        run += 1
                        if run == 3 { clipped += 1 }
                    } else {
                        run = 0
                    }
                }
            }
        }

        // 400ms 블록 = 100ms 조각 4개(75% 겹침)
        var blocks: [Double] = []
        if pieces >= 4 {
            blocks.reserveCapacity(pieces - 3)
            for i in 0...(pieces - 4) { blocks.append((power[i] + power[i + 1] + power[i + 2] + power[i + 3]) / 4) }
        }
        func lufs(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }
        let absolute = blocks.filter { $0 > 0 && lufs($0) > -70 }
        var integrated: Double?
        if !absolute.isEmpty {
            let relative = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
            let gated = absolute.filter { lufs($0) > relative }
            if !gated.isEmpty { integrated = lufs(gated.reduce(0, +) / Double(gated.count)) }
        }
        return Loudness(integrated: integrated, peak: peak > 0 ? 20 * log10(Double(peak)) : -120, clippedRuns: clipped)
    }

    /// K-가중 2단 바이쿼드 계수(vDSP 순서: b0 b1 b2 a1 a2 × 2)
    static func kWeighting(sampleRate rate: Double) -> [Double] {
        // 1단: 고역 셸빙(머리 효과)
        var f0 = 1681.974450955533
        let gain = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / rate)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                     2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        // 2단: 저역 차단(RLB)
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / rate)
        a0 = 1 + k / q + k * k
        let highPass = [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        return shelf + highPass
    }
}

import AVFoundation

public extension Loudness {
    /// 파일 전체를 디코딩해 잰다.
    static func measure(fileAt url: URL) throws -> Loudness {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return Loudness(integrated: nil, peak: -120, clippedRuns: 0)
        }
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: frames) }
        return measure(channels: channels, sampleRate: buffer.format.sampleRate)
    }
}
