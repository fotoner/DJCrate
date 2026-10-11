import AppKit
import DJCDomain

/// 곡 목록 바로 태그 편집(#88)의 앱 쪽: 대상 곡·칸 글자와 클릭 판정. 칸 이름·흐름·고칠 수 있는지는 DJCDomain `TrackListTagEditing`.
extension TrackListTagEditing {
    /// 칸 하나를 고치는 동안 들고 있는 값. 대상 곡과 시작 값은 편집을 시작할 때 정한다.
    struct Session: Equatable {
        let key: TagFields.Key
        /// 초안을 만들 곡(중복·스트리밍 제외, 표 순서)
        let targets: [TrackRow]
        /// 칸에 넣고 시작한 값. 여러 값이면 빈 칸.
        let original: String
        let mixed: Bool

        init?(key: TagFields.Key, targets: [TrackRow], value: (TrackRow) -> String) {
            guard let first = targets.first else { return nil }
            let firstValue = value(first)
            let mixed = targets.dropFirst().contains { value($0) != firstValue }
            self.key = key
            self.targets = targets
            original = mixed ? "" : firstValue
            self.mixed = mixed
        }
    }

    /// 이 클릭 뒤 잠깐 기다려 칸을 고칠지: 이미 혼자 고른 줄을 조합 키 없이 한 번 눌렀을 때만.
    /// 여러 곡을 고른 채 누르면 그 곡 하나만 고르는 클릭이라 고치지 않는다(Finder와 같다).
    static func startsSlowEdit(clickCount: Int, row: Int, selected: IndexSet, modifiers: NSEvent.ModifierFlags) -> Bool {
        clickCount == 1 && row >= 0 && selected == IndexSet(integer: row)
            && modifiers.intersection([.shift, .command, .control, .option]).isEmpty
    }

    /// 고칠 곡: 누른 줄이 고른 줄 안이면 고른 곡 모두, 밖이면 그 줄만.
    /// 누른 곡이 스트리밍이면 편집하지 않는다(빈 배열).
    static func targets(anchor: TrackRow, selection: [TrackRow]) -> [TrackRow] {
        guard !anchor.track.isStreaming else { return [] }
        let candidates = selection.contains { $0.id == anchor.id } ? selection : [anchor]
        var seen = Set<String>()
        return candidates.filter { !$0.track.isStreaming && seen.insert($0.track.id).inserted }
    }

    /// 확정할 때 바꿀 곡. 시작 값 그대로면(여러 값 칸을 비운 채 나오면 포함) 아무 곡도 바꾸지 않는다.
    static func changes(_ session: Session, committing text: String) -> [TrackRow] {
        text == session.original ? [] : session.targets
    }

    /// 목록 칸 글자와 초안 여부: 태그 초안이 있으면 초안 값(태그 시트와 같다), 없으면 rekordbox 값.
    /// 제목·아티스트가 암호화된 스트리밍 곡은 지금 목록 표시를 그대로 쓴다.
    static func text(_ row: TrackRow, _ key: TagFields.Key, draft: TagDraft?) -> (text: String, edited: Bool) {
        // 독립 칸(키·평점·곡 색)을 고치지 않은 초안은 그 칸이 없던 옛 초안일 수 있어 지금 값을 보인다(`adoptingIndependentKeys`)
        if let draft { return (draft.adoptingIndependentKeys(of: row.tagFields).fields[key], draft.base[key] != draft.fields[key]) }
        if row.isEncrypted {
            switch key {
            case .title: return (row.title, false)
            case .artist, .album, .albumArtist: return ("", false)
            default: break
            }
        }
        return (row.tagFields[key], false)
    }

    /// 분류 칸: 코멘트 초안이 있으면 초안 코멘트로 다시 가른다(인스펙터 미리 보기와 같다). 필터·정렬은 rekordbox 값 그대로다.
    static func commentEvaluation(_ row: TrackRow, draft: TagDraft?, rule: (any CommentRule)?) -> CommentEvaluation? {
        guard let draft, draft.base.comment != draft.fields.comment else { return row.commentEvaluation }
        return rule?.evaluate(draft.fields.comment)
    }
}
