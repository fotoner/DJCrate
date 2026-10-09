import Foundation

/// 곡 안의 조표 구간(초). 조표 흐름 추정(`KeyAnalyzer.segments`)은 DJCAnalysis에 있다(#167).
public struct KeySegment: Sendable, Hashable {
    public var start: Double
    public var end: Double
    /// 조표 = 장조 으뜸음 음이름(0 = C … 11 = B). 나란한 단조와 같은 조표다.
    public var signature: Int

    public init(start: Double, end: Double, signature: Int) { self.start = start; self.end = end; self.signature = signature }
}
