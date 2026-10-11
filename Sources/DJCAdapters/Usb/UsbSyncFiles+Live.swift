import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

extension UsbSyncFiles {
    /// 실제 파일: USB 선택 파일은 RekordboxKit `UsbSyncSelectionBundle`(허용한 두 파일만), masterPlaylists6.xml은 스냅샷 옆 사본
    /// (`LibrarySnapshot.masterPlaylistsURL`), 설정은 DJCStorage `UsbSyncPreferencesStore`(손상 파일은 오류로 알리고 보존)
    public static let live = UsbSyncFiles(
        selection: { root, formats in
            let bundle = try UsbSyncSelectionBundle.read(root: UsbRoot(root), formats: formats)
            return UsbSyncNativeSelection(baseFiles: bundle.baseFiles, semanticFingerprint: bundle.semanticFingerprint) { nodes, localDBID, library, master in
                bundle.resolution(sourceNodes: nodes, localDBID: localDBID,
                                  usbPlaylistIDs: library.map(UsbSyncSelectionBundle.playlistIDs(of:)),
                                  representatives: library.map(UsbSyncSelectionBundle.representatives(of:)),
                                  masterNodeIDs: master)
            }
        },
        masterNodes: { snapshot in (try? MasterPlaylistsXML(contentsOf: LibrarySnapshot.masterPlaylistsURL(of: snapshot)))?.nodes ?? [] },
        preferences: { directory in
            UsbSyncPreferencesFiles(load: { try UsbSyncPreferencesStore(directory: directory).load(volumeKey: $0) },
                                    save: { try UsbSyncPreferencesStore(directory: directory).save($0) })
        })
}
