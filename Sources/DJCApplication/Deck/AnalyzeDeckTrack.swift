import DJCDomain
import Foundation

/// 덱 곡 분석(유스케이스): 음원을 연 뒤의 파형·음악 분석·그리드 추정·조성 흐름·메모리 큐 제안과, 디코딩이 잰 값(크로마·음량) 기억.
/// 분석은 음원 시간축으로 하고 덱에 돌려줄 때 rekordbox 시간축(인코더 지연만큼 뒤)으로 옮긴다.
/// 언제 돌릴지(곡에 머문 시간·취소·우선순위)는 덱이 정한다. 무거운 일은 메인 스레드 밖에서 부른다.
public struct AnalyzeDeckTrack: Sendable {
    public var analyzer: TrackAnalyzer
    public var cache: AnalysisStore

    public init(analyzer: TrackAnalyzer, cache: AnalysisStore) {
        self.analyzer = analyzer
        self.cache = cache
    }

    /// 파형(음원 시간축). 작업을 취소하면 조각 단위로 멈춘다
    public func waveform(file: URL, key: String) throws -> Waveform {
        try analyzer.waveform(file, key)
    }

    /// 음악 분석 → rekordbox 시간축으로 옮긴 결과와 섹션 에너지
    @concurrent
    public func sections(file: URL, key: String, timelineOffset: Double) async throws -> DeckSections {
        let analysis = try await analyzer.sections(file, key)
        let shifted = analysis.shifted(by: timelineOffset)
        return DeckSections(source: analysis, shifted: shifted, energies: analyzer.sectionEnergies(shifted))
    }

    /// 그리드 추정: 캐시가 있으면 그것을, 없으면 추정해 캐시에 둔다. 추정은 rekordbox 시간축으로 옮기고 미리 보일 그리드를 함께 돌려준다.
    /// 추정하지 못하면 nil, 작업을 취소하면 `CancellationError`.
    public func gridSuggestion(_ sections: DeckSections, file: URL, key: String, timelineOffset: Double,
                               duration: Double) throws -> DeckGridSuggestion? {
        var estimate = cache.gridEstimate(key, file)
        if estimate == nil {
            estimate = try analyzer.estimateGrid(sections.source, file)
            if let estimate { cache.storeGridEstimate(estimate, key, file) }
        }
        guard var estimate else { return nil }
        for index in estimate.segments.indices { estimate.segments[index].start += timelineOffset }
        let grid = GridDraft(trackUUID: "", base: [], segments: estimate.segments).grid(duration: duration)
        return DeckGridSuggestion(estimate: estimate, grid: grid)
    }

    /// 메모리 큐 제안(rekordbox 시간축). 그리드가 있으면 박에 맞춘다
    public func memoryCueSuggestions(_ analysis: PartAnalysis, existing: [Double], grid: BeatGrid?) -> [Double] {
        analyzer.memoryCueSuggestions(analysis, existing).map { grid?.snap($0) ?? $0 }
    }

    /// 조성 흐름(마디 창, 벌점 5, 최소 16마디, rekordbox 시간축).
    /// - 장·단은 rekordbox 키를 따르고, 키가 없으면 주 조표 구간의 크로마로 정한다(흐름은 장·단을 가리지 않는다).
    /// - 주 조표를 rekordbox 키에 맞춘다(전조는 같은 간격으로 옮긴다). 첫 구간은 0초부터.
    /// - Parameter suggestsMainKey: 주 조성을 키 제안으로 내놓을지(rekordbox 키가 빈 곡)
    public func keyFlow(chroma: KeyChroma, grid: BeatGrid?, duration: Double, timelineOffset offset: Double,
                        rekordboxKey: String?, suggestsMainKey: Bool) -> DeckKeyFlow {
        guard !chroma.frames.isEmpty else { return DeckKeyFlow(segments: [], minor: false, mainKey: nil) }
        let rekordbox = rekordboxKey.flatMap { KeyNotation.signature(camelot: $0) }
        // 창은 rekordbox 시간축(그리드 기준) → 크로마(음원 시간축)로 옮겨 계산하고 되돌린다.
        let windows = analyzer.keyWindows(grid, duration).map { ($0.0 - offset, $0.1 - offset) }
        let result = analyzer.keySegments(chroma, windows, 5, 16)
        let minor = rekordbox?.minor ?? result.main.map { analyzer.isMinor(chroma, $0, result.segments) } ?? false
        var segments = result.segments.map { KeySegment(start: $0.start + offset, end: $0.end + offset, signature: $0.signature) }
        if let main = result.main, let rekordbox, main != rekordbox.signature {
            let shift = rekordbox.signature - main
            segments = segments.map { var s = $0; s.signature = (($0.signature + shift) % 12 + 12) % 12; return s }
        }
        if let first = segments.first, first.start > 0 { segments[0].start = 0 }
        let mainKey = suggestsMainKey ? result.main.map { KeyNotation.camelot(signature: $0, minor: minor) } : nil
        return DeckKeyFlow(segments: segments, minor: minor, mainKey: mainKey)
    }

    /// 디코딩이 구한 크로마를 다음 불러오기에 쓰게 둔다
    public func remember(chroma: KeyChroma, key: String, file: URL) {
        cache.storeChroma(chroma, key, file)
    }

    /// 디코딩이 잰 음량을 다음 불러오기에 쓰게 둔다
    @MainActor
    public func remember(loudness: Loudness, file: URL) {
        cache.storeLoudness(loudness, file)
    }

    /// 재분석: 이 곡의 섹션 분석·그리드 추정·크로마 캐시를 지운다
    public func forget(key: String) {
        cache.removeAll(key)
    }
}

/// 음악 분석 결과: 음원 시간축(그리드 추정용), rekordbox 시간축(덱 표시), 섹션 에너지
public struct DeckSections: Sendable {
    public var source: PartAnalysis
    public var shifted: PartAnalysis
    public var energies: [SectionEnergy]

    public init(source: PartAnalysis, shifted: PartAnalysis, energies: [SectionEnergy]) {
        self.source = source
        self.shifted = shifted
        self.energies = energies
    }
}

/// 그리드 추정 제안(rekordbox 시간축)과 파형 위에 미리 보일 그리드
public struct DeckGridSuggestion: Sendable {
    public var estimate: GridEstimate
    public var grid: BeatGrid
}

/// 곡 안의 조표 흐름(rekordbox 시간축), 장·단, 키 제안으로 내놓을 주 조성(Camelot)
public struct DeckKeyFlow: Sendable, Equatable {
    public var segments: [KeySegment]
    public var minor: Bool
    public var mainKey: String?
}
