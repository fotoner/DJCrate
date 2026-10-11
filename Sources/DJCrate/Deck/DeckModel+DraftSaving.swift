import DJCApplication
import DJCDomain
import Foundation

extension DeckModel {
    var currentDraftSaveFailures: [DraftSaveFailure] {
        guard let uuid = row?.track.uuid else { return [] }
        // 목록에서 복구하거나 되돌려 덱 밖에서 해소된 실패는 남기지 않는다(유스케이스).
        return storage.drafts.currentFailures(uuid, reported: draftSaveFailures)
    }

    func draftSaveCompletion(_ kind: DraftSaveKind, uuid: String) -> @Sendable (DraftSaveFailure?) -> Void {
        let key = "\(kind):\(uuid)"
        let revision = (draftSaveRevisions[key] ?? 0) + 1
        draftSaveRevisions[key] = revision
        return { [weak self] failure in
            Task { @MainActor [weak self] in
                guard let self, self.draftSaveRevisions[key] == revision else { return }
                self.draftSaveFailures.removeAll { $0.kind == kind && $0.trackUUID == uuid }
                if let failure { self.draftSaveFailures.append(failure) }
            }
        }
    }

    func persistGrid(_ draft: GridDraft) {
        storage.drafts.saveGrid(draft, completion: draftSaveCompletion(.grid, uuid: draft.trackUUID))
    }

    func removeGridDraft(_ uuid: String) {
        storage.drafts.removeGrid(uuid, completion: draftSaveCompletion(.grid, uuid: uuid))
    }

    func persistGain(_ gain: Double?, uuid: String) {
        storage.drafts.saveGain(gain, trackUUID: uuid, completion: draftSaveCompletion(.gain, uuid: uuid))
    }

    func retryDraftSaves() {
        guard !isWriteLocked, let uuid = row?.track.uuid else { return }
        let failures = currentDraftSaveFailures
        // 덱에 읽어 둔 초안이 있으면 그것(끌던 편집 포함)을 저장한다. 아직 읽는 중이면 비어 있는 것을 지우기로 보지 않고
        // 실패한 마지막 입력(저장이든 지우기든)을 그대로 다시 저장한다.
        if failures.contains(where: { $0.kind == .cue }) {
            if let draft, draft.trackUUID == uuid { persist(draft) }
            else { storage.drafts.retry(.cue, trackUUID: uuid, completion: draftSaveCompletion(.cue, uuid: uuid)) }
        }
        if failures.contains(where: { $0.kind == .grid }) {
            if let gridDraft, gridDraft.trackUUID == uuid { persistGrid(gridDraft) }
            else { storage.drafts.retry(.grid, trackUUID: uuid, completion: draftSaveCompletion(.grid, uuid: uuid)) }
        }
        // 게인은 곡을 고를 때 바로 읽으므로(`loadGain`) 덱의 값이 마지막 입력이다.
        if failures.contains(where: { $0.kind == .gain }) { persistGain(gainDraft, uuid: uuid) }
    }
}
