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

    func setMergeDrafts(_ drafts: [DuplicateMergeDraft]) throws {
        let before = mergeDrafts
        let moved = try useCases.merge.save(drafts, takingMovedFiles: location.movesDamagedDrafts)
        mergeDrafts = drafts
        reportDraftFilesMovedBySave(moved)
        refreshBase()
        guard let undoManager else { return }
        // 합치기는 저장 뒤 되돌릴 수 없다(R12): 쓰면 이 대상의 단계를 지워 ⌘Z가 꺼진다(`applyMergeDraftsAfterWrite`)
        undoManager.registerUndo(withTarget: mergeUndoTarget) { [weak self] _ in
            guard let self, !libraryBusy else { return }
            do { try setMergeDrafts(before) }
            catch { showToast(.notice(text: error.localizedDescription, kind: .warning)) }
        }
        undoManager.setActionName(String(ui: "중복 곡 합치기 편집"))
    }

    /// 쓴 뒤·복원 뒤: 반영 세션이 합치기 초안을 저장했다(`failure`면 저장하지 못했다). DB는 이미 반영·복원됐으니 저장 오류는 경고로만 알린다
    /// (쓰기 실패로 바꾸면 되돌리기 안내까지 잃는다).
    func applyMergeDraftsAfterWrite(_ drafts: [DuplicateMergeDraft], failure: (any Error)?, moved: [DamagedDraftFile]) {
        // 합치기를 썼거나 되돌렸다: 그 ⌘Z는 끈다(저장 뒤 되돌릴 수 없는 종류, R12)
        undoManager?.removeAllActions(withTarget: mergeUndoTarget)
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
