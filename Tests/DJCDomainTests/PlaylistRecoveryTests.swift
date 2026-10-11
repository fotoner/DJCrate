import DJCDomain
import Foundation
import Testing

@Suite("막힌 재생 목록 초안 다시 적용")
struct PlaylistRecoveryTests {
    func layout(_ tracks: [String] = ["1", "2"], name: String = "원래 목록", other: String = "다른 목록") -> PlaylistLayout {
        PlaylistLayout([
            (PlaylistDraftTests.item("A", name, tracks: tracks), 1),
            (PlaylistDraftTests.item("B", other, tracks: ["3"]), 2),
        ])
    }

    @Test func 선택한_목록만_현재_기준으로_다시_적용하고_다시_바뀌면_막는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("A"), name: "내 이름"), rekordbox: layout())
        try draft.append(.rename(playlist: .id("B"), name: "다른 편집"), rekordbox: layout())
        let current = layout(["2", "1"], name: "외부 이름", other: "외부 다른 이름")
        let recovered = draft.recovering(playlist: "A", rekordbox: current, contentIDs: ["1", "2", "3"])
        #expect(recovered.reapplied == [0] && recovered.refused.isEmpty)
        #expect(recovered.draft.project(onto: current).blocked.map { $0 != nil } == [false, true])
        #expect(recovered.draft.project(onto: current).layout.item("A")?.name == "내 이름")
        #expect(recovered.draft.steps[1] == draft.steps[1])
        #expect(recovered.draft.base["A"]?.name == "외부 이름")
        #expect(recovered.draft.project(onto: layout(name: "다시 변경")).blocked[0] != nil)
        let decoded = try JSONDecoder().decode(PlaylistDraft.self, from: JSONEncoder().encode(recovered.draft))
        #expect(decoded == recovered.draft)
    }

    @Test func 곡의_새_자리를_찾고_연속_편집을_순서대로_다시_쌓는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.removeTracks(playlist: .id("A"), entries: [.init(trackNo: 1, contentID: "1")]), rekordbox: layout())
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["3"]), rekordbox: layout())
        let current = layout(["2", "4", "1"])
        let recovered = draft.recovering(playlist: "A", rekordbox: current, contentIDs: ["1", "2", "3", "4"])
        #expect(recovered.reapplied == [0, 1])
        #expect(recovered.draft.project(onto: current).layout.item("A")?.trackIDs == ["2", "4", "3"])
        #expect(recovered.draft.base["A"]?.entries == current.item("A")?.entries)
    }

    @Test func 사라진_목록_컬렉션_곡_목록_곡은_남기고_가능한_편집만_고른다() throws {
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["gone"]), rekordbox: layout())
        try draft.append(.removeTracks(playlist: .id("A"), entries: [.init(trackNo: 1, contentID: "1")]), rekordbox: layout())
        try draft.append(.rename(playlist: .id("A"), name: "내 이름"), rekordbox: layout())
        let current = layout(["2"])
        let recovered = draft.recovering(playlist: "A", rekordbox: current, contentIDs: ["2", "3"])
        #expect(recovered.reapplied == [2] && Set(recovered.refused.keys) == [0, 1])
        #expect(recovered.draft.edits == draft.edits)
        #expect(recovered.draft.project(onto: current).blocked.map { $0 != nil } == [true, true, false])
        let missing = draft.recovering(playlist: "A", rekordbox: PlaylistLayout(), contentIDs: [])
        #expect(missing.reapplied.isEmpty && missing.refused.count == 3 && missing.draft == draft)
    }

    @Test func 중복곡의_대응이_모호하면_다시_적용하지_않는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.removeTracks(playlist: .id("A"), entries: [.init(trackNo: 1, contentID: "1")]), rekordbox: layout(["1", "1", "2"]))
        let recovered = draft.recovering(playlist: "A", rekordbox: layout(["1", "2", "1"]), contentIDs: ["1", "2"])
        #expect(recovered.reapplied.isEmpty && recovered.refused.count == 1 && recovered.draft == draft)
    }

    @Test func 목록_기준이_같아도_넣을_곡이_사라진_편집은_비교한다() throws {
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["3"]), rekordbox: layout())
        let recovered = draft.recovering(playlist: "A", rekordbox: layout(), contentIDs: ["1", "2"])
        #expect(recovered.reapplied.isEmpty && recovered.refused.count == 1 && recovered.draft == draft)
    }

    @Test func 목록에_항목이_남아도_컬렉션에서_사라진_곡의_편집은_남긴다() throws {
        var draft = PlaylistDraft()
        try draft.append(.removeTracks(playlist: .id("A"), entries: [.init(trackNo: 1, contentID: "1")]), rekordbox: layout())
        let recovered = draft.recovering(playlist: "A", rekordbox: layout(name: "외부 이름"), contentIDs: ["2", "3"])
        #expect(recovered.reapplied.isEmpty && recovered.refused.count == 1 && recovered.draft == draft)
    }

    @Test func 순서_편집도_현재의_유일한_곡_자리로_연결한다() throws {
        var draft = PlaylistDraft()
        try draft.append(.moveTracks(playlist: .id("A"), entries: [.init(trackNo: 2, contentID: "2")], to: 1), rekordbox: layout())
        let current = layout(["3", "1", "2"])
        let recovered = draft.recovering(playlist: "A", rekordbox: current, contentIDs: ["1", "2", "3"])
        #expect(recovered.reapplied == [0])
        #expect(recovered.draft.project(onto: current).layout.item("A")?.trackIDs == ["2", "3", "1"])
    }

    @Test func 사라진_부모와_인텔리전트_대상은_그대로_막는다() throws {
        let original = PlaylistDraftTests.library()
        var draft = PlaylistDraft()
        try draft.append(.create(key: "child", name: "새 목록", isFolder: false, parent: .id("F")), rekordbox: original)
        try draft.append(.addTracks(playlist: .new("child"), contentIDs: ["1"]), rekordbox: original)
        let missing = draft.recovering(playlist: "new:child", rekordbox: layout(), contentIDs: ["1", "2", "3"])
        #expect(missing.reapplied.isEmpty && missing.refused.count == 2 && missing.draft == draft)
        var rename = PlaylistDraft()
        try rename.append(.rename(playlist: .id("A"), name: "내 이름"), rekordbox: original)
        let smart = PlaylistLayout([(PlaylistDraftTests.item("A", "스마트", smart: true), 1)])
        #expect(rename.recovering(playlist: "A", rekordbox: smart, contentIDs: []).reapplied.isEmpty)
    }

    @Test func 폴더_지우기는_현재_하위_목록을_새_기준으로_잡는다() throws {
        let original = PlaylistDraftTests.library()
        var draft = PlaylistDraft()
        try draft.append(.delete(playlist: .id("F")), rekordbox: original)
        let current = PlaylistDraftTests.library(extra: [(PlaylistDraftTests.item("D", "외부 추가", parent: "F", tracks: ["6"]), 3)])
        let recovered = draft.recovering(playlist: "F", rekordbox: current, contentIDs: ["1", "2", "3", "4", "5", "6"])
        #expect(recovered.reapplied == [0] && recovered.draft.base["D"]?.entries == current.item("D")?.entries)
        #expect(recovered.draft.project(onto: current).layout.item("F") == nil)
    }

    @Test func 공유하는_부모_기준도_고르지_않은_편집에는_그대로_남는다() throws {
        let original = layout()
        var draft = PlaylistDraft()
        try draft.append(.reorder(playlist: .id("A"), index: 1), rekordbox: original)
        try draft.append(.reorder(playlist: .id("B"), index: 0), rekordbox: original)
        var current = original
        try current.apply(.create(key: "external", name: "외부 목록", isFolder: false, parent: .root))
        let recovered = draft.recovering(playlist: "A", rekordbox: current, contentIDs: ["1", "2", "3"])
        #expect(recovered.reapplied == [0])
        #expect(recovered.draft.project(onto: current).blocked.map { $0 != nil } == [false, true])
        #expect(recovered.draft.steps[1] == draft.steps[1])
        let both = recovered.draft.recovering(playlist: "B", rekordbox: current, contentIDs: ["1", "2", "3"])
        #expect(both.draft.project(onto: current).blocked.allSatisfy { $0 == nil })
    }
}
