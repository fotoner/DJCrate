import DJCDomain
import Accelerate
import Foundation

/// 곡 안의 조성(조표) 흐름 추정. 전조(마지막 사비 키 업 등)를 찾는 용도다.
///
/// 1. 크로마: 16384점 FFT(홉 8192) 크기를 60Hz~2.2kHz에서 12음으로 접는다(반음 중심에서 멀수록 작게).
/// 2. 마디(그리드가 없으면 2초)마다 크로마를 모아, 12개 조표(장조 으뜸음 기준, 나란한조 포함)와 상관을 본다.
/// 3. 바꾸는 데 벌점을 준 비터비로 흐름을 고르고, 짧은 구간(기본 8마디 미만)은 옆 구간에 합친다.
/// 흐름은 장·단(A/B)을 가리지 않고 조표만 본다. 표시할 때 장·단은 rekordbox 키를 따르고, 키가 없으면 `isMinor`로 정한다.
public enum KeyAnalyzer {
    /// 크로마 값은 DJCDomain에 있다(#167, 덱이 캐시에서 받아 넘긴다)
    public typealias Chroma = KeyChroma

    /// 조표 구간 값은 DJCDomain에 있다(#167, 덱이 들고 있다)
    public typealias Segment = KeySegment

    // MARK: - 크로마

    public static func chroma(channels: [UnsafeBufferPointer<Float>], sampleRate: Double) -> Chroma {
        let log2n: vDSP_Length = 14
        let n = 1 << Int(log2n)
        let hopSamples = n / 2
        let frames = channels.map(\.count).min() ?? 0
        guard frames > n, let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return Chroma(hop: Double(hopSamples) / max(sampleRate, 1), frames: [])
        }
        // 주파수 칸 → 음이름 가중치
        var bins: [(bin: Int, pc: Int, weight: Float)] = []
        for k in 1..<(n / 2) {
            let f = Double(k) * sampleRate / Double(n)
            guard f >= 60, f <= 2200 else { continue }
            let midi = 69 + 12 * log2(f / 440)
            let nearest = midi.rounded()
            let weight = Float(max(0, 1 - abs(midi - nearest) * 2))
            if weight > 0 { bins.append((k, ((Int(nearest) % 12) + 12) % 12, weight)) }
        }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        var mono = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var outReal = [Float](repeating: 0, count: n / 2), outImag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        var result: [[Float]] = []
        var start = 0
        while start + n <= frames {
            // 모노로 모으고 창을 씌운다.
            vDSP.fill(&mono, with: 0)
            for channel in channels {
                vDSP.add(mono, UnsafeBufferPointer(rebasing: channel[start..<start + n]), result: &mono)
            }
            vDSP.multiply(mono, window, result: &mono)
            mono.withUnsafeBufferPointer { m in
                real.withUnsafeMutableBufferPointer { r in
                    imag.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        m.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                        outReal.withUnsafeMutableBufferPointer { orp in
                            outImag.withUnsafeMutableBufferPointer { oip in
                                var out = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                                fft.forward(input: split, output: &out)
                                magnitudes.withUnsafeMutableBufferPointer { mag in
                                    vDSP_zvabs(&out, 1, mag.baseAddress!, 1, vDSP_Length(n / 2))
                                }
                            }
                        }
                    }
                }
            }
            var chroma = [Float](repeating: 0, count: 12)
            var energy: Float = 0
            for b in bins {
                let value = log1p(magnitudes[b.bin] * 0.01)
                chroma[b.pc] += value * b.weight
                energy += magnitudes[b.bin]
            }
            let norm = sqrt(chroma.reduce(0) { $0 + $1 * $1 })
            result.append(energy > 1 && norm > 0 ? chroma.map { $0 / norm } : [Float](repeating: 0, count: 12))
            start += hopSamples
        }
        return Chroma(hop: Double(hopSamples) / sampleRate, frames: result)
    }

    // MARK: - 조표 흐름

    /// 장조·단조 음 분포(Krumhansl-Kessler). 장조는 으뜸음, 단조는 으뜸음 기준.
    static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// 음 분포 틀(장조는 C, 단조는 A가 으뜸음이 아니라 인덱스 0 = 으뜸음)
    public struct Profiles: Sendable, Codable {
        public var major: [Double]
        public var minor: [Double]
        public init(major: [Double], minor: [Double]) { self.major = major; self.minor = minor }
    }

    public static let krumhansl = Profiles(major: major, minor: minor)
    /// 이 라이브러리 400곡(rekordbox 키 기준)으로 학습한 크로마 음 분포(2026-09-26). 교과서 틀보다 배음(5도) 치우침이 적다:
    /// 학습에 안 쓴 150곡에서 주 조표 일치 35% → 65%.
    public static let learned = Profiles(
        major: [0.3441, 0.2274, 0.3069, 0.2365, 0.3339, 0.2826, 0.2556, 0.3617, 0.2383, 0.2839, 0.2197, 0.2856],
        minor: [0.3296, 0.2432, 0.2970, 0.3045, 0.2663, 0.3040, 0.2467, 0.3331, 0.2647, 0.2609, 0.2968, 0.2542])
    /// 쓸 틀
    nonisolated(unsafe) public static var profiles = learned

    /// 조표를 바꿀 때 벌점 배율(반음 차이별). 애니송의 전조는 대개 반음·온음 위로 가고,
    /// 5도 이웃(Camelot ±1)으로 바뀌는 것처럼 보이는 건 화성이 달라진 구간인 경우가 많다.
    static func switchWeight(from a: Int, to b: Int) -> Double {
        switch (b - a + 12) % 12 {
        case 0: 0
        case 1, 2, 10, 11: 1
        case 5, 7: 2.5
        default: 1.5
        }
    }

    /// 크로마와 음 분포 틀(으뜸음을 `rotate`로 돌림)의 상관
    static func correlation(_ chroma: [Double], _ profile: [Double], rotate: Int) -> Double {
        let p = (0..<12).map { profile[(($0 - rotate) % 12 + 12) % 12] }
        let mx = chroma.reduce(0, +) / 12, mp = p.reduce(0, +) / 12
        var num = 0.0, dx = 0.0, dp = 0.0
        for i in 0..<12 {
            num += (chroma[i] - mx) * (p[i] - mp); dx += (chroma[i] - mx) * (chroma[i] - mx); dp += (p[i] - mp) * (p[i] - mp)
        }
        return dx > 0 && dp > 0 ? num / sqrt(dx * dp) : 0
    }

    /// 조표마다 창 크로마와의 상관(장조 틀과 나란한 단조 틀 중 큰 쪽)
    static func scores(_ chroma: [Double], profiles: Profiles = profiles) -> [Double] {
        guard chroma.contains(where: { $0 > 0 }) else { return [Double](repeating: 0, count: 12) }
        return (0..<12).map { s in
            max(correlation(chroma, profiles.major, rotate: s), correlation(chroma, profiles.minor, rotate: (s + 9) % 12))
        }
    }

    /// `start`~`end`초 크로마 합
    static func total(_ chroma: Chroma, from start: Double, to end: Double, into sum: inout [Double]) {
        let a = max(0, Int((start / chroma.hop).rounded(.down))), b = min(chroma.frames.count, Int((end / chroma.hop).rounded(.up)))
        if a < b { for f in a..<b { for i in 0..<12 { sum[i] += Double(chroma.frames[f][i]) } } }
    }

    /// 조표 흐름. `windows`는 (시작, 끝) 초. 벌점이 클수록 덜 바꾼다.
    public static func segments(chroma: Chroma, windows: [(Double, Double)], switchPenalty: Double = 3.0,
                                minWindows: Int = 12, profiles: Profiles = profiles) -> (segments: [Segment], main: Int?) {
        guard !chroma.frames.isEmpty, !windows.isEmpty else { return ([], nil) }
        // 창마다 크로마 합
        let emissions: [[Double]] = windows.map { w in
            var sum = [Double](repeating: 0, count: 12)
            total(chroma, from: w.0, to: w.1, into: &sum)
            return scores(sum, profiles: profiles)
        }
        // 비터비
        let t = emissions.count
        var score = emissions[0], back = [[Int]](repeating: [Int](repeating: 0, count: 12), count: t)
        for i in 1..<t {
            var next = [Double](repeating: 0, count: 12)
            for s in 0..<12 {
                var best = -Double.infinity, from = s
                for p in 0..<12 {
                    let value = score[p] - switchPenalty * switchWeight(from: p, to: s)
                    if value > best { best = value; from = p }
                }
                next[s] = best + emissions[i][s]
                back[i][s] = from
            }
            score = next
        }
        var path = [Int](repeating: 0, count: t)
        path[t - 1] = score.indices.max { score[$0] < score[$1] }!
        for i in stride(from: t - 1, to: 0, by: -1) { path[i - 1] = back[i][path[i]] }
        // 연속 구간
        var runs: [(from: Int, to: Int, key: Int)] = []
        for (i, k) in path.enumerated() {
            if let last = runs.last, last.key == k { runs[runs.count - 1].to = i } else { runs.append((i, i, k)) }
        }
        // 짧은 구간은 옆 구간에 합친다(그 창들에서 점수가 더 높은 쪽).
        var merged = true
        while merged, runs.count > 1 {
            merged = false
            guard let shortest = runs.indices.filter({ runs[$0].to - runs[$0].from + 1 < minWindows })
                .min(by: { runs[$0].to - runs[$0].from < runs[$1].to - runs[$1].from }) else { break }
            let r = runs[shortest]
            let candidates = [shortest - 1, shortest + 1].filter { runs.indices.contains($0) }
            let target = candidates.max { a, b in
                (r.from...r.to).reduce(0) { $0 + emissions[$1][runs[a].key] } < (r.from...r.to).reduce(0) { $0 + emissions[$1][runs[b].key] }
            }!
            if target < shortest { runs[target].to = r.to } else { runs[target].from = r.from }
            runs.remove(at: shortest)
            // 같은 조표끼리 붙었으면 합친다.
            var i = 1
            while i < runs.count {
                if runs[i].key == runs[i - 1].key { runs[i - 1].to = runs[i].to; runs.remove(at: i) } else { i += 1 }
            }
            merged = true
        }
        let segments = runs.map { Segment(start: windows[$0.from].0, end: windows[$0.to].1, signature: $0.key) }
        var totals = [Double](repeating: 0, count: 12)
        for s in segments { totals[s.signature] += s.end - s.start }
        return (segments, totals.indices.max { totals[$0] < totals[$1] })
    }

    /// 조표 `signature` 구간들의 크로마가 장조(으뜸음 = 조표)보다 나란한 단조(으뜸음 = 조표 + 9)에 더 맞는지.
    /// 조표 흐름은 장·단을 가리지 않으므로, rekordbox 키가 없을 때 장·단을 이것으로 정한다.
    public static func isMinor(chroma: Chroma, signature: Int, segments: [Segment], profiles: Profiles = profiles) -> Bool {
        var sum = [Double](repeating: 0, count: 12)
        for segment in segments where segment.signature == signature {
            total(chroma, from: segment.start, to: segment.end, into: &sum)
        }
        return correlation(sum, profiles.minor, rotate: (signature + 9) % 12) > correlation(sum, profiles.major, rotate: signature)
    }

    /// 곡 전체의 주 조성
    public struct MainKey: Sendable, Hashable {
        public var signature: Int
        public var minor: Bool
        public var camelot: String { KeyNotation.camelot(signature: signature, minor: minor) }
    }

    /// 곡 전체의 주 조성: 조표 흐름에서 가장 긴 조표를 고르고, 그 구간의 크로마로 장·단을 가른다(덱과 같은 벌점·최소 길이).
    /// 소리가 없으면 nil.
    public static func mainKey(chroma: Chroma, windows: [(Double, Double)], switchPenalty: Double = 5, minWindows: Int = 16,
                               profiles: Profiles = profiles) -> MainKey? {
        guard chroma.frames.contains(where: { $0.contains { $0 > 0 } }) else { return nil }
        let result = segments(chroma: chroma, windows: windows, switchPenalty: switchPenalty, minWindows: minWindows, profiles: profiles)
        guard let main = result.main else { return nil }
        return MainKey(signature: main, minor: isMinor(chroma: chroma, signature: main, segments: result.segments, profiles: profiles))
    }

    /// 마디(다운비트 사이) 창. 그리드가 없으면 2초 창.
    public static func windows(grid: BeatGrid?, duration: Double) -> [(Double, Double)] {
        if let grid, grid.downbeats.count > 4 {
            var result: [(Double, Double)] = []
            let bars = grid.downbeats
            if let first = bars.first, first > 0.5 { result.append((0, first)) }
            for i in 0..<(bars.count - 1) { result.append((bars[i], bars[i + 1])) }
            if let last = bars.last, duration > last + 0.5 { result.append((last, duration)) }
            return result
        }
        return stride(from: 0.0, to: duration, by: 2.0).map { ($0, min($0 + 2, duration)) }
    }

    /// 크로마 전체 합(정규화)을 으뜸음 기준으로 돌린 것. 학습용.
    public static func rotatedTotal(chroma: Chroma, tonic: Int) -> [Double] {
        var sum = [Double](repeating: 0, count: 12)
        for frame in chroma.frames { for i in 0..<12 { sum[i] += Double(frame[i]) } }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return sum }
        return (0..<12).map { sum[($0 + tonic) % 12] / norm }
    }

    // MARK: - Camelot

    /// 조표 → Camelot 번호(C장조·A단조 = 8)
    public static func camelotNumber(signature: Int) -> Int { ((signature * 7) % 12 + 7) % 12 + 1 }

    public static func camelot(signature: Int, minor: Bool) -> String { "\(camelotNumber(signature: signature))\(minor ? "A" : "B")" }

    /// Camelot("10B" 등) → (조표, 단조인가). 규칙은 `KeyNotation.signature(camelot:)`
    public static func signature(camelot: String) -> (signature: Int, minor: Bool)? { KeyNotation.signature(camelot: camelot) }
}

import AVFoundation

public extension KeyAnalyzer {
    /// 파일 전체를 읽어 크로마를 만든다(음원은 읽기만 한다). 채널을 더해 넘기므로 덱(`DecodedAudio.chroma`)과 같은 값이다.
    static func chroma(fileAt url: URL) throws -> Chroma {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return Chroma(hop: 0.2, frames: []) }
        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length))
        let channels = Int(format.channelCount)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            let start = mono.count
            mono.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
            for c in 1..<max(channels, 1) {
                mono.withUnsafeMutableBufferPointer { all in
                    for i in 0..<n { all[start + i] += data[c][i] }
                }
            }
        }
        return mono.withUnsafeBufferPointer { chroma(channels: [$0], sampleRate: format.sampleRate) }
    }
}
