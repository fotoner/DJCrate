import Foundation

/// 박·마디로 추정한 rekordbox식 비트 그리드(템포 구간)와 그 믿음 정도. 추정(`GridEstimator`)은 DJCAnalysis에 있다(#167).
public struct GridEstimate: Codable, Sendable, Hashable {
    public var segments: [GridSegment]
    /// 맞춘 직선과 MU 박의 차이 중앙값(ms). 작을수록 박이 고르다.
    public var medianResidualMs: Double
    /// 직선에서 25ms 안에 든 박의 비율(0~1).
    public var inlierRatio: Double
    /// 1박 다수결에서 이긴 표의 비율(0~1). 마디 정보가 없으면 0.
    public var downbeatConfidence: Double
    public var bpm: Double { segments.first?.bpm ?? 0 }

    /// 믿을 만한 추정인지(적용 버튼을 바로 권할지).
    public var isConfident: Bool { inlierRatio >= 0.85 && medianResidualMs <= 15 }

    public init(segments: [GridSegment], medianResidualMs: Double, inlierRatio: Double, downbeatConfidence: Double) {
        self.segments = segments; self.medianResidualMs = medianResidualMs
        self.inlierRatio = inlierRatio; self.downbeatConfidence = downbeatConfidence
    }
}
