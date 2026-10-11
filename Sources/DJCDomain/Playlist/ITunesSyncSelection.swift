/// 폴더 선택은 새 하위 목록도 포함한다. 하위를 해제할 때는 형제 선택을 먼저 펼쳐 보존한다.
public struct ITunesSyncSelection: Codable, Equatable, Sendable {
    public struct Node: Sendable {
        public let id: String
        public let parentID: String?
        public let isFolder: Bool
        public init(id: String, parentID: String?, isFolder: Bool) {
            self.id = id; self.parentID = parentID; self.isFolder = isFolder
        }
    }

    public enum State: Sendable { case off, mixed, on }
    public var selectedIDs: Set<String>
    public init(selectedIDs: Set<String> = []) { self.selectedIDs = selectedIDs }

    public func expandedIDs(in nodes: [Node]) -> Set<String> {
        // ID 0은 실제 목록이 아니라 rekordbox의 'All Playlist' 선택이다.
        if selectedIDs.contains("0") { return Set(nodes.map(\.id)).union(selectedIDs.subtracting(["0"])) }
        var result = selectedIDs
        let children = Dictionary(grouping: nodes, by: { $0.parentID ?? "0" })
        var pending = nodes.filter { $0.isFolder && selectedIDs.contains($0.id) }.map(\.id)
        var visited = Set<String>()
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            for child in children[id] ?? [] {
                result.insert(child.id)
                if child.isFolder { pending.append(child.id) }
            }
        }
        return result
    }

    public func state(of id: String, in nodes: [Node]) -> State {
        let expanded = expandedIDs(in: nodes)
        if expanded.contains(id) || (id == "0" && selectedIDs.contains("0")) { return .on }
        let subtree = Self(selectedIDs: [id]).expandedIDs(in: nodes)
        return expanded.isDisjoint(with: subtree) ? .off : .mixed
    }

    public mutating func setSelected(_ selected: Bool, id: String, in nodes: [Node]) {
        guard nodes.contains(where: { $0.id == id }) else { return }
        let subtree = Self(selectedIDs: [id]).expandedIDs(in: nodes)
        selectedIDs = expandedIDs(in: nodes)
        if selected { selectedIDs.formUnion(subtree); return }
        selectedIDs.subtract(subtree)
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parent = byID[id]?.parentID
        var visited = Set<String>()
        while let ancestor = parent, visited.insert(ancestor).inserted {
            selectedIDs.remove(ancestor)
            parent = byID[ancestor]?.parentID
        }
    }
}
