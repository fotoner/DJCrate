import DJCDomain
import Foundation
import Testing

/// 재생 목록 초안(#39·#40): 트리에 편집 얹기, 처음 rekordbox 상태(base)와 달라진 목록의 편집 막기, 사이드바 모양.
/// 편집 규칙(새 항목은 부모 맨 위, 옮기면 새 부모 맨 끝, 곡은 끝에)은 rekordbox 7.2.18 실험으로 확인한 `RekordboxWriter+Playlist`와 같다.
@Suite("재생 목록 초안")
struct PlaylistDraftTests {
    typealias Item = PlaylistLayout.Item

    static func item(_ id: String, _ name: String, parent: String = PlaylistLayout.root, folder: Bool = false, smart: Bool = false,
                     tracks: [String] = []) -> Item {
        Item(id: id, name: name, parentID: parent, isFolder: folder, isSmart: smart,
             entries: tracks.enumerated().map { PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element) })
    }

    /// 맨 위: 폴더 F(목록 A[1,2,3], B[4]) · 목록 C[5] · 인텔리전트 S
    static func library(extra: [(Item, Int)] = []) -> PlaylistLayout {
        PlaylistLayout([
            (item("F", "폴더", folder: true), 1),
            (item("A", "가", parent: "F", tracks: ["1", "2", "3"]), 1),
            (item("B", "나", parent: "F", tracks: ["4"]), 2),
            (item("C", "다", tracks: ["5"]), 2),
            (item("S", "스마트", smart: true), 3),
        ] + extra)
    }

    func blockedReason(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let blocked as PlaylistLayout.Blocked { return blocked.reason } catch { return "\(error)" }
    }

    // MARK: - 트리에 편집 얹기

    @Test func 부모_안은_Seq_순서다() {
        let layout = Self.library()
        #expect(layout.childIDs(of: PlaylistLayout.root) == ["F", "C", "S"])
        #expect(layout.childIDs(of: "F") == ["A", "B"])
        #expect(layout.subtree(of: "F") == ["F", "A", "B"])
        #expect(layout.ancestors(of: "B").map(\.name) == ["폴더"])
    }

    @Test func 새_항목은_부모_맨_위에_생긴다() throws {
        var layout = Self.library()
        try layout.apply(.create(key: "k", name: "새 목록", isFolder: false, parent: .id("F")))
        try layout.apply(.create(key: "d", name: "새 폴더", isFolder: true, parent: .root))
        #expect(layout.childIDs(of: "F") == ["new:k", "A", "B"])
        #expect(layout.childIDs(of: PlaylistLayout.root) == ["new:d", "F", "C", "S"])
        #expect(layout.item("new:d")?.isFolder == true && layout.item("new:k")?.name == "새 목록")
        // 뒤 편집은 new:키로 가리킨다
        try layout.apply(.create(key: "in", name: "안", isFolder: false, parent: .new("d")))
        #expect(layout.childIDs(of: "new:d") == ["new:in"])
    }

    @Test func 쓰기_모듈이_막는_편집은_막는다() {
        var layout = Self.library()
        #expect(blockedReason { try layout.apply(.create(key: "k", name: "  ", isFolder: false, parent: .root)) } == "이름을 적어 주세요")
        #expect(blockedReason { try layout.apply(.create(key: "k", name: "x", isFolder: false, parent: .id("C")) ) }
            == "폴더가 아닌 재생 목록(다) 안에는 넣을 수 없습니다")
        #expect(blockedReason { try layout.apply(.rename(playlist: .root, name: "x")) } == "맨 위는 편집할 수 없습니다")
        #expect(blockedReason { try layout.apply(.rename(playlist: .id("없음"), name: "x")) } == "rekordbox에서 재생 목록을 찾지 못했습니다")
        #expect(blockedReason { try layout.apply(.rename(playlist: .new("없음"), name: "x")) } == "앞에서 만들지 못한 목록입니다")
        #expect(blockedReason { try layout.apply(.addTracks(playlist: .id("S"), contentIDs: ["1"])) }
            == "인텔리전트 재생 목록은 아직 쓰지 않습니다(rekordbox에서 고치세요)")
        #expect(blockedReason { try layout.apply(.addTracks(playlist: .id("F"), contentIDs: ["1"])) } == "폴더에는 곡을 넣거나 뺄 수 없습니다")
        // 같은 폴더로 옮기기는 그대로 둔다
        #expect(blockedReason { try layout.apply(.move(playlist: .id("A"), into: .id("F"))) } == nil && layout.childIDs(of: "F") == ["A", "B"])
        #expect(blockedReason { try layout.apply(.move(playlist: .id("F"), into: .id("F"))) } == "폴더를 제 안으로 옮길 수 없습니다")
        try? layout.apply(.create(key: "in", name: "안", isFolder: true, parent: .id("F")))
        #expect(blockedReason { try layout.apply(.move(playlist: .id("F"), into: .new("in"))) } == "폴더를 제 안으로 옮길 수 없습니다")
        #expect(blockedReason { try layout.apply(.removeTracks(playlist: .id("A"), entries: [.init(trackNo: 2, contentID: "9")])) }
            == "2번째 곡이 편집을 만들 때와 다릅니다. 목록을 다시 읽은 뒤 고치세요")
        #expect(blockedReason { try layout.apply(.removeTracks(playlist: .id("A"), entries: [.init(trackNo: 2, contentID: "2"), .init(trackNo: 2, contentID: "2")])) }
            == "같은 자리를 두 번 가리킵니다")
    }

    @Test func 옮기면_새_부모_맨_끝이고_순서_바꾸기는_부모_안_자리다() throws {
        var layout = Self.library()
        try layout.apply(.move(playlist: .id("C"), into: .id("F")))
        #expect(layout.childIDs(of: "F") == ["A", "B", "C"] && layout.item("C")?.parentID == "F")
        #expect(layout.childIDs(of: PlaylistLayout.root) == ["F", "S"])
        try layout.apply(.reorder(playlist: .id("C"), index: 0))
        #expect(layout.childIDs(of: "F") == ["C", "A", "B"])
        try layout.apply(.reorder(playlist: .id("C"), index: 99))
        #expect(layout.childIDs(of: "F") == ["A", "B", "C"])
    }

    @Test func 폴더를_지우면_안의_목록도_사라진다() throws {
        var layout = Self.library()
        try layout.apply(.delete(playlist: .id("F")))
        #expect(layout.item("A") == nil && layout.item("B") == nil && layout.childIDs(of: PlaylistLayout.root) == ["C", "S"])
    }

    @Test func 곡_넣기는_끝에_붙이고_빼기·옮기기는_자리를_1부터_다시_매긴다() throws {
        var layout = PlaylistLayout([(Item(id: "P", name: "목록", entries: [
            .init(trackNo: 1, contentID: "a"), .init(trackNo: 2, contentID: "b"), .init(trackNo: 4, contentID: "c"),
        ]), 1)])
        // TrackNo에 빈칸이 있어도 넣는 곡은 가장 큰 번호 다음부터(쓰기 모듈과 같다)
        try layout.apply(.addTracks(playlist: .id("P"), contentIDs: ["d", "a"]))
        #expect(layout.item("P")?.entries.map(\.trackNo) == [1, 2, 4, 5, 6])
        #expect(layout.item("P")?.trackIDs == ["a", "b", "c", "d", "a"])
        try layout.apply(.removeTracks(playlist: .id("P"), entries: [.init(trackNo: 2, contentID: "b")]))
        #expect(layout.item("P")?.entries == [.init(trackNo: 1, contentID: "a"), .init(trackNo: 2, contentID: "c"),
                                              .init(trackNo: 3, contentID: "d"), .init(trackNo: 4, contentID: "a")])
        // 5번째 → 1·2번째 사이(실험 단계와 같은 모양): 옮기는 곡을 뺀 목록의 2번째 자리
        try layout.apply(.moveTracks(playlist: .id("P"), entries: [.init(trackNo: 4, contentID: "a")], to: 2))
        #expect(layout.item("P")?.trackIDs == ["a", "a", "c", "d"] && layout.item("P")?.entries.map(\.trackNo) == [1, 2, 3, 4])
    }

    // MARK: - 화면 편집 → 자리

    @Test func 보이는_곡으로_빼기·옮기기_자리를_만든다() {
        let item = Self.item("P", "목록", tracks: ["a", "b", "a", "c", "d"])
        // 목록에는 같은 곡이 처음 한 번만 보인다. 빼기는 그 곡의 모든 자리를 뺀다.
        #expect(item.entries(of: ["a"]).map(\.trackNo) == [1, 3])
        // 옮기기는 보이는 줄(처음 자리)을 옮긴다: d를 b 앞으로 → 옮기는 곡을 뺀 목록에서 b의 자리
        let moving = item.firstEntries(of: ["d"])
        #expect(moving == [.init(trackNo: 5, contentID: "d")])
        #expect(item.insertionPoint(before: "b", moving: moving) == 2)
        #expect(item.insertionPoint(before: nil, moving: moving) == 5)
        #expect(item.insertionPoint(before: "a", moving: item.firstEntries(of: ["c", "b"])) == 1)
    }

    @Test func 넣을_곡_중_이미_든_곡을_가른다() {
        let item = Self.item("P", "목록", tracks: ["a", "b"])
        let split = item.split(adding: ["b", "c", "c", "d"])
        #expect(split.new == ["c", "d"] && split.duplicates == ["b"])
    }

    // MARK: - 초안

    @Test func 편집이_기대는_rekordbox_목록_상태를_처음_한_번_적는다() throws {
        let rekordbox = Self.library()
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["9"]), rekordbox: rekordbox)
        try draft.append(.create(key: "k", name: "새", isFolder: false, parent: .id("F")), rekordbox: rekordbox)
        try draft.append(.addTracks(playlist: .new("k"), contentIDs: ["1"]), rekordbox: rekordbox)
        #expect(draft.edits.count == 3)
        #expect(draft.base["A"] == PlaylistDraft.Base(Self.item("A", "가", parent: "F", tracks: ["1", "2", "3"])))
        // 새 목록과 새 항목을 넣기만 한 부모는 base가 없다(있기만 하면 된다)
        #expect(Set(draft.base.keys) == ["A"])
        let projection = draft.project(onto: rekordbox)
        #expect(projection.blocked.allSatisfy { $0 == nil })
        #expect(projection.layout.item("A")?.trackIDs == ["1", "2", "3", "9"])
        #expect(projection.layout.childIDs(of: "F") == ["new:k", "A", "B"])
        #expect(projection.changed == ["A", "new:k"])
        #expect(projection.ready == draft.edits)
    }

    @Test func 쓸_수_없는_편집은_더하지_않는다() throws {
        let rekordbox = Self.library()
        var draft = PlaylistDraft()
        try draft.append(.delete(playlist: .id("C")), rekordbox: rekordbox)
        #expect(throws: PlaylistLayout.Blocked.self) { try draft.append(.rename(playlist: .id("C"), name: "x"), rekordbox: rekordbox) }
        #expect(draft.edits == [.delete(playlist: .id("C"))])
    }

    @Test func rekordbox에서_바뀐_목록의_편집만_막는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["9"]), rekordbox: Self.library())
        try draft.append(.rename(playlist: .id("C"), name: "새 이름"), rekordbox: Self.library())
        // 그 뒤 rekordbox에서 A에 곡을 넣었다
        var changed = Self.library()
        try changed.apply(.addTracks(playlist: .id("A"), contentIDs: ["7"]))
        let projection = draft.project(onto: changed)
        #expect(projection.blocked == ["초안을 만든 뒤 rekordbox에서 이 목록이 바뀌었으니 현재 목록을 비교해 다시 적용하거나 초안을 버리세요.", nil])
        #expect(projection.ready == [.rename(playlist: .id("C"), name: "새 이름")])
        #expect(projection.layout.item("A")?.trackIDs == ["1", "2", "3", "7"] && projection.layout.item("C")?.name == "새 이름")
        #expect(projection.blockedTargets["A"] != nil && projection.changed == ["C"])
        // rekordbox에서 지운 목록
        var deleted = Self.library()
        try deleted.apply(.delete(playlist: .id("C")))
        #expect(draft.project(onto: deleted).blocked[1] == "rekordbox에서 지운 목록입니다")
    }

    @Test func 폴더_지우기는_그_안이_바뀌어도_막는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.delete(playlist: .id("F")), rekordbox: Self.library())
        #expect(Set(draft.base.keys) == ["F", "A", "B"])
        // rekordbox에서 폴더 안에 목록을 새로 만들었다(지우면 함께 사라진다)
        let added = Self.library(extra: [(Self.item("N", "rekordbox에서 만든 목록", parent: "F"), 3)])
        #expect((draft.project(onto: added).blocked.first ?? nil) == "초안을 만든 뒤 rekordbox에서 이 목록이 바뀌었으니 현재 목록을 비교해 다시 적용하거나 초안을 버리세요.")
        // 안의 목록에 곡이 늘어도
        var grown = Self.library()
        try grown.apply(.addTracks(playlist: .id("B"), contentIDs: ["1"]))
        #expect(draft.project(onto: grown).ready.isEmpty)
        #expect(draft.project(onto: Self.library()).ready == draft.edits)
    }

    @Test func 순서_바꾸기는_부모_안_순서가_바뀌면_막는다() throws {
        var draft = PlaylistDraft()
        try draft.append(.reorder(playlist: .id("C"), index: 0), rekordbox: Self.library())
        #expect(draft.base[PlaylistLayout.root]?.childIDs == ["F", "C", "S"])
        let added = Self.library(extra: [(Self.item("N", "새로 생긴 목록"), 0)])
        #expect(draft.project(onto: added).ready.isEmpty)
        #expect(draft.project(onto: Self.library()).layout.childIDs(of: PlaylistLayout.root) == ["C", "F", "S"])
    }

    @Test func 이름은_마지막_것만_남고_rekordbox_이름으로_되돌리면_편집이_없다() throws {
        let rekordbox = Self.library()
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("C"), name: "하나"), rekordbox: rekordbox)
        try draft.append(.rename(playlist: .id("C"), name: "둘"), rekordbox: rekordbox)
        #expect(draft.edits == [.rename(playlist: .id("C"), name: "둘")])
        try draft.append(.rename(playlist: .id("C"), name: "다"), rekordbox: rekordbox)
        #expect(draft.isEmpty && draft.base.isEmpty)
        // 새 목록의 이름은 만들기에 합친다
        try draft.append(.create(key: "k", name: "무제", isFolder: false, parent: .root), rekordbox: rekordbox)
        try draft.append(.rename(playlist: .new("k"), name: "세트"), rekordbox: rekordbox)
        #expect(draft.edits == [.create(key: "k", name: "세트", isFolder: false, parent: .root)])
    }

    @Test func 새로_만든_것을_지우면_만든_편집부터_없던_일로_한다() throws {
        let rekordbox = Self.library()
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("C"), name: "남는 편집"), rekordbox: rekordbox)
        try draft.append(.create(key: "f", name: "새 폴더", isFolder: true, parent: .root), rekordbox: rekordbox)
        try draft.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .new("f")), rekordbox: rekordbox)
        try draft.append(.addTracks(playlist: .new("k"), contentIDs: ["1", "2"]), rekordbox: rekordbox)
        try draft.append(.delete(playlist: .new("f")), rekordbox: rekordbox)
        #expect(draft.edits == [.rename(playlist: .id("C"), name: "남는 편집")])
        // 있던 목록을 새 폴더에 옮겨 넣었으면 지우기를 그대로 쓴다(옮긴 목록도 함께 지워진다)
        try draft.append(.create(key: "g", name: "새 폴더", isFolder: true, parent: .root), rekordbox: rekordbox)
        try draft.append(.move(playlist: .id("B"), into: .new("g")), rekordbox: rekordbox)
        try draft.append(.delete(playlist: .new("g")), rekordbox: rekordbox)
        #expect(draft.edits.count == 4)
        #expect(draft.project(onto: rekordbox).layout.item("B") == nil)
    }

    @Test func 목록의_초안을_버리면_거기_기대는_편집도_함께_버린다() throws {
        let rekordbox = Self.library()
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("C"), name: "남는 편집"), rekordbox: rekordbox)
        try draft.append(.create(key: "f", name: "새 폴더", isFolder: true, parent: .root), rekordbox: rekordbox)
        try draft.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .new("f")), rekordbox: rekordbox)
        try draft.append(.move(playlist: .new("k"), into: .root), rekordbox: rekordbox)
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["9"]), rekordbox: rekordbox)
        draft.discard(playlist: "new:f", rekordbox: rekordbox)
        // 새 목록은 폴더 밖으로 옮겼지만 폴더 안에 만들었으니 함께 버린다
        #expect(draft.edits == [.rename(playlist: .id("C"), name: "남는 편집"), .addTracks(playlist: .id("A"), contentIDs: ["9"])])
        draft.discard(playlist: "A", rekordbox: rekordbox)
        #expect(draft.edits == [.rename(playlist: .id("C"), name: "남는 편집")] && Set(draft.base.keys) == ["C"])
    }

    @Test func 막힌_편집만_버린다() throws {
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["9"]), rekordbox: Self.library())
        try draft.append(.rename(playlist: .id("C"), name: "새 이름"), rekordbox: Self.library())
        var changed = Self.library()
        try changed.apply(.rename(playlist: .id("A"), name: "rekordbox에서 바꾼 이름"))
        draft.discardBlocked(rekordbox: changed)
        #expect(draft.edits == [.rename(playlist: .id("C"), name: "새 이름")])
    }

    @Test func 쓴_편집을_빼고_되돌리면_다시_쌓는다() throws {
        let rekordbox = Self.library()
        var draft = PlaylistDraft()
        try draft.append(.addTracks(playlist: .id("A"), contentIDs: ["9"]), rekordbox: rekordbox)
        #expect(throws: PlaylistLayout.Blocked.self) { try draft.append(.rename(playlist: .id("S"), name: "x"), rekordbox: rekordbox) }
        #expect(draft.edits.count == 1)
        // 쓴 편집(쓰기 모듈 결과 순서)을 뺀다
        draft.removeSteps(at: [0])
        #expect(draft.isEmpty && draft.base.isEmpty)
        // 되돌리면: 되살린 편집을 먼저, 그 뒤 새로 쌓은 편집
        var later = PlaylistDraft()
        try later.append(.rename(playlist: .id("C"), name: "나중"), rekordbox: rekordbox)
        let rebuilt = PlaylistDraft.rebuilt([.addTracks(playlist: .id("A"), contentIDs: ["9"]), .delete(playlist: .id("없음"))] + later.edits,
                                            rekordbox: rekordbox)
        #expect(rebuilt.draft.edits == [.addTracks(playlist: .id("A"), contentIDs: ["9"]), .rename(playlist: .id("C"), name: "나중")])
        #expect(rebuilt.failed == [.delete(playlist: .id("없음"))])
    }

    @Test func 초안은_JSON으로_오간다() throws {
        var draft = PlaylistDraft()
        try draft.append(.reorder(playlist: .id("C"), index: 0), rekordbox: Self.library())
        let data = try JSONEncoder().encode(draft)
        #expect(try JSONDecoder().decode(PlaylistDraft.self, from: data) == draft)
    }

    // MARK: - 사이드바

    @Test func 사이드바_트리에_초안과_막힘을_표시한다() throws {
        var draft = PlaylistDraft()
        try draft.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .id("F")), rekordbox: Self.library())
        try draft.append(.addTracks(playlist: .new("k"), contentIDs: ["1", "1", "2"]), rekordbox: Self.library())
        try draft.append(.rename(playlist: .id("C"), name: "새 이름"), rekordbox: Self.library())
        var changed = Self.library()
        try changed.apply(.addTracks(playlist: .id("C"), contentIDs: ["8"]))
        let nodes = PlaylistOutlineNode.tree(draft.project(onto: changed))
        #expect(nodes.map(\.name) == ["폴더", "다", "스마트"])
        let folder = try #require(nodes.first)
        #expect(folder.children?.map(\.name) == ["새 목록", "가", "나"])
        let new = try #require(folder.children?.first)
        #expect(new.isDraft && new.isNew && new.trackIDs == ["1", "2"] && new.children == nil)
        // 폴더는 아래 목록 곡을 모은다(같은 곡은 한 번)
        #expect(folder.trackIDs == ["1", "2", "3", "4"] && !folder.isDraft)
        #expect(nodes[1].blockedReason != nil && nodes[1].name == "다")
        #expect(nodes[2].isSmart && nodes[2].trackIDs.isEmpty)
    }
}
