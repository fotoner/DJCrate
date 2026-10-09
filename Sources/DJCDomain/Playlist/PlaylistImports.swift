import Foundation

/// 컬렉션 등록을 기다리는 목록 연결. 완료한 연결도 남겨 재시작·재가져오기 때 중복을 막는다.
public struct PlaylistImports: Codable, Hashable, Sendable {
    public struct Source: Codable, Hashable, Sendable {
        public var libraryID: String
        public var playlistID: String
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var path: String
        public var position: Int
        public var contentID: String?
    }

    public struct Request: Codable, Hashable, Sendable {
        public var source: Source?
        public var target: PlaylistRef
        public var draftKey: String?
        public var name: String?
        public var created: Bool = false
        public var entries: [Entry] = []
    }

    public private(set) var requests: [Request] = []
    public init() {}
    public var pendingCount: Int { requests.reduce(0) { $0 + $1.entries.filter { $0.contentID == nil }.count } }

    public static func pathKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

    /// Apple Music의 폴더 정보는 이름이 없으므로 목록은 맨 위에 만든다. 같은 출처는 이름이 바뀌어도 같은 대상이다.
    /// - Parameters:
    ///   - unidentifiedLibraryID: 보관함 ID가 없는 출처를 묶을 ID(부르는 쪽이 새로 만든다)
    ///   - newKey: 새로 만들 목록의 초안 키
    public mutating func addAppleMusic(_ origins: [String: [AppleMusicOrigin]], unidentifiedLibraryID: String, newKey: () -> String) {
        for path in origins.keys.sorted() {
            for origin in origins[path] ?? [] {
                for playlist in origin.playlists {
                    let source = Source(libraryID: origin.libraryID ?? unidentifiedLibraryID, playlistID: playlist.id)
                    let index: Int
                    if let existing = requests.firstIndex(where: { $0.source == source }) {
                        index = existing
                    } else {
                        let key = newKey()
                        index = requests.count
                        requests.append(Request(source: source, target: .new(key), draftKey: key, name: playlist.name))
                    }
                    add(path: path, position: playlist.position, to: index)
                }
            }
        }
    }

    public mutating func addFiles(_ paths: [String], to target: PlaylistRef) {
        guard !paths.isEmpty else { return }
        let index: Int
        if let existing = requests.firstIndex(where: { $0.source == nil && $0.target == target }) {
            index = existing
        } else {
            index = requests.count
            let key: String? = if case let .new(key) = target { key } else { nil }
            requests.append(Request(target: target, draftKey: key))
        }
        for path in paths {
            add(path: path, position: requests[index].entries.count, to: index)
            // 파일을 다시 놓으면 새 추가 요청이다. 지금 목록에 이미 있는 곡은 확인할 때 뺀다.
            if let entry = requests[index].entries.firstIndex(where: { $0.path == Self.pathKey(path) }) {
                requests[index].entries[entry].contentID = nil
            }
        }
    }

    private mutating func add(path: String, position: Int, to index: Int) {
        let path = Self.pathKey(path)
        if let entry = requests[index].entries.firstIndex(where: { $0.path == path }) {
            requests[index].entries[entry].position = min(position, requests[index].entries[entry].position)
        } else {
            requests[index].entries.append(Entry(path: path, position: position))
        }
        requests[index].entries.sort { ($0.position, $0.path) < ($1.position, $1.path) }
    }

    /// 등록된 곡만 초안에 옮긴다. 한 목록에서 막히면 그 목록의 연결은 소비하지 않는다.
    /// 저장 순서는 초안 → 연결 상태다. 두 번째 저장이 실패해도 같은 키·곡은 다시 만들거나 넣지 않는다.
    public mutating func reconcile(contentIDsByPath: [String: String], draft: inout PlaylistDraft,
                                   rekordbox: PlaylistLayout) -> [String] {
        var reasons: [String] = []
        for index in requests.indices {
            var request = requests[index]
            let ready = request.entries.indices.filter { request.entries[$0].contentID == nil && contentIDsByPath[request.entries[$0].path] != nil }
            guard !ready.isEmpty else { continue }
            var next = draft
            do {
                var layout = next.project(onto: rekordbox).layout
                let id = request.target.layoutID
                if let reason = next.project(onto: rekordbox).blockedTargets[id] { throw PlaylistLayout.Blocked(reason) }
                if layout.item(id) == nil, !request.created, let name = request.name, case let .new(key) = request.target {
                    let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = base.isEmpty ? String(ui: "새 재생 목록") : base
                    let names = Set(layout.children(of: PlaylistLayout.root).map(\.name))
                    var unique = title, suffix = 2
                    while names.contains(unique) { unique = "\(title) (\(suffix))"; suffix += 1 }
                    layout = try next.append(.create(key: key, name: unique, isFolder: false, parent: .root), rekordbox: rekordbox)
                }
                guard let item = layout.item(id), item.holdsTracks else {
                    throw PlaylistLayout.Blocked(String(ui: "연결할 재생 목록이 없습니다. 추가한 곡을 원하는 목록에 다시 놓으세요."))
                }
                request.created = true
                for entryIndex in ready {
                    guard let contentID = contentIDsByPath[request.entries[entryIndex].path] else { continue }
                    let item = layout.item(id)!
                    if !item.trackIDs.contains(contentID) {
                        layout = try next.append(.addTracks(playlist: request.target, contentIDs: [contentID]), rekordbox: rekordbox)
                        // 나중 순서의 곡이 먼저 등록됐으면 그 앞에 끼워 넣는다. 기존 목록의 다른 곡은 옮기지 않는다.
                        if let before = request.entries.dropFirst(entryIndex + 1).compactMap(\.contentID).first(where: { layout.item(id)!.trackIDs.contains($0) }) {
                            let current = layout.item(id)!
                            let moving = current.firstEntries(of: [contentID])
                            layout = try next.append(.moveTracks(playlist: request.target, entries: moving,
                                                               to: current.insertionPoint(before: before, moving: moving)), rekordbox: rekordbox)
                        }
                    }
                    request.entries[entryIndex].contentID = contentID
                }
                requests[index] = request
                draft = next
            } catch let error as PlaylistLayout.Blocked {
                reasons.append(error.reason)
            } catch { reasons.append(error.localizedDescription) }
        }
        return reasons
    }

    public mutating func remapTargets(_ ids: [String: String]) {
        for index in requests.indices {
            if let id = ids[requests[index].target.layoutID] { requests[index].target = PlaylistRef(id) }
        }
    }

    public mutating func restoreTargets(createdKeys: Set<String>) {
        for index in requests.indices {
            if let key = requests[index].draftKey, createdKeys.contains(key) { requests[index].target = .new(key) }
        }
    }

    public mutating func removePending(paths: Set<String>) {
        let paths = Set(paths.map(Self.pathKey))
        for index in requests.indices { requests[index].entries.removeAll { $0.contentID == nil && paths.contains($0.path) } }
        requests.removeAll { $0.entries.isEmpty }
    }

    public mutating func reset(contentIDs: Set<String>) {
        for index in requests.indices {
            for entry in requests[index].entries.indices where requests[index].entries[entry].contentID.map(contentIDs.contains) == true {
                requests[index].entries[entry].contentID = nil
            }
        }
    }
}
