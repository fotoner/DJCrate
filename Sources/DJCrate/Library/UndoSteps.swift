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

/// 쓰는 동안 누른 ⌘Z 요청(R12, 컨실 S6·O3). 덱·태그·재생 목록이 한 줄에 누른 차례대로 두었다가, 잠금이 풀리면 앞에서부터 실행한다.
/// 실행 취소 기록에 다시 올리지 않는다(그사이 한 새 편집의 실행 취소 차례를 바꾸지 않게). 실행한 되돌리기는 다시 실행(⇧⌘Z)에 남기지 않는다.
/// 앞 요청이 아직 잠겨 있으면 뒤 요청도 기다린다(누른 차례를 지킨다). 앱 조립 지점과 시험이 덱과 라이브러리에 같은 줄을 준다(`connectWriteLocks`)
@MainActor
final class PendingUndoRequests {
    private var requests: [(ready: @MainActor () -> Bool, run: @MainActor () -> Void)] = []
    private var flushing = false

    var isEmpty: Bool { requests.isEmpty }

    /// 누른 요청을 줄 끝에 둔다
    func append(ready: @escaping @MainActor () -> Bool, run: @escaping @MainActor () -> Void) {
        requests.append((ready, run))
    }

    /// 앞에서부터 풀린 요청을 실행한다(잠긴 요청에서 멈춘다)
    func flush() {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while let first = requests.first, first.ready() {
            requests.removeFirst()
            first.run()
        }
    }

    func removeAll() { requests = [] }
}
