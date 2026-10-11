import DJCDomain

/// 고른 곡 → 쓰기·넣기·빼기 대상. 메뉴(보일지·곡 수)·반영 세션(실제 대상)·시험 가짜가 모두 이 규칙을 부른다(adv2 N9·adv4 T7).
public enum ReflectionTargets {
    /// 반영 대기 곡: 초안 표시가 있는 곡과 아직 저장 중인 입력이 있는 곡(저장이 끝나기 전에도 쓰기 대상이다)
    public static func pending(marked: Set<String>, unsaved: Set<String>) -> Set<String> { marked.union(unsaved) }

    /// 반영 대기 초안이 있는 rekordbox 곡(추가한 곡은 넣기로 쓴다)
    public static func write(_ rows: [TrackRow], pending: Set<String>) -> [TrackRow] {
        rows.filter { !$0.isStaged && pending.contains($0.track.uuid) }
    }

    /// DJCrate에 추가한 곡(rekordbox 컬렉션에 넣는다)
    public static func add(_ rows: [TrackRow]) -> [TrackRow] { rows.filter(\.isStaged) }

    /// rekordbox 컬렉션의 로컬 곡(스트리밍·추가한 곡 제외). iTunes 동기화 목록의 곡은 Music에서 빼므로 고르지 않는다.
    public static func delete(_ rows: [TrackRow], iTunesSelection: Bool) -> [TrackRow] {
        iTunesSelection ? [] : rows.filter { !$0.isStaged && !$0.track.isStreaming }
    }
}
