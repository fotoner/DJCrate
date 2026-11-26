@testable import DJCrate
import DJCDomain
import Testing

/// 머리 줄의 켜진 필터 칩(#339·#351): 켠 조건 → 칩, 칩 끄기, 줄인 칩 글, 모두 끄기, 필터가 걸리지 않는 목록.
/// 화면(폭에 따라 칩 하나로 줄이기)은 자가 테스트·`ListHeaderLayoutTests`가, 본문 다시 계산은 `LayoutRecomputeTests`가 본다.
@MainActor
@Suite("필터 칩 — 켠 조건을 칩으로, 칩 끄기")
struct AttributeFilterChipsTests {
    private let colors = TrackColor.rekordboxDefaults

    private func chips(_ filter: TrackFilter) -> AttributeFilterChips {
        AttributeFilterChips(filter: filter, colors: colors)
    }

    private func loadedStore() -> LibraryStore {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil))
        store.phase = .loaded
        return store
    }

    private let three = TrackFilter(bpm: BPMRange(lower: 120, upper: 130), key: KeyCondition("8A", mode: .compatible), genre: "House")

    // MARK: 켠 조건 → 칩

    @Test func 켠_조건이_없으면_칩이_없다() {
        let none = chips(TrackFilter())
        #expect(none.isEmpty)
        #expect(none.chips.isEmpty)
    }

    @Test(arguments: [(1, "★ 이상"), (3, "★★★ 이상"), (4, "★★★★ 이상"), (5, "★★★★★")])
    func 평점_칩은_별과_이상으로_읽고_별_다섯은_별만_보인다(count: Int, title: String) {
        let result = chips(TrackFilter(minimumRating: count))
        #expect(result.chips.map(\.title) == [title])
        #expect(result.chips.map(\.condition) == [.rating(count)])
    }

    @Test func 곡_색_칩은_rekordbox_색_이름을_보인다() {
        let result = chips(TrackFilter(colorIDs: ["2"]))
        #expect(result.chips.map(\.title) == ["곡 색 Red"])
        #expect(result.chips.map(\.condition) == [.color("2")])
        // 라이브러리에서 이름을 바꿔 읽었으면 바꾼 이름을 따른다
        let renamed = AttributeFilterChips(filter: TrackFilter(colorIDs: ["2"]), colors: [TrackColor(id: "2", name: "Opener")])
        #expect(renamed.chips.map(\.title) == ["곡 색 Opener"])
    }

    @Test func 곡_색을_여럿_고르면_색마다_칩이_하나이고_rekordbox_색_순서다() {
        let result = chips(TrackFilter(colorIDs: ["7", "2", "6"]))
        #expect(result.chips.map(\.title) == ["곡 색 Red", "곡 색 Aqua", "곡 색 Blue"])
        // 목록에 없는 색 번호(지운 색)도 끌 수 있게 뒤에 번호 그대로 둔다
        #expect(chips(TrackFilter(colorIDs: ["2", "99"])).chips.map(\.title) == ["곡 색 Red", "곡 색 99"])
    }

    @Test func BPM_키_장르_칩은_조건을_글로_말한다() {
        #expect(chips(three).chips.map(\.title) == ["BPM 120–130", "어울리는 키 8A", "장르 House"])
        #expect(chips(TrackFilter(bpm: BPMRange(lower: 127.5, upper: nil))).chips.map(\.title) == ["BPM 127.5 이상"])
        #expect(chips(TrackFilter(bpm: BPMRange(lower: nil, upper: 100))).chips.map(\.title) == ["BPM 100 이하"])
        #expect(chips(TrackFilter(key: KeyCondition("Am"))).chips.map(\.title) == ["키 8A"])
        // Camelot으로 바꿀 수 없는 값은 적은 글자 그대로
        #expect(chips(TrackFilter(key: KeyCondition("Atonal"))).chips.map(\.title) == ["키 Atonal"])
    }

    @Test func 조건_순서는_필터_창의_구역_순서다() {
        let all = TrackFilter(minimumRating: 3, colorIDs: ["2", "7"], bpm: BPMRange(lower: 120, upper: 130), key: KeyCondition("8A"), genre: "House")
        #expect(chips(all).chips.map(\.title) == ["BPM 120–130", "키 8A", "장르 House", "★★★ 이상", "곡 색 Red", "곡 색 Blue"])
    }

    // MARK: 접근성 이름

    @Test func 칩의_접근성_이름은_조건_전체를_읽고_끈다고_말한다() {
        // 별 글자(★)는 낭독이 어색해 별 개수로 읽는다
        #expect(chips(TrackFilter(minimumRating: 3)).chips.map(\.accessibilityName) == ["평점 별 3개 이상 필터 끄기"])
        #expect(chips(TrackFilter(minimumRating: 5)).chips.map(\.accessibilityName) == ["평점 별 5개 필터 끄기"])
        #expect(chips(TrackFilter(colorIDs: ["2"])).chips.map(\.accessibilityName) == ["곡 색 Red 필터 끄기"])
        #expect(chips(three).chips.map(\.accessibilityName) == ["BPM 120–130 필터 끄기", "어울리는 키 8A 필터 끄기", "장르 House 필터 끄기"])
    }

    // MARK: 줄인 칩

    @Test func 폭이_모자라_칩_하나로_줄이면_첫_조건_글을_남기고_나머지는_개수로_말한다() {
        #expect(chips(three).collapsedTitle == "BPM 120–130 외 2")
        #expect(chips(TrackFilter(minimumRating: 3, colorIDs: ["2"])).collapsedTitle == "★★★ 이상 외 1")
        // 줄인 칩을 눌러 목록을 여는 이름. 조건 하나는 그 조건 그대로다
        #expect(chips(three).collapsedAccessibilityName == "필터 3개, 목록 열기")
        #expect(chips(TrackFilter(minimumRating: 3)).collapsedTitle == "★★★ 이상")
        #expect(chips(TrackFilter(minimumRating: 3)).collapsedAccessibilityName == "평점 별 3개 이상 필터 끄기")
    }

    @Test func 긴_첫_조건은_뒤를_줄여_외_N이_잘리지_않게_한다() {
        let long = TrackFilter(bpm: BPMRange(lower: 120, upper: 130), genre: "Progressive House Extended Mix Collection")
        // 첫 조건이 짧으면 그대로, 길면 뒤를 …로 줄인 글에 「외 N」을 붙인다
        #expect(chips(long).collapsedTitle == "BPM 120–130 외 1")
        let genreFirst = TrackFilter(minimumRating: 3, genre: "Progressive House Extended Mix Collection")
        let title = chips(genreFirst).collapsedTitle
        #expect(title.hasSuffix(" 외 1") && title.contains("…") && title.hasPrefix("장르 Progressive Ho"))
        #expect(title.count < "장르 Progressive House Extended Mix Collection 외 1".count)
        // 한글은 영문의 두 배 폭으로 센다
        #expect(AttributeFilterChips.clipped("가나다라마바사아자차카", units: 8) == "가나다…")
        #expect(AttributeFilterChips.clipped("abcdefghij", units: 8) == "abcdefg…" && AttributeFilterChips.clipped("abcdefgh", units: 8) == "abcdefgh")
    }

    // MARK: 칩 끄기

    @Test func 스토어는_켠_조건을_칩으로_보인다() {
        let store = loadedStore()
        #expect(store.attributeFilterChips.isEmpty)
        store.minimumRating = 4
        store.colorFilters = ["6"]
        #expect(store.attributeFilterChips.chips.map(\.title) == ["★★★★ 이상", "곡 색 Aqua"])
    }

    @Test func 평점_칩을_끄면_다른_조건과_검색은_그대로다() {
        let store = loadedStore()
        store.search = "합성"
        store.filter = TrackFilter(minimumRating: 3, colorIDs: ["2"], bpm: BPMRange(lower: 120, upper: 130))
        store.clearAttributeFilter(.rating(3))
        #expect(store.minimumRating == 0)
        #expect(store.colorFilters == ["2"] && store.filter.bpm == BPMRange(lower: 120, upper: 130))
        #expect(store.search == "합성")
        #expect(store.attributeFilterChips.chips.map(\.title) == ["BPM 120–130", "곡 색 Red"])
    }

    @Test func 조건마다_칩_하나가_그_조건만_끈다() {
        let store = loadedStore()
        store.search = "합성"
        let all = TrackFilter(minimumRating: 3, colorIDs: ["2", "7"], bpm: BPMRange(lower: 120, upper: 130), key: KeyCondition("8A", mode: .compatible), genre: "House")
        func cleared(_ condition: AttributeFilterChip.Condition) -> [String] {
            store.filter = all
            store.clearAttributeFilter(condition)
            return store.attributeFilterChips.chips.map(\.title)
        }
        #expect(cleared(.bpm(BPMRange(lower: 120, upper: 130))) == ["어울리는 키 8A", "장르 House", "★★★ 이상", "곡 색 Red", "곡 색 Blue"])
        #expect(cleared(.key(KeyCondition("8A", mode: .compatible))) == ["BPM 120–130", "장르 House", "★★★ 이상", "곡 색 Red", "곡 색 Blue"])
        #expect(cleared(.genre("House")) == ["BPM 120–130", "어울리는 키 8A", "★★★ 이상", "곡 색 Red", "곡 색 Blue"])
        #expect(cleared(.rating(3)) == ["BPM 120–130", "어울리는 키 8A", "장르 House", "곡 색 Red", "곡 색 Blue"])
        // 곡 색은 그 색만 빠지고 다른 색은 남는다
        #expect(cleared(.color("2")) == ["BPM 120–130", "어울리는 키 8A", "장르 House", "★★★ 이상", "곡 색 Blue"])
        #expect(store.search == "합성")
    }

    @Test func 지금_켜지지_않은_조건의_칩을_끄려_해도_다른_조건은_그대로다() {
        // 칩을 누른 사이 다른 곳에서 조건이 바뀐 경우: 새로 켜진 조건을 함부로 끄지 않는다
        let store = loadedStore()
        store.filter = TrackFilter(minimumRating: 4, colorIDs: ["2"], bpm: BPMRange(lower: 100, upper: 110),
                                   key: KeyCondition("9A"), genre: "Techno")
        let before = store.filter
        store.clearAttributeFilter(.rating(3))
        store.clearAttributeFilter(.color("7"))
        store.clearAttributeFilter(.bpm(BPMRange(lower: 120, upper: 130)))
        store.clearAttributeFilter(.key(KeyCondition("9A", mode: .compatible)))
        store.clearAttributeFilter(.genre("House"))
        #expect(store.filter == before)
    }

    @Test func 모두_끄면_칩이_사라지고_검색은_그대로다() {
        let store = loadedStore()
        store.search = "합성"
        store.filter = TrackFilter(minimumRating: 5, colorIDs: ["8"], bpm: BPMRange(lower: 90, upper: nil), key: KeyCondition("1A"), genre: "House")
        store.clearAttributeFilters()
        #expect(store.filter == TrackFilter())
        #expect(!store.isAttributeFiltered)
        #expect(store.attributeFilterChips.isEmpty)
        #expect(store.search == "합성")
    }

    // MARK: BPM 칸의 글자

    @Test func BPM_칸의_글자는_비면_열림_숫자면_값_아니면_받지_않는다() {
        #expect(FilterBPMText.parse("") == .empty && FilterBPMText.parse("  ") == .empty)
        #expect(FilterBPMText.parse("128") == .value(128) && FilterBPMText.parse(" 127.5 ") == .value(127.5) && FilterBPMText.parse("127,5") == .value(127.5))
        for text in ["abc", "0", "-3", "1e999", "12 8", "nan"] { #expect(FilterBPMText.parse(text) == .invalid, "\(text)") }
        #expect(FilterBPMText.text(128) == "128" && FilterBPMText.text(127.5) == "127.5" && FilterBPMText.text(nil) == "")
    }

    /// 칸 하나가 숫자가 아니어도 다른 칸의 값은 받고, 칸이 지금 조건을 그대로 보이면 건드리지 않는다(독립 리뷰가 짚은 두 경우)
    @Test func BPM_칸은_칸마다_따로_받고_잘못된_칸은_지금_값을_둔다() {
        #expect(FilterBPMText.resolve("130", current: nil) == 130 && FilterBPMText.resolve("", current: 120) == nil)
        // 숫자가 아니거나 0 이하면 그 칸만 받지 않고 지금 값을 둔다
        #expect(FilterBPMText.resolve("abc", current: 120) == 120 && FilterBPMText.resolve("0", current: nil) == nil)
        // 최소 칸이 잘못돼도 최대 칸의 값은 조건에 들어간다
        let current = BPMRange(lower: 120, upper: nil)
        #expect(BPMRange(lower: FilterBPMText.resolve("abc", current: current.lower), upper: FilterBPMText.resolve("130", current: current.upper))
                == BPMRange(lower: 120, upper: 130))
        // 소수 셋째 자리 값은 칸에 둘째 자리까지만 보인다. 창을 다시 열어 그 글자가 칸에 실려도 조건은 그대로다
        #expect(FilterBPMText.text(127.123) == "127.12")
        #expect(FilterBPMText.resolve(FilterBPMText.text(127.123), current: 127.123) == 127.123)
        // 칸의 글자를 사용자가 바꾸면 그 값을 받는다
        #expect(FilterBPMText.resolve("127.5", current: 127.123) == 127.5)
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
