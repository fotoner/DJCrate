@testable import DJCrate
import Testing

/// 검색·평점·곡 색 필터 때문에 곡 목록이 비었을 때의 안내 문구와 단추(#299, C17~C20)
@Suite("결과 없음 안내")
struct NoResultsGuideTests {
    @Test func 검색어도_필터도_없으면_이_안내를_쓰지_않는다() {
        #expect(NoResultsGuide(search: "", isFiltered: false, hasUnwrittenEdits: true) == nil)
        #expect(NoResultsGuide(search: "  \n", isFiltered: false, hasUnwrittenEdits: false) == nil)
    }

    @Test func 검색만_걸렸으면_찾지_못했다고_알리고_검색_지우기만_보인다() throws {
        let guide = try #require(NoResultsGuide(search: "  없는 곡 ", isFiltered: false, hasUnwrittenEdits: false))
        #expect(guide.title == "‘없는 곡’에 맞는 곡을 찾지 못했습니다")
        #expect(guide.description == "검색어를 다시 확인해 주세요")
        #expect(guide.filterNote == nil)
        #expect(guide.offersClearSearch)
        #expect(!guide.offersClearFilter)
        #expect(guide.footnote == nil)
    }

    @Test func 검색과_필터가_함께_걸렸으면_필터도_켜져_있다고_알리고_필터_끄기를_보인다() throws {
        let guide = try #require(NoResultsGuide(search: "없는 곡", isFiltered: true, hasUnwrittenEdits: false))
        #expect(guide.title == "‘없는 곡’에 맞는 곡을 찾지 못했습니다")
        #expect(guide.description == "검색어를 다시 확인해 주세요")
        #expect(guide.filterNote == "필터도 켜져 있습니다")
        #expect(guide.offersClearSearch)
        #expect(guide.offersClearFilter)
    }

    @Test func 필터만_걸렸으면_조건에_맞는_곡이_없다고_알리고_필터_끄기만_보인다() throws {
        let guide = try #require(NoResultsGuide(search: "", isFiltered: true, hasUnwrittenEdits: false))
        #expect(guide.title == "조건에 맞는 곡이 없습니다")
        #expect(guide.description == "검색어나 필터 조건을 다시 확인해 주세요")
        #expect(guide.filterNote == nil)
        #expect(!guide.offersClearSearch)
        #expect(guide.offersClearFilter)
        #expect(guide.footnote == nil)
    }

    @Test func 쓰지_않은_편집이_있을_때만_필터가_rekordbox_값으로_거른다고_덧붙인다() throws {
        let filtered = try #require(NoResultsGuide(search: "", isFiltered: true, hasUnwrittenEdits: true))
        #expect(filtered.footnote == "필터는 rekordbox에 들어 있는 값으로 거릅니다")
        let both = try #require(NoResultsGuide(search: "곡", isFiltered: true, hasUnwrittenEdits: true))
        #expect(both.footnote == "필터는 rekordbox에 들어 있는 값으로 거릅니다")
        // 필터가 꺼져 있으면 편집이 있어도 필터 이야기를 하지 않는다
        let searchOnly = try #require(NoResultsGuide(search: "곡", isFiltered: false, hasUnwrittenEdits: true))
        #expect(searchOnly.footnote == nil)
    }

    @Test func 화면_문구에_내부_용어와_옛_이름을_쓰지_않는다() throws {
        let guide = try #require(NoResultsGuide(search: "곡", isFiltered: true, hasUnwrittenEdits: true))
        let texts = [guide.title, guide.description, guide.filterNote, guide.footnote].compactMap { $0 }
        for text in texts { #expect(!text.contains("거르기") && !text.contains("초안")) }
    }
}
