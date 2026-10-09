import DJCApplication
import DJCDomain
import Foundation

extension UsbSyncPlan {
    /// 시험용: 새 목록의 초안 키를 앱과 같은 모양(`sync-<UUID>`)으로 만든다(앱은 동기화 창의 포트가 만든다)
    static func build(source: UsbSyncSource, selection: ITunesSyncSelection, library: UsbLibrary,
                      matches: [Int: String], badges: [Int: UsbSyncStatus], bindings: [String: UsbSyncPlaylistBinding],
                      linkedPlaylistIDs: [String: Int] = [:], removedPlaylistIDs: Set<Int> = [], excluding: Set<String> = []) throws -> UsbSyncPlan {
        try build(source: source, selection: selection, library: library, matches: matches, badges: badges, bindings: bindings,
                  linkedPlaylistIDs: linkedPlaylistIDs, removedPlaylistIDs: removedPlaylistIDs, excluding: excluding,
                  newKey: { "sync-" + UUID().uuidString.lowercased() })
    }
}
