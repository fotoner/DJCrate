/// 설정 '스트리밍 곡 숨기기'(`SettingKeys.hideStreaming`)의 규칙. 곡 목록·곡 수에 보이는 것만 거르고,
/// 라이브러리에서 읽은 곡·초안·재생 목록 편집·rekordbox에 쓰는 내용은 이 규칙이 만지지 않는다.
public enum StreamingVisibility {
    /// 이 곡을 목록에서 숨기는가
    public static func hides(_ track: Track, hidingStreaming: Bool) -> Bool {
        hidingStreaming && track.isStreaming
    }

    /// 순서를 그대로 두고 보일 줄만 남긴다.
    public static func visible<Row>(_ rows: [Row], hidingStreaming: Bool, track: (Row) -> Track) -> [Row] {
        hidingStreaming ? rows.filter { !hides(track($0), hidingStreaming: true) } : rows
    }

    /// 곡 ID 목록에서 컬렉션에서 찾을 수 있고 숨기지 않는 자리의 수(같은 곡이 여러 번 든 목록은 자리마다 센다).
    public static func visibleCount(of ids: [String], hidingStreaming: Bool, track: (String) -> Track?) -> Int {
        ids.reduce(0) { count, id in
            guard let found = track(id), !hides(found, hidingStreaming: hidingStreaming) else { return count }
            return count + 1
        }
    }

    /// 필터별 곡 수. 숨기는 곡은 어느 필터에서도 세지 않는다.
    public static func filterCounts<Row>(_ rows: [Row], filters: [LibraryFilter], hidingStreaming: Bool, track: (Row) -> Track,
                                         includes: (LibraryFilter, Row) -> Bool) -> [LibraryFilter: Int] {
        let shown = visible(rows, hidingStreaming: hidingStreaming, track: track)
        var counts: [LibraryFilter: Int] = [:]
        for filter in filters { counts[filter] = shown.reduce(0) { includes(filter, $1) ? $0 + 1 : $0 } }
        return counts
    }
}
