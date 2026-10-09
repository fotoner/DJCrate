import DJCDomain
import Foundation

public extension UsbExportCandidates {
    /// 로컬 DB 밖의 목록(iTunes 포함)을 기존 내보내기 입력으로 바꾼다. 곡 ID는 스냅샷의 ContentID여야 한다.
    /// 폴더의 부분 선택은 호출자가 잘라낸 layout으로 넘기고, 목록 안 순서·중복은 그대로 유지한다.
    static func playlistTree(layout: PlaylistLayout, rootIDs: [String]) throws -> [UsbPlaylistInput] {
        try validatePlaylistLayout(layout)
        for id in rootIDs where layout.item(id) == nil {
            throw UsbError.readFailed(detail: String(ui: "선택한 재생 목록을 찾지 못했습니다. 목록을 다시 읽은 뒤 내보내세요"))
        }
        var result: [UsbPlaylistInput] = []
        var visited = Set<String>()
        func visit(_ item: PlaylistLayout.Item, parent: String?) throws {
            guard visited.insert(item.id).inserted else { return }
            guard !item.isNew else {
                throw UsbError.writeRefused([UsbBlock(code: "pendingPlaylist", scope: .playlist(item.id),
                    message: String(ui: "미반영 재생 목록은 내보낼 수 없습니다. rekordbox에 목록을 쓴 뒤 내보내세요"))])
            }
            let attribute = item.isSmart ? 4 : item.isFolder ? 1 : 0
            result.append(UsbPlaylistInput(localID: item.id, name: item.name, parentLocalID: parent, attribute: attribute,
                                           trackLocalIDs: item.isFolder ? [] : item.trackIDs))
            if attribute == 1 {
                for child in layout.children(of: item.id) { try visit(child, parent: item.id) }
            }
        }
        for id in rootIDs { if let item = layout.item(id) { try visit(item, parent: nil) } }
        return result
    }

    /// outline을 부르기 전에 검사해 순환·중복 때문에 선택 목록을 잃거나 재귀가 끝나지 않는 일을 막는다.
    private static func validatePlaylistLayout(_ layout: PlaylistLayout) throws {
        let blocked = UsbError.writeRefused([UsbBlock(code: "invalidPlaylistLayout", scope: .volume,
            message: String(ui: "재생 목록의 부모 관계나 ID가 맞지 않습니다. 목록을 다시 읽은 뒤 내보내세요"))])
        var pending = layout.childIDs(of: PlaylistLayout.root).map { (id: $0, parent: PlaylistLayout.root) }
        var seen = Set<String>()
        while let next = pending.popLast() {
            guard let item = layout.item(next.id), !item.id.isEmpty, item.id != PlaylistLayout.root,
                  item.parentID == next.parent, seen.insert(item.id).inserted else { throw blocked }
            let children = layout.childIDs(of: item.id)
            guard children.isEmpty || (item.isFolder && !item.isSmart) else { throw blocked }
            pending += children.map { (id: $0, parent: item.id) }
        }
        guard seen.count == layout.items.count else { throw blocked }
    }
}
