import DJCDomain
import Foundation

/// 검색·평점·곡 색 필터 때문에 곡 목록이 비었을 때의 안내 문구와 단추(#299).
/// 검색어가 있으면 검색 결과 없음 안내이고(필터도 켜져 있으면 그 사실과 [필터 끄기]를 더한다), 필터만 켜졌으면 조건 결과 없음 안내다.
/// 뷰(`EmptyLibraryOverlay`)는 이 값을 그리기만 한다. 아직 쓰지 않은 편집이 있을 때만 작은 글씨를 붙인다:
/// 필터는 편집한 값이 아니라 rekordbox에 들어 있는 값으로 거르기 때문이다.
struct NoResultsGuide: Equatable {
    var title: String
    var description: String
    /// 검색과 필터가 함께 걸렸을 때 덧붙이는 줄
    var filterNote: String?
    var offersClearSearch: Bool
    var offersClearFilter: Bool
    /// 아직 rekordbox에 쓰지 않은 편집이 있을 때 필터가 거르는 기준을 알리는 작은 글씨
    var footnote: String?

    /// 검색어도 필터도 없으면 nil(이 안내를 쓰지 않는다)
    init?(search: String, isFiltered: Bool, hasUnwrittenEdits: Bool) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || isFiltered else { return nil }
        if query.isEmpty {
            title = String(ui: "조건에 맞는 곡이 없습니다")
            description = String(ui: "검색어나 필터 조건을 다시 확인해 주세요")
        } else {
            title = String(ui: "‘\(query)’에 맞는 곡을 찾지 못했습니다")
            description = String(ui: "검색어를 다시 확인해 주세요")
        }
        filterNote = !query.isEmpty && isFiltered ? String(ui: "필터도 켜져 있습니다") : nil
        offersClearSearch = !query.isEmpty
        offersClearFilter = isFiltered
        footnote = isFiltered && hasUnwrittenEdits ? String(ui: "필터는 rekordbox에 들어 있는 값으로 거릅니다") : nil
    }
}
