import Foundation

/// 섹션 하나의 에너지(음량·보컬·드럼과 그 합 점수). 계산(`PartLabeler.energies`)은 DJCAnalysis에 있다(#167).
public struct SectionEnergy: Sendable {
    public var span: PartAnalysis.Span
    public var loudness: Double
    public var vocal: Double
    public var drum: Double
    public var score: Double

    public init(span: PartAnalysis.Span, loudness: Double, vocal: Double, drum: Double, score: Double) {
        self.span = span; self.loudness = loudness; self.vocal = vocal; self.drum = drum; self.score = score
    }
}
