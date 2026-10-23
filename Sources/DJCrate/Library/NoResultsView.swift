import DJCDomain
import SwiftUI

/// 검색·필터 결과가 없을 때의 안내(#299). 문구와 단추 구성은 `NoResultsGuide`가 정한다. 잎 뷰라 값과 클로저만 받는다(MVVM-3).
struct NoResultsView: View {
    let guide: NoResultsGuide
    let clearSearch: () -> Void
    let clearFilter: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(guide.title, systemImage: guide.offersClearSearch ? "magnifyingglass" : "line.3.horizontal.decrease.circle")
        } description: {
            Text(guide.description)
            if let note = guide.filterNote { Text(note) }
            if let footnote = guide.footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
        } actions: {
            if guide.offersClearSearch { Button(.ui("검색 지우기"), action: clearSearch) }
            if guide.offersClearFilter { Button(.ui("필터 끄기"), action: clearFilter) }
        }
    }
}
