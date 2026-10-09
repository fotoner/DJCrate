import DJCDomain
import Foundation

/// 쓰기 전 USB 초안을 얹은 재생 목록 항목(#240). 로컬 재생 목록처럼 목록을 초안을 얹은 순서로 보여 주고, 끌어서 옮기기·빼기의 자리를
/// 그 순서로 정한다. 계획(`UsbEditPlanner`)이 편집을 차례로 적용하는 것과 같게 대 본다: 목록 항목 넣기·빼기·옮기기, USB에서 곡 빼기.
/// 쓰기 전에는 곡 번호·결과를 모르는 편집(로컬 곡 넣기·목록 동기화)이나 목록을 지우는 편집이 그 목록에 닿으면 얹은 모양을 모른다(nil)
public enum UsbDraftProjection {
    /// 목록의 항목(초안을 얹은 차례). 편집 자리가 어긋나 쓸 때 막힐 초안이거나 얹은 모양을 모르면 nil
    public static func entries(of playlist: UsbPlaylist, library: UsbLibrary, edits: [UsbLibraryEdit]) -> [Int]? {
        let ref = PlaylistRef.id(String(playlist.id))
        var entries = UsbSyncPlan.entries(of: playlist)
        for edit in edits {
            switch edit {
            case let .removeTracks(ids):
                let removing = Set(ids)
                entries.removeAll { removing.contains($0) }
            case let .addTracks(_, target?) where target == ref:
                return nil
            case let .syncPlaylist(target, _) where target == ref:
                return nil
            case let .playlist(edit):
                switch edit {
                case let .addTracks(target, ids) where target == ref:
                    let added = ids.compactMap { Int($0) }
                    guard added.count == ids.count else { return nil }
                    entries += added
                case let .removeTracks(target, picked) where target == ref:
                    guard let positions = positions(picked, in: entries) else { return nil }
                    entries = entries.enumerated().filter { !positions.contains($0.offset) }.map(\.element)
                case let .moveTracks(target, picked, to) where target == ref:
                    guard let positions = positions(picked, in: entries) else { return nil }
                    var order = entries.enumerated().filter { !positions.contains($0.offset) }.map(\.element)
                    order.insert(contentsOf: positions.sorted().map { entries[$0] }, at: min(max(to - 1, 0), order.count))
                    entries = order
                case let .delete(target):
                    // 지운 폴더 안의 목록도 없어진다
                    if target == ref || ancestors(of: playlist, in: library).contains(target) { return nil }
                default:
                    continue
                }
            default:
                continue
            }
        }
        return entries
    }

    /// 초안이 항목을 바꾼 목록을 얹은 라이브러리. 항목은 목록이 있는 모든 형식에 같게 둔다(항목 편집은 두 형식이 같은 목록만 받는다).
    /// 얹은 모양을 모르는 목록은 읽은 그대로 둔다
    public static func library(_ library: UsbLibrary, edits: [UsbLibraryEdit]) -> UsbLibrary {
        guard edits.contains(where: touchesEntries) else { return library }
        var projected = library
        for index in projected.playlists.indices where projected.playlists[index].attribute == 0 {
            let playlist = projected.playlists[index]
            let present = UsbFormat.allCases.filter(playlist.presentIn.contains)
            let lists = present.map { playlist.entries[$0] ?? [] }
            guard lists.allSatisfy({ $0 == lists.first }), let entries = entries(of: playlist, library: library, edits: edits),
                  entries != lists.first ?? [] else { continue }
            for format in present { projected.playlists[index].entries[format] = entries }
        }
        return projected
    }

    /// 목록 항목을 바꿀 수 있는 편집
    public static func touchesEntries(_ edit: UsbLibraryEdit) -> Bool {
        switch edit {
        case .removeTracks, .addTracks(_, .some), .syncPlaylist: true
        case let .playlist(edit):
            switch edit {
            case .addTracks, .removeTracks, .moveTracks, .delete: true
            case .create, .rename, .move, .reorder: false
            }
        case .addTracks(_, .none), .refreshTracks, .syncSelection: false
        }
    }

    /// 자리(1부터)마다 그 자리의 곡이 같은지 보고 0부터의 자리를 돌려준다(계획의 `matching`과 같다)
    private static func positions(_ picked: [PlaylistEntry], in entries: [Int]) -> Set<Int>? {
        var positions: Set<Int> = []
        for entry in picked {
            guard entry.trackNo >= 1, entry.trackNo <= entries.count, String(entries[entry.trackNo - 1]) == entry.contentID,
                  positions.insert(entry.trackNo - 1).inserted else { return nil }
        }
        return positions
    }

    private static func ancestors(of playlist: UsbPlaylist, in library: UsbLibrary) -> [PlaylistRef] {
        var result: [PlaylistRef] = [], seen: Set<Int> = [playlist.id], parent = playlist.parentID
        while parent != 0, seen.insert(parent).inserted {
            result.append(.id(String(parent)))
            parent = library.playlists.first { $0.id == parent }?.parentID ?? 0
        }
        return result
    }
}
