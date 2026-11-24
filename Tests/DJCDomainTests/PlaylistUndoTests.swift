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
        let removed = Self.layout([("A", "가", ["1"])])
        #expect(PlaylistUndo.reversing(before: base, after: removed, current: removed, ids: [:]) == .unsupported)
        var folder = Self.layout([("A", "가", ["1", "2"])])
        folder = PlaylistLayout([(PlaylistLayout.Item(id: "F", name: "폴더", isFolder: true), 1),
                                 (PlaylistLayout.Item(id: "A", name: "가", parentID: "F", entries: Self.entries(["1", "2"])), 1)])
        let moved = PlaylistLayout([(PlaylistLayout.Item(id: "F", name: "폴더", isFolder: true), 1),
                                    (PlaylistLayout.Item(id: "A", name: "가", entries: Self.entries(["1", "2"])), 2)])
        #expect(PlaylistUndo.reversing(before: folder, after: moved, current: moved, ids: [:]) == .unsupported)
        #expect(PlaylistUndo.reversing(before: base, after: base, current: base, ids: [:]) == .unsupported)
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
