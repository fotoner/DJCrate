import Foundation

/// rekordbox 플레이리스트·폴더(djmdPlaylist / djmdSongPlaylist, 값). 읽기는 RekordboxKit(`RekordboxLibrary.load`)이 한다.
public struct RekordboxPlaylist: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let parentID: String
    public let seq: Int
    /// Attribute 1 = 폴더, 0 = 플레이리스트, 4 = 인텔리전트 재생 목록(`isSmart`, 조건은 `smartSource`)
    public let isFolder: Bool
    /// TrackNo 순서의 ContentID
    public let trackIDs: [String]
    /// `trackIDs`와 같은 순서의 TrackNo(빈칸이 있을 수 있다). 곡 빼기·옮기기 편집이 자리를 이것으로 가리킨다.
    public var trackNumbers: [Int] = []
    /// 인텔리전트 재생 목록(Attribute 4 또는 SmartList 규칙이 있음). 편집하지 않는다.
    public var isSmart = false
    /// 인텔리전트 목록의 조건 칸을 읽은 결과(`isSmart`일 때만). 읽기 전용이고 곡 항목(`trackIDs`)·편집 가능 여부에는 영향이 없다(#68).
    public var smartSource: SmartPlaylistSource?

    public init(id: String, name: String, parentID: String, seq: Int, isFolder: Bool, trackIDs: [String], trackNumbers: [Int] = [],
                isSmart: Bool = false, smartSource: SmartPlaylistSource? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.seq = seq
        self.isFolder = isFolder
        self.trackIDs = trackIDs
        self.trackNumbers = trackNumbers
        self.isSmart = isSmart
        self.smartSource = smartSource
    }
}

public extension PlaylistLayout {
    /// 스냅샷에서 읽은 재생 목록 → 초안을 얹을 트리
    init(rekordbox playlists: [RekordboxPlaylist]) {
        self.init(playlists.map { playlist in
            let numbered = playlist.trackNumbers.count == playlist.trackIDs.count
            let entries = playlist.trackIDs.enumerated().map {
                PlaylistEntry(trackNo: numbered ? playlist.trackNumbers[$0.offset] : $0.offset + 1, contentID: $0.element)
            }
            return (PlaylistLayout.Item(id: playlist.id, name: playlist.name, parentID: playlist.parentID, isFolder: playlist.isFolder,
                                        isSmart: playlist.isSmart, entries: entries), playlist.seq)
        })
    }
}

/// 사이드바 트리 노드. `children`이 nil이면 잎(플레이리스트)이다.
public struct PlaylistNode: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let isFolder: Bool
    public let children: [PlaylistNode]?
    /// 폴더면 하위 플레이리스트 곡을 순서대로 모은 것(중복 제거).
    public let trackIDs: [String]

    public static func tree(_ playlists: [RekordboxPlaylist]) -> [PlaylistNode] {
        let byParent = Dictionary(grouping: playlists, by: \.parentID)
        func build(_ parent: String) -> [PlaylistNode] {
            (byParent[parent] ?? []).sorted { $0.seq < $1.seq }.map { playlist in
                if playlist.isFolder {
                    let children = build(playlist.id)
                    var seen = Set<String>()
                    let tracks = children.flatMap(\.trackIDs).filter { seen.insert($0).inserted }
                    return PlaylistNode(id: playlist.id, name: playlist.name, isFolder: true,
                                        children: children, trackIDs: tracks)
                }
                // rekordbox는 같은 곡을 한 플레이리스트에 여러 번 넣을 수 있다(실데이터 19건).
                // 표 선택은 곡 ID가 유일해야 하므로 첫 등장만 남긴다.
                var seen = Set<String>()
                return PlaylistNode(id: playlist.id, name: playlist.name, isFolder: false,
                                    children: nil, trackIDs: playlist.trackIDs.filter { seen.insert($0).inserted })
            }
        }
        return build("root")
    }

    public func find(_ id: String) -> PlaylistNode? {
        if self.id == id { return self }
        for child in children ?? [] {
            if let hit = child.find(id) { return hit }
        }
        return nil
    }
}
