import Foundation

/// USB에서 가져와 DJCrate 데이터 폴더(`usb-histories/`)에 보존한 기기 재생 기록 하나(#43).
/// rekordbox가 USB를 연결할 때 기기 기록을 Histories로 가져오는 것과 같은 일이다. 보존은 바로 하고, rekordbox 라이브러리에는
/// 다른 초안처럼 "rekordbox 쓰기 대기"에 올렸다가 rekordbox에 쓰기 때 넣는다(`HistoryWriteQueue`).
/// 컬렉션에 없는 곡도 USB에서 읽은 제목·경로를 그대로 남긴다(rekordbox에 쓸 때는 rekordbox처럼 뺀다).
public struct ArchivedHistory: Codable, Sendable, Hashable, Identifiable {
    /// 사이드바 선택 ID 접두사. rekordbox 기록 ID(숫자)와 겹치지 않는다
    public static let idPrefix = "usbhistory-"

    public var id: String
    /// "HISTORY yyyy-MM-dd"(가져온 날짜, 같은 이름이 있으면 " (n)", `HistoryNaming`)
    public var name: String
    public var importedAt: Date
    /// 가져온 차례(같은 시각에 여럿을 가져오면 이 순서로 놓는다)
    public var sequence: Int
    public var source: Source
    /// 재생 순서(`trackNumber` 1부터)
    public var entries: [Entry]
    /// rekordbox에 쓴 기록의 `djmdHistory.ID`(쓴 뒤). 그 기록이 rekordbox에서 사라지면(쓰기 전으로 복원 등) 다시 쓰기 대기다
    public var rekordboxHistoryID: String?
    /// 쓴 기록이 속한 `djmdProperty.DBID`. 다른 라이브러리의 같은 기록 ID와 혼동하지 않는다(옛 보존 파일에는 없음).
    public var rekordboxLibraryID: String?
    /// 사용자가 rekordbox 쓰기 대기에서 뺐다(보존본은 남는다)
    public var excludedFromRekordbox: Bool

    public init(id: String, name: String, importedAt: Date, sequence: Int, source: Source, entries: [Entry],
                rekordboxHistoryID: String? = nil, rekordboxLibraryID: String? = nil, excludedFromRekordbox: Bool = false) {
        self.id = id
        self.name = name
        self.importedAt = importedAt
        self.sequence = sequence
        self.source = source
        self.entries = entries
        self.rekordboxHistoryID = rekordboxHistoryID
        self.rekordboxLibraryID = rekordboxLibraryID
        self.excludedFromRekordbox = excludedFromRekordbox
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, importedAt, sequence, source, entries, rekordboxHistoryID, rekordboxLibraryID, excludedFromRekordbox
    }

    /// 쓰기 상태 칸이 없는 파일도 읽는다(없으면 쓰지 않음·빼지 않음)
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        sequence = try container.decode(Int.self, forKey: .sequence)
        source = try container.decode(Source.self, forKey: .source)
        entries = try container.decode([Entry].self, forKey: .entries)
        rekordboxHistoryID = try container.decodeIfPresent(String.self, forKey: .rekordboxHistoryID)
        rekordboxLibraryID = try container.decodeIfPresent(String.self, forKey: .rekordboxLibraryID)
        excludedFromRekordbox = try container.decodeIfPresent(Bool.self, forKey: .excludedFromRekordbox) ?? false
    }

    /// 어느 USB의 어느 기록인지. 같은 USB 기록을 다시 읽으면 이 키로 알아본다
    public struct Source: Codable, Sendable, Hashable {
        /// 볼륨키(볼륨 UUID 대문자, 없으면 "mount_…")
        public var volumeKey: String
        public var volumeName: String
        /// `UsbFormat.rawValue`
        public var format: String
        /// USB 안 기록 번호(OneLibrary history_id, Device Library 표 11 id)
        public var historyID: Int
        /// USB 안 이름(예: "HISTORY 001")
        public var historyName: String

        public init(volumeKey: String, volumeName: String, format: String, historyID: Int, historyName: String) {
            self.volumeKey = volumeKey
            self.volumeName = volumeName
            self.format = format
            self.historyID = historyID
            self.historyName = historyName
        }

        /// 볼륨 이름은 바뀔 수 있어 키에 넣지 않는다
        public struct Key: Hashable, Sendable {
            public var volumeKey: String
            public var format: String
            public var historyID: Int
            public var historyName: String
        }

        public var key: Key { Key(volumeKey: volumeKey, format: format, historyID: historyID, historyName: historyName) }
    }

    /// 기록 한 줄. USB 곡 정보를 함께 남겨 USB를 뺀 뒤에도, 컬렉션에 없는 곡도 보인다
    public struct Entry: Codable, Sendable, Hashable {
        public var trackNumber: Int
        /// USB content_id
        public var usbContentID: Int
        /// 로컬 컬렉션 짝(ContentID). 보존한 원본 키로 스냅샷을 읽을 때마다 다시 검증한다
        public var contentID: String?
        public var title: String
        public var artist: String?
        /// USB 안 경로("/Contents/…")
        public var path: String
        /// 로컬 짝짓기 키(`UsbTrackMatch`)
        public var masterDbId: Int64
        public var masterContentId: Int64
        public var fileName: String
        /// 컬렉션에 없는 곡 줄에 보일 BPM·길이(초). USB에 없으면 nil
        public var bpm: Double?
        public var lengthSeconds: Int?

        public init(trackNumber: Int, usbContentID: Int, contentID: String?, title: String, artist: String?, path: String,
                    masterDbId: Int64, masterContentId: Int64, fileName: String, bpm: Double? = nil, lengthSeconds: Int? = nil) {
            self.trackNumber = trackNumber
            self.usbContentID = usbContentID
            self.contentID = contentID
            self.title = title
            self.artist = artist
            self.path = path
            self.masterDbId = masterDbId
            self.masterContentId = masterContentId
            self.fileName = fileName
            self.bpm = bpm
            self.lengthSeconds = lengthSeconds
        }
    }

    /// 로컬 짝이 있는 곡 ID(재생 순서, 반복 재생 포함)
    public var matchedContentIDs: [String] { entries.compactMap(\.contentID) }
}

/// rekordbox 쓰기 대기에 올릴 보존 기록(입출력 없음). 앱은 쓰기 대기 목록·미리 보기·rekordbox에 쓰기(⇧⌘E)가 이것을 쓴다.
public enum HistoryWriteQueue {
    /// - shadowed: rekordbox에 이미 같은 기록이 있어 숨긴 보존 기록(`HistoryDuplicates`). rekordbox가 직접 가져왔거나 DJCrate가 쓴 것
    /// - rekordboxHistoryIDs: 지금 rekordbox 라이브러리(스냅샷)에 있는 기록 ID
    /// 대기: 숨김 아님, 사용자가 빼지 않음, 쓴 적 없거나 쓴 기록이 rekordbox에서 사라짐(복원 등), 컬렉션 짝 곡이 하나 이상(rekordbox는 컬렉션 곡만 넣는다),
    /// 같은 곡이 두 번 들지 않음(rekordbox 쓰기가 늘 막는 모양이라 대기에 두면 쓸 때마다 막힘을 묻는다, `hasRepeatedTracks`). 가져온 차례대로
    public static func pending(_ archived: [ArchivedHistory], shadowed: Set<String>, rekordboxHistoryIDs: Set<String>) -> [ArchivedHistory] {
        archived.filter { history in
            !shadowed.contains(history.id) && !history.excludedFromRekordbox && !history.matchedContentIDs.isEmpty
                && !hasRepeatedTracks(history)
                && history.rekordboxHistoryID.map { !rekordboxHistoryIDs.contains($0) } ?? true
        }.sorted { ($0.importedAt, $0.sequence, $0.id) < ($1.importedAt, $1.sequence, $1.id) }
    }

    /// 컬렉션 짝 곡 중 같은 곡이 두 번 이상 든 기록. rekordbox가 이런 기록을 가져올 때 재생 횟수를 몇 번 올리는지 확인하지 않아
    /// rekordbox 쓰기가 막는다(`RekordboxWriter+History`). rekordbox에서 USB를 연결해 직접 가져오게 안내한다
    public static func hasRepeatedTracks(_ history: ArchivedHistory) -> Bool {
        let ids = history.matchedContentIDs
        return Set(ids).count != ids.count
    }
}
