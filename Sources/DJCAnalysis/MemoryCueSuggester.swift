import DJCDomain
import Foundation

/// 자동 메모리 큐 후보: Music Understanding 섹션 경계를 박에 스냅한 지점.
///
/// 직접 찍은 큐가 섹션 경계와 거의 일치한다는 관찰(2026-09-25, 6곡)에서 출발했다.
/// `CueEvaluation`으로 수동 큐 대비 재현율·정밀도를 재고 게이트를 정한다.
public enum MemoryCueSuggester {
    /// - Parameters:
    ///   - minimumSectionBars: 이보다 짧은 섹션의 시작은 후보에서 뺀다(짧은 브레이크·꼬리).
    public static func candidates(_ analysis: PartAnalysis, minimumSectionBars: Double = 2) -> [Double] {
        let barLength = analysis.bpm.map { 240 / $0 } ?? 2
        return analysis.sections
            .filter { $0.duration >= barLength * minimumSectionBars }
            .map { analysis.snap($0.start) }
            .filter { $0 > 0.5 && $0 < analysis.duration - 1 }
    }

    /// 기존 큐와 ±1마디 안에 겹치는 후보는 만들지 않는다.
    public static func suggestions(_ analysis: PartAnalysis, existing: [Double]) -> [Double] {
        let barLength = analysis.bpm.map { 240 / $0 } ?? 2
        return candidates(analysis).filter { candidate in
            !existing.contains { abs($0 - candidate) <= barLength }
        }
    }
}

/// 후보와 정답(직접 찍은 큐)의 일치 평가.
public struct CueEvaluation: Sendable {
    public var truth = 0
    public var predicted = 0
    public var truthMatched = 0
    public var predictedMatched = 0

    public var recall: Double { truth == 0 ? 0 : Double(truthMatched) / Double(truth) }
    public var precision: Double { predicted == 0 ? 0 : Double(predictedMatched) / Double(predicted) }

    public init() {}

    public init(truth: [Double], predicted: [Double], tolerance: Double) {
        self.truth = truth.count
        self.predicted = predicted.count
        truthMatched = truth.filter { t in predicted.contains { abs($0 - t) <= tolerance } }.count
        predictedMatched = predicted.filter { p in truth.contains { abs($0 - p) <= tolerance } }.count
    }

    public static func + (lhs: CueEvaluation, rhs: CueEvaluation) -> CueEvaluation {
        var sum = CueEvaluation()
        sum.truth = lhs.truth + rhs.truth
        sum.predicted = lhs.predicted + rhs.predicted
        sum.truthMatched = lhs.truthMatched + rhs.truthMatched
        sum.predictedMatched = lhs.predictedMatched + rhs.predictedMatched
        return sum
    }
}
