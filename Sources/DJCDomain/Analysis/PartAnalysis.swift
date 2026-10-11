import Foundation

/// Music Understanding 결과를 초 단위로 옮긴 캐시 가능한 모델. 분석(`PartAnalyzer`)은 DJCAnalysis에 있다(#167).
public struct PartAnalysis: Codable, Sendable {
    public struct Span: Codable, Sendable, Hashable {
        public var start: Double
        public var end: Double
        public var duration: Double { end - start }

        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    public struct KeySpan: Codable, Sendable, Hashable {
        public var span: Span
        public var tonic: String
        public var mode: String
        public var name: String { "\(tonic) \(mode)" }

        public init(span: Span, tonic: String, mode: String) { self.span = span; self.tonic = tonic; self.mode = mode }
    }

    public struct Sample: Codable, Sendable, Hashable {
        public var time: Double
        public var value: Double

        public init(time: Double, value: Double) { self.time = time; self.value = value }
    }

    public var duration: Double
    public var bpm: Double?
    public var beats: [Double]
    public var bars: [Double]
    public var sections: [Span]
    public var segments: [Span]
    public var phrases: [Span]
    public var keys: [KeySpan]
    public var pace: [Sample]
    public var vocal: [Sample]
    public var drum: [Sample]
    public var loudness: [Sample]
    public var integratedLoudness: Double?

    public init(duration: Double, bpm: Double?, beats: [Double], bars: [Double], sections: [Span], segments: [Span], phrases: [Span],
                keys: [KeySpan], pace: [Sample], vocal: [Sample], drum: [Sample], loudness: [Sample], integratedLoudness: Double?) {
        self.duration = duration; self.bpm = bpm; self.beats = beats; self.bars = bars; self.sections = sections
        self.segments = segments; self.phrases = phrases; self.keys = keys; self.pace = pace; self.vocal = vocal
        self.drum = drum; self.loudness = loudness; self.integratedLoudness = integratedLoudness
    }

    /// 구간 안 샘플의 평균. 무음 구간의 `-inf` LUFS 같은 비유한 값은 `floor`로 바꾼다.
    public static func mean(_ samples: [Sample], in span: Span, floor: Double = -70) -> Double {
        let values = samples
            .filter { $0.time >= span.start && $0.time < span.end }
            .map { $0.value.isFinite ? max($0.value, floor) : floor }
        return values.isEmpty ? floor : values.reduce(0, +) / Double(values.count)
    }

    /// 가장 가까운 박으로 스냅. 다운비트(마디 시작)가 반 박 안에 있으면 그쪽을 택한다.
    public func snap(_ time: Double) -> Double {
        guard let beat = beats.min(by: { abs($0 - time) < abs($1 - time) }) else { return time }
        let beatLength = bpm.map { 60 / $0 } ?? 0.5
        if let bar = bars.min(by: { abs($0 - beat) < abs($1 - beat) }), abs(bar - time) <= beatLength / 2 {
            return bar
        }
        return beat
    }

    /// 몇 번째 마디인지 (1부터).
    public func barNumber(at time: Double) -> Int? {
        guard !bars.isEmpty else { return nil }
        return bars.lastIndex(where: { $0 <= time + 0.05 }).map { $0 + 1 }
    }
}

public extension PartAnalysis {
    /// 모든 시각을 옮긴다. MU는 AVFoundation 시간축(인코더 지연을 잘라 낸 음원)으로 분석하므로,
    /// rekordbox 시간축에서 보여 줄 때 그 지연만큼 뒤로 민다.
    func shifted(by seconds: Double) -> PartAnalysis {
        guard seconds != 0 else { return self }
        func span(_ s: Span) -> Span { Span(start: s.start + seconds, end: s.end + seconds) }
        func sample(_ s: Sample) -> Sample { Sample(time: s.time + seconds, value: s.value) }
        var copy = self
        copy.duration += seconds
        copy.beats = beats.map { $0 + seconds }
        copy.bars = bars.map { $0 + seconds }
        copy.sections = sections.map(span)
        copy.segments = segments.map(span)
        copy.phrases = phrases.map(span)
        copy.keys = keys.map { KeySpan(span: span($0.span), tonic: $0.tonic, mode: $0.mode) }
        copy.pace = pace.map(sample)
        copy.vocal = vocal.map(sample)
        copy.drum = drum.map(sample)
        copy.loudness = loudness.map(sample)
        return copy
    }
}
