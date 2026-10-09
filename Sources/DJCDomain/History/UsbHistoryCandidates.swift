import Foundation

/// USB 라이브러리(두 형식을 합친 `UsbLibrary`)의 기기 재생 기록 → 보존 후보(`UsbHistoryImport.Candidate`). 읽기만 한다.
public enum UsbHistoryCandidates {
    /// USB 라이브러리의 기기 기록 → 가져오기 후보. OneLibrary 먼저, 그다음 Device Library, 형식 안에서는 기록 번호 순.
    /// 항목이 없는 기록(폴더 행 등)은 뺀다. 곡 행이 없더라도 USB 번호·재생 순서를 남긴다.
    /// 곡 정보(제목·아티스트·경로·짝짓기 키)는 그 기록 형식의 원본 곡에서 읽는다.
    /// matches: UsbStore.localMatches[볼륨키] = (합친 라이브러리의 USB content_id → 로컬 ContentID)
    public static func make(library: UsbLibrary, volumeKey: String, volumeName: String, matches: [Int: String]) -> [UsbHistoryImport.Candidate] {
        let representative = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var tracksByFormat: [UsbFormat: [Int: UsbTrack]] = [:]
        var artistsByFormat: [UsbFormat: [Int: String]] = [:]
        for format in library.formats {
            let metadata = library.historyMetadata(in: format)
            tracksByFormat[format] = Dictionary(metadata.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            artistsByFormat[format] = Dictionary(metadata.artists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        let histories = library.histories.sorted { (order($0.format), $0.id) < (order($1.format), $1.id) }
        var candidates: [UsbHistoryImport.Candidate] = []
        for history in histories {
            var entries: [ArchivedHistory.Entry] = []
            for contentID in history.entries {
                guard let track = tracksByFormat[history.format]?[contentID] else {
                    // 곡이 지워졌거나 읽히지 않았어도 재생 항목을 버리지 않는다. 다른 형식의 같은 번호에 잇지 않는다
                    entries.append(ArchivedHistory.Entry(trackNumber: entries.count + 1, usbContentID: contentID, contentID: nil,
                                                          title: "USB #\(contentID)", artist: nil, path: "", masterDbId: 0,
                                                          masterContentId: 0, fileName: ""))
                    continue
                }
                // matches는 합친 모델의 대표 곡에 대한 짝이다. 같은 번호가 원래 형식에서 다른 곡이면 짝을 가져오지 않는다
                let match = representative[contentID].flatMap { current -> String? in
                    guard current.presentIn.contains(history.format), current.masterDbId == track.masterDbId,
                          current.masterContentId == track.masterContentId, UsbLayout.nfc(current.path) == UsbLayout.nfc(track.path),
                          UsbLayout.nfc(current.fileName) == UsbLayout.nfc(track.fileName) else { return nil }
                    return matches[contentID]
                }
                entries.append(ArchivedHistory.Entry(
                    trackNumber: entries.count + 1, usbContentID: contentID, contentID: match, title: track.title,
                    artist: track.artistID.flatMap { artistsByFormat[history.format]?[$0] }, path: track.path,
                    masterDbId: track.masterDbId, masterContentId: track.masterContentId, fileName: track.fileName,
                    bpm: track.bpmx100 > 0 ? Double(track.bpmx100) / 100 : nil, lengthSeconds: track.lengthSeconds > 0 ? track.lengthSeconds : nil))
            }
            guard !entries.isEmpty else { continue }
            let source = ArchivedHistory.Source(volumeKey: volumeKey, volumeName: volumeName, format: history.format.rawValue,
                                                historyID: history.id, historyName: history.name)
            candidates.append(UsbHistoryImport.Candidate(source: source, entries: entries))
        }
        return candidates
    }

    /// OneLibrary 먼저(`UsbFormat` 선언 순서)
    private static func order(_ format: UsbFormat) -> Int {
        UsbFormat.allCases.firstIndex(of: format) ?? UsbFormat.allCases.count
    }
}
