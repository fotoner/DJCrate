import DJCApplication
@testable import DJCrate
import AppKit
import DJCDomain
import Testing

@MainActor
@Suite("그리드 이동 버튼 — 반복·실행 취소")
struct GridShiftButtonTests {
    @Test func 누른_즉시_이동하고_1초_뒤부터_75ms마다_반복한다() {
        let button = GridShiftControl(frame: .zero)
        var delay: Float = 0, interval: Float = 0
        button.getPeriodicDelay(&delay, interval: &interval)
        #expect(delay == 1)
        #expect(interval == 0.075)
        #expect(button.isContinuous)
        let expected: NSEvent.EventTypeMask = [.leftMouseDown, .periodic]
        let events = button.sendAction(on: expected)
        #expect(events == Int(expected.rawValue), "뗄 때는 추가로 이동하지 않는다")
    }

    @Test(arguments: [-10.0, -1.0, 1.0, 10.0])
    func 클릭과_홀드는_각각_한_번에_큐와_그리드를_되돌린다(ms: Double) async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.pressHotCue(slot: 0)
        let undo = UndoManager()
        undo.groupsByEvent = false
        h.deck.undoManager = undo
        let button = GridShiftControl(frame: .zero)
        button.deck = h.deck
        button.stepMilliseconds = ms
        let before = h.deck.draftSnapshot

        button.moveGrid()
        let clicked = h.deck.draftSnapshot
        button.beginHold()
        for _ in 0..<5 { button.moveGrid() }
        button.endHold()
        let held = h.deck.draftSnapshot
        let start = try #require(held?.grid?.segments.first?.start)
        #expect(abs(start - (0.5 + 6 * ms / 1000)) < 0.000_001)
        #expect(h.drafts.grid("track-1") == held?.grid)
        #expect(h.drafts.cue("track-1") == held?.cue)
        undo.undo()
        #expect(h.deck.draftSnapshot == clicked)
        undo.undo()
        #expect(h.deck.draftSnapshot == before)
        #expect(!undo.canUndo)
        undo.redo()
        undo.redo()
        #expect(h.deck.draftSnapshot == held)
    }

    @Test func 홀드_중_쓰기를_잠그거나_곡을_다시_읽으면_반복하지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let button = GridShiftControl(frame: .zero)
        button.deck = h.deck
        button.stepMilliseconds = 10
        button.beginHold()
        button.moveGrid()
        h.deck.isWriteLocked = true
        let locked = h.deck.draftSnapshot
        button.moveGrid()
        button.endHold()
        #expect(h.deck.draftSnapshot == locked)

        h.deck.isWriteLocked = false
        button.beginHold()
        h.deck.reload()
        try await h.loaded()
        let reloaded = h.deck.draftSnapshot
        button.moveGrid()
        button.endHold()
        #expect(h.deck.draftSnapshot == reloaded)
    }
}
