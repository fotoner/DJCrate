import DJCDomain
import Foundation

/// 곡 하나의 그리드 추정(DJCrate 시간축): Music Understanding(캐시) → 어택 곡선 → 추정기.
public enum GridSuggestion {
    public static func estimate(fileAt url: URL, cacheKey: String) async throws -> GridEstimator.Estimate? {
        let analysis = try await PartAnalyzer.analyze(fileAt: url, cacheKey: cacheKey)
        try Task.checkCancellation()
        let onset = try await Task.detached(priority: .utility) { try OnsetEnvelope.compute(url: url) }.value
        try Task.checkCancellation()
        return GridEstimator.estimate(beats: analysis.beats, bars: analysis.bars, duration: analysis.duration, onset: onset)
    }
}
