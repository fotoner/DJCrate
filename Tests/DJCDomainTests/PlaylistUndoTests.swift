@testable import DJCDomain
import Foundation
import Testing

/// 저장 뒤 ⌘Z(R12, #405)의 재생 목록 몫: 편집 한 번 전후에 보이던 목록(rekordbox + 초안)을 견줘, 지금 보이는 목록 위에서 그 편집을
/// 거꾸로 하는 단계를 만든다. 범위는 이름·순서(목록 순서·곡 순서)·곡 넣기다. 새로 만든 목록은 쓰기 결과의 연결 ID로 찾는다.
/// 그 밖(만들기·지우기·폴더 옮기기·곡 빼기)은 되돌리지 않고, 대상이 지금 그 편집 뒤 모양이 아니면(바깥에서 바뀜) 정할 수 없다.
@Suite("재생 목록 저장 뒤 ⌘Z 역편집")
struct PlaylistUndoTests {
    static func entries(_ ids: [String]) -> [PlaylistEntry] {
        ids.enumerated().map { PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element) }
    }

    static func layout(_ items: [(id: String, name: String, tracks: [String])], parent: String = PlaylistLayout.root) -> PlaylistLayout {
        PlaylistLayout(items.enumerated().map { (PlaylistLayout.Item(id: $0.element.id, name: $0.element.name, parentID: parent,
                                                                      entries: entries($0.element.tracks)), $0.offset + 1) })
    }

    /// 편집 결과를 지금 보이는 목록에 얹으면 편집 전 모양이 되는지
    static func applying(_ edits: [PlaylistEdit], to layout: PlaylistLayout) throws -> PlaylistLayout {
        var layout = layout
        for edit in edits { try layout.apply(edit) }
        return layout
    }

    @Test func 이름을_바꾼_편집은_이름을_편집_전으로_되돌린다() throws {
        let before = Self.layout([("A", "가", []), ("B", "나", [])])
        let after = Self.layout([("A", "새 이름", []), ("B", "나", [])])
        let result = PlaylistUndo.reversing(before: before, after: after, current: after, ids: [:])
        #expect(result == .edits([.rename(playlist: .id("A"), name: "가")]))
    }

    @Test func 새로_만든_목록은_쓰기_결과의_연결_ID로_찾는다() throws {
        let before = Self.layout([("new:k", "만든 목록", ["1"])])
        let after = Self.layout([("new:k", "만든 목록", ["1", "2", "3"])])
        // 쓴 뒤 rekordbox에는 실제 ID 900으로 있다
        let current = Self.layout([("900", "만든 목록", ["1", "2", "3"])])
        let result = PlaylistUndo.reversing(before: before, after: after, current: current, ids: ["new:k": "900"])
        guard case let .edits(edits) = result else { Issue.record("\(result)"); return }
        #expect(edits == [.removeTracks(playlist: .id("900"), entries: [PlaylistEntry(trackNo: 2, contentID: "2"), PlaylistEntry(trackNo: 3, contentID: "3")])])
        #expect(try Self.applying(edits, to: current).item("900")?.trackIDs == ["1"])
    }

    @Test func 목록_순서를_바꾼_편집은_편집_전_순서로_되돌린다() throws {
        let before = Self.layout([("A", "가", []), ("B", "나", []), ("C", "다", [])])
        let after = Self.layout([("C", "다", []), ("A", "가", []), ("B", "나", [])])
        guard case let .edits(edits) = PlaylistUndo.reversing(before: before, after: after, current: after, ids: [:]) else {
            Issue.record("되돌리지 못함"); return
        }
        #expect(try Self.applying(edits, to: after).childIDs(of: PlaylistLayout.root) == ["A", "B", "C"])
    }

    // MARK: - 컨실 2라운드 G·H

    /// 목록 순서 역편집은 옮긴 목록 하나를 원래 자리로 옮기는 단계 하나다: 옮길 수 없는 형제(인텔리전트 목록)를 건드리지 않는다(G·S15)
    @Test func 목록_순서_역편집은_옮긴_목록_하나만_원래_자리로_옮긴다() throws {
        func layout(_ ids: [String]) -> PlaylistLayout {
            PlaylistLayout(ids.enumerated().map { (PlaylistLayout.Item(id: $0.element, name: $0.element, isSmart: $0.element == "S"), $0.offset + 1) })
        }
        let before = layout(["A", "S", "B", "C"]), after = layout(["C", "A", "S", "B"])
        let result = PlaylistUndo.reversing(before: before, after: after, current: after, ids: [:])
        #expect(result == .edits([.reorder(playlist: .id("C"), index: 3)]))
        if case let .edits(edits) = result { #expect(try Self.applying(edits, to: after).childIDs(of: PlaylistLayout.root) == ["A", "S", "B", "C"]) }
    }

    /// 두 목록이 자리를 바꾼 모양은 어느 쪽을 옮겨도 되돌아간다: 그 편집이 옮긴 목록(B)을 원래 자리로 옮긴다(쓰기 결과·연결 갱신 대상이 옮긴 목록이다, 컨실 3라운드 G)
    @Test func 순서_역편집은_그_편집이_옮긴_목록을_되돌린다() throws {
        let before = Self.layout([("A", "가", []), ("B", "나", [])]), after = Self.layout([("B", "나", []), ("A", "가", [])])
        let result = PlaylistUndo.reversing(before: before, after: after, current: after, ids: [:], moved: ["B"])
        #expect(result == .edits([.reorder(playlist: .id("B"), index: 1)]))
    }

    /// 목록 하나를 옮긴 것으로 나타낼 수 없는 순서 바꿈은 되돌리지 않는다(⌘Z를 끈다, G)
    @Test func 한_단계로_되돌릴_수_없는_목록_순서는_되돌리지_않는다() {
        let before = Self.layout([("A", "가", []), ("B", "나", []), ("C", "다", []), ("D", "라", [])])
        let after = Self.layout([("B", "나", []), ("A", "가", []), ("D", "라", []), ("C", "다", [])])
        #expect(PlaylistUndo.reversing(before: before, after: after, current: after, ids: [:]) == .unsupported)
    }

    /// 역편집은 한 목록에 닿는 단계로만 만든다: 여러 목록에 걸치면 자동 저장이 나눠 쓸 수 있어 되돌리지 않는다(G: 한 단위로 판정)
    @Test func 여러_목록에_걸친_역편집은_만들지_않는다() {
        let before = Self.layout([("A", "가", ["1"]), ("B", "나", ["1"])])
        let after = Self.layout([("A", "가", ["1", "2"]), ("B", "나", ["1", "2"])])
        #expect(PlaylistUndo.reversing(before: before, after: after, current: after, ids: [:]) == .unsupported)
    }

    /// 아직 쓰지 않은 새 목록(`new:키`)은 새 목록 참조 그대로 둔다(`.id("new:키")`가 아니다, H·G13)
    @Test func 아직_쓰지_않은_새_목록은_새_목록_참조로_되돌린다() {
        let before = Self.layout([("new:k", "가", [])]), after = Self.layout([("new:k", "나", [])])
        #expect(PlaylistUndo.reversing(before: before, after: after, current: after, ids: [:]) == .edits([.rename(playlist: .new("k"), name: "가")]))
    }

    @Test func 곡_순서를_바꾼_편집은_편집_전_곡_순서로_되돌린다() throws {
        let before = Self.layout([("A", "가", ["1", "2", "3", "2"])])
        let after = Self.layout([("A", "가", ["2", "1", "3", "2"])])
        guard case let .edits(edits) = PlaylistUndo.reversing(before: before, after: after, current: after, ids: [:]) else {
            Issue.record("되돌리지 못함"); return
        }
        #expect(edits.allSatisfy { if case .moveTracks = $0 { true } else { false } })
        #expect(try Self.applying(edits, to: after).item("A")?.trackIDs == ["1", "2", "3", "2"])
    }

    @Test func 만들기_지우기_폴더_옮기기_곡_빼기는_되돌리지_않는다() {
        let base = Self.layout([("A", "가", ["1", "2"])])
        let created = Self.layout([("A", "가", ["1", "2"]), ("new:k", "새 목록", [])])
        #expect(PlaylistUndo.reversing(before: base, after: created, current: created, ids: [:]) == .unsupported)
        #expect(PlaylistUndo.reversing(before: created, after: base, current: base, ids: [:]) == .unsupported)
        // 곡 빼기와 순서 바꾸기가 섞여 어느 쪽도 다른 쪽의 부분 열이 아니면 되돌리지 않는다
        let mixedBase = Self.layout([("A", "가", ["1", "2", "3"])]), reordered = Self.layout([("A", "가", ["3", "1"])])
        #expect(PlaylistUndo.reversing(before: mixedBase, after: reordered, current: reordered, ids: [:]) == .unsupported)
        var folder = Self.layout([("A", "가", ["1", "2"])])
        folder = PlaylistLayout([(PlaylistLayout.Item(id: "F", name: "폴더", isFolder: true), 1),
                                 (PlaylistLayout.Item(id: "A", name: "가", parentID: "F", entries: Self.entries(["1", "2"])), 1)])
        let moved = PlaylistLayout([(PlaylistLayout.Item(id: "F", name: "폴더", isFolder: true), 1),
                                    (PlaylistLayout.Item(id: "A", name: "가", entries: Self.entries(["1", "2"])), 2)])
        #expect(PlaylistUndo.reversing(before: folder, after: moved, current: moved, ids: [:]) == .unsupported)
        #expect(PlaylistUndo.reversing(before: base, after: base, current: base, ids: [:]) == .unsupported)
    }

    // MARK: - 곡 빼기와 가운데 넣기(#295 E5): 한쪽이 다른 쪽의 부분 열이면 되돌린다

    /// 편집 전·뒤 곡 열로 역편집을 만들고, 편집 뒤 목록에 얹으면 편집 전 곡 열이 되는지 본다
    static func reversedTracks(_ old: [String], _ new: [String]) throws -> (edits: [PlaylistEdit], tracks: [String]?) {
        let before = layout([("A", "가", old)]), after = layout([("A", "가", new)])
        guard case let .edits(edits) = PlaylistUndo.reversing(before: before, after: after, current: after, ids: [:]) else { return ([], nil) }
        return (edits, try applying(edits, to: after).item("A")?.trackIDs)
    }

    @Test func 가운데_곡을_뺀_편집은_끝에_넣고_원래_자리로_옮겨_되돌린다() throws {
        let result = try Self.reversedTracks(["1", "2", "3"], ["1", "3"])
        #expect(result.tracks == ["1", "2", "3"])
        // 넣은 꼬리 구간을 꼬리 자리(번호)로 집어 원래 자리로 옮긴다
        #expect(result.edits == [.addTracks(playlist: .id("A"), contentIDs: ["2"]),
                                 .moveTracks(playlist: .id("A"), entries: [PlaylistEntry(trackNo: 3, contentID: "2")], to: 2)])
    }

    @Test func 여러_자리에서_뺀_곡은_이어진_자리마다_한_단계로_옮기고_끝_자리는_옮기지_않는다() throws {
        let result = try Self.reversedTracks(["1", "2", "3", "4", "5"], ["1", "4"])
        #expect(result.tracks == ["1", "2", "3", "4", "5"])
        #expect(result.edits == [.addTracks(playlist: .id("A"), contentIDs: ["2", "3", "5"]),
                                 .moveTracks(playlist: .id("A"), entries: [PlaylistEntry(trackNo: 3, contentID: "2"),
                                                                            PlaylistEntry(trackNo: 4, contentID: "3")], to: 2)])
    }

    @Test(arguments: [(["1", "2", "1", "3"], ["2", "3"]), (["1", "2", "1", "3"], ["1", "2", "3"]), (["1", "2", "1", "3"], ["2", "1", "3"]),
                      (["1", "1", "1"], ["1"])])
    func 같은_곡이_여러_번_든_목록에서_뺀_편집도_곡_수와_차례를_되돌린다(_ old: [String], _ new: [String]) throws {
        #expect(try Self.reversedTracks(old, new).tracks == old)
    }

    @Test func 가운데_넣은_곡은_그_자리_항목을_빼서_되돌린다() throws {
        let result = try Self.reversedTracks(["1", "3"], ["1", "2", "3"])
        #expect(result.tracks == ["1", "3"])
        #expect(result.edits == [.removeTracks(playlist: .id("A"), entries: [PlaylistEntry(trackNo: 2, contentID: "2")])])
        #expect(try Self.reversedTracks(["1", "1"], ["1", "2", "1", "2"]).tracks == ["1", "1"])
    }

    /// 곡 빼기의 ⌘Z를 쓴 뒤 ⇧⌘Z(역편집의 역편집)는 가운데 넣기를 되돌리는 꼴이라 같은 규칙으로 편집 뒤 모양이 된다
    @Test func 곡_빼기_역편집의_역편집은_편집_뒤_곡_열이다() throws {
        let old = ["1", "2", "1", "3"], new = ["1", "3"]
        let undone = try #require(Self.reversedTracks(old, new).tracks)
        #expect(try Self.reversedTracks(new, undone).tracks == new)
    }

    @Test func 대상이_지금_편집_뒤_모양이_아니면_정할_수_없다() {
        let before = Self.layout([("A", "가", ["1"])])
        let after = Self.layout([("A", "새 이름", ["1"])])
        // 쓴 뒤 rekordbox에서 이름을 또 바꿨다
        let current = Self.layout([("A", "바깥 이름", ["1"])])
        #expect(PlaylistUndo.reversing(before: before, after: after, current: current, ids: [:]) == .changed)
        // 넣은 곡 뒤에 바깥에서 곡을 더 넣었다
        let added = Self.layout([("A", "가", ["1", "2"])])
        let outside = Self.layout([("A", "가", ["1", "2", "3"])])
        #expect(PlaylistUndo.reversing(before: before, after: added, current: outside, ids: [:]) == .changed)
        // 목록이 사라졌다
        #expect(PlaylistUndo.reversing(before: before, after: after, current: Self.layout([]), ids: [:]) == .changed)
    }
}
