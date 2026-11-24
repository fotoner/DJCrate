import DJCApplication
import DJCDomain
import Foundation

extension LibraryStore {
    func stageMerge(_ draft: DuplicateMergeDraft) throws {
        guard !libraryBusy else { return }
        try setMergeDrafts(MergeDuplicates.staging(draft, onto: mergeDrafts, pending: pendingUUIDs, playlistDraftEmpty: playlists.playlistDraft.isEmpty))
    }

    /// 합치기 초안 하나를 버린다. 쓰는 동안은 버리지 않는다: 합치기 초안은 쓰는 묶음에 들 수 있다(중복 후보 목록 전체를 막지 않고 여기서 막는다)
    func discardMerge(_ id: String) throws {
        guard !libraryBusy else { return }
        try setMergeDrafts(mergeDrafts.filter { $0.id != id })
    }

    /// - Parameter registersUndo: 실행 취소 단계를 건다. 쓰는 동안 눌러 미뤘다가 실행하는 ⌘Z는 걸지 않는다(그 뒤 ⇧⌘Z는 다시 하지 않는다)
    func setMergeDrafts(_ drafts: [DuplicateMergeDraft], registersUndo: Bool = true) throws {
        let before = mergeDrafts
        let moved = try useCases.merge.save(drafts, takingMovedFiles: location.movesDamagedDrafts)
        mergeDrafts = drafts
        reportDraftFilesMovedBySave(moved)
        refreshBase()
        guard registersUndo, let undoManager else { return }
        // 합치기는 저장 뒤 되돌릴 수 없다(R12): 쓰면 그 전 단계는 실행할 수 없어 맨 위가 되면 ⌘Z가 꺼진다(`applyMergeDraftsAfterWrite`)
        let generation = mergeWriteGeneration
        undoSteps.register(undoManager, kind: .library, canUndo: { [weak self] in self?.mergeWriteGeneration == generation }) { [weak self] in
            self?.undoMerge(to: before, generation: generation)
        }
        undoManager.setActionName(String(ui: "중복 곡 합치기 편집"))
    }

    /// 합치기 ⌘Z. 쓰는 중이면 누른 요청으로 미뤘다가 쓰기 뒤 단계를 다시 걸지 않고 실행한다. 꺼낼 때 쓰기 세대가 달라졌으면(그새 합치기를 썼다)
    /// 실행하지 않고 ⌘Z 기록을 비우며 이유를 알린다(#295 E6)
    private func undoMerge(to before: [DuplicateMergeDraft], generation: Int, deferred: Bool = false) {
        if libraryBusy {
            guard !deferred, undoManager?.isRedoing != true else { return }
            pendingUndo.append(ready: { [weak self] in self.map { !$0.libraryBusy } ?? true }) { [weak self] in
                self?.undoMerge(to: before, generation: generation, deferred: true)
            }
            return
        }
        guard mergeWriteGeneration == generation else { return refuseUndo() }
        do { try setMergeDrafts(before, registersUndo: !deferred) }
        catch { showToast(.notice(text: error.localizedDescription, kind: .warning)) }
    }

    /// 쓴 뒤·복원 뒤: 반영 세션이 합치기 초안을 저장했다(`failure`면 저장하지 못했다). DB는 이미 반영·복원됐으니 저장 오류는 경고로만 알린다
    /// (쓰기 실패로 바꾸면 되돌리기 안내까지 잃는다).
    func applyMergeDraftsAfterWrite(_ drafts: [DuplicateMergeDraft], failure: (any Error)?, moved: [DamagedDraftFile]) {
        // 합치기를 썼거나 되돌렸다: 그 전 단계는 실행할 수 없다(저장 뒤 되돌릴 수 없는 종류, R12). 맨 위가 되면 메뉴가 꺼진다
        mergeWriteGeneration += 1
        mergeDrafts = drafts
        if failure == nil {
            reportDraftFilesMovedBySave(moved)
        } else {
            notify(.notice(text: String(ui: "라이브러리에는 저장했지만 합치기 편집 파일을 보관하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요"), kind: .warning))
        }
    }

    func prepareMerge(keeping id: String, removing: [String], prompter: any ReflectionPrompter = AlertPrompter()) async {
        guard let snapshotURL, !libraryBusy else { return }
        do {
            let draft = try await useCases.merge.draft(keeping: id, removing: removing, snapshot: snapshotURL)
            guard !libraryBusy else { return }
            // 초안 단계는 같은 음원인지 비교만 한다. 잃는 정보는 rekordbox에 쓸 때 한 번 경고로 묻는다(#212).
            let paths = rowsByID.filter { ([id] + removing).contains($0.key) }.mapValues(\.track.folderPath)
            if prompter.show(MergeDuplicates.confirmation(draft, paths: paths)) { try stageMerge(draft) }
        } catch {
            _ = prompter.show(ReflectionPrompt(title: String(ui: "합치기 편집을 만들지 않았습니다"),
                                              text: (error as? PlaylistLayout.Blocked)?.reason ?? error.localizedDescription))
        }
    }
}
