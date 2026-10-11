import Foundation

// USB 동기화 선택 파일(rekordbox의 Sync/Playlists 문서)을 원본 목록에 맞춰 푼 결과(값). 파일 읽기·풀기는 RekordboxKit
// `UsbSyncSelectionBundle`에 있다(#167).

/// 선택 파일을 쓸 수 없게 하는 문제(이유와 할 일)
public enum UsbSyncSelectionIssue: String, Codable, Hashable, Sendable {
    case formatConflict, databaseMismatch, sourceMissing, sourceAmbiguous, sourceStructure
    case deviceIDAmbiguous, missingFormatFile, unsupportedSource, enabledStateUnknown

    public var message: String {
        switch self {
        case .formatConflict:
            String(ui: "USB의 두 형식에 저장된 동기화 선택이 다릅니다. rekordbox에서 다시 동기화한 뒤 읽으세요")
        case .databaseMismatch:
            String(ui: "USB 동기화 선택이 다른 rekordbox 라이브러리에 연결되어 있습니다. 원래 라이브러리를 연 뒤 다시 동기화하세요")
        case .sourceMissing, .sourceAmbiguous:
            String(ui: "USB 동기화 선택의 원본 목록을 유일하게 찾지 못했습니다. 원본 목록을 읽은 뒤 다시 동기화하세요")
        case .sourceStructure:
            String(ui: "USB 동기화 선택의 폴더 구조가 원본과 다릅니다. rekordbox에서 다시 동기화한 뒤 읽으세요")
        case .deviceIDAmbiguous:
            String(ui: "USB 동기화 선택의 USB 목록 번호를 확인하지 못했습니다. rekordbox에서 다시 동기화한 뒤 읽으세요")
        case .missingFormatFile:
            String(ui: "USB의 한 형식에 동기화 선택 파일이 없습니다. rekordbox에서 두 형식을 다시 동기화한 뒤 읽으세요")
        case .unsupportedSource:
            String(ui: "USB 동기화 선택에 지원하지 않는 원본이 있습니다. rekordbox에서 동기화하세요")
        case .enabledStateUnknown:
            String(ui: "USB 동기화의 켜짐 상태를 확인하지 못했습니다. rekordbox에서 다시 동기화한 뒤 읽으세요")
        }
    }
}

/// 선택 파일을 원본 목록에 맞춰 푼 결과: 선택·켜짐·원본 → USB 목록 연결·지운 원본의 USB 목록·문제
public struct UsbSyncSelectionResolution: Sendable {
    public let selection: ITunesSyncSelection
    public let enabled: Bool?
    /// 두 형식이 같은 USB 목록을 가리키는 원본 → USB 목록 ID(합친 모델의 대표 번호). 동기화 연결로 쓴다.
    public let playlistIDs: [String: Int]
    /// 형식별 Dev_ID. 두 형식의 목록 번호가 다르면 서로 다를 수 있다(2026-10-08 실험).
    public let formatPlaylistIDs: [UsbFormat: [String: Int]]
    /// 로컬에서 지운 rekordbox 원본의 행이 가리키던 USB 목록(두 형식이 같은 목록을 가리킬 때만, 대표 번호). rekordbox는 SYNC 때 이 목록을 지운다.
    public let removedSourcePlaylistIDs: Set<Int>
    public let issues: [UsbSyncSelectionIssue]
    public var canWrite: Bool { issues.isEmpty }

    public init(selection: ITunesSyncSelection, enabled: Bool?, playlistIDs: [String: Int], formatPlaylistIDs: [UsbFormat: [String: Int]],
                removedSourcePlaylistIDs: Set<Int>, issues: [UsbSyncSelectionIssue]) {
        self.selection = selection
        self.enabled = enabled
        self.playlistIDs = playlistIDs
        self.formatPlaylistIDs = formatPlaylistIDs
        self.removedSourcePlaylistIDs = removedSourcePlaylistIDs
        self.issues = issues
    }
}

