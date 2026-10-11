import DJCDomain
import Testing

/// '재생 목록에 넣기…'의 고를 목록(#249): 이름·폴더 경로로 찾고, 찾지 않을 때는 최근 목록을 위에 둔다.
@Suite("재생 목록 고르기 목록")
struct PlaylistChoicesTests {
    typealias Item = PlaylistLayout.Item

    /// 트리 순서: 폴더 F 안의 A·B, 맨 위 C
    static let playlists: [(item: Item, path: [String])] = [
        (Item(id: "A", name: "Warm Up", parentID: "F"), ["클럽"]),
        (Item(id: "B", name: "Peak", parentID: "F"), ["클럽"]),
        (Item(id: "C", name: "집에서"), []),
    ]

    @Test func 찾지_않으면_최근_목록이_최근_순서로_위에_오고_나머지는_트리_순서다() {
        let choices = PlaylistChoices(playlists: Self.playlists, recentIDs: ["C", "B"]).choices(matching: "")
        #expect(choices.map(\.id) == ["C", "B", "A"])
        #expect(choices.map(\.recent) == [true, true, false])
        #expect(choices.map(\.path) == ["", "클럽", "클럽"])
    }

    @Test func 지금_없는_최근_목록은_빼고_같은_목록은_한_번만_보인다() {
        let choices = PlaylistChoices(playlists: Self.playlists, recentIDs: ["없는-목록", "A"]).choices(matching: "  ")
        #expect(choices.map(\.id) == ["A", "B", "C"])
        #expect(choices.map(\.recent) == [true, false, false])
    }

    @Test func 찾는_말은_대소문자_없이_폴더_경로와_이름에서_찾고_최근_표시를_하지_않는다() {
        let set = PlaylistChoices(playlists: Self.playlists, recentIDs: ["B"])
        #expect(set.choices(matching: " peak ").map(\.id) == ["B"])
        #expect(set.choices(matching: "peak").map(\.recent) == [false])
        #expect(set.choices(matching: "클럽").map(\.id) == ["A", "B"])
        #expect(set.choices(matching: "클럽 warm").map(\.id) == ["A"])
        #expect(set.choices(matching: "없음").isEmpty)
    }

    @Test func 폴더_경로는_화살표로_잇는다() {
        let nested = [(item: Item(id: "X", name: "목록", parentID: "G"), path: ["위", "아래"])]
        #expect(PlaylistChoices(playlists: nested, recentIDs: []).choices(matching: "").first?.path == "위 › 아래")
    }
}
