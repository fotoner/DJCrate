import DJCDomain
import Foundation

/// USB 원본이 바뀐 때는 rekordbox 선택을 다시 채택하고, 같은 원본에서 편집 중인 선택만 이어 쓴다.
public struct UsbSyncPreferenceChoice {
    public var selection: ITunesSyncSelection
    public var enabled: Bool
    public var usesSavedPreferences: Bool

    public static func resolve(preferences: UsbSyncPreferences?, localDBID: Int64, hasNativeFiles: Bool,
                        fingerprint: String?, nativeSelection: ITunesSyncSelection, nativeEnabled: Bool?,
                        fallbackSelection: ITunesSyncSelection, currentEnabled: Bool = true) -> Self {
        let sameLibrary = preferences?.localDBID == localDBID
        let sameNative = fingerprint != nil && preferences?.nativeSelectionFingerprint == fingerprint
        if sameLibrary, let preferences, !hasNativeFiles || sameNative {
            // 동기화하지 않은 체크는 닫을 때 버리므로(rekordbox와 같다, 2026-10-08 실험 G2a) 선택 파일이 있으면 그 선택과
            // 켜짐이 정본이다. 저장한 설정은 USB 목록 연결(bindings)을 잇는 데만 쓴다.
            guard hasNativeFiles else {
                return Self(selection: preferences.selection, enabled: preferences.syncPlaylists, usesSavedPreferences: true)
            }
            return Self(selection: nativeSelection, enabled: nativeEnabled ?? preferences.syncPlaylists, usesSavedPreferences: true)
        }
        if hasNativeFiles {
            return Self(selection: nativeSelection,
                        enabled: nativeEnabled ?? (sameLibrary ? preferences?.syncPlaylists : nil) ?? currentEnabled,
                        usesSavedPreferences: false)
        }
        // rekordbox는 선택 파일이 없는 USB를 "장치와 플레이리스트 동기화" 꺼짐으로 연다(2026-10-08 빈 USB 실험).
        return Self(selection: fallbackSelection, enabled: false, usesSavedPreferences: false)
    }

    /// 닫을 때 USB에 쓸 것이 있는지: "장치와 플레이리스트 동기화"를 USB 파일과 다르게 바꿨을 때만.
    /// 선택 파일이 없는 USB는 꺼짐으로 본다. 라이브러리가 없는 빈 USB는 켜짐만 쓰지 않는다(SYNC 때 DB와 함께 만든다)
    public static func enabledChanged(hasNativeFiles: Bool, nativeEnabled: Bool?, hasLibrary: Bool, syncPlaylists: Bool) -> Bool {
        guard hasNativeFiles else { return hasLibrary && syncPlaylists }
        return nativeEnabled != nil && nativeEnabled != syncPlaylists
    }

    /// USB의 선택과 다르게 체크했는지. 폴더 자체 체크와 하위를 모두 체크한 것은 선택 파일에서 다르다(폴더 행 1과 2)
    public static func selectionDiffers(_ selection: ITunesSyncSelection, from usb: ITunesSyncSelection,
                                        nodes: [ITunesSyncSelection.Node]) -> Bool {
        selection.selectedIDs.contains("0") != usb.selectedIDs.contains("0")
            || selection.expandedIDs(in: nodes) != usb.expandedIDs(in: nodes)
    }

    /// rekordbox는 동기화가 켜진 채 동기화하지 않은 변경(체크 변경, 켜기)이 있으면 닫을 때 지금 동기화할지 물었다
    /// (2026-10-08 실험 G2a·G3·G5c). 끄고 닫을 때는 묻지 않았다(G5a). SYNC를 누를 수 없는 상태면 묻지 않는다.
    public static func asksToSyncOnClose(syncPlaylists: Bool, canSync: Bool, selectionDiffers: Bool,
                                         enabledChanged: Bool) -> Bool {
        syncPlaylists && canSync && (selectionDiffers || enabledChanged)
    }
}
