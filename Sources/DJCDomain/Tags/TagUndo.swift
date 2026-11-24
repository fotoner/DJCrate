import Foundation

/// 저장 뒤 ⌘Z(R12, #405)의 태그 몫: 편집 한 번이 바꾼 칸만 지금 rekordbox 값 위에서 편집 전 값으로 되돌린 역편집 초안을 만든다.
public enum TagUndo {
    /// 저장 뒤에는 되돌리지 않는 칸: 앨범·아티스트. 이름·앨범 행을 함께 고쳐 막아 둔 규칙(공유 앨범 값 변경·동명 앨범 선택·동기화 상태)에 걸린다
    /// (`TagDraft.conflictingKeys`의 앨범 관계 칸과 같다)
    public static let excludedAfterSave: Set<TagFields.Key> = [.artist, .album, .albumArtist]

    /// 편집 한 번(`before` → `after`, nil은 초안 없음 = 그때 rekordbox 값)이 바꾼 칸을 `current`(지금 rekordbox 값 위의 초안) 위에서 편집 전 값으로 되돌린다.
    /// 바꾼 칸 밖(그사이 바깥에서 고친 칸 포함)은 `current` 그대로다. 되돌릴 칸이 없으면(제외 칸만 바꿨다) nil
    public static func reverting(before: TagDraft?, after: TagDraft?, onto current: TagDraft,
                                 excluding: Set<TagFields.Key> = excludedAfterSave) -> TagDraft? {
        guard let old = before?.fields ?? after?.base, let new = after?.fields ?? before?.base else { return nil }
        let keys = TagFields.Key.allCases.filter { old[$0] != new[$0] && !excluding.contains($0) }
        guard !keys.isEmpty else { return nil }
        var reverted = current
        for key in keys { reverted.fields[key] = old[key] }
        return reverted
    }
}
