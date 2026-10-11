@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 덱 시험 대부분은 "인코더 지연 0·rekordbox 원본 그리드 없음" 곡이다(adv4 T7). 실제 읽기가 내는 다른 모양
/// (압축 음원의 인코더 지연, 분석 파일의 원본 그리드, 분석 파일 상태)을 메모리 읽기로 주고 덱이 그 값을 쓰는지 본다.
@MainActor
@Suite("덱 — 곡 파일 값")
struct DeckTrackAssetsTests {
    @Test func 인코더_지연이_있는_곡은_음원을_그만큼_밀어_열고_그_값을_덱이_쓴다() async throws {
        let h = try DeckHarness(timelineOffset: 0.0261)
        try await h.loaded()
        #expect(h.deck.timelineOffset == 0.0261 && h.audio.loadedOffset == 0.0261)
        // 조성 흐름도 같은 지연으로 크로마 창을 옮긴다(첫 구간은 0초부터)
        h.deck.keyChroma = KeyChroma(hop: 0.2, frames: Array(repeating: [1, 0, 0.2, 0, 0.8, 0.5, 0, 0.9, 0, 0.3, 0, 0.1], count: 900))
        h.deck.refreshKeySegments()
        #expect(h.deck.keySegments.first?.start == 0 && !h.deck.keySegments.isEmpty)
    }

    @Test func rekordbox_분석_그리드가_있는_곡은_원본_그리드로_판정한다() async throws {
        let grid = [GridSegment(start: 0.5, bpm: 128, firstBeatNumber: 1)]
        let h = try DeckHarness(grid: grid, gridBase: grid)
        try await h.loaded()
        #expect(h.deck.hasRekordboxGrid && !h.deck.needsGrid && h.deck.gridDraft?.hasChanges != true)
        #expect(h.deck.originalGrid?.beats.first.map { abs($0.bpm - 128) < 0.001 } == true)
        // 파형 파일까지 있는 분석 곡은 덱 머리에 경고가 없다
        #expect(h.deck.analysisState == .ready && h.deck.analysisState?.note == nil)
    }

    @Test func 분석_경로가_없는_곡은_분석_전_안내를_불러올_때_정한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        #expect(h.deck.analysisState == .notAnalyzed(attachesAnalysis: true))
        #expect(h.deck.analysisState?.note?.title == "rekordbox 분석 전")
        // 곡을 내리면 비운다
        h.deck.load(nil)
        #expect(h.deck.analysisState == nil)
    }
}
