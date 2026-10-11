import DJCDomain
import Foundation

/// 덱이 곡을 분석하는 일(포트): 파형·음악 분석(박·마디·섹션)·그리드 추정·조성 흐름·메모리 큐 제안.
/// 실제 구현(`.live`)은 DJCAdapters가 DJCAnalysis로 준다. 무거운 일(파형·음악 분석·그리드 추정)은 메인 스레드 밖에서 부르고,
/// 부른 작업을 취소하면 조각 단위로 멈춘다. 계산은 모두 음원(AVFoundation) 시간축이다.
public struct TrackAnalyzer: Sendable {
    /// 3밴드 파형(음원, 곡 UUID). 디스크 캐시는 구현이 본다
    public var waveform: @Sendable (URL, String) throws -> Waveform
    /// 음악 분석(음원, 곡 UUID). 디스크 캐시는 구현이 본다
    public var sections: @Sendable (URL, String) async throws -> PartAnalysis
    /// 박·마디와 음원 어택으로 그리드를 추정한다
    public var estimateGrid: @Sendable (PartAnalysis, URL) throws -> GridEstimate?
    public var sectionEnergies: @Sendable (PartAnalysis) -> [SectionEnergy]
    /// 메모리 큐 제안(분석, 이미 있는 큐 시각)
    public var memoryCueSuggestions: @Sendable (PartAnalysis, [Double]) -> [Double]
    /// 조성을 볼 창(그리드, 곡 길이): 마디마다, 그리드가 없으면 2초마다
    public var keyWindows: @Sendable (BeatGrid?, Double) -> [(Double, Double)]
    /// 조표 흐름(크로마, 창, 바꾸기 벌점, 최소 창 수)과 가장 긴 조표
    public var keySegments: @Sendable (KeyChroma, [(Double, Double)], Double, Int) -> (segments: [KeySegment], main: Int?)
    /// 그 조표 구간의 크로마가 나란한 단조에 더 맞는지
    public var isMinor: @Sendable (KeyChroma, Int, [KeySegment]) -> Bool

    public init(waveform: @escaping @Sendable (URL, String) throws -> Waveform,
                sections: @escaping @Sendable (URL, String) async throws -> PartAnalysis,
                estimateGrid: @escaping @Sendable (PartAnalysis, URL) throws -> GridEstimate?,
                sectionEnergies: @escaping @Sendable (PartAnalysis) -> [SectionEnergy],
                memoryCueSuggestions: @escaping @Sendable (PartAnalysis, [Double]) -> [Double],
                keyWindows: @escaping @Sendable (BeatGrid?, Double) -> [(Double, Double)],
                keySegments: @escaping @Sendable (KeyChroma, [(Double, Double)], Double, Int) -> (segments: [KeySegment], main: Int?),
                isMinor: @escaping @Sendable (KeyChroma, Int, [KeySegment]) -> Bool) {
        self.waveform = waveform
        self.sections = sections
        self.estimateGrid = estimateGrid
        self.sectionEnergies = sectionEnergies
        self.memoryCueSuggestions = memoryCueSuggestions
        self.keyWindows = keyWindows
        self.keySegments = keySegments
        self.isMinor = isMinor
    }
}
