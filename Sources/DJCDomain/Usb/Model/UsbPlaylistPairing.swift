import Foundation

/// 두 형식의 재생 목록을 번호가 아니라 자리(부모 짝 아래 같은 이름·종류)로 짝짓는다(#233).
/// rekordbox는 새 목록 번호로 Device Library는 빈 번호를 다시 쓰고 OneLibrary는 가장 큰 값+1을 써서(2026-10-08 실험),
/// 같은 목록이 형식마다 다른 번호를 갖거나 같은 번호가 형식마다 다른 목록이 된다.
enum UsbPlaylistPairing {
    struct Key: Hashable {
        var name: String
        var attribute: Int
    }

    /// - 맨 위부터 내려가며 짝지은 부모 아래에서 이름(글자 그대로)·종류가 같은 목록이 형식마다 하나씩이면 짝짓는다.
    ///   같은 키가 여럿이면 번호까지 같은 것만 짝짓고 나머지는 한 형식 목록으로 둔다(잘못 짝지어 다른 목록을 덮지 않게).
    /// - 대표 번호(`UsbPlaylist.id`): OneLibrary 번호. Device Library에만 있는 목록은 그 번호, 그 번호를 OneLibrary가 쓰면 −번호.
    ///   형식 번호가 대표 번호와 다르면 `formatIDs`에 둔다. 부모는 대표 번호로 적는다.
    /// - 맨 위에서 닿지 않는 목록(없는 부모·고리·한 형식 안 번호 중복)은 `playlistConflict`(편집 막음)로 보고한다.
    static func merge(oneLibrary ol: [UsbPlaylist], deviceLibrary dl: [UsbPlaylist]) -> ([UsbPlaylist], [UsbFormatMismatch]) {
        let olReached = reachable(ol), dlReached = reachable(dl)
        let olChildren = children(ol, reached: olReached), dlChildren = children(dl, reached: dlReached)
        var pairs: [Int: Int] = [:], pairedDL: Set<Int> = []
        var queue = [(0, 0)]
        while let (olParent, dlParent) = queue.popLast() {
            let left = Dictionary(grouping: olChildren[olParent] ?? [], by: key)
            let right = Dictionary(grouping: dlChildren[dlParent] ?? [], by: key)
            for (key, lists) in left {
                guard let candidates = right[key] else { continue }
                var matched: [(Int, Int)] = []
                if lists.count == 1, candidates.count == 1 {
                    matched = [(lists[0].id, candidates[0].id)]
                } else {
                    let ids = Set(candidates.map(\.id))
                    matched = lists.filter { ids.contains($0.id) }.map { ($0.id, $0.id) }
                }
                for (olID, dlID) in matched {
                    pairs[olID] = dlID
                    pairedDL.insert(dlID)
                    queue.append((olID, dlID))
                }
            }
        }

        let olIDs = Set(ol.map(\.id))
        var dlRepresentative: [Int: Int] = [:]
        for (olID, dlID) in pairs { dlRepresentative[dlID] = olID }
        for list in dl where !pairedDL.contains(list.id) {
            dlRepresentative[list.id] = olIDs.contains(list.id) ? -list.id : list.id
        }
        func representativeParent(_ list: UsbPlaylist) -> Int {
            list.parentID == 0 ? 0 : dlRepresentative[list.parentID] ?? list.parentID
        }

        var result: [UsbPlaylist] = [], mismatches: [UsbFormatMismatch] = []
        let dlByID = Dictionary(dl.map { ($0.id, $0) }) { first, _ in first }
        for left in ol {
            guard let dlID = pairs[left.id], let right = dlByID[dlID] else {
                result.append(left)
                mismatches.append(olReached.contains(left.id) ? .playlistOnlyIn(.oneLibrary, id: left.id) : .playlistConflict(id: left.id))
                continue
            }
            var playlist = UsbFieldFormats.playlist.merging(oneLibrary: left, deviceLibrary: right).0
            playlist.id = left.id
            playlist.parentID = left.parentID
            playlist.formatIDs = dlID == left.id ? [:] : [.deviceLibrary: dlID]
            playlist.presentIn = left.presentIn.union(right.presentIn)
            playlist.sortOrder = left.sortOrder.merging(right.sortOrder) { first, _ in first }
            playlist.entries = left.entries.merging(right.entries) { first, _ in first }
            if left.entries[.oneLibrary] ?? [] != right.entries[.deviceLibrary] ?? [] {
                mismatches.append(.playlistEntriesDiffer(id: left.id))
            }
            result.append(playlist)
        }
        for right in dl where !pairedDL.contains(right.id) {
            var playlist = right
            playlist.id = dlRepresentative[right.id] ?? right.id
            playlist.parentID = representativeParent(right)
            playlist.formatIDs = playlist.id == right.id ? [:] : [.deviceLibrary: right.id]
            result.append(playlist)
            mismatches.append(dlReached.contains(right.id) ? .playlistOnlyIn(.deviceLibrary, id: playlist.id) : .playlistConflict(id: playlist.id))
        }
        return (result, mismatches)
    }

    static func key(_ playlist: UsbPlaylist) -> Key { Key(name: playlist.name, attribute: playlist.attribute) }

    /// 맨 위(0)에서 부모를 따라 닿는 목록 번호. 한 형식 안에서 번호가 겹치는 목록은 넣지 않는다
    static func reachable(_ lists: [UsbPlaylist]) -> Set<Int> {
        let counts = Dictionary(grouping: lists, by: \.id).mapValues(\.count)
        let byParent = Dictionary(grouping: lists.filter { counts[$0.id] == 1 && $0.id != 0 && $0.id != $0.parentID }, by: \.parentID)
        var reached: Set<Int> = [], queue = [0]
        while let parent = queue.popLast() {
            for child in byParent[parent] ?? [] where reached.insert(child.id).inserted { queue.append(child.id) }
        }
        return reached
    }

    static func children(_ lists: [UsbPlaylist], reached: Set<Int>) -> [Int: [UsbPlaylist]] {
        Dictionary(grouping: lists.filter { reached.contains($0.id) }, by: \.parentID)
    }
}
