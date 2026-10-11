import DJCAnalysis
import DJCApplication
import DJCDomain
import DJCEnvironment
import Foundation

extension AnalysisStore {
    /// 분석 캐시 폴더(`paths.analysis`의 그리드 추정·크로마·섹션 분석)와 음량 캐시.
    /// 음량 캐시는 목록(반영 분석 입력)도 함께 쓰는 하나라 조립 지점이 그 읽기·저장을 넘긴다.
    public static func live(paths: DJCCachePaths, loudness: @escaping @Sendable (URL) -> Loudness?,
                            storeLoudness: @escaping @MainActor (Loudness, URL) -> Void) -> AnalysisStore {
        AnalysisStore(
            chroma: { AnalysisCache.chroma(key: $0, file: $1, paths: paths) },
            storeChroma: { AnalysisCache.store($0, key: $1, file: $2, paths: paths) },
            loudness: loudness,
            storeLoudness: storeLoudness,
            gridEstimate: { AnalysisCache.gridEstimate(key: $0, file: $1, paths: paths) },
            storeGridEstimate: { AnalysisCache.store($0, key: $1, file: $2, paths: paths) },
            removeAll: { AnalysisCache.removeAll(key: $0, paths: paths) })
    }
}
