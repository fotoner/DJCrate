import Foundation

// rekordbox 재생 기록 쓰기(`RekordboxWriter.write(histories:)`, #43)가 주고받는 값. 관문은 RekordboxKit에 그대로 있고, 유스케이스·화면이
// RekordboxKit 없이 입력을 만들고 보고를 읽도록 값만 여기 둔다(#167, `RekordboxWriteReport`와 같다).
// 백업 폴더의 보고서 JSON과 칸 이름이 같아야 하므로 저장 칸 이름을 바꾸지 않는다.

/// USB에서 가져온 기기 재생 기록 하나를 rekordbox Histories에 넣는 편집(#43). rekordbox가 USB 기록을 가져올 때와 같은 행을 쓴다
public struct HistoryImport: Sendable, Hashable, Codable {
    /// DJCrate 보존 기록 ID("usbhistory-…"), 결과를 잇는 열쇠
    public var id: String
    /// 원하는 이름("HISTORY 2026-10-09"). 이미 있으면 " (n)"을 붙여 쓴다
    public var name: String
    /// 가져온 시각. 로컬 "yyyy-MM-dd HH:mm:ss"로 적고 연·월 폴더도 이 날짜
    public var dateCreated: Date
    /// 재생 순서(반복 포함). 컬렉션에 없는 곡(없거나 rb_local_deleted=1)은 빼고 쓴다
    public var contentIDs: [String]
    /// 보존본에 있으나 컬렉션 짝을 찾지 못해 입력 곡에서 이미 빠진 항목 수.
    public var skippedBeforeMatching: Int
    /// 짝을 확인한 컬렉션 DBID. 미리 보기·실제 쓰기 대상에서도 같은 라이브러리여야 한다.
    public var expectedLibraryID: String?
    /// 이 라이브러리에 쓴 기록 ID(복원 후 다시 대기인 기록 포함).
    public var existingHistoryID: String?
    /// 스냅샷의 ContentID만 믿지 않고 원래 USB 곡 식별을 대상에서도 확인한다.
    public var trackIdentities: [TrackIdentity]

    public struct TrackIdentity: Codable, Sendable, Hashable {
        public var contentID: String
        public var masterDbId: Int64
        public var masterContentId: Int64
        public var fileName: String

        public init(contentID: String, masterDbId: Int64, masterContentId: Int64, fileName: String) {
            self.contentID = contentID
            self.masterDbId = masterDbId
            self.masterContentId = masterContentId
            self.fileName = fileName
        }
    }

    public init(id: String, name: String, dateCreated: Date, contentIDs: [String], skippedBeforeMatching: Int = 0,
                expectedLibraryID: String? = nil, existingHistoryID: String? = nil, trackIdentities: [TrackIdentity] = []) {
        self.id = id
        self.name = name
        self.dateCreated = dateCreated
        self.contentIDs = contentIDs
        self.skippedBeforeMatching = skippedBeforeMatching
        self.expectedLibraryID = expectedLibraryID
        self.existingHistoryID = existingHistoryID
        self.trackIdentities = trackIdentities
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, dateCreated, contentIDs, skippedBeforeMatching, expectedLibraryID, existingHistoryID, trackIdentities
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        dateCreated = try values.decode(Date.self, forKey: .dateCreated)
        contentIDs = try values.decode([String].self, forKey: .contentIDs)
        skippedBeforeMatching = try values.decodeIfPresent(Int.self, forKey: .skippedBeforeMatching) ?? 0
        expectedLibraryID = try values.decodeIfPresent(String.self, forKey: .expectedLibraryID)
        existingHistoryID = try values.decodeIfPresent(String.self, forKey: .existingHistoryID)
        trackIdentities = try values.decodeIfPresent([TrackIdentity].self, forKey: .trackIdentities) ?? []
    }
}

/// 재생 기록 하나의 쓰기 결과(`RekordboxWriter.HistoryOutcome`)
public struct RekordboxHistoryOutcome: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable { case written, blocked, unchanged }

    /// `HistoryImport.id`
    public var id: String
    /// 실제로 쓴 이름(막혔으면 원하던 이름). 미리 보기(dryRun)는 지금 쓰면 붙을 이름
    public var name: String
    /// 쓴 `djmdHistory.ID`. 새 기록의 미리 보기·막힘이면 nil. unchanged는 최신 대상에 이미 있는 기록 ID다.
    public var historyID: String?
    public var status: Status
    /// 막힌 이유: 무엇을 하면 되는지까지 한국어 한 문장
    public var reason: String?
    /// 쓴(쓸) 항목 수. 막혔으면 0
    public var entries: Int
    /// 컬렉션에 없어 뺀 항목 수. 막혔으면 0
    public var skipped: Int

    public init(id: String, name: String, historyID: String?, status: Status, reason: String?, entries: Int, skipped: Int) {
        self.id = id
        self.name = name
        self.historyID = historyID
        self.status = status
        self.reason = reason
        self.entries = entries
        self.skipped = skipped
    }
}
