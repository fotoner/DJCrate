import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 덱 곡 분석 유스케이스. 분석기·캐시는 가짜(음원·캐시 폴더 없이)로, 시간축 옮기기·캐시 쓰기·조성 흐름 규칙을 본다.
@Suite("덱 곡 분석")
@MainActor
struct AnalyzeDeckTrackTests {
    final class Probe: Sendable {
        let calls = Mutex<[String]>([])
        let windows = Mutex<[(Double, Double)]>([])
        let energiesInput = Mutex<PartAnalysis?>(nil)
        func record(_ name: String) { calls.withLock { $0.append(name) } }
        var names: [String] { calls.withLock { $0 } }
    }

    nonisolated static let file = URL(filePath: "/music/a.m4a")
    nonisolated static func span(_ a: Double, _ b: Double) -> PartAnalysis.Span { .init(start: a, end: b) }
    nonisolated static let analysis = PartAnalysis(duration: 10, bpm: 120, beats: [0.5, 1, 1.5, 2], bars: [0.5, 2.5], sections: [span(0, 4), span(4, 10)],
                                       segments: [], phrases: [], keys: [], pace: [], vocal: [], drum: [], loudness: [],
                                       integratedLoudness: nil)
    nonisolated static let estimate = GridEstimate(segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], medianResidualMs: 3,
                                       inlierRatio: 0.95, downbeatConfidence: 0.9)

    /// 가짜 분석기: 조표 흐름은 `segments`·`main`을 그대로 내고 받은 창을 남긴다
    static func analyzer(_ probe: Probe, estimate: GridEstimate? = estimate, segments: [KeySegment] = [], main: Int? = nil,
                         minor: Bool = false) -> TrackAnalyzer {
        TrackAnalyzer(
            waveform: { _, _ in probe.record("waveform"); return Waveform(rate: 1, duration: 0, low: [], mid: [], high: []) },
            sections: { _, key in probe.record("sections \(key)"); return analysis },
            estimateGrid: { input, _ in probe.record("estimate \(input.beats.first ?? -1)"); return estimate },
            sectionEnergies: { input in
                probe.energiesInput.withLock { $0 = input }
                return input.sections.map { SectionEnergy(span: $0, loudness: -10, vocal: 0, drum: 0, score: 0.5) }
            },
            memoryCueSuggestions: { _, existing in probe.record("cues \(existing)"); return [1.02, 4.9] },
            keyWindows: { _, duration in [(0, duration / 2), (duration / 2, duration)] },
            keySegments: { _, windows, penalty, minimum in
                probe.windows.withLock { $0 = windows }
                probe.record("segments \(penalty) \(minimum)")
                return (segments, main)
            },
            isMinor: { _, _, _ in probe.record("isMinor"); return minor })
    }

    @Test func 음악_분석은_rekordbox_시간축으로_옮기고_옮긴_값으로_섹션_에너지를_잰다() async throws {
        let probe = Probe()
        let use = AnalyzeDeckTrack(analyzer: Self.analyzer(probe), cache: MemoryAnalysisStore().store)
        let sections = try await use.sections(file: Self.file, key: "track-1", timelineOffset: 0.05)
        #expect(sections.source.beats == Self.analysis.beats)
        #expect(sections.shifted.beats == [0.55, 1.05, 1.55, 2.05] && sections.shifted.sections.first?.start == 0.05)
        #expect(probe.energiesInput.withLock { $0?.sections.first?.start } == 0.05)
        #expect(sections.energies.count == 2)
    }

    @Test func 그리드_추정은_캐시에_없을_때만_추정해_두고_rekordbox_시간축으로_옮긴다() async throws {
        let probe = Probe(), cache = MemoryAnalysisStore()
        let use = AnalyzeDeckTrack(analyzer: Self.analyzer(probe), cache: cache.store)
        let sections = DeckSections(source: Self.analysis, shifted: Self.analysis.shifted(by: 0.05), energies: [])
        let first = try #require(try use.gridSuggestion(sections, file: Self.file, key: "track-1", timelineOffset: 0.05, duration: 10))
        // 추정은 음원 시간축 분석으로 하고, 캐시에는 음원 시간축 값을 둔다
        #expect(probe.names == ["estimate 0.5"])
        #expect(cache.store.gridEstimate("track-1", Self.file) == Self.estimate)
        #expect(abs(first.estimate.segments[0].start - 0.55) < 1e-9 && first.grid.beats.contains { abs($0.time - 0.55) < 1e-9 })
        // 두 번째는 캐시에서
        let second = try use.gridSuggestion(sections, file: Self.file, key: "track-1", timelineOffset: 0.05, duration: 10)
        #expect(probe.names == ["estimate 0.5"] && second?.estimate == first.estimate)
        // 추정하지 못하면 제안이 없고 캐시에 두지 않는다
        let none = AnalyzeDeckTrack(analyzer: Self.analyzer(Probe(), estimate: nil), cache: MemoryAnalysisStore().store)
        #expect(try none.gridSuggestion(sections, file: Self.file, key: "track-1", timelineOffset: 0, duration: 10) == nil)
    }

    @Test func 조성_흐름은_rekordbox_키에_맞추고_창은_음원_시간축으로_옮겨_계산한다() {
        let probe = Probe()
        // 흐름: 0~5초 조표 0(C), 5~10초 조표 2(D). 주 조표 0
        let raw = [KeySegment(start: 0.2, end: 5, signature: 0), KeySegment(start: 5, end: 10, signature: 2)]
        let use = AnalyzeDeckTrack(analyzer: Self.analyzer(probe, segments: raw, main: 0), cache: MemoryAnalysisStore().store)
        let chroma = KeyChroma(hop: 0.2, frames: [[Float](repeating: 1, count: 12)])
        // 주 조표 C를 rekordbox 키 7B의 조표로 옮긴다(전조는 같은 간격으로)
        let flow = use.keyFlow(chroma: chroma, grid: nil, duration: 10, timelineOffset: 0.1, rekordboxKey: "7B", suggestsMainKey: false)
        let seven = KeyNotation.signature(camelot: "7B")!.signature
        #expect(flow.segments.map(\.signature) == [seven, (seven + 2) % 12])
        #expect(flow.segments.first?.start == 0 && abs(flow.segments[1].start - 5.1) < 1e-9, "첫 구간은 0초부터, 나머지는 rekordbox 시간축")
        #expect(!flow.minor && flow.mainKey == nil && !probe.names.contains("isMinor"))
        #expect(probe.windows.withLock { $0.map(\.0) } == [-0.1, 4.9], "창은 음원 시간축으로 옮겨 계산한다")
        #expect(probe.names.contains("segments 5.0 16"))

        // rekordbox 키가 없으면 장·단을 크로마로 정하고, 바라면 주 조성을 키 제안으로 낸다
        let blank = AnalyzeDeckTrack(analyzer: Self.analyzer(Probe(), segments: raw, main: 0, minor: true), cache: MemoryAnalysisStore().store)
        let guessed = blank.keyFlow(chroma: chroma, grid: nil, duration: 10, timelineOffset: 0, rekordboxKey: nil, suggestsMainKey: true)
        #expect(guessed.minor && guessed.mainKey == KeyNotation.camelot(signature: 0, minor: true) && guessed.segments.map(\.signature) == [0, 2])
    }

    @Test func 디코딩이_잰_값은_캐시에_두고_재분석은_그_곡_캐시를_지운다() {
        let cache = MemoryAnalysisStore()
        let use = AnalyzeDeckTrack(analyzer: Self.analyzer(Probe()), cache: cache.store)
        let chroma = KeyChroma(hop: 0.2, frames: [[Float](repeating: 0.5, count: 12)])
        use.remember(chroma: chroma, key: "track-1", file: Self.file)
        use.remember(loudness: Loudness(integrated: -9, peak: -0.5, clippedRuns: 0), file: Self.file)
        cache.store.storeGridEstimate(Self.estimate, "track-1", Self.file)
        #expect(cache.store.chroma("track-1", Self.file)?.frames == chroma.frames)
        #expect(cache.store.loudness(Self.file)?.integrated == -9)
        use.forget(key: "track-1")
        #expect(cache.store.chroma("track-1", Self.file) == nil && cache.store.gridEstimate("track-1", Self.file) == nil)
        #expect(cache.store.loudness(Self.file) != nil, "음량은 곡 파일 값이라 재분석이 지우지 않는다")
    }

    @Test func 메모리_큐_제안은_그리드가_있으면_박에_맞춘다() {
        let probe = Probe()
        let use = AnalyzeDeckTrack(analyzer: Self.analyzer(probe), cache: MemoryAnalysisStore().store)
        let grid = GridDraft(trackUUID: "", base: [], segments: [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)]).grid(duration: 10)
        #expect(use.memoryCueSuggestions(Self.analysis, existing: [3], grid: grid) == [1, 5])
        #expect(use.memoryCueSuggestions(Self.analysis, existing: [3], grid: nil) == [1.02, 4.9])
        #expect(probe.names == ["cues [3.0]", "cues [3.0]"])
    }
}
