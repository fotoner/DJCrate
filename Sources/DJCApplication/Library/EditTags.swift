import DJCDomain
import Foundation

/// 태그 초안 편집(유스케이스, #250): 칸 바꾸기·초안 버리기·충돌 고르기를 되돌리기 한 단위(`DraftChange`)로 만들고 저장한다.
/// 받는 값(스트리밍·USB 곡 거르기, 키·평점·곡 색 고르기 값)과 충돌 해결 규칙은 `TagEditRules`(DJCDomain)에 있다.
/// 화면은 결과를 메모리 초안에 넣고(`TagEditRules.applying`) 되돌리기를 등록한 뒤 `save`로 저장한다.
public struct EditTags: Sendable {
    let drafts: DraftStore

    public init(drafts: DraftStore) {
        self.drafts = drafts
    }

    /// 칸 하나 바꾸기
    public struct Change: Sendable {
        public var row: TrackRow
        public var key: TagFields.Key
        public var value: String

        public init(row: TrackRow, key: TagFields.Key, value: String) {
            self.row = row
            self.key = key
            self.value = value
        }
    }

    /// 여러 칸을 한 번에 바꾼 앞뒤 초안(되돌리기 한 단위). 받지 않는 칸은 건너뛴다. 바뀐 칸이 없으면 nil.
    /// 같은 곡을 여러 번 바꾸면 앞은 처음 초안, 뒤는 모든 칸을 바꾼 초안이다.
    public func edit(_ changes: [Change], drafts current: [String: TagDraft], colors: [TrackColor]) -> DraftChange<[String: TagDraft]>? {
        var before: [String: TagDraft] = [:]
        var after: [String: TagDraft] = [:]
        for change in changes {
            let uuid = change.row.track.uuid
            let original = TagEditRules.draft(for: change.row, in: current)
            guard let value = TagEditRules.accepted(change.value, for: change.key, row: change.row, base: original.base,
                                                    colors: colors) else { continue }
            before[uuid] = before[uuid] ?? original
            var edited = after[uuid] ?? original
            edited.fields[change.key] = value
            after[uuid] = edited
        }
        return DraftChange(before: before, after: after)
    }

    /// 초안 버리기: 고른 곡의 모든 칸을 초안의 기준 값으로 돌린다.
    public func revert(_ rows: [TrackRow], drafts current: [String: TagDraft], colors: [TrackColor]) -> DraftChange<[String: TagDraft]>? {
        edit(rows.flatMap { row in
            let base = TagEditRules.draft(for: row, in: current).base
            return TagFields.Key.allCases.map { Change(row: row, key: $0, value: base[$0]) }
        }, drafts: current, colors: colors)
    }

    /// 지금 rekordbox 값과 충돌한 칸 하나를 사용자가 고른다(`TagEditRules.resolving`). 다른 칸의 충돌은 쓰기가 계속 막는다.
    /// - Parameter current: 목록의 새 행(UUID별). 없으면 고른 행을 지금 값으로 본다
    public func resolveConflict(_ key: TagFields.Key, keepingDraft: Bool, rows: [TrackRow], drafts: [String: TagDraft],
                                current: [String: TrackRow]) -> DraftChange<[String: TagDraft]>? {
        var before: [String: TagDraft] = [:]
        var after: [String: TagDraft] = [:]
        for row in rows where !row.track.isStreaming && !row.isUsb {
            let uuid = row.track.uuid
            guard let original = drafts[uuid],
                  let resolved = TagEditRules.resolving(original, key: key, current: (current[uuid] ?? row).tagFields,
                                                        keepingDraft: keepingDraft) else { continue }
            before[uuid] = original
            after[uuid] = resolved
        }
        return DraftChange(before: before, after: after)
    }

    /// 바꾼 초안을 저장한다. 고친 칸이 없는 초안은 저장소가 지운다.
    @MainActor public func save(_ changed: [String: TagDraft]) {
        drafts.saveTags(Array(changed.values))
    }
}
