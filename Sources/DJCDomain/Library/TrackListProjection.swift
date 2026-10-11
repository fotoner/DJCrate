import Foundation

/// 곡 목록 투영: 사이드바 대상이 보여 줄 줄 → 스트리밍 숨기기 → (정렬은 화면 모델) → 검색·평점·곡 색 거르기.
/// 입출력 없이 읽어 둔 곡 행만으로 계산한다. 화면 모델은 필터·검색·정렬이 바뀔 때만 부른다.
public enum TrackListProjection {
    /// 사이드바 대상이 보여 줄 줄(숨기기·정렬 전)
    public enum Source: Sendable {
        case filter(LibraryFilter)
        /// rekordbox 재생 목록 순서(ContentID)
        case playlist(trackIDs: [String])
        /// iTunes 동기화 목록. 같은 곡이 여러 번 들 수 있어 줄마다 고유 ID와 순번을 붙인다
        case iTunesPlaylist(id: String, trackIDs: [String], numbers: [Int])
        /// 재생 기록. 반복 재생도 기록 행마다 한 줄이다
        case history([RekordboxHistory.Entry])
        /// 그대로 보이는 줄(추가한 곡·USB 곡)
        case rows([TrackRow])
        /// 초안이 있는 곡(UUID)
        case pending(Set<String>)
        /// 중복 후보 묶음의 곡 ID(묶음 차례). 같은 곡은 처음 한 번만 둔다
        case duplicates([String])
    }

    public static func base(_ source: Source, rows: [TrackRow], rowsByID: [TrackRow.ID: TrackRow]) -> [TrackRow] {
        switch source {
        case let .filter(filter): return rows.filter(filter.includes)
        case let .playlist(trackIDs): return trackIDs.compactMap { rowsByID[$0] }
        case let .iTunesPlaylist(id, trackIDs, numbers):
            var occurrences: [String: Int] = [:]
            return zip(trackIDs, numbers).compactMap { trackID, number in
                guard var row = rowsByID[trackID] else { return nil }
                let occurrence = occurrences[trackID, default: 0]
                occurrences[trackID] = occurrence + 1
                row.playlistOccurrence = .init(id: "\(id):\(trackID):\(occurrence)", number: number)
                return row
            }
        case let .history(entries):
            return entries.compactMap { entry in
                guard var row = rowsByID[entry.contentID] else { return nil }
                row.historyEntry = entry
                return row
            }
        case let .rows(rows): return rows
        case let .pending(uuids): return rows.filter { uuids.contains($0.track.uuid) }
        case let .duplicates(ids):
            var seen = Set<String>()
            return ids.compactMap { seen.insert($0).inserted ? rowsByID[$0] : nil }
        }
    }

    /// '스트리밍 곡 숨기기'를 적용한 줄과 숨긴 줄의 ID(선택에서도 뺀다)
    public struct Visible: Sendable {
        public var rows: [TrackRow]
        public var hiddenIDs: Set<TrackRow.ID>
        /// 숨긴 줄 수(안내 문구). 같은 곡이 두 번 든 재생 목록은 ID가 하나라도 두 줄로 센다
        public var hiddenCount = 0
    }

    public static func hidingStreaming(_ base: [TrackRow], hide: Bool) -> Visible {
        guard hide else { return Visible(rows: base, hiddenIDs: []) }
        let hidden = base.filter { $0.track.isStreaming }
        guard !hidden.isEmpty else { return Visible(rows: base, hiddenIDs: []) }
        return Visible(rows: StreamingVisibility.visible(base, hidingStreaming: true) { $0.track }, hiddenIDs: Set(hidden.map(\.id)),
                       hiddenCount: hidden.count)
    }

    /// 검색어를 비교할 모양(앞뒤 공백을 떼고 소문자)
    public static func needle(_ search: String) -> String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 검색·평점·곡 색 거르기. 정렬한 순서를 그대로 둔다. 거를 것이 없으면 받은 배열을 그대로 돌려준다.
    public static func filtered(_ sorted: [TrackRow], search: String, minimumRating: Int, color: String?) -> [TrackRow] {
        let needle = needle(search)
        let attributes = minimumRating > 0 || color != nil
        guard !needle.isEmpty || attributes else { return sorted }
        return sorted.filter { row in
            (needle.isEmpty || row.searchKey.contains(needle))
                && (!attributes || matchesAttributes(row, minimumRating: minimumRating, color: color))
        }
    }

    /// 평점·곡 색 거르기(#65). rekordbox 값(초안 전)으로 거른다. USB 곡도 같은 칸으로 거른다.
    public static func matchesAttributes(_ row: TrackRow, minimumRating: Int, color: String?) -> Bool {
        row.track.rating >= minimumRating && (color.map { row.track.colorID == $0 } ?? true)
    }

    /// 중복 후보 검색: 검색한 곡이 든 묶음을 통째로 남긴다(비교 상대가 잘리지 않게).
    public static func duplicateGroups<Group>(_ groups: [Group], members: (Group) -> [String], search: String,
                                              rowsByID: [TrackRow.ID: TrackRow]) -> [Group] {
        let needle = needle(search)
        guard !needle.isEmpty else { return groups }
        return groups.filter { group in members(group).contains { rowsByID[$0]?.searchKey.contains(needle) == true } }
    }
}

/// 목록 선택 규칙
public enum TrackSelection {
    /// 불러오기 명령(⌘→·메뉴)이 덱에 올릴 곡: 하나만 골랐으면 그 곡, 여럿이면 표 순서로 첫 곡(재생 기록 행은 컬렉션 곡으로).
    public static func primary(selection: Set<TrackRow.ID>, displayRows: [TrackRow],
                               rowsByID: [TrackRow.ID: TrackRow]) -> TrackRow? {
        guard !selection.isEmpty else { return nil }
        if selection.count == 1, let id = selection.first, let row = rowsByID[id] { return row }
        if let row = displayRows.first(where: { selection.contains($0.id) }) { return rowsByID[row.track.id] ?? row }
        return selection.first.flatMap { rowsByID[$0] }
    }

    /// 재생 기록의 반복 행을 함께 골라도 곡 편집·반영 대상은 한 번만 넘긴다.
    /// USB 곡은 읽기 전용이라 편집·쓰기·재생 목록 대상에 넣지 않는다.
    public static func uniqueTracks(_ candidates: [TrackRow], rowsByID: [TrackRow.ID: TrackRow]) -> [TrackRow] {
        var seen = Set<String>()
        return candidates.filter { !$0.isUsb && seen.insert($0.track.id).inserted }.map { rowsByID[$0.track.id] ?? $0 }
    }

    /// 다시 읽은 뒤 남길 선택: 라이브러리에 있는 곡이나 지금 보이는 줄(지운 곡은 뺀다)
    public static func existing(_ selection: Set<TrackRow.ID>, rowsByID: [TrackRow.ID: TrackRow],
                                displayRows: [TrackRow]) -> Set<TrackRow.ID> {
        let visible = Set(displayRows.map(\.id))
        return selection.filter { rowsByID[$0] != nil || visible.contains($0) }
    }

    /// 숨긴 스트리밍 줄과 스트리밍 곡을 뺀 선택(숨은 곡에 쓰기·덱 동작이 가지 않게)
    public static func withoutHidden(_ selection: Set<TrackRow.ID>, hiddenIDs: Set<TrackRow.ID>,
                                     rowsByID: [TrackRow.ID: TrackRow]) -> Set<TrackRow.ID> {
        selection.filter { !hiddenIDs.contains($0) && rowsByID[$0]?.track.isStreaming != true }
    }
}
