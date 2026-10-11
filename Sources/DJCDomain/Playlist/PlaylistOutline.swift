import Foundation

/// 사이드바 재생 목록 트리 한 칸(초안을 얹은 모양). `children`이 nil이면 잎(목록)이다.
public struct PlaylistOutlineNode: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isFolder: Bool
    public var isSmart: Bool
    public var children: [PlaylistOutlineNode]?
    /// 표에 보일 곡. rekordbox는 같은 곡을 한 목록에 여러 번 넣을 수 있지만 표 선택은 곡 ID가 유일해야 하므로 처음 한 번만 둔다.
    /// 폴더면 아래 목록 곡을 순서대로 모은 것(중복 제거).
    public var trackIDs: [String]
    /// 초안으로 바뀜(새로 만든 것 포함)
    public var isDraft: Bool
    /// 쓸 수 없는 초안 편집이 가리키면 그 이유
    public var blockedReason: String?

    /// 초안으로 만든 목록
    public var isNew: Bool { id.hasPrefix("new:") }

    public static func tree(_ projection: PlaylistDraft.Projection) -> [PlaylistOutlineNode] {
        tree(projection.layout, changed: projection.changed, blocked: projection.blockedTargets)
    }

    public static func tree(_ layout: PlaylistLayout, changed: Set<String> = [], blocked: [String: String] = [:]) -> [PlaylistOutlineNode] {
        func unique(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }
        }
        func build(_ parent: String) -> [PlaylistOutlineNode] {
            layout.children(of: parent).map { item in
                let children = item.isFolder ? build(item.id) : nil
                return PlaylistOutlineNode(id: item.id, name: item.name, isFolder: item.isFolder, isSmart: item.isSmart, children: children,
                                           trackIDs: unique(children.map { $0.flatMap(\.trackIDs) } ?? item.trackIDs),
                                           isDraft: changed.contains(item.id), blockedReason: blocked[item.id])
            }
        }
        return build(PlaylistLayout.root)
    }

    /// 인텔리전트 목록(`isSmart`)에 계산한 곡을 채운 트리(목록 ID → 곡 ID). 폴더가 모은 곡(`trackIDs`)은 그대로 둔다:
    /// 인텔리전트 목록의 곡을 폴더 곡 모음에 넣는 규칙은 rekordbox와 맞춰 보지 않았다(#68).
    public func fillingSmartTracks(_ tracks: [String: [String]]) -> PlaylistOutlineNode {
        var node = self
        if isSmart, let ids = tracks[id] { node.trackIDs = ids }
        node.children = children?.map { $0.fillingSmartTracks(tracks) }
        return node
    }

    public func find(_ id: String) -> PlaylistOutlineNode? {
        if self.id == id { return self }
        for child in children ?? [] {
            if let hit = child.find(id) { return hit }
        }
        return nil
    }
}
