import Foundation

/// ⌘Z 단계 목록(R12, #405 컨실 2라운드 A). 덱·태그·재생 목록·합치기·재생 기록이 한 목록에 건 차례대로 단계를 둔다.
/// 단계를 미리 빼지 않는다: 맨 위 단계만 지금 실행할 수 있는지 보고(아래 단계는 차례가 와 맨 위가 됐을 때 본다), 맨 위가 실행할 수 없으면
/// ⌘Z 기록을 비워 메뉴를 끈다(아래 다른 편집을 실행하지 않는다). 판정은 쓰기·다시 읽기가 끝나 자리 잡은 때(`settle`)와 ⌘Z·⇧⌘Z 뒤에 한다.
/// 맨 위 묶음이 이 목록의 단계인지는 묶음의 "버려도 되는 동작" 표시(`setActionIsDiscardable`)로 가린다. 이 앱은 문서 기반이 아니라 그 표시를 달리 쓰지 않는다.
/// 단계는 `UndoManager`의 처리기만 붙든다: 관리자가 버린 단계(다시 실행 기록 비움·지우기)는 이 목록에서도 사라진다(O12)
@MainActor
final class UndoSteps {
    enum Kind { case deck, library }

    private final class Step {
        let kind: Kind
        let canUndo: @MainActor () -> Bool
        /// 실행 취소 중에 걸려 다시 실행(⇧⌘Z) 쪽에 있다
        let isRedo: Bool
        init(kind: Kind, canUndo: @escaping @MainActor () -> Bool, isRedo: Bool) {
            self.kind = kind
            self.canUndo = canUndo
            self.isRedo = isRedo
        }
    }

    private struct Entry { weak var step: Step? }
    private var entries: [Entry] = []
    private var observers: [NSObjectProtocol] = []
    private weak var observed: UndoManager?
    /// 판정해도 되는지(쓰는 중이거나 쓴 뒤 다시 읽기 전이 아니고 미룬 ⌘Z가 없다). 덱과 라이브러리가 조건을 준다(`LibraryStore.connectWriteLocks`)
    var isSettled: @MainActor () -> Bool = { true }
    /// 맨 위 단계를 실행할 수 없어 ⌘Z 기록을 비운 뒤 부른다(이유를 알리고 쓴 단계 기록을 비운다, #295 E6)
    var onCleared: (@MainActor () -> Void)?

    /// 단계를 건다(실행 취소 중이면 다시 실행 쪽에 걸린다). 거는 묶음이 열려 있을 때 부른다
    func register(_ manager: UndoManager, kind: Kind, canUndo: @escaping @MainActor () -> Bool, perform: @escaping @MainActor () -> Void) {
        observe(manager)
        let step = Step(kind: kind, canUndo: canUndo, isRedo: manager.isUndoing)
        entries.removeAll { $0.step == nil }
        entries.append(Entry(step: step))
        // 처리기가 단계를 붙든다: 관리자가 이 동작을 버리면 단계도 사라진다
        manager.registerUndo(withTarget: step) { [weak self, step] _ in
            self?.entries.removeAll { $0.step == nil || $0.step === step }
            perform()
        }
        manager.setActionIsDiscardable(true)
    }

    /// 맨 위 단계를 판정한다: 이 목록의 단계이고 지금 실행할 수 없으면 ⌘Z 기록을 모두 비운다(메뉴가 꺼진다).
    /// 자리 잡지 않았으면(쓰는 중·다시 읽기 전·미룬 ⌘Z가 있다) 판정하지 않는다(멀쩡한 단계를 지우지 않게)
    /// - Parameter afterChange: ⌘Z·⇧⌘Z를 끝낸 알림에서 부른다(그 알림 동안 관리자는 아직 되돌리는 중으로 보인다)
    func settle(_ manager: UndoManager?, afterChange: Bool = false) {
        guard let manager, manager.canUndo, afterChange || (!manager.isUndoing && !manager.isRedoing), manager.undoActionIsDiscardable,
              isSettled() else { return }
        entries.removeAll { $0.step == nil }
        guard let top = entries.last(where: { $0.step?.isRedo == false })?.step, !top.canUndo() else { return }
        manager.removeAllActions()
        entries = []
        onCleared?()
    }

    /// ⌘Z 기록을 모두 비운다(실행할 수 없는 ⌘Z를 눌렀다·미룬 ⌘Z가 무효, #295 E6). 되돌리는 중(처리기 안)에는 관리자의 기록을 지울 수 없어
    /// 그 ⌘Z·⇧⌘Z가 끝난 알림에서 비운다
    func removeAll(from manager: UndoManager?) {
        guard let manager else { return }
        if manager.isUndoing || manager.isRedoing {
            observe(manager)
            clearsAfterChange = true
            return
        }
        manager.removeAllActions()
        entries = []
    }

    /// 되돌리는 중에 비우라고 했다: 그 ⌘Z·⇧⌘Z가 끝나면 비운다
    private var clearsAfterChange = false

    /// ⌘Z·⇧⌘Z가 끝났다: 되돌리는 중에 비우라고 했으면 비우고, 아니면 새 맨 위를 판정한다
    private func changed(_ manager: UndoManager?) {
        guard clearsAfterChange else { return settle(manager, afterChange: true) }
        clearsAfterChange = false
        manager?.removeAllActions()
        entries = []
    }

    /// 그 갈래의 단계를 모두 뺀다(곡이 바뀜·통째로 잠그는 쓰기·관리자 바뀜)
    func removeAll(_ kind: Kind, from manager: UndoManager?) {
        for entry in entries where entry.step?.kind == kind {
            if let step = entry.step { manager?.removeAllActions(withTarget: step) }
        }
        entries.removeAll { $0.step == nil || $0.step?.kind == kind }
    }

    /// ⌘Z·⇧⌘Z 뒤에 새 맨 위를 판정한다(다른 종류의 동작을 되돌린 뒤도)
    private func observe(_ manager: UndoManager) {
        guard observed !== manager else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observed = manager
        observers = [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: manager, queue: nil) { [weak self, weak manager] _ in
                MainActor.assumeIsolated { self?.changed(manager) }
            }
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
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
