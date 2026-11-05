import Foundation

/// PRO DJ LINK 재생 기록(입출력 없음). DJCrate가 LINK로 라이브러리를 내어 주는 동안 CDJ가 "틀었다"고 알린 곡을
/// rekordbox의 "LINK HISTORY yyyy-MM-dd"처럼 기록한다. 기록은 USB 기기 기록과 같은 보존본(`ArchivedHistory`)으로 DJCrate에
/// 바로 남기고, rekordbox에는 다른 초안처럼 rekordbox에 쓰기 때 넣는다(`HistoryWriteQueue`). 쓰기 칸은 USB 기록과 같다
/// (2026-10-16 rekordbox 7.2.x가 만든 LINK HISTORY를 스냅샷으로 비교: 이름만 다르고 `DJPlayCount` +1까지 같다).
public enum LinkHistory {
    /// LINK 기록의 출처 표시. USB 기록 키(볼륨 UUID)와 겹치지 않는 값을 쓰고, 세션은 `historyName`에 둔다
    public static let volumeKey = "pro-dj-link"
    public static let format = "link"

    /// LINK 세션(서버를 한 번 띄운 동안) 하나의 출처
    public static func source(session: String) -> ArchivedHistory.Source {
        ArchivedHistory.Source(volumeKey: volumeKey, volumeName: "PRO DJ LINK", format: format, historyID: 0, historyName: session)
    }

    /// 곡 하나를 기록했을 때의 보존본(새로 만들었거나 곡을 더한 것)
    public struct Recorded: Sendable, Equatable {
        public var history: ArchivedHistory
        /// 이번에 새로 만든 기록인지(사이드바에 펼쳐 보인다)
        public var isNew: Bool
    }

    /// CDJ가 알린 재생 곡 하나를 기록한다. 그 세션의 쓰지 않은 기록이 있으면 끝에 더하고, 없으면 새 기록을 만든다.
    /// rekordbox에 이미 쓴 기록에는 더하지 않는다(쓴 기록에 곡을 더하는 쓰기는 없다). 연결 중인 기록은 쓰기 대기에 오르지 않으므로(`isOpen`)
    /// 보통은 생기지 않는다.
    /// - Parameters:
    ///   - entry: 기록할 곡(번호는 여기서 매긴다)
    ///   - session: LINK 세션 열쇠(서버를 띄울 때마다 새로)
    ///   - existing: 지금 보존한 기록 전부(이름 충돌·세션 기록 찾기)
    ///   - now: 기록한 시각(새 기록의 날짜·이름)
    public static func record(_ entry: ArchivedHistory.Entry, session: String, existing: [ArchivedHistory], now: Date,
                              calendar: Calendar, makeID: () -> String) -> Recorded {
        if var open = openHistory(session: session, in: existing) {
            var entry = entry
            entry.trackNumber = (open.entries.map(\.trackNumber).max() ?? 0) + 1
            open.entries.append(entry)
            return Recorded(history: open, isNew: false)
        }
        // 저장 파일(ISO 8601)은 초 아래를 버린다. 다시 읽은 값과 같게 초 단위로 맞춘다
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let name = HistoryNaming.name(for: now, calendar: calendar, taken: Set(existing.map(\.name)), prefix: HistoryNaming.linkPrefix)
        var first = entry
        first.trackNumber = 1
        let history = ArchivedHistory(id: ArchivedHistory.idPrefix + "link-" + makeID(), name: name, importedAt: now,
                                      sequence: (existing.map(\.sequence).max() ?? 0) + 1, source: source(session: session),
                                      entries: [first])
        return Recorded(history: history, isNew: true)
    }

    /// CDJ가 기록에서 뺀 곡: 그 세션의 쓰지 않은 기록에서 그 곡의 마지막 줄을 빼고 번호를 다시 매긴다. 뺄 것이 없으면 nil
    public static func remove(contentID: String, session: String, existing: [ArchivedHistory]) -> ArchivedHistory? {
        guard var open = openHistory(session: session, in: existing),
              let index = open.entries.lastIndex(where: { $0.contentID == contentID }) else { return nil }
        open.entries.remove(at: index)
        for position in open.entries.indices { open.entries[position].trackNumber = position + 1 }
        return open
    }

    /// 그 세션에서 아직 rekordbox에 쓰지 않은 마지막 기록
    static func openHistory(session: String, in existing: [ArchivedHistory]) -> ArchivedHistory? {
        existing.last { $0.source.isLink && $0.source.historyName == session && $0.rekordboxHistoryID == nil }
    }

    /// 연결 중인 LINK 세션의 기록인지. 이 기록은 곡이 계속 붙으므로 rekordbox 쓰기 대기에 올리지 않는다
    /// (쓰는 사이 붙은 곡이 쓴 표시에 묻히지 않게). LINK를 끄면(앱을 다시 켜도) 세션이 닫혀 대기에 오른다
    public static func isOpen(_ history: ArchivedHistory, openSessions: Set<String>) -> Bool {
        history.source.isLink && openSessions.contains(history.source.historyName)
    }

    /// 컬렉션 곡 하나의 기록 줄. 원본 키는 그 곡 자신(MasterDBID·MasterSongID·FileNameL)이라, 스냅샷을 다시 읽을 때와
    /// rekordbox에 쓸 때 USB 기록과 같은 검증(`UsbHistoryMatches`·쓰기 관문)이 이 곡인지 다시 확인한다.
    /// 키를 모르면(스냅샷 키 없음·MasterSongID 없음) 파일 이름을 비워 짝을 두지 않는다(보존만 하고 쓰지 않는다)
    public static func entry(row: TrackRow, keys: LocalLibraryKeys?, linkID: UInt32) -> ArchivedHistory.Entry {
        let track = row.track
        let key = keys?.tracks.first { $0.contentID == track.id }
        let songID = key.flatMap { Int64($0.masterSongID) }
        let fileName = songID == nil ? "" : key?.fileNameL ?? ""
        return ArchivedHistory.Entry(trackNumber: 0, usbContentID: Int(linkID), contentID: fileName.isEmpty ? nil : track.id,
                                     title: track.title, artist: track.artist, path: track.folderPath,
                                     masterDbId: keys?.masterDBID(of: track.id) ?? 0, masterContentId: songID ?? 0, fileName: fileName,
                                     bpm: track.bpm, lengthSeconds: track.lengthSeconds)
    }
}

extension ArchivedHistory.Source {
    /// PRO DJ LINK 기록인지(USB 기기 기록이 아님)
    public var isLink: Bool { volumeKey == LinkHistory.volumeKey && format == LinkHistory.format }
}
