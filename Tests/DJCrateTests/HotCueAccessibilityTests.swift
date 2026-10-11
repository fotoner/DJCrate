@testable import DJCrate
import DJCDomain
import Testing

@Suite("핫큐 패드 접근성")
@MainActor
struct HotCueAccessibilityTests {
    @Test func 빈_칸과_일반_핫큐는_설정과_이동을_구분한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        #expect(h.deck.hotCueAccessibility(slot: 0).label == "핫큐 A 비어 있음, 설정")
        #expect(h.deck.hotCueAccessibility(slot: 0).value.isEmpty)
        h.deck.seek(10.5)
        h.deck.pressHotCue(slot: 0)
        #expect(h.deck.hotCueAccessibility(slot: 0).label == "핫큐 A로 이동")
        #expect(h.deck.hotCueAccessibility(slot: 0).value == "10초")
    }

    @Test func 루프_핫큐는_박_수와_반복_상태를_읽는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(10.5)
        h.deck.toggleLoop()
        h.deck.pressHotCue(slot: 0)
        #expect(h.deck.hotCueAccessibility(slot: 0).label == "루프 핫큐 A")
        #expect(h.deck.hotCueAccessibility(slot: 0).value == "4박, 반복 중")
        h.deck.togglePlay()
        h.deck.pressHotCue(slot: 0)
        #expect(h.deck.hotCueAccessibility(slot: 0).value == "4박, 반복 꺼짐")
        h.deck.pressHotCue(slot: 0)
        #expect(h.deck.hotCueAccessibility(slot: 0).value == "4박, 반복 중")
    }

    @Test func 짧은_루프의_분수_박도_유지한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.loopSize = 0.5
        h.deck.toggleLoop()
        h.deck.pressHotCue(slot: 2)
        #expect(h.deck.hotCueAccessibility(slot: 2).label == "루프 핫큐 C")
        #expect(h.deck.hotCueAccessibility(slot: 2).value == "½박, 반복 중")
    }
}
