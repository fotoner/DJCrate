import Foundation

/// UI의 원본 ID를 보존한다. 선택용 그룹은 USB의 실제 폴더로 만들지 않는다.
public struct UsbSyncSourceNode: Codable, Hashable, Sendable {
    public static let rekordboxSelectionID = "usb-sync-source:rekordbox"
    public static let iTunesSelectionID = "usb-sync-source:itunes"

    public let id: String
    public let parentID: String?
    public let isFolder: Bool
    /// masterPlaylists6.xml의 같은 NODE의 Timestamp. USB 선택 파일에 그대로 옮긴다(없으면 그 목록을 체크해 쓰지 않는다).
    public let timestamp: Int64?

    public init(id: String, parentID: String?, isFolder: Bool, timestamp: Int64? = nil) {
        self.id = id
        self.parentID = parentID
        self.isFolder = isFolder
        self.timestamp = timestamp
    }

    public var selectionNode: ITunesSyncSelection.Node {
        .init(id: id, parentID: parentID, isFolder: isFolder)
    }
}

/// 선택 당시의 두 sync 원문까지 보관해 다른 앱이 바꾼 선택을 덮지 않는다.
public struct UsbSyncSelectionDraft: Codable, Hashable, Sendable {
    public let localDBID: Int64
    public let sourceNodes: [UsbSyncSourceNode]
    public let selection: ITunesSyncSelection
    public let enabled: Bool
    public let playlistRefs: [String: PlaylistRef]
    /// 키가 없으면 선택 창을 열 때 그 형식의 파일도 없었다.
    public let baseFiles: [UsbFormat: Data]
    /// 동기화 켜짐(AutomaticSync)만 바꾼다. rekordbox처럼 선택·NODE는 원문 그대로 둔다.
    public let enabledOnly: Bool
    /// 동기화 계획이 USB에 넣지 않고 건너뛴 곡(iTunes 목록의 연결되지 않은 곡, 스트리밍 곡 등). rekordbox의 내보내기 기록처럼
    /// 쓰기를 막지 않고 미리 보기·확인·결과에 이유별 수로 알린다. 모두 곡 단위(`.track`) 막힘이다.
    public let skippedTracks: [UsbBlock]

    public init(localDBID: Int64, sourceNodes: [UsbSyncSourceNode], selection: ITunesSyncSelection,
                enabled: Bool, playlistRefs: [String: PlaylistRef], baseFiles: [UsbFormat: Data], enabledOnly: Bool = false,
                skippedTracks: [UsbBlock] = []) {
        self.localDBID = localDBID
        self.sourceNodes = sourceNodes
        self.selection = selection
        self.enabled = enabled
        self.playlistRefs = playlistRefs
        self.baseFiles = baseFiles
        self.enabledOnly = enabledOnly
        self.skippedTracks = skippedTracks
    }

    /// 켜짐만 바꾸는 초안. 원본 목록·선택은 쓰지 않는다.
    public static func enabledOnly(localDBID: Int64, enabled: Bool, baseFiles: [UsbFormat: Data]) -> Self {
        Self(localDBID: localDBID, sourceNodes: [], selection: ITunesSyncSelection(), enabled: enabled,
             playlistRefs: [:], baseFiles: baseFiles, enabledOnly: true)
    }

    private enum CodingKeys: String, CodingKey {
        case localDBID, sourceNodes, selection, enabled, playlistRefs, baseFiles, enabledOnly, skippedTracks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localDBID = try container.decode(Int64.self, forKey: .localDBID)
        sourceNodes = try container.decode([UsbSyncSourceNode].self, forKey: .sourceNodes)
        selection = try container.decode(ITunesSyncSelection.self, forKey: .selection)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        playlistRefs = try container.decode([String: PlaylistRef].self, forKey: .playlistRefs)
        baseFiles = try container.decode([UsbFormat: Data].self, forKey: .baseFiles)
        // 이 칸이 없던 초안은 선택 전체를 쓰는 초안이다.
        enabledOnly = try container.decodeIfPresent(Bool.self, forKey: .enabledOnly) ?? false
        skippedTracks = try container.decodeIfPresent([UsbBlock].self, forKey: .skippedTracks) ?? []
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(localDBID)
        hasher.combine(sourceNodes)
        hasher.combine(selection.selectedIDs)
        hasher.combine(enabled)
        hasher.combine(playlistRefs)
        hasher.combine(baseFiles)
        hasher.combine(enabledOnly)
        hasher.combine(skippedTracks)
    }
}
