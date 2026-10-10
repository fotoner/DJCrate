import Foundation

/// 태그 초안을 고치는 규칙(#250): 곡의 지금 초안과 칸 값, 칸마다 받는 값, 충돌한 칸 고르기.
/// 순서(여러 칸을 되돌리기 한 단위로 묶기·저장)는 유스케이스 `EditTags`가 정한다. 앱 화면과 CLI가 같은 규칙을 쓴다.
public enum TagEditRules {
    /// 곡의 태그 초안(없으면 지금 rekordbox 값에서 새로). 안 고친 독립 칸(키·평점·곡 색)은 지금 값으로 맞춘다: 그 칸이 없던 옛 초안이나 그 뒤
    /// rekordbox에서 그 칸만 바뀐 초안이 그 칸을 고친 것처럼 보이거나 쓰기 때 기준이 어긋나지 않게 한다(`TagDraft.adoptingIndependentKeys`).
    /// 추가한 곡의 기준 키는 빈칸이다(`TrackRow.tagFields`): 키를 고를 수 없던 때 목록의 키를 기준으로 든 옛 초안도 여기서 맞춘다.
    public static func draft(for row: TrackRow, in drafts: [String: TagDraft]) -> TagDraft {
        guard let draft = drafts[row.track.uuid] else { return TagDraft(trackUUID: row.track.uuid, base: row.tagFields) }
        return draft.adoptingIndependentKeys(of: row.tagFields)
    }

    /// 칸에 보일 값(초안이 있으면 초안 값)
    public static func cell(_ row: TrackRow, _ key: TagFields.Key, in drafts: [String: TagDraft]) -> String {
        if let draft = drafts[row.track.uuid] {
            return TagFields.Key.independent.contains(key) ? self.draft(for: row, in: drafts).fields[key] : draft.fields[key]
        }
        return row.tagFields[key]
    }

    /// 곡들의 값. 모두 같으면 그 값, 다르면 `mixed`.
    public static func value(_ key: TagFields.Key, rows: [TrackRow], in drafts: [String: TagDraft]) -> (value: String, mixed: Bool) {
        guard let first = rows.first else { return ("", false) }
        let value = cell(first, key, in: drafts)
        for row in rows.dropFirst() where cell(row, key, in: drafts) != value { return ("", true) }
        return (value, false)
    }

    /// 초안에서 그 칸을 고쳤는지
    public static func isEdited(_ row: TrackRow, _ key: TagFields.Key, in drafts: [String: TagDraft]) -> Bool {
        guard let draft = drafts[row.track.uuid] else { return false }
        return draft.base[key] != draft.fields[key]
    }

    /// 칸 하나에 넣을 값. 받지 않으면 nil이다.
    /// - USB 곡은 읽기 전용, 스트리밍 곡은 파일 태그가 없어 초안을 만들지 않는다.
    /// - 키는 고르기에서만 고친다. 붙여넣기·채우기·표 편집이 Camelot 이름이 아닌 값이나 고칠 수 없는 곡의 키를 초안에 넣지 못하게 여기서도 거른다.
    /// - 평점·곡 색도 고르기 값(별 1~5개·rekordbox 색)만 받는다. 고칠 수 없는 곡(추가한 곡·상태 0·256·257 밖의 곡, #65)에는 넣지 않는다.
    /// - 초안의 기준 값으로 되돌리기는 그대로 받는다: 기준이 옛 표기여도 되돌릴 수 있어야 한다.
    public static func accepted(_ value: String, for key: TagFields.Key, row: TrackRow, base: TagFields, colors: [TrackColor]) -> String? {
        guard !row.track.isStreaming, !row.isUsb else { return nil }
        guard TagChoice.keys.contains(key), value != base[key] else { return value }
        guard TrackListTagEditing.unavailableReason(row, key: key) == nil else { return nil }
        return TagChoice.accepted(key, value, colors: colors)
    }

    /// 지금 rekordbox 값과 부딪친 칸 하나를 사용자가 고른 초안. 그 칸이 부딪치지 않았으면 nil이다.
    /// 다른 칸의 충돌은 그대로 두고(쓰기가 계속 막는다), 남은 충돌이 없으면 안 고친 칸을 지금 값으로 맞춘다.
    public static func resolving(_ draft: TagDraft, key: TagFields.Key, current: TagFields, keepingDraft: Bool) -> TagDraft? {
        guard draft.conflictingKeys(with: current).contains(key) else { return nil }
        var resolved = draft
        resolved.base[key] = current[key]
        if !keepingDraft { resolved.fields[key] = current[key] }
        return resolved.rebased(onto: current) ?? resolved
    }

    /// 바꾼 초안을 메모리 초안에 넣은 결과. 고친 칸이 없어진 초안은 뺀다.
    public static func applying(_ changed: [String: TagDraft], to drafts: [String: TagDraft]) -> [String: TagDraft] {
        var updated = drafts
        for (uuid, draft) in changed { updated[uuid] = draft.hasChanges ? draft : nil }
        return updated
    }
}
