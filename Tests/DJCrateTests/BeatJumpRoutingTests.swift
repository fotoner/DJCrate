@testable import DJCrate
import DJCDomain
import Foundation
import Testing

/// ←→·⇧←→(선택한 큐가 있으면 그 큐, 없으면 재생 위치), Esc(큐 선택 풀기), S·⇧S·A(제안).
/// 120 BPM 시험 곡: 0.5초부터 0.5초 간격으로 박이 있다.
@MainActor
@Suite("단축키 — 비트 점프·제안")
struct BeatJumpRoutingTests {
    static let left: UInt16 = 123, right: UInt16 = 124, escape: UInt16 = 53, s: UInt16 = 1, a: UInt16 = 0

    func router(_ h: DeckHarness) -> KeyRouter {
        let router = KeyRouter()
        router.deck = h.deck
        return router
    }

    @Test func 선택한_큐가_없으면_화살표는_재생_위치를_1박_Shift는_1마디_옮긴다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = router(h)
        h.deck.seek(10)
        #expect(h.deck.selectedCueID == nil)
        #expect(router.handleKeyDown(Self.right, focus: .deck))
        #expect(h.deck.currentTime == 10.5)
        #expect(router.handleKeyDown(Self.right, shift: true, focus: .deck))
        #expect(h.deck.currentTime == 12.5)
        #expect(router.handleKeyDown(Self.left, isRepeat: true, focus: .deck), "누르고 있으면 계속 옮긴다")
        #expect(h.deck.currentTime == 12)
        #expect(router.handleKeyDown(Self.left, shift: true, focus: .deck))
        #expect(h.deck.currentTime == 10)
        #expect(h.deck.cuePoint == 0, "CUE 지점은 그대로다")
        #expect(h.deck.draft?.cues.isEmpty == true)
    }

    @Test func 멈춰_있으면_박_사이에서_가까운_박으로_붙는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = router(h)
        h.deck.seek(10.2)
        #expect(router.handleKeyDown(Self.left, focus: .deck))
        #expect(h.deck.currentTime == 10)
    }

    @Test func 재생_중에는_박_안의_위치를_지켜_그_자리에서_이어_재생한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = router(h)
        h.deck.seek(10.2)
        h.deck.togglePlay()
        #expect(router.handleKeyDown(Self.right, focus: .deck))
        #expect(abs(h.deck.currentTime - 10.7) < 1e-9)
        #expect(h.deck.isPlaying)
        #expect(h.audio.log.last == "play 10.700")
    }

    @Test func 선택한_큐가_있으면_화살표는_큐를_1박_Shift는_1마디_민다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = router(h)
        h.deck.seek(10)
        h.deck.cueDown()
        h.deck.cueUp()
        h.deck.addMemoryCue()
        let id = try #require(h.deck.selectedCueID)
        #expect(router.handleKeyDown(Self.right, focus: .deck))
        #expect(h.deck.cue(id)?.time == 10.5)
        #expect(router.handleKeyDown(Self.right, shift: true, focus: .deck))
        #expect(h.deck.cue(id)?.time == 12.5)
        #expect(router.handleKeyDown(Self.left, shift: true, focus: .deck))
        #expect(router.handleKeyDown(Self.left, focus: .deck))
        #expect(h.deck.cue(id)?.time == 10)
        #expect(h.deck.currentTime == 10, "큐를 밀 때 재생 위치는 그대로다")
    }

    @Test func Esc는_덱에서_큐_선택만_풀고_그_뒤_화살표는_재생_위치를_옮긴다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = router(h)
        h.deck.seek(10)
        h.deck.cueDown()
        h.deck.cueUp()
        h.deck.addMemoryCue()
        #expect(!router.handleKeyDown(Self.escape, focus: .trackList), "목록의 Esc는 바꾸지 않는다")
        #expect(h.deck.selectedCueID != nil)
        #expect(router.handleKeyDown(Self.escape, focus: .deck))
        #expect(h.deck.selectedCueID == nil)
        #expect(h.deck.draft?.cues.map(\.time) == [10], "큐는 그대로 둔다")
        #expect(router.handleKeyDown(Self.right, focus: .deck))
        #expect(h.deck.currentTime == 10.5)
        #expect(h.deck.draft?.cues.map(\.time) == [10])
        #expect(!router.handleKeyDown(Self.escape, focus: .deck), "선택이 없으면 지금처럼 아무 일도 없다")
    }

    @Test func 목록에서는_화살표로_재생_위치를_옮기지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = router(h)
        h.deck.seek(10)
        #expect(!router.handleKeyDown(Self.right, focus: .trackList))
        #expect(h.deck.currentTime == 10)
    }

    @Test func S는_다음_제안_Shift_S는_이전_제안으로_재생_위치만_옮긴다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        var messages: [String] = []
        h.deck.feedback = AppFeedback(announce: { messages.append($0.text) })
        let router = router(h)
        h.deck.suggestions = [10, 20, 30]   // 분석을 끈 시험이라 직접 넣는다
        h.deck.seek(12)
        #expect(router.handleKeyDown(Self.s, focus: .deck))
        #expect(h.deck.currentTime == 20)
        #expect(router.handleKeyDown(Self.s, focus: .trackList), "Q/E처럼 목록에서도 받는다")
        #expect(h.deck.currentTime == 30)
        #expect(router.handleKeyDown(Self.s, shift: true, focus: .deck))
        #expect(router.handleKeyDown(Self.s, shift: true, focus: .deck))
        #expect(h.deck.currentTime == 10)
        #expect(h.deck.draft?.cues.isEmpty == true, "옮기기만 하고 큐는 만들지 않는다")
        #expect(h.deck.cuePoint == 0)
        #expect(messages.isEmpty)
        #expect(router.handleKeyDown(Self.s, shift: true, focus: .deck))
        #expect(h.deck.currentTime == 10, "앞쪽에 제안이 없으면 그대로")
        #expect(messages == ["앞쪽에 제안이 없습니다"])
    }

    @Test func A는_재생_위치에서_가장_가까운_제안을_메모리_큐로_받는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        var messages: [String] = []
        h.deck.feedback = AppFeedback(announce: { messages.append($0.text) })
        let router = router(h)
        h.deck.suggestions = [10, 20, 30]
        h.deck.seek(18)
        #expect(router.handleKeyDown(Self.a, focus: .deck))
        #expect(h.deck.draft?.cues.map(\.time) == [20])
        #expect(h.deck.draft?.cues.first?.kind == .memory)
        #expect(h.deck.currentTime == 18, "재생 위치는 그대로다")
        #expect(messages == ["제안을 받아 20초에 메모리 큐를 찍었습니다"])
    }

    @Test func 제안이_없으면_아무_일도_하지_않고_안내만_한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        var messages: [String] = []
        h.deck.feedback = AppFeedback(announce: { messages.append($0.text) })
        let router = router(h)
        h.deck.seek(12)
        #expect(router.handleKeyDown(Self.a, focus: .deck))
        #expect(router.handleKeyDown(Self.s, focus: .deck))
        #expect(h.deck.draft?.cues.isEmpty == true)
        #expect(h.deck.currentTime == 12)
        #expect(h.deck.toast == nil, "화면 알림은 띄우지 않는다")
        #expect(messages == ["받을 제안이 없습니다", "뒤쪽에 제안이 없습니다"])
    }

    @Test func 쓰기_중에는_새_키를_막고_덱도_움직이지_않는다() async throws {
        let policy = WriteLockPolicy(isWriting: true)
        for focus: KeyRoutingPolicy.Focus in [.deck, .trackList] {
            for key in [Self.left, Self.right, Self.escape, Self.s, Self.a] {
                #expect(policy.blocksKey(key, in: .init(focus: focus)))
            }
        }
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.suggestions = [10, 20]
        h.deck.seek(12)
        h.deck.isWriteLocked = true
        h.deck.step(beats: 1)
        h.deck.jumpToSuggestion(forward: true)
        h.deck.acceptNearestSuggestion()
        #expect(h.deck.currentTime == 12)
        #expect(h.deck.draft?.cues.isEmpty == true)
    }

    @Test func 기본_표는_S와_A를_제안에_쓰고_겹치지_않는다() {
        let standard = DeckShortcuts.standard
        #expect(standard.keys(for: .nextSuggestion) == [Self.s])
        #expect(standard.keys(for: .acceptSuggestion) == [Self.a])
        #expect(standard.conflicts.isEmpty)
        #expect(KeyRoutingPolicy.accepts(Self.s, in: .init(focus: .trackList)))
        #expect(KeyRoutingPolicy.accepts(Self.a, in: .init(focus: .trackList)))
        #expect(!KeyRoutingPolicy.accepts(Self.a, in: .init(focus: .sheet)), "태그 표에서는 글자 입력")
    }
}
