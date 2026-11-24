import Foundation

/// 저장 뒤 ⌘Z(R12, #405)의 태그 몫: 편집 한 번이 바꾼 칸만 지금 rekordbox 값 위에서 편집 전 값으로 되돌린 역편집 초안을 만든다.
public enum TagUndo {
    /// 편집 한 번(`before` → `after`, nil은 초안 없음 = 그때 rekordbox 값)이 바꾼 칸을 `current`(지금 rekordbox 값 위의 초안) 위에서 편집 전 값으로 되돌린다.
    /// 바꾼 칸 밖(그사이 바깥에서 고친 칸 포함)은 `current` 그대로다. 아래면 nil(정할 수 없다: ⌘Z를 끈다)
    /// - 바꾼 칸의 지금 값이 그 편집 직후 값이 아니다(쓴 뒤 바깥에서 또 바뀜)
    /// - 되돌린 초안이 도메인 쓰기 규칙(`TagDraft.issues`)에 새로 걸린다(앨범·아티스트도 규칙에 걸리지 않으면 되돌린다)
    /// - 바꾼 칸이 없다
    public static func reverting(before: TagDraft?, after: TagDraft?, onto current: TagDraft) -> TagDraft? {
        guard let old = before?.fields ?? after?.base, let new = after?.fields ?? before?.base else { return nil }
        let keys = TagFields.Key.allCases.filter { old[$0] != new[$0] }
        guard !keys.isEmpty, keys.allSatisfy({ current.fields[$0] == new[$0] }) else { return nil }
        var reverted = current
        for key in keys { reverted.fields[key] = old[key] }
        guard Set(reverted.issues).isSubset(of: Set(current.issues)) else { return nil }
        return reverted
    }
}
