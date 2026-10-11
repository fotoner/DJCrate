import Foundation

/// 애니송 파트 라벨(휴리스틱 v0). 추정(`PartLabeler.label`)은 DJCAnalysis에 있다(#167: CLI `djc analyze`가 값만 보인다).
public enum PartLabel: String, Codable, Sendable, CaseIterable {
    case firstChorus = "1사비"
    case secondChorus = "2사비"
    case lastChorus = "라사비"
    case interlude = "간주"
}

/// 파트 하나의 자리(초)·마디·신뢰도
public struct PartMarker: Codable, Sendable, Hashable {
    public var label: PartLabel
    public var time: Double
    public var bar: Int?
    public var confidence: Double

    public init(label: PartLabel, time: Double, bar: Int?, confidence: Double) {
        self.label = label
        self.time = time
        self.bar = bar
        self.confidence = confidence
    }
}
