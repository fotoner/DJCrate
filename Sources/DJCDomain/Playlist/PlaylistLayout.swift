import Foundation

/// 재생 목록·폴더 트리(입출력 없음). rekordbox에서 읽은 상태에 초안 편집을 얹어 화면에 보일 모양을 만들고, 편집을 쓸 수 있는지 미리 본다.
/// 편집 규칙은 rekordbox 7.2.18 화면과 같게 쓰는 `RekordboxWriter+Playlist`를 따른다(새 항목은 부모 맨 위, 옮기면 새 부모 맨 끝,
/// 곡은 가장 큰 TrackNo 다음부터, 빼거나 옮기면 1부터 다시 매김). 막는 조건과 이유 문구도 같다.
public struct PlaylistLayout: Hashable, Sendable {
    /// 맨 위(부모 ID)
    public static let root = "root"

    public struct Item: Codable, Hashable, Sendable, Identifiable {
        /// rekordbox ID. 초안으로 만든 목록은 `new:키`(`PlaylistRef.new`).
        public var id: String
        public var name: String
        public var parentID: String
        public var isFolder: Bool
        /// 인텔리전트 재생 목록(규칙을 확인하지 않아 편집하지 않는다)
        public var isSmart: Bool
        /// 곡 항목(TrackNo 순서). 같은 곡이 여러 번 들 수 있다.
        public var entries: [PlaylistEntry]

        public init(id: String, name: String, parentID: String = PlaylistLayout.root, isFolder: Bool = false, isSmart: Bool = false,
                    entries: [PlaylistEntry] = []) {
            self.id = id
            self.name = name
            self.parentID = parentID
            self.isFolder = isFolder
            self.isSmart = isSmart
            self.entries = entries
        }

        /// 곡 ContentID(TrackNo 순서)
        public var trackIDs: [String] { entries.map(\.contentID) }
        /// 초안으로 만든 목록
        public var isNew: Bool { id.hasPrefix("new:") }
        /// 곡을 넣고 뺄 수 있는 목록(폴더·인텔리전트 목록이 아님)
        public var holdsTracks: Bool { !isFolder && !isSmart }

        /// 그 곡들의 모든 자리(목록에서 빼기: 같은 곡이 여러 번 들었어도 목록에는 한 줄이라 모두 뺀다)
        public func entries(of contentIDs: Set<String>) -> [PlaylistEntry] {
            entries.filter { contentIDs.contains($0.contentID) }
        }

        /// 그 곡들의 처음 자리(목록에 보이는 줄). 끌어 옮길 때 쓴다.
        public func firstEntries(of contentIDs: Set<String>) -> [PlaylistEntry] {
            var seen = Set<String>()
            return entries.filter { contentIDs.contains($0.contentID) && seen.insert($0.contentID).inserted }
        }

        /// `moveTracks`의 `to`: 옮기는 곡을 뺀 목록에서 `before` 곡(처음 자리) 앞 자리(1부터). nil이면 맨 끝.
        public func insertionPoint(before contentID: String?, moving: [PlaylistEntry]) -> Int {
            let moving = Set(moving)
            let rest = entries.filter { !moving.contains($0) }
            guard let contentID, let index = rest.firstIndex(where: { $0.contentID == contentID }) else { return rest.count + 1 }
            return index + 1
        }

        /// 넣을 곡을 새 곡과 이미 든 곡으로 가른다(넣을 곡 안의 중복도 한 번만).
        public func split(adding contentIDs: [String]) -> (new: [String], duplicates: [String]) {
            var present = Set(trackIDs), new: [String] = [], duplicates: [String] = []
            for id in contentIDs {
                if present.contains(id) {
                    if !new.contains(id), !duplicates.contains(id) { duplicates.append(id) }
                } else {
                    new.append(id)
                    present.insert(id)
                }
            }
            return (new, duplicates)
        }
    }

    /// 편집을 쓸 수 없는 이유
    public struct Blocked: Error, Hashable, Sendable, CustomStringConvertible {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    public private(set) var items: [String: Item] = [:]
    /// 부모 → 자식 ID(부모 안 순서)
    private var order: [String: [String]] = [:]

    public init() {}

    /// `seq`는 부모 안 순서(rekordbox `Seq`). 같으면 ID 순서(쓰기 모듈과 같다).
    public init(_ entries: [(item: Item, seq: Int)]) {
        for entry in entries { items[entry.item.id] = entry.item }
        for (parent, children) in Dictionary(grouping: entries, by: { $0.item.parentID }) {
            order[parent] = children.sorted { ($0.seq, $0.item.id) < ($1.seq, $1.item.id) }.map(\.item.id)
        }
    }

    public func item(_ id: String) -> Item? { items[id] }

    public func childIDs(of parent: String) -> [String] { order[parent] ?? [] }

    public func children(of parent: String) -> [Item] { childIDs(of: parent).compactMap { items[$0] } }

    /// 자신과 그 아래 모든 목록·폴더 ID(위에서부터)
    public func subtree(of id: String) -> [String] { [id] + childIDs(of: id).flatMap { subtree(of: $0) } }

    /// 맨 위에서 그 항목 바로 위 폴더까지
    public func ancestors(of id: String) -> [Item] {
        var chain: [Item] = [], seen = Set<String>()
        var current = items[id]?.parentID
        while let parent = current, parent != Self.root, let item = items[parent], seen.insert(parent).inserted {
            chain.insert(item, at: 0)
            current = item.parentID
        }
        return chain
    }

    /// 맨 위부터 트리 순서로 모든 항목
    public var outline: [Item] { childIDs(of: Self.root).flatMap { subtree(of: $0) }.compactMap { items[$0] } }

    // MARK: - 편집 얹기

    /// 편집 하나를 얹는다. 쓰기 모듈이 막는 편집이면 `Blocked`를 던지고 그대로 둔다(컬렉션에 없는 곡은 여기서 모른다).
    public mutating func apply(_ edit: PlaylistEdit) throws {
        switch edit {
        case let .create(key, name, isFolder, parent):
            let id = PlaylistRef.new(key).description
            guard items[id] == nil else { throw Blocked(String(ui: "같은 묶음에 같은 key(\(key))로 만든 목록이 있습니다")) }
            guard !Self.isBlank(name) else { throw Blocked(String(ui: "이름을 적어 주세요")) }
            let parentID = try folderID(parent, for: name)
            items[id] = Item(id: id, name: name, parentID: parentID, isFolder: isFolder)
            order[parentID, default: []].insert(id, at: 0)

        case let .rename(ref, name):
            let item = try target(ref)
            guard !Self.isBlank(name) else { throw Blocked(String(ui: "이름을 적어 주세요")) }
            items[item.id]?.name = name

        case let .move(ref, into):
            let item = try target(ref)
            let parentID = try folderID(into, for: item.name)
            guard parentID != item.parentID else { return }
            guard !subtree(of: item.id).contains(parentID) else { throw Blocked(String(ui: "폴더를 제 안으로 옮길 수 없습니다")) }
            order[item.parentID]?.removeAll { $0 == item.id }
            order[parentID, default: []].append(item.id)
            items[item.id]?.parentID = parentID

        case let .reorder(ref, index):
            let item = try target(ref)
            var siblings = childIDs(of: item.parentID).filter { $0 != item.id }
            siblings.insert(item.id, at: min(max(index, 0), siblings.count))
            order[item.parentID] = siblings

        case let .delete(ref):
            let item = try target(ref)
            for id in subtree(of: item.id) {
                items[id] = nil
                order[id] = nil
            }
            order[item.parentID]?.removeAll { $0 == item.id }

        case let .addTracks(ref, contentIDs):
            let item = try trackList(ref)
            let start = item.entries.map(\.trackNo).max() ?? 0
            items[item.id]?.entries += contentIDs.enumerated().map { PlaylistEntry(trackNo: start + $0.offset + 1, contentID: $0.element) }

        case let .removeTracks(ref, entries):
            let item = try trackList(ref)
            let picked = try matching(entries, in: item)
            let rest = item.entries.indices.filter { !picked.contains($0) }.map { item.entries[$0] }
            items[item.id]?.entries = picked.isEmpty ? item.entries : Self.renumbered(rest)

        case let .moveTracks(ref, entries, to):
            let item = try trackList(ref)
            let picked = try matching(entries, in: item)
            var rest = item.entries.indices.filter { !picked.contains($0) }.map { item.entries[$0] }
            rest.insert(contentsOf: picked.map { item.entries[$0] }, at: min(max(to - 1, 0), rest.count))
            items[item.id]?.entries = Self.renumbered(rest)
        }
    }

    static func isBlank(_ name: String) -> Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func renumbered(_ entries: [PlaylistEntry]) -> [PlaylistEntry] {
        entries.enumerated().map { PlaylistEntry(trackNo: $0.offset + 1, contentID: $0.element.contentID) }
    }

    /// 편집할 목록(맨 위는 안 됨, 인텔리전트 목록은 막음)
    func target(_ ref: PlaylistRef) throws -> Item {
        switch ref {
        case .root: throw Blocked(String(ui: "맨 위는 편집할 수 없습니다"))
        case .new:
            guard let item = items[ref.description] else { throw Blocked(String(ui: "앞에서 만들지 못한 목록입니다")) }
            return item
        case let .id(id):
            guard let item = items[id] else { throw Blocked(String(ui: "rekordbox에서 재생 목록을 찾지 못했습니다")) }
            guard !item.isSmart else { throw Blocked(String(ui: "인텔리전트 재생 목록은 아직 쓰지 않습니다(rekordbox에서 고치세요)")) }
            return item
        }
    }

    func trackList(_ ref: PlaylistRef) throws -> Item {
        let item = try target(ref)
        guard !item.isFolder else { throw Blocked(String(ui: "폴더에는 곡을 넣거나 뺄 수 없습니다")) }
        return item
    }

    func folderID(_ ref: PlaylistRef, for name: String) throws -> String {
        if ref == .root { return Self.root }
        let item = try target(ref)
        guard item.isFolder else { throw Blocked(String(ui: "폴더가 아닌 재생 목록(\(item.name)) 안에는 넣을 수 없습니다")) }
        return item.id
    }

    /// 편집이 가리키는 곡 자리(TrackNo 순서의 번호). 그 자리에 그 곡이 없으면 막는다.
    func matching(_ entries: [PlaylistEntry], in item: Item) throws -> [Int] {
        guard Set(entries.map(\.trackNo)).count == entries.count else { throw Blocked(String(ui: "같은 자리를 두 번 가리킵니다")) }
        return try entries.map { entry in
            guard let index = item.entries.firstIndex(of: entry) else {
                throw Blocked(String(ui: "\(entry.trackNo)번째 곡이 편집을 만들 때와 다릅니다. 목록을 다시 읽은 뒤 고치세요"))
            }
            return index
        }.sorted()
    }
}

public extension PlaylistRef {
    /// 트리(`PlaylistLayout`) 안 ID: `root`, rekordbox ID, `new:키`
    var layoutID: String { description }
}

public extension PlaylistEdit {
    /// 새 목록을 넣거나 옮겨 넣을 곳(만들기의 부모, 옮기기의 폴더)
    var destination: PlaylistRef? {
        switch self {
        case let .create(_, _, _, parent): parent
        case let .move(_, into): into
        default: nil
        }
    }
}
