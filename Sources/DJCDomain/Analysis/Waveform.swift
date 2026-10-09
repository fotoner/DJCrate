import Foundation

/// rekordbox식 3밴드 파형. 저음(~200Hz)·중음(200~2,500Hz)·고음(2,500Hz~)의 RMS를
/// 초당 `rate`칸으로 계산해 0~255로 양자화한다. 계산(`WaveformAnalyzer`)·캐시는 DJCAnalysis에 있다(#167).
public struct Waveform: Codable, Sendable {
    public var rate: Double
    public var duration: Double
    public var low: [UInt8]
    public var mid: [UInt8]
    public var high: [UInt8]

    public init(rate: Double, duration: Double, low: [UInt8], mid: [UInt8], high: [UInt8]) {
        self.rate = rate; self.duration = duration; self.low = low; self.mid = mid; self.high = high
    }

    public var count: Int { low.count }

    public var colorColumns: [WaveformColumn] {
        (0..<count).map { WaveformColumn(low: Double(low[$0]) / 255,
                                        mid: Double(mid[$0]) / 255, high: Double(high[$0]) / 255) }
    }

    /// 개요 파형용 다운샘플(구간 최대값).
    public func downsampled(to points: Int) -> Waveform {
        guard count > points, points > 0 else { return self }
        func reduce(_ band: [UInt8]) -> [UInt8] {
            (0..<points).map { i in
                let start = i * band.count / points, end = max(start + 1, (i + 1) * band.count / points)
                return band[start..<end].max() ?? 0
            }
        }
        return Waveform(rate: Double(points) / duration, duration: duration,
                        low: reduce(low), mid: reduce(mid), high: reduce(high))
    }

    /// `[start, end)` 초 구간만 잘라낸다.
    public func slice(from start: Double, to end: Double) -> Waveform {
        let a = max(0, Int(start * rate)), b = min(count, Int(end * rate))
        guard a < b else { return Waveform(rate: rate, duration: 0, low: [], mid: [], high: []) }
        return Waveform(rate: rate, duration: Double(b - a) / rate,
                        low: Array(low[a..<b]), mid: Array(mid[a..<b]), high: Array(high[a..<b]))
    }
}
