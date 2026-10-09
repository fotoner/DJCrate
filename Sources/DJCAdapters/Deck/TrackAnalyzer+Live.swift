import DJCAnalysis
import DJCApplication
import DJCDomain
import DJCEnvironment
import Foundation

extension TrackAnalyzer {
    /// DJCAnalysis의 분석기. 파형 캐시는 `paths.waveforms`(섹션 분석 캐시는 `PartAnalyzer`가 이 프로세스의 캐시 폴더를 따른다).
    public static func live(paths: DJCCachePaths) -> TrackAnalyzer {
        TrackAnalyzer(
            waveform: { try WaveformCache.load(fileAt: $0, key: $1, paths: paths) },
            sections: { try await PartAnalyzer.analyze(fileAt: $0, cacheKey: $1) },
            estimateGrid: { analysis, url in
                let onset = try OnsetEnvelope.compute(url: url)
                try Task.checkCancellation()
                return GridEstimator.estimate(beats: analysis.beats, bars: analysis.bars, duration: analysis.duration, onset: onset)
            },
            sectionEnergies: { PartLabeler.energies($0) },
            memoryCueSuggestions: { MemoryCueSuggester.suggestions($0, existing: $1) },
            keyWindows: { KeyAnalyzer.windows(grid: $0, duration: $1) },
            keySegments: { KeyAnalyzer.segments(chroma: $0, windows: $1, switchPenalty: $2, minWindows: $3) },
            isMinor: { KeyAnalyzer.isMinor(chroma: $0, signature: $1, segments: $2) })
    }
}
