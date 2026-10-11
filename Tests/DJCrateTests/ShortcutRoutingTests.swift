@testable import DJCrate
import DJCDomain
import Foundation
import Testing

/// 설정에서 바꾼 단축키로 KeyRouter가 덱을 움직이는지(키 위치 기준). 120 BPM 시험 곡.
@MainActor
@Suite("단축키 — 바꾼 키")
struct ShortcutRoutingTests {
    static let p: UInt16 = 35, x: UInt16 = 7, z: UInt16 = 6, space: UInt16 = 49, c: UInt16 = 8, m: UInt16 = 46

    func router(_ h: DeckHarness, _ change: (inout DeckShortcuts) throws -> Void) rethrows -> KeyRouter {
        var shortcuts = h.deck.shortcuts
        try change(&shortcuts)
        h.deck.shortcuts = shortcuts
        let router = KeyRouter()
        router.deck = h.deck
        return router
    }

    @Test func 기본_키는_예전처럼_동작한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = router(h) { _ in }
        #expect(router.handleKeyDown(Self.space, focus: .deck))
        #expect(h.deck.isPlaying)
        #expect(router.handleKeyDown(Self.space, focus: .sheet), "태그 표에서도 스페이스는 재생/정지")
        #expect(!h.deck.isPlaying)
        #expect(!router.handleKeyDown(Self.c, focus: .sheet), "태그 표에서 다른 덱 키는 표에 넘긴다")
    }

    @Test func 재생_키를_바꾸면_새_키로_재생하고_옛_키는_넘긴다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = try router(h) { try $0.replace(Self.space, with: Self.p, in: .playPause) }
        #expect(!router.handleKeyDown(Self.space, focus: .deck))
        #expect(!h.deck.isPlaying)
        #expect(router.handleKeyDown(Self.p, focus: .deck))
        #expect(h.deck.isPlaying)
        #expect(h.audio.log.contains { $0.hasPrefix("play") })
    }

    @Test func CUE_키를_바꾸면_새_키를_떼야_미리_듣기가_끝난다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = try router(h) { try $0.replace(Self.c, with: Self.x, in: .cue) }
        #expect(!router.handleKeyDown(Self.c, focus: .deck))
        #expect(!h.deck.isCuePreviewing)
        #expect(router.handleKeyDown(Self.x, focus: .deck))
        #expect(h.deck.isCuePreviewing)
        #expect(!router.handleKeyUp(Self.c))
        #expect(h.deck.isCuePreviewing, "다른 키를 떼도 미리 듣기는 이어진다")
        #expect(router.handleKeyUp(Self.x))
        #expect(!h.deck.isCuePreviewing)
    }

    @Test func 핫큐_키를_바꾸면_새_키로_찍고_Shift로_지운다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = try router(h) { try $0.replace(18, with: Self.z, in: .hotCueA) }
        h.deck.seek(10.5)
        #expect(!router.handleKeyDown(18, focus: .deck))
        #expect(h.deck.hotCue(slot: 0) == nil)
        #expect(router.handleKeyDown(Self.z, focus: .deck))
        #expect(h.deck.hotCue(slot: 0)?.time == 10.5)
        #expect(router.handleKeyDown(Self.z, shift: true, focus: .deck))
        #expect(h.deck.hotCue(slot: 0) == nil)
        // 숫자 패드 1은 그대로 핫큐 A
        #expect(router.handleKeyDown(83, focus: .deck))
        #expect(h.deck.hotCue(slot: 0) != nil)
    }

    @Test func 겹친_키는_목록_위쪽_동작이_받는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = try router(h) { try $0.add(Self.m, to: .tapTempo) }
        h.deck.seek(20.5)
        #expect(router.handleKeyDown(Self.m, focus: .deck))
        #expect(h.deck.draft?.cues.contains { $0.kind == .memory } == true)
        #expect(h.deck.taps.isEmpty)
    }

    @Test func 태그_표에서는_스페이스가_재생일_때만_덱으로_간다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = try router(h) {
            try $0.replace(Self.space, with: Self.p, in: .playPause)
            try $0.add(Self.space, to: .loop)
        }
        // 스페이스는 태그 표에서도 덱으로 오지만(#28), 재생/정지가 아니면 표에 넘긴다.
        #expect(KeyRoutingPolicy.accepts(Self.space, in: .init(focus: .sheet), shortcuts: h.deck.shortcuts))
        #expect(!router.handleKeyDown(Self.space, focus: .sheet))
        #expect(!h.deck.isLooping)
        // 태그 표에서 글자 키는 칸 입력에 쓴다: 재생 키로 바꿨어도 표에 넘긴다.
        #expect(!KeyRoutingPolicy.accepts(Self.p, in: .init(focus: .sheet), shortcuts: h.deck.shortcuts))
    }

    @Test func 반복_입력은_한_번만_누른_것으로_본다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = router(h) { _ in }
        #expect(router.handleKeyDown(Self.space, focus: .deck))
        #expect(router.handleKeyDown(Self.space, isRepeat: true, focus: .deck))
        #expect(h.deck.isPlaying, "키를 누르고 있어도 재생/정지를 되풀이하지 않는다")
    }

    @Test func 곡_목록은_바꾼_키를_받고_뺀_키는_표에_넘긴다() throws {
        var shortcuts = DeckShortcuts.standard
        try shortcuts.replace(Self.space, with: Self.p, in: .playPause)
        let list = KeyRoutingPolicy.Context(focus: .trackList)
        #expect(KeyRoutingPolicy.accepts(Self.p, in: list, shortcuts: shortcuts))
        #expect(!KeyRoutingPolicy.accepts(Self.space, in: list, shortcuts: shortcuts))
        // 곡 목록에서 ←→⌫⌦는 할 일이 없어도 삼킨다(경고음 방지, #28 규칙)
        shortcuts.remove(123, from: .nudgeBack)
        #expect(KeyRoutingPolicy.accepts(123, in: list, shortcuts: shortcuts))
        // 태그 표는 스페이스만, 명령 조합은 받지 않는다(#28 규칙 그대로)
        #expect(!KeyRoutingPolicy.accepts(Self.p, in: .init(focus: .sheet), shortcuts: shortcuts))
        #expect(KeyRoutingPolicy.accepts(Self.space, in: .init(focus: .sheet), shortcuts: shortcuts))
        #expect(!KeyRoutingPolicy.accepts(Self.p, in: .init(hasShortcutModifiers: true), shortcuts: shortcuts))
        #expect(!KeyRoutingPolicy.accepts(Self.p, in: .init(focus: .textInput), shortcuts: shortcuts))
    }
}
