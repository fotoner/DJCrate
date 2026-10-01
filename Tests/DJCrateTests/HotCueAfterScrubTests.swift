@testable import DJCrate
import Testing

/// #92 모델 경로 대조. GUI 클릭 누락과 구분해, 놓은 뒤 남는 스크럽 상태·재개 타이머를 확인한다.
@MainActor
@Suite("덱 — 스크럽 뒤 핫큐")
struct HotCueAfterScrubTests {
    @Test(arguments: [false, true], [false, true])
    func 전체와_확대_스크럽을_반복해도_놓은_뒤_핫큐를_무시하지_않는다(zoom: Bool, playing: Bool) async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(20)
        h.deck.pressHotCue(slot: 0)
        let cue = try #require(h.deck.hotCue(slot: 0))
        h.deck.playQuantize = false
        for _ in 0..<20 {
            h.deck.stopPlayback()
            h.deck.seek(60)
            if playing { h.deck.togglePlay() }
            if zoom { h.deck.beginScrubDrag() } else { h.deck.beginScrub() }
            for i in 0..<40 {
                let movement = i.isMultiple(of: 2) ? 2.0 : 4.0
                if zoom { h.deck.dragScrub(by: movement) } else { h.deck.scrub(to: 60 + movement) }
            }
            h.deck.endScrub()
            #expect(h.deck.scrubAnchor == nil && !h.deck.resumeAfterScrub)
            h.deck.selectedCueID = nil
            h.deck.pressHotCue(slot: 0)
            #expect(h.deck.selectedCueID == cue.id)
            #expect(h.deck.playhead == cue.time && h.audio.position == cue.time)
            #expect(h.deck.isPlaying && h.audio.isPlaying)
        }
    }

    @Test(arguments: [false, true])
    func 스크롤_재개_대기_중_누른_핫큐는_타이머_뒤에도_유지된다(quantized: Bool) async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(20)
        h.deck.pressHotCue(slot: 0)
        let cue = try #require(h.deck.hotCue(slot: 0))
        h.deck.playQuantize = quantized
        h.deck.seek(60)
        h.deck.togglePlay()
        h.deck.scrubCoalesced(to: 62)
        let restart = try #require(h.deck.seekRestartTask)
        #expect(!h.deck.isPlaying && h.deck.resumeAfterScrub)
        h.deck.pressHotCue(slot: 0)
        #expect(h.deck.selectedCueID == cue.id && h.audio.position == cue.time)
        await restart.value
        #expect(!h.deck.resumeAfterScrub && h.deck.scrubAnchor == nil)
        #expect(h.deck.selectedCueID == cue.id && h.audio.position == cue.time)
        #expect(h.deck.isPlaying && h.audio.isPlaying)
    }
}
