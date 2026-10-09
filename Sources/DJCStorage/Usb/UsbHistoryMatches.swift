import DJCDomain

/// 보존한 USB 원본 키를 현재 스냅샷과 다시 견준다. USB가 빠져도 오래된 ContentID를 그대로 믿지 않는다.
public enum UsbHistoryMatches {
    /// 로컬 키를 아직 모르거나 검증하지 못했으면 짝을 비운다. 제목·경로·재생 순서·쓴 표시는 그대로 남긴다.
    public static func rematch(_ archived: [ArchivedHistory], localDBID: Int64?, local: [UsbLocalTrackKey],
                               masterDBIDs: [String: Int64] = [:]) -> [ArchivedHistory] {
        var families: [Int64: [Int64: [UsbLocalTrackKey]]] = [:]
        if let localDBID {
            for track in local {
                if let songID = Int64(track.masterSongID) {
                    let databaseID = masterDBIDs[track.contentID] ?? localDBID
                    families[databaseID, default: [:]][songID, default: []].append(track)
                }
            }
        }
        var matches: [UsbTrackKey: String] = [:]
        var checked: Set<UsbTrackKey> = []
        return archived.map { history in
            var history = history
            history.entries = history.entries.map { entry in
                var entry = entry
                guard !entry.fileName.isEmpty else {
                    entry.contentID = nil
                    return entry
                }
                let key = UsbTrackKey(masterDbId: entry.masterDbId, masterContentId: entry.masterContentId, fileName: entry.fileName)
                if localDBID != nil, checked.insert(key).inserted {
                    // MasterSongID만으로 이어 붙이지 않고 기존 파일 이름·모호성 규칙까지 적용한다.
                    let candidates = families[entry.masterDbId]?[entry.masterContentId] ?? []
                    matches[key] = UsbTrackMatch.match(key, localDBID: entry.masterDbId, local: candidates)
                }
                entry.contentID = matches[key]
                return entry
            }
            return history
        }
    }
}
