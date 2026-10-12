import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 재생 목록 묶음 편집(#260): 요청 여러 개를 지금 rekordbox 상태 + 초안에 차례로 얹어 계획하고, 막힌 요청은 이유와 함께 건너뛴다.
/// CLI `djc draft playlist`와 앱 사이드바(#261 다중 선택)가 같은 규칙을 부른다.
@Suite("재생 목록 초안 편집 — 묶음")
struct EditPlaylistsBatchTests {
    static func entries(_ ids: [String]) -> [PlaylistEntry] {
        ids.enumerated().map { PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element) }
    }

    /// 맨 위: 폴더(F1) · 세트(P1, 곡 1·2·3) · 자동(S1, 인텔리전트). 폴더 안: 세트(P2) · 유일(P3, 곡 4)
    static let rekordbox = PlaylistLayout([
        (PlaylistLayout.Item(id: "F1", name: "폴더", isFolder: true), 1),
        (PlaylistLayout.Item(id: "P1", name: "세트", entries: entries(["1", "2", "3"])), 2),
        (PlaylistLayout.Item(id: "S1", name: "자동", isSmart: true), 3),
        (PlaylistLayout.Item(id: "P2", name: "세트", parentID: "F1"), 1),
        (PlaylistLayout.Item(id: "P3", name: "유일", parentID: "F1", entries: entries(["4"])), 2),
    ])

    static func plan(_ requests: [PlaylistEditRequest], onto draft: PlaylistDraft = PlaylistDraft(), contentIDs: Set<String>? = nil,
                     allOrNothing: Bool = false) -> EditPlaylists.Batch {
        var count = 0
        return EditPlaylists.planning(requests, onto: draft, rekordbox: rekordbox, contentIDs: contentIDs, allOrNothing: allOrNothing) {
            count += 1
            return "k\(count)"
        }
    }

    @Test func 대상_글자는_root_ID_초안_목록_임시_이름_이름으로_읽는다() {
        #expect(PlaylistTarget("root") == .ref(.root))
        #expect(PlaylistTarget("123") == .ref(.id("123")))
        #expect(PlaylistTarget("new:abc") == .ref(.new("abc")))
        #expect(PlaylistTarget("@set") == .alias("set"))
        #expect(PlaylistTarget("name:세트 A") == .name("세트 A"))
        #expect(PlaylistTarget("name:세트 A").description == "name:세트 A" && PlaylistTarget("@set").description == "@set")
    }

    @Test func 막힌_요청은_이유와_함께_건너뛰고_나머지를_쌓는다() {
        let batch = Self.plan([
            .rename(PlaylistTarget("P1"), name: "새 이름"),
            .rename(PlaylistTarget("S1"), name: "고친 자동"),
            .delete(PlaylistTarget("없음")),
            .delete(PlaylistTarget("P3")),
        ])
        #expect(batch.outcomes.map(\.status) == [.stacked, .skipped, .skipped, .stacked])
        #expect(batch.outcomes[1].reason == "인텔리전트 재생 목록은 아직 쓰지 않습니다(rekordbox에서 고치세요)")
        #expect(batch.outcomes[2].reason == "rekordbox에서 재생 목록을 찾지 못했습니다")
        #expect(batch.draft.edits == [.rename(playlist: .id("P1"), name: "새 이름"), .delete(playlist: .id("P3"))])
        #expect(!batch.refused && batch.hasChanges)
        // 편집마다 지금 rekordbox 목록 상태를 base로 적는다(그 뒤 rekordbox에서 바뀌면 쓰기 미리 보기가 막는다)
        #expect(batch.draft.base["P1"]?.name == "세트" && batch.draft.base["P3"]?.entries == Self.entries(["4"]))
        #expect(batch.layout.item("P1")?.name == "새 이름" && batch.layout.item("P3") == nil)
    }

    @Test func 하나라도_막히면_아무것도_쌓지_않을_수_있다() {
        let before = Self.plan([.rename(PlaylistTarget("P3"), name: "이전")]).draft
        let batch = Self.plan([.rename(PlaylistTarget("P1"), name: "새 이름"), .delete(PlaylistTarget("S1"))], onto: before, allOrNothing: true)
        #expect(batch.refused && !batch.hasChanges)
        #expect(batch.draft == before)
        #expect(batch.outcomes.map(\.status) == [.stacked, .skipped])
        #expect(batch.firstSkipReason == "인텔리전트 재생 목록은 아직 쓰지 않습니다(rekordbox에서 고치세요)")
    }

    @Test func 같은_묶음에서_만든_목록은_임시_이름으로_가리킨다() throws {
        let batch = Self.plan([
            .create(name: "새 폴더", isFolder: true, parent: PlaylistTarget("root"), position: nil, alias: "f", tracks: []),
            .create(name: "피크", isFolder: false, parent: PlaylistTarget("@f"), position: nil, alias: "p", tracks: ["2", "1", "2"]),
            .addTracks(PlaylistTarget("@p"), contentIDs: ["3", "1"]),
            .move(PlaylistTarget("P1"), into: PlaylistTarget("@f"), position: .before(PlaylistTarget("@p"))),
        ])
        #expect(batch.outcomes.allSatisfy { $0.status == .stacked })
        #expect(batch.aliases == ["f": "new:k1", "p": "new:k2"])
        #expect(batch.outcomes.map(\.playlistID) == ["new:k1", "new:k2", "new:k2", "P1"])
        #expect(batch.layout.childIDs(of: "root").first == "new:k1")
        #expect(batch.layout.childIDs(of: "new:k1") == ["P1", "new:k2"])
        // 만든 목록에 넣는 곡도 앱처럼 이미 든 곡은 한 번만 넣는다
        #expect(batch.layout.item("new:k2")?.trackIDs == ["2", "1", "3"])
        #expect(batch.outcomes[2].ignored == ["1"])
        #expect(batch.draft.edits == [
            .create(key: "k1", name: "새 폴더", isFolder: true, parent: .root),
            .create(key: "k2", name: "피크", isFolder: false, parent: .new("k1")),
            .addTracks(playlist: .new("k2"), contentIDs: ["2", "1"]),
            .addTracks(playlist: .new("k2"), contentIDs: ["3"]),
            .move(playlist: .id("P1"), into: .new("k1")),
            .reorder(playlist: .id("P1"), index: 0),
        ])
    }

    @Test func 만들지_못한_목록을_가리키는_요청과_겹친_임시_이름은_막는다() {
        let batch = Self.plan([
            .create(name: "안", isFolder: false, parent: PlaylistTarget("P1"), position: nil, alias: "x", tracks: []),
            .addTracks(PlaylistTarget("@x"), contentIDs: ["1"]),
            .create(name: "하나", isFolder: false, parent: PlaylistTarget("root"), position: nil, alias: "y", tracks: []),
            .create(name: "둘", isFolder: false, parent: PlaylistTarget("root"), position: nil, alias: "y", tracks: []),
        ])
        #expect(batch.outcomes.map(\.status) == [.skipped, .skipped, .stacked, .skipped])
        #expect(batch.outcomes[0].reason == "폴더가 아닌 재생 목록(세트) 안에는 넣을 수 없습니다")
        #expect(batch.outcomes[1].reason?.contains("@x") == true)
        #expect(batch.outcomes[3].reason?.contains("@y") == true)
        // 만들지 못한 목록의 `new:키`는 결과에 내지 않는다(뒤 명령이 그 ID로 이어 편집하지 않게)
        #expect(batch.outcomes[0].playlistID == nil && batch.outcomes[3].playlistID == nil)
        #expect(batch.aliases == ["y": "new:k2"])
    }

    @Test func 이름으로_가리키되_그_차례_모양에서_하나일_때만_고른다() {
        let batch = Self.plan([
            .rename(PlaylistTarget("name:세트"), name: "둘"),
            .addTracks(PlaylistTarget("name:유일"), contentIDs: ["1"]),
            .rename(PlaylistTarget("name:유일"), name: "바꾼 이름"),
            .addTracks(PlaylistTarget("name:바꾼 이름"), contentIDs: ["2"]),
            .delete(PlaylistTarget("name:없는 이름")),
        ])
        #expect(batch.outcomes.map(\.status) == [.skipped, .stacked, .stacked, .stacked, .skipped])
        #expect(batch.outcomes[0].reason?.contains("2개") == true)
        #expect(batch.outcomes[4].reason?.contains("없는 이름") == true)
        #expect(batch.layout.item("P3")?.trackIDs == ["4", "1", "2"])
    }

    @Test func 컬렉션에_없는_곡과_이미_든_곡은_넣지_않는다() {
        let batch = Self.plan([
            .addTracks(PlaylistTarget("P1"), contentIDs: ["9"]),
            .addTracks(PlaylistTarget("P1"), contentIDs: ["1", "2"]),
            .addTracks(PlaylistTarget("P1"), contentIDs: ["1", "4"]),
            .create(name: "새", isFolder: false, parent: PlaylistTarget("root"), position: nil, alias: nil, tracks: ["4", "9"]),
        ], contentIDs: ["1", "2", "3", "4"])
        #expect(batch.outcomes.map(\.status) == [.skipped, .unchanged, .stacked, .skipped])
        #expect(batch.outcomes[0].reason == "rekordbox 컬렉션에 없는 곡입니다(ContentID 9)")
        #expect(batch.outcomes[1].ignored == ["1", "2"] && batch.outcomes[2].ignored == ["1"])
        #expect(batch.draft.edits == [.addTracks(playlist: .id("P1"), contentIDs: ["4"])])
    }

    @Test func 곡_빼기는_그_곡의_모든_자리를_빼고_목록에_없는_곡은_알린다() {
        let draft = Self.plan([.addTracks(PlaylistTarget("P1"), contentIDs: ["2"])]).draft
        #expect(draft.edits == [])
        let batch = Self.plan([
            .removeTracks(PlaylistTarget("P1"), contentIDs: ["2", "8"]),
            .removeTracks(PlaylistTarget("P1"), contentIDs: ["8"]),
            .removeTracks(PlaylistTarget("F1"), contentIDs: ["1"]),
        ])
        #expect(batch.outcomes.map(\.status) == [.stacked, .skipped, .skipped])
        #expect(batch.outcomes[0].ignored == ["8"])
        #expect(batch.outcomes[2].reason == "폴더에는 곡을 넣거나 뺄 수 없습니다")
        #expect(batch.layout.item("P1")?.trackIDs == ["1", "3"])
    }

    @Test func 곡_순서는_준_순서대로_놓고_목록_순서면_편집_하나다() {
        // 목록 순서(1·3)를 2 앞으로: 앱의 끌어 옮기기와 같은 편집 하나
        let listed = Self.plan([.moveTracks(PlaylistTarget("P1"), contentIDs: ["1", "3"], before: "2")])
        #expect(listed.draft.edits == [.moveTracks(playlist: .id("P1"), entries: [PlaylistEntry(trackNo: 1, contentID: "1"),
                                                                                    PlaylistEntry(trackNo: 3, contentID: "3")], to: 1)])
        #expect(listed.layout.item("P1")?.trackIDs == ["1", "3", "2"])
        // 다른 순서(3·1)를 맨 끝으로: 곡마다 차례로 옮긴다
        let given = Self.plan([.moveTracks(PlaylistTarget("P1"), contentIDs: ["3", "1"], before: nil)])
        #expect(given.layout.item("P1")?.trackIDs == ["2", "3", "1"])
        #expect(given.outcomes.first?.status == .stacked)
        // 이미 그 자리면 바뀌지 않고, 앞에 둘 곡이 목록에 없으면 막는다
        let same = Self.plan([.moveTracks(PlaylistTarget("P1"), contentIDs: ["2", "3"], before: nil),
                              .moveTracks(PlaylistTarget("P1"), contentIDs: ["1"], before: "9"),
                              .moveTracks(PlaylistTarget("P1"), contentIDs: ["9"], before: nil)])
        #expect(same.outcomes.map(\.status) == [.unchanged, .skipped, .skipped])
    }

    @Test func 자리는_부모_안_번호나_앞_항목으로_준다() {
        let batch = Self.plan([
            .create(name: "끝", isFolder: false, parent: PlaylistTarget("root"), position: .index(99), alias: "end", tracks: []),
            .create(name: "가운데", isFolder: false, parent: PlaylistTarget("root"), position: .before(PlaylistTarget("P1")), alias: nil, tracks: []),
            .move(PlaylistTarget("P3"), into: nil, position: .index(0)),
            .move(PlaylistTarget("P2"), into: PlaylistTarget("root"), position: nil),
            .move(PlaylistTarget("P1"), into: nil, position: .before(PlaylistTarget("P1"))),
            // 다른 폴더로 옮기며 자기 앞을 주면 그 폴더 안 자리가 아니다
            .move(PlaylistTarget("P1"), into: PlaylistTarget("F1"), position: .before(PlaylistTarget("P1"))),
            .move(PlaylistTarget("S1"), into: PlaylistTarget("F1"), position: .before(PlaylistTarget("P1"))),
        ])
        #expect(batch.outcomes.map(\.status) == [.stacked, .stacked, .stacked, .stacked, .unchanged, .skipped, .skipped])
        #expect(batch.outcomes[5].reason == "자리로 준 항목이 그 폴더 안에 없습니다")
        #expect(batch.layout.childIDs(of: "root") == ["F1", "new:k2", "P1", "S1", "new:k1", "P2"])
        #expect(batch.layout.childIDs(of: "F1") == ["P3"])
    }

    @Test func 기존_초안의_새_목록과_막힌_편집_위에_쌓는다() throws {
        var existing = PlaylistDraft()
        try existing.append(.create(key: "old", name: "앱에서 만든 폴더", isFolder: true, parent: .root), rekordbox: Self.rekordbox)
        let batch = Self.plan([.create(name: "안", isFolder: false, parent: PlaylistTarget("new:old"), position: nil, alias: nil, tracks: []),
                               .rename(PlaylistTarget("new:old"), name: "고친 폴더")], onto: existing)
        #expect(batch.outcomes.map(\.status) == [.stacked, .stacked])
        // 같은 묶음에서 만든 목록의 이름 바꾸기는 만들기에 합친다(앱 초안 규칙)
        #expect(batch.draft.edits == [.create(key: "old", name: "고친 폴더", isFolder: true, parent: .root),
                                      .create(key: "k1", name: "안", isFolder: false, parent: .new("old"))])
    }

    @Test func 이름_바꾸기는_앞뒤_공백을_빼고_같은_이름이면_바뀌지_않는다() {
        let batch = Self.plan([.rename(PlaylistTarget("P1"), name: "  세트 "), .rename(PlaylistTarget("P1"), name: "  ")])
        #expect(batch.outcomes.map(\.status) == [.unchanged, .skipped])
        #expect(batch.outcomes[1].reason == "이름을 적어 주세요")
        #expect(!batch.hasChanges)
    }
}
