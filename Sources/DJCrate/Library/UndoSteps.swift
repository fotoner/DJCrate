import Foundation

/// ⌘Z 단계마다 따로 둔 대상(R12, #405). 저장 뒤 되돌릴 수 없게 된 단계(범위 밖 종류·대상을 하나로 정할 수 없음)만 기록에서 빼
/// 그 ⌘Z 메뉴가 꺼지게 한다(무동작으로 남기지 않는다). `UndoManager`는 대상을 붙들지 않으므로 단계가 남아 있는 동안 이 목록이 붙든다.
@MainActor
final class UndoSteps {
    private final class Step {
        let canUndo: @MainActor () -> Bool
        init(canUndo: @escaping @MainActor () -> Bool) { self.canUndo = canUndo }
    }

    private var steps: [ObjectIdentifier: Step] = [:]

    /// 단계를 건다(실행 취소 중이면 다시 실행 쪽에 걸린다). `canUndo`가 거짓이 되면 `prune`이 그 단계를 뺀다
    func register(_ manager: UndoManager, canUndo: @escaping @MainActor () -> Bool, perform: @escaping @MainActor () -> Void) {
        let step = Step(canUndo: canUndo)
        steps[ObjectIdentifier(step)] = step
        manager.registerUndo(withTarget: step) { [weak self] step in
            self?.steps[ObjectIdentifier(step)] = nil
            perform()
        }
    }

    /// 되돌릴 수 없게 된 단계를 기록에서 뺀다(저장 뒤 다시 읽은 때처럼 기준이 자리 잡은 뒤 부른다)
    func prune(_ manager: UndoManager?) {
        for (key, step) in steps where !step.canUndo() {
            manager?.removeAllActions(withTarget: step)
            steps[key] = nil
        }
    }

    /// 모든 단계를 뺀다
    func removeAll(_ manager: UndoManager?) {
        for step in steps.values { manager?.removeAllActions(withTarget: step) }
        steps = [:]
    }
}
