import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 태그 편집: 초안만 바뀌고, 시트(엑셀식) 일괄 편집은 되돌리기 단위로 묶는다.
extension LibraryStore {
    // MARK: - 태그 편집 (초안만 바뀐다)

    func keySuggestion(estimate: String?, rows: [TrackRow]) -> String? {
        guard let row = rows.first, !dismissedKeySuggestions.contains(row.track.uuid) else { return nil }
        return KeyPicker.suggestion(estimate: estimate, rows: rows, current: tagValue(.musicalKey, rows: rows))
    }

    /// 보이는 제안을 적용할 때만 초안을 만든다. 그 사이 키를 고쳤거나 제안을 무시했으면 넣지 않는다.
    func applyKeySuggestion(estimate: String?, rows: [TrackRow]) {
        guard let suggestion = keySuggestion(estimate: estimate, rows: rows) else { return }
        setTag(.musicalKey, suggestion, rows: KeyPicker.targets(rows))
    }

    /// 무시해서 가린 제안. 덱 제안 줄의 "무시한 제안 다시 보기"를 보일지 가른다: 무시한 곡이어도 보일 제안이 더는 없으면(키를 골랐거나 추정이 없으면) nil이다.
    func dismissedKeySuggestion(estimate: String?, rows: [TrackRow]) -> String? {
        guard let row = rows.first, dismissedKeySuggestions.contains(row.track.uuid) else { return nil }
        return KeyPicker.suggestion(estimate: estimate, rows: rows, current: tagValue(.musicalKey, rows: rows))
    }

    func dismissKeySuggestion(rows: [TrackRow]) {
        guard rows.count == 1, let row = rows.first, KeyPicker.isEditable(rows) else { return }
        dismissedKeySuggestions.insert(row.track.uuid)
        settings.setStrings(SettingKeys.dismissedKeySuggestions, dismissedKeySuggestions)
    }

    /// 무시를 푼다(덱 제안 줄의 다시 보기·덱 재분석). 제안 줄이 바로 바뀌도록 메모리 사본을 함께 고친다.
    func restoreKeySuggestion(uuid: String) {
        guard dismissedKeySuggestions.remove(uuid) != nil else { return }
        settings.setStrings(SettingKeys.dismissedKeySuggestions, dismissedKeySuggestions)
    }

    /// 곡의 태그 초안(없으면 지금 rekordbox 값에서 새로). 안 고친 독립 칸(키·평점·곡 색)은 지금 값으로 맞춘다: 그 칸이 없던 옛 초안이나 그 뒤
    /// rekordbox에서 그 칸만 바뀐 초안이 그 칸을 고친 것처럼 보이거나 쓰기 때 기준이 어긋나지 않게 한다(`TagDraft.adoptingIndependentKeys`).
    /// 추가한 곡의 기준 키는 빈칸이다(`TrackRow.tagFields`): 키를 고를 수 없던 때 목록의 키를 기준으로 든 옛 초안도 여기서 맞춘다.
    func tagDraft(for row: TrackRow) -> TagDraft {
        guard let draft = tagDrafts[row.track.uuid] else { return TagDraft(trackUUID: row.track.uuid, base: row.tagFields) }
        return draft.adoptingIndependentKeys(of: row.tagFields)
    }

    /// 추가한 곡을 넣을 때 함께 쓸 키(사용자가 고른 Camelot 이름, #5). 키를 고치지 않았거나 비웠으면(넣는 곡은 처음부터 키가 없다) nil.
    func confirmedStagedKey(uuid: String) -> String? { AddedTrackDrafts.confirmedKey(tagDrafts[uuid]) }

    /// 선택한 곡들의 값. 모두 같으면 그 값, 다르면 `mixed`.
    func tagValue(_ key: TagFields.Key, rows: [TrackRow]) -> (value: String, mixed: Bool) {
        guard let first = rows.first else { return ("", false) }
        let value = tagCell(first, key)
        for row in rows.dropFirst() where tagCell(row, key) != value { return ("", true) }
        return (value, false)
    }

    func setTag(_ key: TagFields.Key, _ value: String, rows: [TrackRow]) {
        applyTagEdits(rows.map { (row: $0, key: key, value: value) })
    }

    func revertTags(rows: [TrackRow]) {
        applyTagEdits(rows.flatMap { row in
            TagFields.Key.allCases.map { (row: row, key: $0, value: tagDraft(for: row).base[$0]) }
        })
    }

    /// 현재 값과 충돌한 칸 하나만 사용자가 선택한다. 다른 칸의 충돌은 writer가 계속 막는다.
    func resolveTagConflict(_ key: TagFields.Key, keepingDraft: Bool, rows: [TrackRow]) {
        guard !isWritingRekordbox else { return }
        var before: [String: TagDraft] = [:]
        var after: [String: TagDraft] = [:]
        for row in rows where !row.track.isStreaming && !row.isUsb {
            let uuid = row.track.uuid
            guard let original = tagDrafts[uuid] else { continue }
            let current = (rowsByUUID[uuid] ?? row).tagFields
            guard original.conflictingKeys(with: current).contains(key) else { continue }
            before[uuid] = original
            var resolved = original
            resolved.base[key] = current[key]
            if !keepingDraft { resolved.fields[key] = current[key] }
            after[uuid] = resolved.rebased(onto: current) ?? resolved
        }
        guard let change = DraftChange(before: before, after: after) else { return }
        applyTagSnapshot(after)
        registerTagUndo(change)
    }

    // MARK: - 태그 시트(엑셀식) 일괄 편집 + 되돌리기

    func tagCell(_ row: TrackRow, _ key: TagFields.Key) -> String {
        if let draft = tagDrafts[row.track.uuid] {
            return TagFields.Key.independent.contains(key) ? tagDraft(for: row).fields[key] : draft.fields[key]
        }
        return row.tagFields[key]
    }

    func isTagEdited(_ row: TrackRow, _ key: TagFields.Key) -> Bool {
        guard let draft = tagDrafts[row.track.uuid] else { return false }
        return draft.base[key] != draft.fields[key]
    }

    /// 여러 셀을 한 번에 바꾼다. 되돌리기 한 단위가 된다.
    func applyTagEdits(_ changes: [(row: TrackRow, key: TagFields.Key, value: String)]) {
        guard !isWritingRekordbox else { return }
        var before: [String: TagDraft] = [:]
        var after: [String: TagDraft] = [:]
        // USB 곡은 읽기 전용이다(초안을 만들지 않는다)
        for change in changes where !change.row.track.isStreaming && !change.row.isUsb {
            let uuid = change.row.track.uuid
            let original = tagDraft(for: change.row)
            var value = change.value
            // 키는 고르기에서만 고친다. 붙여넣기·채우기·표 편집이 Camelot 이름이 아닌 값이나 고칠 수 없는 곡의 키를 초안에 넣지 못하게 여기서도 거른다
            // (초안의 기준 값으로 되돌리는 것은 그대로 받는다: 기준이 옛 표기여도 되돌릴 수 있어야 한다).
            if change.key == .musicalKey, value != original.base.musicalKey {
                guard KeyPicker.unavailableReason(change.row) == nil, let accepted = KeyPicker.accepted(value) else { continue }
                value = accepted
            }
            // 평점·곡 색도 고르기 값(별 1~5개·rekordbox 색)만 받고, 고칠 수 없는 곡(추가한 곡·상태 0·256·257 밖의 곡, #65)에는 초안을 만들지 않는다
            if change.key == .rating || change.key == .color, value != original.base[change.key] {
                guard TrackListTagEditing.unavailableReason(change.row, key: change.key) == nil,
                      let accepted = TagChoice.accepted(change.key, value, colors: trackColors) else { continue }
                value = accepted
            }
            before[uuid] = before[uuid] ?? original
            var edited = after[uuid] ?? original
            edited.fields[change.key] = value
            after[uuid] = edited
        }
        guard let change = DraftChange(before: before, after: after) else { return }
        applyTagSnapshot(after)
        registerTagUndo(change)
    }

    private func registerTagUndo(_ change: DraftChange<[String: TagDraft]>) {
        guard let undoManager else { return }
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        let groupsByEvent = undoManager.groupsByEvent
        if grouping {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { target in
            guard !target.isWritingRekordbox else { return }
            target.applyTagSnapshot(change.before)
            target.registerTagUndo(change.reversed)
        }
        undoManager.setActionName(String(ui: "태그 편집"))
        if grouping {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupsByEvent
        }
    }

    /// 곡별 초안 전체를 복원해 base와 여러 칸을 함께 보존한다.
    private func applyTagSnapshot(_ drafts: [String: TagDraft]) {
        var updated = tagDrafts
        for (uuid, draft) in drafts { updated[uuid] = draft.hasChanges ? draft : nil }
        tagDrafts = updated
        for uuid in drafts.keys { updateEdited(uuid) }
        persistTagDrafts(Array(drafts.values))
        tagRevision += 1
    }
}
