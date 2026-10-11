/// 조성 추정의 크로마(`KeyAnalyzer.Chroma`). 덱이 캐시에서 받아 디코딩 때 다시 계산하지 않게 넘긴다(#167).
public struct KeyChroma: Sendable {
    /// 프레임 간격(초)
    public var hop: Double
    /// 프레임 × 12(C부터). 무음 프레임은 0.
    public var frames: [[Float]]

    public init(hop: Double, frames: [[Float]]) { self.hop = hop; self.frames = frames }
}
