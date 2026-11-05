@testable import DJCrate
import DJCDomain
import Testing

/// 머리 줄의 켜진 필터 칩(#339): 켠 조건 → 칩, 칩 끄기, 모두 끄기, 필터가 걸리지 않는 목록.
/// 화면(폭에 따라 칩 하나로 줄이기)은 자가 테스트가, 본문 다시 계산은 `LayoutRecomputeTests`가 본다.
@MainActor
@Suite("필터 칩 — 켠 조건을 칩으로, 칩 끄기")
struct AttributeFilterChipsTests {
    private let colors = TrackColor.rekordboxDefaults

    private func chips(rating: Int = 0, color: String? = nil) -> AttributeFilterChips {
        AttributeFilterChips(minimumRating: rating, colorFilter: color, colors: colors)
    }

    private func loadedStore() -> LibraryStore {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        store.phase = .loaded
        return store
    }

    // MARK: 켠 조건 → 칩

    @Test func 켠_조건이_없으면_칩이_없다() {
        let none = chips()
        #expect(none.isEmpty)
        #expect(none.chips.isEmpty)
    }

    @Test(arguments: [(1, "★ 이상"), (3, "★★★ 이상"), (4, "★★★★ 이상"), (5, "★★★★★")])
    func 평점_칩은_별과_이상으로_읽고_별_다섯은_별만_보인다(count: Int, title: String) {
        let result = chips(rating: count)
        #expect(result.chips.map(\.title) == [title])
        #expect(result.chips.map(\.condition) == [.rating(count)])
    }

    @Test func 곡_색_칩은_rekordbox_색_이름을_보인다() {
        let result = chips(color: "2")
        #expect(result.chips.map(\.title) == ["곡 색 Red"])
        #expect(result.chips.map(\.condition) == [.color("2")])
        // 라이브러리에서 이름을 바꿔 읽었으면 바꾼 이름을 따른다
        let renamed = AttributeFilterChips(minimumRating: 0, colorFilter: "2", colors: [TrackColor(id: "2", name: "Opener")])
        #expect(renamed.chips.map(\.title) == ["곡 색 Opener"])
    }

    @Test func 두_조건을_켜면_평점_칩_다음에_곡_색_칩이_온다() {
        let result = chips(rating: 3, color: "7")
        #expect(result.chips.map(\.title) == ["★★★ 이상", "곡 색 Blue"])
        #expect(!result.isEmpty)
    }

    // MARK: 접근성 이름

    @Test func 칩의_접근성_이름은_조건_전체를_읽고_끈다고_말한다() {
        // 별 글자(★)는 낭독이 어색해 별 개수로 읽는다
        #expect(chips(rating: 3).chips.map(\.accessibilityName) == ["평점 별 3개 이상 필터 끄기"])
        #expect(chips(rating: 5).chips.map(\.accessibilityName) == ["평점 별 5개 필터 끄기"])
        #expect(chips(color: "2").chips.map(\.accessibilityName) == ["곡 색 Red 필터 끄기"])
    }

    @Test func 폭이_모자라_칩_하나로_줄이면_개수를_보이고_모두_끈다고_말한다() {
        #expect(chips(rating: 3, color: "2").collapsedTitle == "필터 2")
        #expect(chips(rating: 3, color: "2").collapsedAccessibilityName == "필터 2개 모두 끄기")
        #expect(chips(rating: 3).collapsedTitle == "필터 1")
        #expect(chips(color: "2").collapsedAccessibilityName == "필터 1개 모두 끄기")
    }

    // MARK: 칩 끄기

    @Test func 스토어는_켠_조건을_칩으로_보인다() {
        let store = loadedStore()
        #expect(store.attributeFilterChips.isEmpty)
        store.minimumRating = 4
        store.colorFilter = "6"
        #expect(store.attributeFilterChips.chips.map(\.title) == ["★★★★ 이상", "곡 색 Aqua"])
    }

    @Test func 평점_칩을_끄면_곡_색_필터와_검색은_그대로다() {
        let store = loadedStore()
        store.search = "합성"
        store.minimumRating = 3
        store.colorFilter = "2"
        store.clearAttributeFilter(.rating(3))
        #expect(store.minimumRating == 0)
        #expect(store.colorFilter == "2")
        #expect(store.search == "합성")
        #expect(store.attributeFilterChips.chips.map(\.title) == ["곡 색 Red"])
    }

    @Test func 곡_색_칩을_끄면_평점_필터와_검색은_그대로다() {
        let store = loadedStore()
        store.search = "합성"
        store.minimumRating = 3
        store.colorFilter = "2"
        store.clearAttributeFilter(.color("2"))
        #expect(store.colorFilter == nil)
        #expect(store.minimumRating == 3)
        #expect(store.search == "합성")
        #expect(store.attributeFilterChips.chips.map(\.title) == ["★★★ 이상"])
    }

    @Test func 지금_켜지지_않은_조건의_칩을_끄려_해도_다른_조건은_그대로다() {
        // 칩을 누른 사이 다른 곳에서 조건이 바뀐 경우: 새로 켜진 조건을 함부로 끄지 않는다
        let store = loadedStore()
        store.minimumRating = 4
        store.colorFilter = "2"
        store.clearAttributeFilter(.rating(3))
        store.clearAttributeFilter(.color("7"))
        #expect(store.minimumRating == 4)
        #expect(store.colorFilter == "2")
    }

    @Test func 모두_끄면_칩이_사라지고_검색은_그대로다() {
        let store = loadedStore()
        store.search = "합성"
        store.minimumRating = 5
        store.colorFilter = "8"
        store.clearAttributeFilters()
        #expect(store.minimumRating == 0)
        #expect(store.colorFilter == nil)
        #expect(!store.isAttributeFiltered)
        #expect(store.attributeFilterChips.isEmpty)
        #expect(store.search == "합성")
    }

    // MARK: 필터가 걸리지 않는 목록

    @Test(arguments: [
        SidebarItem.filter(.all), .playlist("1"), .history("1"), .staged, .pending,
        .usb(.collection(volumeKey: "V")), .usb(.playlist(volumeKey: "V", id: 3)),
    ])
    func 곡_줄이_있는_목록에는_필터_단추가_있다(_ sidebar: SidebarItem) {
        let store = loadedStore()
        store.sidebar = sidebar
        #expect(store.listIsFilterable)
    }

    @Test func 중복_후보와_USB_쓰기_대기에는_필터_단추가_없다() {
        let store = loadedStore()
        store.sidebar = .duplicates
        #expect(!store.listIsFilterable)
        store.sidebar = .usb(.pending(volumeKey: "V"))
        #expect(!store.listIsFilterable)
    }

    @Test func 필터를_켠_채_필터가_없는_목록에_갔다_와도_조건과_칩이_남는다() {
        let store = loadedStore()
        store.minimumRating = 3
        store.sidebar = .duplicates
        // 단추·칩은 숨지만(머리 줄 배선은 ListHeaderLayoutTests가 본다) 조건은 꺼지지 않는다
        #expect(!store.listIsFilterable)
        #expect(store.minimumRating == 3)
        store.sidebar = .filter(.all)
        #expect(store.listIsFilterable)
        #expect(store.attributeFilterChips.chips.map(\.title) == ["★★★ 이상"])
    }
}
