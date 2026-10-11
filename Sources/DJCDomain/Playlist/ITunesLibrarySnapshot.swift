import Foundation

/// iTunes 동기화 선택·목록 파일을 읽지 못함(rekordbox 동기화 정보가 깨졌거나 목록 계층이 맞지 않음)
public enum ITunesSelectionError: Error, LocalizedError {
    case invalidFile
    public var errorDescription: String? {
        String(ui: "iTunes 동기화 정보를 읽을 수 없습니다. rekordbox에서 iTunes 목록을 다시 동기화한 뒤 새 스냅샷을 뜨세요.")
    }
}

/// DB 스냅샷 옆에 보관하는 iTunes 목록 사본(값). Music·rekordbox에는 쓰지 않는다. 파일 읽기·쓰기와 동기화 파일 해석은 DJCStorage가 한다.
public struct ITunesLibrarySnapshot: Codable, Equatable, Sendable {
    public struct Playlist: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var parentID: String?
        public var isFolder: Bool
        /// 로컬 위치가 없는 곡도 nil로 남겨 누락 개수를 알린다.
        public var paths: [String?]

        public init(id: String, name: String, parentID: String? = nil, isFolder: Bool = false, paths: [String?] = []) {
            self.id = id; self.name = name; self.parentID = parentID; self.isFolder = isFolder; self.paths = paths
        }
    }

    public enum Status: String, Codable, Sendable {
        case ready, stale, notCaptured, unavailable
        /// 아직 읽는 중이라 결과가 없다(처음 상태·뒤에서 Music을 읽는 동안). 화면에만 쓰고 사본 파일에는 쓰지 않는다.
        /// 읽기가 끝난 뒤 캡처한 목록이 없는 `notCaptured`와 구분한다.
        case loading
        public var message: String? {
            switch self {
            case .ready: nil
            case .loading: String(ui: "새 스냅샷을 뜨고 있습니다")
            case .stale: String(ui: "iTunes 목록 갱신에 실패해 이전 사본을 표시합니다. Music 접근 권한과 rekordbox의 iTunes 읽기 설정을 확인한 뒤 새로고침하세요.")
            case .notCaptured: String(ui: "이 사본에는 캡처한 iTunes 목록이 없습니다")
            case .unavailable: String(ui: "iTunes 목록을 읽지 못했으니 Music 접근 권한과 rekordbox의 iTunes 읽기 설정을 확인한 뒤 새로고침하세요.")
            }
        }
    }

    public var version = 1
    public var playlists: [Playlist]
    public var status: Status
    public var unavailablePlaylistCount: Int
    /// 선택 창과 이후 선택 변경에 쓰는 전체 보관함. 옛 사본에는 없다.
    public var sourcePlaylists: [Playlist]?
    public var selectedIDs: Set<String>?
    /// 선택 창을 연 뒤 외부에서 동기화 선택을 바꿨는지 검사할 원문.
    public var syncData: Data?
    public var availablePlaylists: [Playlist] { sourcePlaylists ?? playlists }
    public var selectionNodes: [ITunesSyncSelection.Node] {
        availablePlaylists.map { .init(id: $0.id, parentID: $0.parentID, isFolder: $0.isFolder) }
    }
    /// 선택 창을 처음 열 때의 선택. `rootSelected`: rekordbox 동기화 선택에서 맨 위(Music 보관함 전체)를 골랐는지
    /// (동기화 파일을 읽는 일은 RekordboxKit·DJCStorage가 한다, `initialSelection`)
    public func initialSelection(rootSelected: Bool) -> ITunesSyncSelection {
        // 옛 사본의 조상 폴더를 전체 선택으로 오해하지 않는다.
        var ids = selectedIDs ?? Set(playlists.filter { !$0.isFolder }.map(\.id))
        if rootSelected { ids.insert("0") }
        return ITunesSyncSelection(selectedIDs: ids)
    }

    public init(playlists: [Playlist] = [], status: Status = .ready, unavailablePlaylistCount: Int = 0,
                sourcePlaylists: [Playlist]? = nil, selectedIDs: Set<String>? = nil) {
        self.playlists = playlists; self.status = status; self.unavailablePlaylistCount = unavailablePlaylistCount
        self.sourcePlaylists = sourcePlaylists; self.selectedIDs = selectedIDs
    }

    public static func url(for database: URL) -> URL { database.appendingPathExtension("itunes.json") }

    public func applying(_ selection: ITunesSyncSelection) throws -> Self {
        var result = try Self.select(ids: selection.expandedIDs(in: selectionNodes), from: availablePlaylists)
        result.status = status
        result.selectedIDs = selection.selectedIDs
        result.syncData = syncData
        return result
    }

    /// 동기화 ID로만 고르고, 그 목록을 찾아갈 수 있도록 현재 조상 폴더를 함께 남긴다.
    public static func select(ids: Set<String>, from source: [Playlist]) throws -> Self {
        let normalized = try source.map { playlist -> Playlist in
            guard let id = normalizedID(playlist.id) else { throw ITunesSelectionError.invalidFile }
            var result = playlist
            result.id = id
            if let parent = playlist.parentID, parent != "0" {
                guard let normalizedParent = normalizedID(parent) else { throw ITunesSelectionError.invalidFile }
                result.parentID = normalizedParent
            } else { result.parentID = nil }
            return result
        }
        try validate(normalized)
        let byID = Dictionary(uniqueKeysWithValues: normalized.map { ($0.id, $0) })
        var included = ids.intersection(byID.keys)
        for id in Array(included) {
            var parent = byID[id]?.parentID
            while let ancestor = parent {
                included.insert(ancestor)
                parent = byID[ancestor]?.parentID
            }
        }
        return Self(playlists: normalized.filter { included.contains($0.id) },
                    unavailablePlaylistCount: ids.subtracting(byID.keys).count,
                    sourcePlaylists: normalized, selectedIDs: ids)
    }

    public static func validate(_ playlists: [Playlist]) throws {
        let byID = Dictionary(grouping: playlists, by: \.id)
        guard byID.values.allSatisfy({ $0.count == 1 }), playlists.allSatisfy({
            $0.id != "0" && normalizedID($0.id) == $0.id
        }) else { throw ITunesSelectionError.invalidFile }
        for playlist in playlists {
            var seen: Set<String> = [playlist.id]
            var parent = playlist.parentID
            while let id = parent {
                guard seen.insert(id).inserted, let ancestor = byID[id]?.first, ancestor.isFolder else {
                    throw ITunesSelectionError.invalidFile
                }
                parent = ancestor.parentID
            }
        }
    }

    /// Apple API는 UInt64, rekordbox는 앞의 0을 생략한 16진수로 같은 ID를 나타낸다.
    public static func normalizedID(_ text: String) -> String? {
        guard !text.isEmpty, text.count <= 16, text.allSatisfy(\.isHexDigit), let value = UInt64(text, radix: 16) else { return nil }
        return String(value, radix: 16).uppercased()
    }
}
