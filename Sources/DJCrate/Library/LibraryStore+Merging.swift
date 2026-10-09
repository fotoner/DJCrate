import DJCApplication
import DJCDomain
import Foundation

extension LibraryStore {
    func stageMerge(_ draft: DuplicateMergeDraft) throws {
        guard !isWritingRekordbox else { return }
        try setMergeDrafts(MergeDuplicates.staging(draft, onto: mergeDrafts, pending: pendingUUIDs, playlistDraftEmpty: playlistDraft.isEmpty))
    }

    func setMergeDrafts(_ drafts: [DuplicateMergeDraft]) throws {
        let before = mergeDrafts
        let moved = try useCases.merge.save(drafts, takingMovedFiles: location.movesDamagedDrafts)
        mergeDrafts = drafts
        reportDraftFilesMovedBySave(moved)
        refreshBase()
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            guard !target.isWritingRekordbox else { return }
            do { try target.setMergeDrafts(before) }
            catch { target.reflectionMessage = AppMessage(kind: .warning, text: error.localizedDescription) }
        }
        undoManager.setActionName(String(ui: "중복 곡 합치기 초안"))
    }

    /// 쓴 뒤·복원 뒤: 반영 세션이 합치기 초안을 저장했다(`failure`면 저장하지 못했다). DB는 이미 반영·복원됐으니 저장 오류는 경고로만 알린다
    /// (쓰기 실패로 바꾸면 되돌리기 안내까지 잃는다).
    func applyMergeDraftsAfterWrite(_ drafts: [DuplicateMergeDraft], failure: (any Error)?, moved: [DamagedDraftFile]) {
        mergeDrafts = drafts
        if failure == nil {
            reportDraftFilesMovedBySave(moved)
        } else {
            reflectionMessage = AppMessage(kind: .warning, text: String(ui: "라이브러리에는 썼지만 합치기 초안 파일을 저장하지 못했습니다. DJCrate 데이터 폴더의 쓰기 권한을 확인하세요"))
        }
    }

    func prepareMerge(keeping id: String, removing: [String], prompter: any ReflectionPrompter = AlertPrompter()) async {
        guard let snapshotURL, !isWritingRekordbox else { return }
        do {
            let draft = try await useCases.merge.draft(keeping: id, removing: removing, snapshot: snapshotURL)
            guard !isWritingRekordbox else { return }
            // 초안 단계는 같은 음원인지 비교만 한다. 잃는 정보는 rekordbox에 쓸 때 한 번 경고로 묻는다(#212).
            let paths = rowsByID.filter { ([id] + removing).contains($0.key) }.mapValues(\.track.folderPath)
            if prompter.show(MergeDuplicates.confirmation(draft, paths: paths)) { try stageMerge(draft) }
        } catch {
            _ = prompter.show(ReflectionPrompt(title: String(ui: "합치기 초안을 만들지 않았습니다"),
                                              text: (error as? PlaylistLayout.Blocked)?.reason ?? error.localizedDescription))
        }
    }
}
