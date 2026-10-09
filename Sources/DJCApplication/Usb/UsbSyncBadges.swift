import DJCDomain
import Foundation

/// 곡마다 로컬 곡과 견준 갱신 상태
public enum UsbSyncBadges {
    /// 로컬 키를 모르면(스냅샷을 아직 읽지 않음) 배지를 달지 않는다
    public static func compute(library: UsbLibrary, local: LocalLibraryKeys?) -> [Int: UsbSyncStatus] {
        evaluate(library: library, local: local).badges
    }

    /// 배지와 로컬 짝(USB content_id → 로컬 ContentID, 짝이 하나인 곡만). 동기화·큐 가져오기가 짝을 쓴다
    public static func evaluate(library: UsbLibrary, local: LocalLibraryKeys?) -> (badges: [Int: UsbSyncStatus], matches: [Int: String]) {
        guard let local else { return ([:], [:]) }
        // 쓰기 계획(`UsbEditPlanner.localPairs`)과 같은 규칙: 로컬 행의 MasterDBID·MasterSongID가 USB 곡의 값과 같은 행 중에서
        // 고른다. 이 라이브러리 DBID로 고르면 다른 라이브러리에서 가져온 곡을 계획은 잇고 고아 판정은 빼서 더하기·빼기가 번갈아 생긴다.
        struct Identity: Hashable { var database: Int64; var song: Int64 }
        let byIdentity = Dictionary(grouping: local.tracks) {
            Identity(database: local.masterDBID(of: $0.contentID), song: UsbSQLiteCast.integer($0.masterSongID) ?? 0)
        }
        var result: [Int: UsbSyncStatus] = [:]
        var matches: [Int: String] = [:]
        for track in library.tracks {
            let key = UsbTrackKey(masterDbId: track.masterDbId, masterContentId: track.masterContentId, fileName: track.fileName)
            let family = byIdentity[Identity(database: track.masterDbId, song: track.masterContentId)] ?? []
            guard let contentID = UsbTrackMatch.match(key, localDBID: track.masterDbId, local: family) else {
                result[track.id] = .missingLocal
                continue
            }
            matches[track.id] = contentID
            let counters = local.counters[contentID]
            let modified = max(track.hasModified, track.deviceFields.values.compactMap(\.hasModified).max() ?? 0)
            result[track.id] = UsbSyncStatus.compare(localInfo: counters?.information, localAnalysis: counters?.analysis,
                                                     localCue: counters?.cue, usbInfo: track.informationUpdateCount,
                                                     usbAnalysis: track.analysisDataUpdateCount, usbCue: track.cueUpdateCount,
                                                     hasModified: modified, hasCueRows: false)
        }
        return (result, matches)
    }
}
