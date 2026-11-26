@testable import DJCrate
import Foundation
import Testing

/// ⌘Z 단계 목록(R12, #405 컨실 2라운드 A·O12): 맨 위 단계만 판정하고, 맨 위가 다른 종류의 동작이면 판정하지 않으며, 관리자가 버린 단계는 붙들지 않는다
@MainActor
@Suite("⌘Z 단계 목록")
struct UndoStepsTests {
    final class Sentinel {}
    final class Foreign {}

    func manager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    func event(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func 관리자가_버린_단계는_붙들지_않는다() {
        let undo = manager(), steps = UndoSteps()
        weak var held: Sentinel?
        do {
            let sentinel = Sentinel()
            held = sentinel
            event(undo) { steps.register(undo, kind: .library, canUndo: { _ = sentinel; return true }) {} }
        }
        #expect(held != nil)
        undo.removeAllActions()
        #expect(held == nil, "관리자가 지운 단계의 판정 함수를 붙들지 않는다")
    }

    @Test func 맨_위가_다른_종류의_동작이면_판정하지_않고_그_동작을_되돌린_뒤_판정한다() {
        let undo = manager(), steps = UndoSteps(), foreign = Foreign()
        var stuck = false, foreignUndone = false
        event(undo) { steps.register(undo, kind: .library, canUndo: { !stuck }) {} }
        event(undo) { undo.registerUndo(withTarget: foreign) { _ in foreignUndone = true } }
        stuck = true
        steps.settle(undo)
        #expect(undo.canUndo, "맨 위는 다른 종류(USB·글자 입력 등)라 그대로 둔다")
        undo.undo()
        #expect(foreignUndone)
        #expect(!undo.canUndo, "되돌린 뒤 맨 위가 된 단계를 판정해 메뉴를 끈다")
    }

    @Test func 아래_단계는_맨_위가_될_때까지_판정하지_않는다() {
        let undo = manager(), steps = UndoSteps()
        var lowerStuck = true, ran: [String] = []
        event(undo) { steps.register(undo, kind: .library, canUndo: { !lowerStuck }) { ran.append("아래") } }
        event(undo) { steps.register(undo, kind: .deck, canUndo: { true }) { ran.append("위"); lowerStuck = false } }
        steps.settle(undo)
        #expect(undo.canUndo)
        undo.undo()
        #expect(undo.canUndo, "위 단계를 되돌리면 아래 단계가 실행할 수 있게 된다")
        undo.undo()
        #expect(ran == ["위", "아래"])
    }
}
