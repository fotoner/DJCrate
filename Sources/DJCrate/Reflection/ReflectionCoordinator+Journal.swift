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
            guard mayStartJournalAction() else { return }
            guard let finding = await Self.judge(gate: session.ports.gate, target: session.target) else { return noRecord() }
            let prompt = ReflectionPrompt(title: String(ui: "쓰다가 중단된 저장을 되돌릴까요?"),
                                          text: ([Self.restoreGoal(finding.journal)]
                                              + (finding.changedSince
                                                  ? [String(ui: "⚠︎ 이 백업 뒤에 rekordbox에서도 라이브러리가 바뀌었습니다(큐·재생 목록·곡 추가 등). 복원하면 그 변경도 함께 사라집니다.")] : []))
                                              .joined(separator: "\n\n"),
                                          confirm: String(ui: "기록으로 복원"), critical: finding.changedSince, destructive: finding.changedSince)
            guard store.whileAwaitingConfirmation({ prompter.show(prompt) }) else { return }
            // 확인하는 사이 USB 쓰기나 다른 저장이 시작됐을 수 있다: 관문을 부르기 직전에 다시 보고, 끝날 때까지 라이브러리 쓰기 상태(덱 포함)를 건다
            guard mayStartJournalAction() else { return }
            session.ports.lock.set(true, true)
            defer { session.ports.lock.set(false, true) }
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

    /// 복원이 되돌릴 실제 목표: 기록 종류마다 다르다. 시점 복원은 재시도하며 목표가 바뀔 수 있어 기록에 지금 적힌 시점을 말한다
    static func restoreGoal(_ journal: RekordboxWriteJournal) -> String {
        switch journal.entry {
        case .drafts, .trackAdd, .trackDelete: String(ui: "쓰다가 끊긴 저장을 이 기록으로 쓰기 전 상태로 되돌립니다.")
        case .restore: String(ui: "끊긴 복원을 이 기록의 같은 백업으로 다시 끝냅니다.")
        case .pointRestore:
            if let snapshot = journal.basis.pointSnapshot {
                String(ui: "끊긴 복원을 ‘\(URL(filePath: snapshot).lastPathComponent)’ 복원 시점으로 다시 끝냅니다.")
            } else {
                String(ui: "끊긴 복원을 이 기록의 복원 시점으로 다시 끝냅니다.")
            }
        case .iTunesSync: String(ui: "끊긴 iTunes 동기화가 바꾼 동기화 파일만 쓰기 전 상태로 되돌립니다.")
        }
    }

    /// 복원·이대로 두기를 시작할 수 있는지(S7): 종료 중·막힌 초안 비교 창·USB 쓰기·다른 저장이 도는 중이면 알리고 false.
    /// 기존 앱 쓰기 상태(`libraryBusy`)를 지나가야 USB 동기화 같은 다른 라이브러리 일과 겹치지 않는다
    private func mayStartJournalAction() -> Bool {
        if refusesNow() { return false }
        if session.ports.lock.isLocked() {
            store.showToast(.notice(String(ui: "rekordbox 저장이 끝난 뒤 다시 시도하세요"), nil))
            return false
        }
        return true
    }

    // MARK: - 이대로 두기

    /// 확인한 뒤 이대로 둔다(`RekordboxWriteGate.keepJournal`): 라이브러리는 그대로 두고, 그 쓰기의 미정리 목록을 먼저 지운 다음 기록에 적힌 판의 초안을
    /// 지우지 않고 제안으로 바꾸고, 기록은 마지막에 지운다. 쓰기 잠금 안에서 하므로 그 사이 기록·DB가 달라졌으면 아무것도 하지 않는다
    func keepJournal() async {
        let session = session
        await serialized {
            guard mayStartJournalAction() else { return }
            guard let finding = await Self.judge(gate: session.ports.gate, target: session.target) else { return noRecord() }
            let files = session.ports.drafts, home = session.location.draftHome
            // 기록에 적힌 초안 저장소가 이 앱의 것이 아니면(다른 데이터 폴더가 남긴 기록) 미정리 목록·제안 전환을 마칠 수 없다: 기록을 지우면
            // 그 폴더의 앱이 정리하지 못하고 초안을 지울 수 있으므로 건드리지 않고 알린다
            if let drafts = finding.journal.drafts, !Self.sameFolder(URL(filePath: drafts.home), home) {
                store.showToast(.notice(String(ui: "다른 데이터 폴더의 쓰기 기록이라 이대로 두지 않았습니다. 그 데이터 폴더로 DJCrate를 연 뒤 처리하세요"), nil))
                return
            }
            let prompt = ReflectionPrompt(title: String(ui: "쓰다가 중단된 저장을 이대로 둘까요?"),
                                          text: String(ui: "라이브러리는 지금 상태 그대로 두고 쓰기 기록만 지웁니다. 그 쓰기에 든 편집은 지우지 않고 제안으로 남습니다."),
                                          confirm: String(ui: "이대로 두기"))
            guard store.whileAwaitingConfirmation({ prompter.show(prompt) }) else { return }
            guard mayStartJournalAction() else { return }
            // 라이브러리 파일은 바꾸지 않으므로 덱은 그대로 두고, 앱 쓰기 상태만 건다
            session.ports.lock.set(true, false)
            defer { session.ports.lock.set(false, false) }
            let gate = session.ports.gate, target = session.target
            let journal = finding.journal, request = finding.request
            // 미정리 목록은 그 쓰기를 한 앱이 기록에 적은 경로로 찾는다(같은 폴더를 다른 경로로 열었어도 같은 목록이다)
            let listHome = journal.drafts.map { URL(filePath: $0.home) } ?? home
            do {
                let kept = try await BlockingWork.run {
                    try gate.keepJournal(target, request) {
                        // 그 쓰기의 미정리 목록을 먼저 지우고 지웠는지 확인한 뒤에만 이어 간다(남았으면 던져 기록을 남긴다). 그다음 적힌 판의 초안을 제안으로 바꾼다
                        func remaining() throws -> [DraftCleanupList] {
                            // 목록 폴더를 읽을 수 있어야 "목록이 없다"고 본다(관문의 목록 읽기는 열지 못한 폴더를 빈 목록으로 돌려준다)
                            try Self.requireReadableCleanupFolder(in: target.backups)
                            return try gate.cleanupLists(target, listHome).filter { $0.operationID == journal.operationID }
                        }
                        for list in try remaining() { try gate.removeCleanupList(list, target) }
                        guard try remaining().isEmpty else { throw Self.cleanupListKept() }
                        if let drafts = journal.drafts { _ = try files.markSuggestions(drafts.written, Set(drafts.playlistSteps)) }
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

    /// 미정리 목록을 처리하지 못해 기록을 남긴다는 오류(기록을 남기면 다시 고를 수 있다)
    private nonisolated static func cleanupListKept() -> DJCError {
        .writeRefused(String(ui: "미정리 목록을 지우지 못해 기록을 남겼습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인한 뒤 다시 시도하세요"))
    }

    /// 미정리 목록 폴더를 열거할 수 있는지 본다. 폴더가 없을 때만 목록이 없는 것이다. 있는데 열 수 없거나(권한이 사라짐)
    /// 위 폴더를 볼 수 없으면 목록이 있는지 모르니 던져 기록을 남긴다
    private nonisolated static func requireReadableCleanupFolder(in backups: URL) throws {
        let folder = backups.appending(path: DraftCleanupList.folderName, directoryHint: .isDirectory)
        var info = stat()
        if lstat(folder.path, &info) != 0 {
            if errno == ENOENT { return }
            throw cleanupListKept()
        }
        do { _ = try FileManager.default.contentsOfDirectory(atPath: folder.path) } catch { throw cleanupListKept() }
    }

    /// 같은 폴더인지(링크를 푼 경로로 견준다)
    private static func sameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
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
