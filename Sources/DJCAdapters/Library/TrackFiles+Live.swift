import DJCAnalysis
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension TrackFiles {
    /// 이 Mac의 파일 시스템과 음원 태그(AVFoundation)
    public static let live = TrackFiles(
        exists: { FileManager.default.fileExists(atPath: $0) },
        audioFiles: { StagedTrack.audioFiles(in: $0) },
        stagedTrack: { try await StagedTrack.make(fileAt: $0, addedOn: $1) },
        tagKey: { await StagedTrack.tagKey(fileAt: $0) },
        read: { try Data(contentsOf: $0) })
}

extension StagingAnalysis {
    /// DJCAnalysis 그리드 추정·조성 분석(덱과 같은 크로마 캐시)과 rekordbox 인코더 지연 규칙
    public static let live = StagingAnalysis(
        estimateGrid: { try await GridSuggestion.estimate(fileAt: $0, cacheKey: $1) },
        timelineOffset: { RekordboxTimeline.predictedOffset(url: $0) },
        mainKey: { url, grid, offset, duration, cacheKey in
            await Task.detached(priority: .utility) { () -> String?? in
                let chroma: KeyAnalyzer.Chroma
                if let cacheKey, let cached = AnalysisCache.chroma(key: cacheKey, file: url) {
                    chroma = cached
                } else {
                    guard let computed = try? KeyAnalyzer.chroma(fileAt: url) else { return nil }
                    if let cacheKey { AnalysisCache.store(computed, key: cacheKey, file: url) }
                    chroma = computed
                }
                let windows = KeyAnalyzer.windows(grid: grid, duration: duration).map { ($0.0 - offset, $0.1 - offset) }
                return .some(KeyAnalyzer.mainKey(chroma: chroma, windows: windows)?.camelot)
            }.value
        })
}
