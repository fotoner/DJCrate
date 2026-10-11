@testable import DJCrate
import DJCDomain
import Foundation
import Testing

/// 확대 파형을 끄는 동안 핫큐(#133). 120 BPM, 0.5초부터 박, 곡 180초(`DeckHarness`).
@MainActor
@Suite("덱 — 끄는 중 핫큐")
struct ScrubHotCueTests {
    /// 재생 중 60초에서 확대 파형을 잡고 2초 앞으로 끈 상태
    func dragging(_ h: DeckHarness) {
        h.deck.seek(60)
        h.deck.togglePlay()
        h.deck.beginScrubDrag()
        h.deck.dragScrub(by: 2)
    }

    @Test func 끄는_중_빈_핫큐는_끈_자리에_찍고_끌기와_재생은_그대로() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        dragging(h)
        h.deck.pressHotCue(slot: 2)
        #expect(h.deck.hotCue(slot: 2)?.time == 62)
        #expect(!h.deck.isPlaying, "놓기 전에는 재생하지 않는다")
        h.deck.dragScrub(by: 3)
        #expect(h.deck.playhead == 63)
        h.deck.endScrub()
        #expect(h.deck.isPlaying && h.audio.position == 63, "놓으면 놓은 자리에서 이어 재생")
    }

    @Test func 끄는_중_저장된_핫큐는_그_자리로_옮기고_끌기는_거기서_이어진다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(20)
        h.deck.pressHotCue(slot: 0)
        let a = try #require(h.deck.hotCue(slot: 0))
        dragging(h)
        h.deck.pressHotCue(slot: 0)
        #expect(h.deck.playhead == 20 && h.audio.position == 20)
        #expect(!h.deck.isPlaying && !h.audio.isPlaying, "끄는 동안 재생을 시작하지 않는다")
        #expect(h.deck.selectedCueID == a.id)
        h.deck.dragScrub(by: 3)
        #expect(h.deck.playhead == 21, "끌기 시작 자리(60초)로 튀지 않고 핫큐에서 이어진다")
        h.deck.endScrub()
        #expect(h.deck.isPlaying && h.audio.position == 21)
    }

    @Test func 정지_중_끌다가_저장된_핫큐로_옮겨도_놓은_뒤_멈춘_채() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(20)
        h.deck.pressHotCue(slot: 0)
        h.deck.seek(60)
        h.deck.beginScrubDrag()
        h.deck.dragScrub(by: 2)
        h.deck.pressHotCue(slot: 0)
        h.deck.endScrub()
        #expect(h.deck.playhead == 20 && !h.deck.isPlaying && !h.audio.isPlaying)
    }

    @Test func 끄는_중_루프_핫큐는_시작_자리로만_옮기고_루프는_걸지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(30.5)
        h.deck.toggleLoop()
        h.deck.pressHotCue(slot: 1)
        let loop = try #require(h.deck.hotCue(slot: 1))
        #expect(loop.loop != nil)
        h.deck.exitLoop()
        dragging(h)
        h.deck.pressHotCue(slot: 1)
        #expect(h.deck.playhead == 30.5 && !h.deck.isLooping && h.deck.engagedLoopID == nil && h.audio.loop == nil)
        h.deck.endScrub()
        #expect(h.deck.isPlaying && !h.deck.isLooping)
    }

    @Test func 놓은_뒤에는_핫큐가_평소대로_동작한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(20)
        h.deck.pressHotCue(slot: 0)
        dragging(h)
        h.deck.endScrub()
        h.deck.dragScrub(by: 5)
        #expect(h.deck.playhead == 62, "놓은 뒤 들어온 끌기 값은 버린다")
        h.deck.playQuantize = false
        h.deck.pressHotCue(slot: 0)
        #expect(h.deck.playhead == 20 && h.deck.isPlaying)
    }
}

/// 끄는 동안 키 상태로 핫큐를 누른다(`DragHotCueKeys`). 키·마우스 상태는 가짜로 준다.
@MainActor
@Suite("덱 — 끄는 중 핫큐 키")
struct DragHotCueKeysTests {
    final class Keys {
        var pressed: Set<UInt16> = []
        var shift = false
        var mouse = true
    }

    func watcher(_ keys: Keys) -> DragHotCueKeys {
        let watcher = DragHotCueKeys()
        watcher.input = .init(isKeyDown: { keys.pressed.contains($0) }, isShiftDown: { keys.shift }, isMouseDown: { keys.mouse })
        return watcher
    }

    func dragging(_ h: DeckHarness) {
        h.deck.seek(60)
        h.deck.togglePlay()
        h.deck.beginScrubDrag()
        h.deck.dragScrub(by: 2)
    }

    @Test func 끄는_동안_새로_누른_핫큐_키는_핫큐를_누른다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let keys = Keys(), watcher = watcher(keys)
        dragging(h)
        watcher.begin(deck: h.deck, polling: false)
        keys.pressed = [20]
        watcher.poll()
        watcher.poll()
        #expect(h.deck.hotCue(slot: 2)?.time == 62)
        #expect(h.deck.draft?.cues.filter { $0.kind == .hot(2) }.count == 1, "누르고 있어도 한 번")
        watcher.end()
    }

    @Test func 끌기_전부터_누른_키는_무시하고_Shift와_함께면_지운다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(20)
        h.deck.pressHotCue(slot: 0)
        let keys = Keys(), watcher = watcher(keys)
        keys.pressed = [18]
        dragging(h)
        watcher.begin(deck: h.deck, polling: false)
        watcher.poll()
        #expect(h.deck.playhead == 62, "끌기 전부터 누르던 1은 누른 것으로 보지 않는다")
        keys.pressed = []
        watcher.poll()
        keys.shift = true
        keys.pressed = [18]
        watcher.poll()
        #expect(h.deck.hotCue(slot: 0) == nil && h.deck.playhead == 62)
        watcher.end()
    }

    @Test func 쓰는_중이면_막고_마우스를_떼면_멈춘다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let keys = Keys(), watcher = watcher(keys)
        dragging(h)
        watcher.begin(deck: h.deck, polling: false)
        h.deck.isWriteLocked = true
        keys.pressed = [20]
        watcher.poll()
        #expect(h.deck.hotCue(slot: 2) == nil)
        h.deck.isWriteLocked = false
        keys.pressed = []
        watcher.poll()
        keys.mouse = false
        keys.pressed = [21]
        watcher.poll()
        #expect(h.deck.hotCue(slot: 3) == nil && !watcher.isWatching, "끝 신호를 놓쳐도 마우스를 떼면 멈춘다")
    }
}
