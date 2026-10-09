import DJCAnalysis
import DJCApplication
import DJCDomain
import Foundation

extension PartAnalysisTools {
    /// DJCAnalysis 음악 분석(분석 캐시는 이 프로세스의 캐시 폴더, `DJC_HOME`을 따른다)과 섹션 에너지·파트 추정(휴리스틱 v0)
    public static let live = PartAnalysisTools(analyze: { try await PartAnalyzer.analyze(fileAt: $0, cacheKey: $1) },
                                               energies: { PartLabeler.energies($0) },
                                               parts: { PartLabeler.label($0) })
}
