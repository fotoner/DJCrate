import DJCDomain
import Testing

/// 사이드바 트리에 인텔리전트 목록의 계산한 곡을 채우는 규칙(#68). 채우지 않으면 지금 dev와 같은 트리다.
@Suite("인텔리전트 재생 목록 트리 채우기")
struct SmartPlaylistOutlineTests {
    /// 폴더 F(일반 A[1,2] · 인텔리전트 S) · 인텔리전트 T
    static var layout: PlaylistLayout {
        PlaylistLayout([
            (PlaylistLayout.Item(id: "F", name: "폴더", isFolder: true), 1),
            (PlaylistLayout.Item(id: "A", name: "일반", parentID: "F",
                                 entries: [PlaylistEntry(trackNo: 1, contentID: "1"), PlaylistEntry(trackNo: 2, contentID: "2")]), 1),
            (PlaylistLayout.Item(id: "S", name: "스마트", parentID: "F", isSmart: true), 2),
            (PlaylistLayout.Item(id: "T", name: "스마트 둘", isSmart: true), 2),
        ])
    }

    @Test func 인텔리전트_목록만_곡을_채우고_폴더_곡_모음은_그대로다() throws {
        let tree = PlaylistOutlineNode.tree(Self.layout)
        let filled = tree.map { $0.fillingSmartTracks(["S": ["7", "8"], "T": ["9"], "A": ["99"], "F": ["98"]]) }
        let folder = try #require(filled.first { $0.id == "F" })
        #expect(folder.trackIDs == ["1", "2"], "폴더는 인텔리전트 목록 곡을 모으지 않는다")
        #expect(folder.children?.first { $0.id == "A" }?.trackIDs == ["1", "2"], "일반 목록은 건드리지 않는다")
        #expect(folder.children?.first { $0.id == "S" }?.trackIDs == ["7", "8"])
        #expect(filled.first { $0.id == "T" }?.trackIDs == ["9"])
    }

    @Test func 비워_두면_트리가_그대로다() {
        let tree = PlaylistOutlineNode.tree(Self.layout)
        #expect(tree.map { $0.fillingSmartTracks([:]) } == tree)
    }

    @Test func 계산하지_않은_인텔리전트_목록은_빈_채로_남는다() throws {
        let filled = PlaylistOutlineNode.tree(Self.layout).map { $0.fillingSmartTracks(["T": ["9"]]) }
        let folder = try #require(filled.first { $0.id == "F" })
        #expect(folder.children?.first { $0.id == "S" }?.trackIDs == [])
        #expect(folder.children?.first { $0.id == "S" }?.isSmart == true)
    }
}
