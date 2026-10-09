import Foundation

/// 마지막 동기화로 연결한 로컬 목록과 USB 목록. 경로는 USB에서 이름·부모가 바뀌었는지 확인할 때 쓴다.
public struct UsbSyncPlaylistBinding: Codable, Equatable, Sendable {
    public var usbID: Int
    public var path: [String]
    public var isFolder: Bool

    public init(usbID: Int, path: [String], isFolder: Bool) {
        self.usbID = usbID
        self.path = path
        self.isFolder = isFolder
    }
}

/// USB마다 기억하는 동기화 선택. 다른 로컬 라이브러리에서는 DBID를 확인한 뒤 선택을 다시 만든다.
public struct UsbSyncPreferences: Codable, Equatable, Sendable {
    public var volumeKey: String
    public var localDBID: Int64
    public var selection: ITunesSyncSelection
    public var syncPlaylists: Bool
    public var bindings: [String: UsbSyncPlaylistBinding]
    /// USB 선택 파일을 읽은 때의 의미 지문. 같을 때만 아직 쓰지 않은 앱 선택을 이어 쓴다.
    public var nativeSelectionFingerprint: String?

    public init(volumeKey: String, localDBID: Int64, selection: ITunesSyncSelection = ITunesSyncSelection(),
                syncPlaylists: Bool = true, bindings: [String: UsbSyncPlaylistBinding] = [:],
                nativeSelectionFingerprint: String? = nil) {
        self.volumeKey = volumeKey
        self.localDBID = localDBID
        self.selection = selection
        self.syncPlaylists = syncPlaylists
        self.bindings = bindings
        self.nativeSelectionFingerprint = nativeSelectionFingerprint
    }
}
