import DJCApplication
import DJCDomain
import Foundation

/// 중단 알림(R11): 쓰다가 끊긴 기록이 남았을 때 상태 줄의 [기록으로 복원…]·[이대로 두기…]가 부르는 흐름.
/// 판정은 쓰기 잠금 아래 관문이 하고(`RekordboxWriteGate.journal`), 복원·이대로 두기는 사용자가 확인한 요청으로만 한다.
/// 쓰기 하나로 엔진의 차례(`serialized` → `engine.exclusive`)를 받고, 끝나면 엔진에 알린다: 복원은 자동 저장을 멈추고(R8, `restored()`),
/// 이대로 두기는 기록을 다시 판정하게 한다(`recheckJournal()`).
extension ReflectionCoordinator {
    // MARK: - 입구(상태 줄 단추)

    /// 상태 줄 [기록으로 복원…]. 다른 쓰기·복원이 도는 중이면 무시한다
    func startRestoreJournal() {
        guard store.writeTask == nil else { return }
        start { await self.restoreJournal() }
    }

    /// 상태 줄 [이대로 두기…]
    func startKeepJournal() {
        guard store.writeTask == nil else { return }
        start { await self.keepJournal() }
    }

    /// 대량 유예의 [취소](R14)
    func cancelGrace() { engine?.cancelGrace() }

    // MARK: - 찾은 기록

    /// 중단 기록을 판정해 상태 줄이 복원 안내의 차례를 정하게 한다(엔진은 찾은 기록을 내보내지 않는다).
    /// 쓰기 잠금을 기다리지 않는다: 다른 프로세스가 쓰는 중이거나 rekordbox가 켜져 있으면 찾지 못하고, 그때는 기본 차례로 보인다
    func loadFinding() {
        guard autoFeed.finding == nil else { return }
        let gate = session.ports.gate, target = session.target, feed = autoFeed
        Task {
            let finding = await Self.judge(gate: gate, target: target)
            // 그 사이 중단이 풀렸으면 넣지 않는다
            if feed.conditions.holds.contains(where: { $0.kind == .interrupted }) { feed.setFinding(finding) }
        }
    }

    private static func judge(gate: RekordboxWriteGate, target: RekordboxWriteTarget) async -> RekordboxJournalFinding? {
        let verdict = try? await BlockingWork.run { try gate.journal(target, nil) }
        if case let .interrupted(finding)? = verdict { return finding }
        return nil
    }

    // MARK: - 기록으로 복원

    /// 확인한 뒤 기록으로 복원한다(`RekordboxWriteGate.restoreJournal`). 복원 확인 창은 백업 뒤 rekordbox에서 라이브러리가 바뀌었으면 경고한다.
    /// 복원하면 자동 저장이 멈추고(R8) 라이브러리를 다시 읽는다
    func restoreJournal() async {
        let session = session
        var restored = false
        await serialized {
            guard let finding = await Self.judge(gate: session.ports.gate, target: session.target) else { return noRecord() }
            let prompt = ReflectionPrompt(title: String(ui: "쓰다가 중단된 저장을 되돌릴까요?"),
                                          text: ([String(ui: "쓰다가 끊긴 저장을 이 기록으로 쓰기 전 상태로 되돌립니다.")]
                                              + (finding.changedSince
                                                  ? [String(ui: "⚠︎ 이 백업 뒤에 rekordbox에서도 라이브러리가 바뀌었습니다(큐·재생 목록·곡 추가 등). 복원하면 그 변경도 함께 사라집니다.")] : []))
                                              .joined(separator: "\n\n"),
                                          confirm: String(ui: "기록으로 복원"), critical: finding.changedSince, destructive: finding.changedSince)
            guard store.whileAwaitingConfirmation({ prompter.show(prompt) }) else { return }
            let gate = session.ports.gate, target = session.target, request = finding.request
            do {
                switch try await BlockingWork.run({ try gate.restoreJournal(target, request) }) {
                case .restored, .alreadyRestored:
                    restored = true
                    store.showToast(.notice(String(ui: "기록으로 복원했습니다"), nil, kind: .success))
                case .changed: changedNotice()
                case .nothing: noRecord()
                }
            } catch {
                failed(String(ui: "기록으로 복원하지 못했습니다"), error)
            }
        }
        if restored { engine?.restored() } else { engine?.recheckJournal() }
        await store.refreshIfRekordboxChanged()
    }

    // MARK: - 이대로 두기

    /// 확인한 뒤 이대로 둔다(`RekordboxWriteGate.keepJournal`): 라이브러리는 그대로 두고, 그 쓰기의 미정리 목록을 먼저 지운 다음 기록에 적힌 판의 초안을
    /// 지우지 않고 제안으로 바꾸고, 기록은 마지막에 지운다. 쓰기 잠금 안에서 하므로 그 사이 기록·DB가 달라졌으면 아무것도 하지 않는다
    func keepJournal() async {
        let session = session
        await serialized {
            guard let finding = await Self.judge(gate: session.ports.gate, target: session.target) else { return noRecord() }
            let prompt = ReflectionPrompt(title: String(ui: "쓰다가 중단된 저장을 이대로 둘까요?"),
                                          text: String(ui: "라이브러리는 지금 상태 그대로 두고 쓰기 기록만 지웁니다. 그 쓰기에 든 편집은 지우지 않고 제안으로 남습니다."),
                                          confirm: String(ui: "이대로 두기"))
            guard store.whileAwaitingConfirmation({ prompter.show(prompt) }) else { return }
            let gate = session.ports.gate, target = session.target, files = session.ports.drafts, home = session.location.draftHome
            let journal = finding.journal, request = finding.request
            do {
                let kept = try await BlockingWork.run {
                    try gate.keepJournal(target, request) {
                        // 그 쓰기의 미정리 목록을 먼저 지운 뒤 적힌 판의 초안을 제안으로 바꾼다. 다른 `DJC_HOME`의 초안은 건드리지 않는다
                        for list in try gate.cleanupLists(target, home) where list.operationID == journal.operationID {
                            try gate.removeCleanupList(list, target)
                        }
                        if let drafts = journal.drafts, URL(filePath: drafts.home).standardizedFileURL.path == home.standardizedFileURL.path {
                            _ = try files.markSuggestions(drafts.written, Set(drafts.playlistSteps))
                        }
                    }
                }
                switch kept {
                case .kept: store.showToast(.notice(String(ui: "이대로 두었습니다"), nil, kind: .success))
                case .changed: changedNotice()
                case .nothing: noRecord()
                }
            } catch {
                failed(String(ui: "이대로 두지 못했습니다"), error)
            }
        }
        engine?.recheckJournal()
        await store.refreshExternalDrafts()
    }

    // MARK: - 알림

    private func noRecord() {
        store.showToast(.notice(String(ui: "처리할 쓰기 기록이 없습니다"), nil))
    }

    private func changedNotice() {
        store.showToast(.notice(String(ui: "그 사이 라이브러리가 바뀌어 처리하지 않았습니다"), nil))
    }

    private func failed(_ title: String, _ error: any Error) {
        AppErrorMessage.log(error)
        store.showToast(.notice(title, AppErrorMessage.message(for: error), kind: .failure))
    }
}
