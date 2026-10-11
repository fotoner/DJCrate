import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 태그 편집 조각(#250): 인스펙터·태그 시트·곡 목록 칸·덱 제안 줄이 함께 쓴다. 초안만 바뀌고, 여러 칸 편집은 되돌리기 한 단위로 묶는다.
/// 태그 초안(`LibraryStore.tagDrafts`)은 목록 ✎ 칸·반영과 같은 색인이라 공유 핵심에 두고 이 조각이 바꾼다.
/// 받는 값·충돌 해결의 규칙과 순서는 유스케이스 `EditTags`가 맡는다. 여기에는 되돌리기 등록과 표시만 남는다.
@MainActor
@Observable
final class TagEditStore {
    /// 무시한 키 제안(곡 UUID). 게인·그리드 제안처럼 곡마다 기억하고, 덱 제안 줄에 바로 반영한다.
    private(set) var dismissedKeySuggestions: Set<String>
    /// 공유 핵심. 이 조각은 핵심의 속성(`LibraryStore.tags`)이라 핵심과 함께 사라진다.
    @ObservationIgnored private unowned let library: LibraryStore
    @ObservationIgnored private let edit: EditTags
    @ObservationIgnored private let settings: SettingsStore

    init(library: LibraryStore) {
        self.library = library
        edit = library.useCases.tags
        settings = library.settings
        dismissedKeySuggestions = library.settings.strings(SettingKeys.dismissedKeySuggestions)
    }

    // MARK: - 키 제안(덱 제안 줄)

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

    /// 쓰는 동안(덱 제안 줄의 단추를 막는다)
    var isWritingRekordbox: Bool { library.isWritingRekordbox }

    /// 목록에 있는 같은 곡의 행(동기화로 rekordbox 값이 바뀌었으면 새 값)
    func listedRow(uuid: String) -> TrackRow? { library.rowsByUUID[uuid] }

    // MARK: - 읽기

    /// 곡의 태그 초안(없으면 지금 rekordbox 값에서 새로). 안 고친 독립 칸은 지금 값으로 맞춘다(`TagEditRules.draft`).
    func tagDraft(for row: TrackRow) -> TagDraft { TagEditRules.draft(for: row, in: library.tagDrafts) }

    /// 추가한 곡을 넣을 때 함께 쓸 키(사용자가 고른 Camelot 이름, #5). 키를 고치지 않았거나 비웠으면(넣는 곡은 처음부터 키가 없다) nil.
    func confirmedStagedKey(uuid: String) -> String? { AddedTrackDrafts.confirmedKey(library.tagDrafts[uuid]) }

    /// 선택한 곡들의 값. 모두 같으면 그 값, 다르면 `mixed`.
    func tagValue(_ key: TagFields.Key, rows: [TrackRow]) -> (value: String, mixed: Bool) {
        TagEditRules.value(key, rows: rows, in: library.tagDrafts)
    }

    func tagCell(_ row: TrackRow, _ key: TagFields.Key) -> String { TagEditRules.cell(row, key, in: library.tagDrafts) }

    func isTagEdited(_ row: TrackRow, _ key: TagFields.Key) -> Bool { TagEditRules.isEdited(row, key, in: library.tagDrafts) }

    // MARK: - 바꾸기(초안만 바뀐다)

    func setTag(_ key: TagFields.Key, _ value: String, rows: [TrackRow]) {
        applyTagEdits(rows.map { (row: $0, key: key, value: value) })
    }

    func revertTags(rows: [TrackRow]) {
        guard !library.isWritingRekordbox else { return }
        commit(edit.revert(rows, drafts: library.tagDrafts, colors: library.trackColors))
    }

    /// 현재 값과 충돌한 칸 하나만 사용자가 선택한다. 다른 칸의 충돌은 writer가 계속 막는다.
    func resolveTagConflict(_ key: TagFields.Key, keepingDraft: Bool, rows: [TrackRow]) {
        guard !library.isWritingRekordbox else { return }
        commit(edit.resolveConflict(key, keepingDraft: keepingDraft, rows: rows, drafts: library.tagDrafts, current: library.rowsByUUID))
    }

    /// 여러 셀을 한 번에 바꾼다(태그 시트 붙여넣기·채우기). 되돌리기 한 단위가 된다.
    func applyTagEdits(_ changes: [(row: TrackRow, key: TagFields.Key, value: String)]) {
        guard !library.isWritingRekordbox else { return }
        commit(edit.edit(changes, drafts: library.tagDrafts, colors: library.trackColors))
    }

    private func commit(_ change: DraftChange<[String: TagDraft]>?) {
        guard let change else { return }
        show(change.after)
        registerUndo(change)
    }

    /// 되돌리기 대상은 공유 핵심이다: 쓰기를 시작하거나 되돌리기 관리자가 바뀌면 핵심을 대상으로 한 단계를 모두 지운다(`LibraryStore`).
    private func registerUndo(_ change: DraftChange<[String: TagDraft]>) {
        guard let undoManager = library.undoManager else { return }
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        let groupsByEvent = undoManager.groupsByEvent
        if grouping {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: library) { target in
            guard !target.isWritingRekordbox else { return }
            target.tags.show(change.before)
            target.tags.registerUndo(change.reversed)
        }
        undoManager.setActionName(String(ui: "태그 편집"))
        if grouping {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupsByEvent
        }
    }

    /// 곡별 초안 전체를 복원해 base와 여러 칸을 함께 보존한다.
    private func show(_ drafts: [String: TagDraft]) {
        library.tagDrafts = TagEditRules.applying(drafts, to: library.tagDrafts)
        for uuid in drafts.keys { library.updateEdited(uuid) }
        let changed = Array(drafts.values)
        library.rememberTagSaves(changed)
        edit.save(changed)
        library.tagRevision += 1
    }
}
