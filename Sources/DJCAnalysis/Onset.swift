import DJCDomain
import AVFoundation
import Foundation

/// 1ms 단위 어택(온셋) 강도 곡선. 킥(저역)과 스네어·하이햇(고역)의 소리 시작에서 솟는다.
///
/// rekordbox 박은 어택에 찍힌다. 박 간격(BPM)은 MU로 충분히 정확하지만 박 위치(위상)는
/// 어택에 맞춰야 rekordbox와 같은 자리에 온다. 이 곡선으로 위상을 잡고,
/// rekordbox 그리드와 맞대어 두 시간축의 차이도 잰다.
public struct OnsetEnvelope: Sendable {
    /// 초당 칸 수(1000 = 1ms)
    public let rate: Double
    /// 저역(킥)·고역(스네어·하이햇) 어택을 섞은 값
    public let values: [Float]
    /// 저역만(킥)
    public let low: [Float]
    public var duration: Double { Double(values.count) / rate }

    public init(rate: Double, values: [Float], low: [Float] = []) {
        self.rate = rate
        self.values = values
        self.low = low
    }

    public static func compute(url: URL, rate: Double = 1000) throws -> OnsetEnvelope {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let hop = max(1, Int((sampleRate / rate).rounded()))
        // 44.1kHz에서 칸은 44샘플이라 실제로는 초당 1002.27칸이다. 1000으로 두면 곡 끝에서 수백 ms 밀린다.
        let actualRate = sampleRate / Double(hop)
        var low = Biquad.lowPass(frequency: 130, sampleRate: sampleRate)
        var high = Biquad.highPass(frequency: 2500, sampleRate: sampleRate)
        var lowEnergy: [Float] = [], highEnergy: [Float] = []
        let expected = Int(Double(file.length) / Double(hop)) + 8
        lowEnergy.reserveCapacity(expected); highEnergy.reserveCapacity(expected)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return OnsetEnvelope(rate: actualRate, values: [], low: []) }
        var sumLow: Float = 0, sumHigh: Float = 0, filled = 0
        let channels = Int(format.channelCount)
        while file.framePosition < file.length {
            if Task.isCancelled { throw CancellationError() }
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var x: Float = 0
                for c in 0..<channels { x += data[c][i] }
                x /= Float(channels)
                let l = low.process(x), h = high.process(x)
                sumLow += l * l
                sumHigh += h * h
                filled += 1
                if filled == hop {
                    lowEnergy.append(sumLow); highEnergy.append(sumHigh)
                    sumLow = 0; sumHigh = 0; filled = 0
                }
            }
        }
        let onsetLow = rise(lowEnergy), onsetHigh = rise(highEnergy)
        let scaleLow = percentile(onsetLow, 0.995), scaleHigh = percentile(onsetHigh, 0.995)
        let values = zip(onsetLow, onsetHigh).map { l, h in
            (scaleLow > 0 ? min(l / scaleLow, 2) : 0) + 0.5 * (scaleHigh > 0 ? min(h / scaleHigh, 2) : 0)
        }
        let lowNormalized = onsetLow.map { scaleLow > 0 ? min($0 / scaleLow, 2) : 0 }
        return OnsetEnvelope(rate: actualRate, values: values, low: lowNormalized)
    }

    /// 로그 에너지의 상승분(반파 정류). 3칸 이동평균으로 잡음을 누른 뒤 2칸 전과 비교한다.
    static func rise(_ energy: [Float]) -> [Float] {
        guard energy.count > 4 else { return energy.map { _ in 0 } }
        let log = energy.map { Foundation.log(1 + $0 * 1000) }
        var smooth = log
        for i in 1..<(log.count - 1) { smooth[i] = (log[i - 1] + log[i] + log[i + 1]) / 3 }
        var out = [Float](repeating: 0, count: log.count)
        for i in 2..<smooth.count { out[i] = max(0, smooth[i] - smooth[i - 2]) }
        return out
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    /// 선형 보간 값.
    public func value(at time: Double) -> Float { Self.interpolate(values, at: time * rate) }

    /// 저역(킥)만의 선형 보간 값.
    public func lowValue(at time: Double) -> Float { Self.interpolate(low, at: time * rate) }

    static func interpolate(_ series: [Float], at x: Double) -> Float {
        guard x >= 0 else { return 0 }
        let i = Int(x)
        guard i + 1 < series.count else { return 0 }
        let f = Float(x - Double(i))
        return series[i] * (1 - f) + series[i + 1] * f
    }

    /// 박 목록을 `lag`만큼 앞당겼을 때(`t - lag`) 어택 합이 가장 큰 lag를 찾는다.
    /// 반환: (lag 초, 최고 점수, 선명도 = 최고 / 범위 중앙값). 선명도가 낮으면 믿지 않는다.
    public func bestLag(for times: [Double], range: ClosedRange<Double>, step: Double = 0.0005) -> (lag: Double, score: Double, sharpness: Double) {
        var scores: [(Double, Double)] = []
        var lag = range.lowerBound
        while lag <= range.upperBound + 1e-9 {
            var sum = 0.0
            for t in times { sum += Double(value(at: t - lag)) }
            scores.append((lag, sum))
            lag += step
        }
        guard let best = scores.max(by: { $0.1 < $1.1 }) else { return (0, 0, 0) }
        let sorted = scores.map(\.1).sorted()
        let median = sorted[sorted.count / 2]
        return (best.0, best.1, median > 0 ? best.1 / median : 0)
    }
}

/// 2차 IIR 필터(RBJ 쿡북). 샘플 단위로 상태를 이어 간다.
struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    static func lowPass(frequency: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate, alpha = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: Float((1 - c) / 2 / a0), b1: Float((1 - c) / a0), b2: Float((1 - c) / 2 / a0),
                      a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
    }

    static func highPass(frequency: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate, alpha = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0),
                      a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
    }
}
