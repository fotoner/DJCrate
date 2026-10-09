
import Foundation

/// 목록 편집용 PlaylistLayout과 분리해 iTunes ID가 rekordbox 쓰기 대상으로 들어가지 않게 한다.
public struct SyncedITunesLibrary: Sendable {
    /// iTunes 목록의 곡을 rekordbox 컬렉션 곡에 잇지 못한 이유. USB 동기화는 이 곡을 빼고 이유별 수로 알린다
    public enum UnlinkedReason: String, CaseIterable, Sendable {
        /// Music에 로컬 파일 위치가 없다(스트리밍·클라우드에만 있는 곡)
        case noLocalFile
        /// 보호된 AAC(.m4p). rekordbox가 읽지 못해 컬렉션에 없다
        case protectedFile
        /// 같은 경로의 곡이 rekordbox 컬렉션에 없다
        case notInCollection
        /// 같은 경로의 곡이 rekordbox 컬렉션에 여럿이다
        case ambiguous

        /// USB 동기화 결과에 적는 한 문장(이유와 할 일)
        public var message: String {
            switch self {
            case .noLocalFile:
                String(ui: "Music에 음원 파일이 없는 곡(스트리밍·클라우드)이라 USB에 넣지 않았습니다. Music에서 내려받아 rekordbox 컬렉션에 넣은 뒤 다시 동기화하세요")
            case .protectedFile:
                String(ui: "보호된 음원(m4p)이라 rekordbox 컬렉션에 없어 USB에 넣지 않았습니다. 보호되지 않은 음원으로 바꿔 넣은 뒤 다시 동기화하세요")
            case .notInCollection:
                String(ui: "rekordbox 컬렉션에 없는 곡이라 USB에 넣지 않았습니다. rekordbox 컬렉션에 넣은 뒤 다시 동기화하세요")
            case .ambiguous:
                String(ui: "같은 음원 경로의 곡이 rekordbox 컬렉션에 여럿이라 USB에 넣지 않았습니다. 중복 곡을 정리한 뒤 다시 동기화하세요")
            }
        }
    }

    /// 잇지 못한 곡 하나. key는 같은 음원을 여러 목록에서 한 번만 세는 데 쓴다(위치가 없으면 nil이라 항목마다 센다)
    public struct Unlinked: Hashable, Sendable {
        public let reason: UnlinkedReason
        public let key: String?
        public init(reason: UnlinkedReason, key: String?) { self.reason = reason; self.key = key }
    }

    public struct Node: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let children: [Node]?
        public let trackIDs: [String]
        /// 연결된 곡의 원래 목록 순번. 누락된 곡의 자리는 건너뛴다.
        public let trackNumbers: [Int]
        public let unavailableTrackCount: Int
        /// 잇지 못한 곡(목록 순서). 폴더는 비어 있다(하위 목록이 따로 들고 있다)
        public let unlinked: [Unlinked]
        public var isFolder: Bool { children != nil }
    }

    public var tree: [Node] = []
    public var index: [String: Node] = [:]
    /// 읽기 전 처음 상태는 `.loading`. 읽기가 끝난 뒤의 `.notCaptured`와 구분한다.
    public var status: ITunesLibrarySnapshot.Status = .loading
    public var unavailablePlaylistCount = 0
    public var playlistCount: Int { index.values.filter { !$0.isFolder }.count }
    public init() {}

    public init(snapshot: ITunesLibrarySnapshot, tracks: [Track]) {
        status = snapshot.status
        unavailablePlaylistCount = snapshot.unavailablePlaylistCount
        guard status == .ready || status == .stale else { return }
        do { try ITunesLibrarySnapshot.validate(snapshot.playlists) }
        catch { status = .unavailable; return }
        let byPath = Dictionary(grouping: tracks.filter { !$0.isDeleted && !$0.isStreaming }, by: { Self.pathKey($0.folderPath) })
        let byParent = Dictionary(grouping: snapshot.playlists, by: { $0.parentID ?? "0" })
        func unique(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }
        }
        func build(_ parent: String) -> [Node] {
            (byParent[parent] ?? []).map { playlist in
                if playlist.isFolder {
                    let children = build(playlist.id)
                    let ids = unique(children.flatMap(\.trackIDs))
                    return Node(id: "itunes:\(playlist.id)", name: playlist.name, children: children,
                                trackIDs: ids, trackNumbers: Array(ids.indices.map { $0 + 1 }),
                                unavailableTrackCount: children.reduce(0) { $0 + $1.unavailableTrackCount }, unlinked: [])
                }
                var unlinked: [Unlinked] = []
                let entries = playlist.paths.enumerated().compactMap { position, path -> (String, Int)? in
                    guard let path else { unlinked.append(Unlinked(reason: .noLocalFile, key: nil)); return nil }
                    let key = Self.pathKey(path), matches = byPath[key] ?? []
                    guard matches.count == 1 else {
                        let reason: UnlinkedReason = if matches.count > 1 { .ambiguous }
                            else if (path as NSString).pathExtension.lowercased() == "m4p" { .protectedFile }
                            else { .notInCollection }
                        unlinked.append(Unlinked(reason: reason, key: key))
                        return nil
                    }
                    return (matches[0].id, position + 1)
                }
                return Node(id: "itunes:\(playlist.id)", name: playlist.name, children: nil,
                            trackIDs: entries.map(\.0), trackNumbers: entries.map(\.1), unavailableTrackCount: unlinked.count,
                            unlinked: unlinked)
            }
        }
        tree = build("0")
        func walk(_ nodes: [Node]) {
            for node in nodes { index[node.id] = node; walk(node.children ?? []) }
        }
        walk(tree)
    }

    public static func pathKey(_ path: String) -> String {
        URL(filePath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
}
