import DJCDomain
import Foundation

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

/// 재생 기록 쓰기(#43): `djmdHistory`(연·월 폴더, 기록) + `djmdSongHistory`(항목) + 곡 행 `DJPlayCount`·`TrackInfoUpdated`.
///
/// rekordbox 7.2.19가 USB 기기 기록을 자동으로 가져온 결과를 따른다(2026-10-09 EXPORT 모드, USB "SEUNGMOOK 001"의 곡 1개 기록,
/// 전후 스냅샷 `djc lab db-diff`, docs/rekordbox-internals.md "재생 기록 폴더 읽기·USB 기록 가져오기 실험"):
/// - 월 폴더(없으면): ID "yyyyMM", Name 월 숫자(앞 0 없음), Attribute 1, ParentID 연 폴더, Seq 그 연 폴더 안 다음 번호, UUID = ID.
/// - 연 폴더가 없으면 새로 만드는 규칙은 미확인이라 막는다. 기존 연 폴더의 ID = Name = UUID "yyyy", ParentID "root" 모양만 읽기로 확인했다.
/// - 기록: ID 32비트 난수 글자, Attribute 0, ParentID 월 폴더, Seq 그 월 폴더 안 다음 번호, UUID 소문자 v4.
/// - 항목: ID·UUID 둘 다 소문자 v4(서로 다름), TrackNo 1부터(컬렉션에 없는 곡은 빼고 다시 매긴다).
/// - 새 행은 상태 칸 0, `usn` NULL, DateCreated 로컬 "yyyy-MM-dd HH:mm:ss", created_at·updated_at UTC ms.
/// - 곡 행: `DJPlayCount` +1(정수), `TrackInfoUpdated` +1(글자, NULL이면 '1'), `rb_local_usn`, `updated_at`. 그 밖의 칸·표와
///   `masterPlaylists6.xml`은 그대로다.
/// - 변경 번호: (월 폴더) → 기록 → 항목(TrackNo 순) → 곡 행(처음 나온 순). rekordbox는 곡 행 앞에 빈 번호를 하나 두지만
///   DJCrate는 행마다 하나씩이다(번호 값은 비교하지 않는다).
/// 2026-10-09 사본 재현(`djc lab history-repro`)의 칸 값·저장 형식 차이 0으로 확인했다. 미확인 조건은 기록별로 막는다.
extension RekordboxWriter {
    /// 2026-10-09 rekordbox 7.2.19 실험 → 사본 재현(차이 0) → 골든 시험으로 확인한 쓰기 경로.
    public static let writesHistories = true

    public struct HistoryOutcome: Sendable, Hashable, Codable {
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

        static func blocked(_ history: HistoryImport, _ reason: String) -> HistoryOutcome {
            HistoryOutcome(id: history.id, name: history.name, historyID: nil, status: .blocked, reason: reason, entries: 0, skipped: 0)
        }
    }

    /// 기록 ID·UUID 난수와 로컬 시간대. 앱·CLI는 `system`이고, 시험만 정해 준다.
    package struct HistoryEnvironment {
        /// DateCreated와 연·월 폴더를 정하는 로컬 시간대(rekordbox는 로컬 시각을 적는다)
        package var timeZone: TimeZone
        /// 기록 ID 후보(숫자 글자). 이미 있거나 모양이 맞지 않으면 다시 부른다
        package var historyID: () -> String
        /// 소문자 v4 UUID 글자(기록 UUID, 항목 ID·UUID)
        package var uuid: () -> String

        package init(timeZone: TimeZone, historyID: @escaping () -> String, uuid: @escaping () -> String) {
            self.timeZone = timeZone
            self.historyID = historyID
            self.uuid = uuid
        }

        package static var system: HistoryEnvironment {
            HistoryEnvironment(timeZone: .current, historyID: { String(UInt32.random(in: 1...UInt32.max)) },
                               uuid: { UUID().uuidString.lowercased() })
        }
    }

    /// 기록 하나를 막는 이유(부르는 쪽이 SAVEPOINT로 그 기록만 되돌린다)
    struct HistoryBlocked: Error {
        var reason: String
    }

    /// 최신 대상에 이미 같은 기록이 있다. DB·카운터를 고치지 않고 보존본 연결만 갱신한다.
    struct HistoryPresent: Error {
        var outcome: HistoryOutcome
    }

    /// 같은 쓰기에서 곡 행을 고치는 다른 초안. 같은 곡 행을 두 번 고치는 조합은 확인하지 않아 그 기록을 막는다.
    struct HistoryConflicts {
        /// 태그·그림 초안 곡 UUID
        var edited: Set<String> = []
        /// 합치기 묶음의 곡 UUID(남기는 곡·빼는 곡 모두)
        var merged: Set<String> = []
    }

    /// 확인을 통과한 기록 하나(백업 전과 트랜잭션 안에서 같은 함수로 만든다. 쓸 때는 트랜잭션 안의 결과만 쓴다)
    struct CheckedHistory {
        struct Track {
            var contentID: String
            var playCount: Int?
            var trackInfoUpdated: String?
        }

        /// 쓸 이름(같은 이름의 살아 있는 기록이 있으면 " (n)")
        var name: String
        /// 로컬 "yyyy-MM-dd HH:mm:ss"
        var dateCreated: String
        /// 연 폴더 ID·이름 "yyyy"
        var yearID: String
        /// 월 폴더 ID "yyyyMM"
        var monthID: String
        /// 월 폴더 이름(앞 0 없는 월 숫자)
        var monthName: String
        var createsMonth: Bool
        /// 쓸 곡(재생 순서, 컬렉션에 있는 곡만)
        var tracks: [Track]
        var skipped: Int
    }

    /// 쓴 기록이 가져야 할 행(트랜잭션 안과 커밋 뒤에 다시 읽어 비교한다)
    struct HistoryExpectation {
        var name: String
        var historyID: String
        /// 넣은 행(폴더·기록·항목)과 칸 값
        var rows: [(table: String, id: String, values: [String: CipherDatabase.Value])] = []
        /// 항목 ID(TrackNo 순)
        var entryIDs: [String] = []
    }

    /// 기록을 쓴 곡 행이 가져야 할 칸. 같은 쓰기에서 여러 기록에 든 곡은 마지막 기록의 값이다.
    struct HistoryPlay {
        var playCount: Int
        var trackInfoUpdated: String
        var usn: Int
        var updatedAt: String
    }

    static var closedHistoryReason: String {
        String(ui: "재생 기록 쓰기는 rekordbox 실험을 사본에서 다시 확인하기 전이라 아직 쓰지 않습니다. DJCrate에는 보존돼 있습니다")
    }

    // MARK: - 확인

    /// 쓰기 전에 막을 조건: 빈 이름·날짜·연·월 폴더 자리·컬렉션 곡 없음·같은 곡 반복·동기화 곡·같은 곡의 다른 초안. 막히면 `HistoryBlocked`.
    /// 백업을 뜨기 전(읽기 연결)과 트랜잭션 안(앞 기록을 쓴 DB)에서 같은 함수로 두 번 본다. 이름 " (n)"·폴더를 새로 만들지는 트랜잭션 안의 결과를 쓴다.
    static func checkHistory(_ history: HistoryImport, db: CipherDatabase, conflicts: HistoryConflicts,
                             environment: HistoryEnvironment) throws -> CheckedHistory {
        guard !history.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HistoryBlocked(reason: String(ui: "기록 이름이 비어 있어 쓰지 않으니 DJCrate에서 기록을 다시 가져온 뒤 쓰세요"))
        }
        guard let date = historyDate(history.dateCreated, timeZone: environment.timeZone) else {
            throw HistoryBlocked(reason: String(ui: "기록 날짜를 읽지 못해 쓰지 않으니 DJCrate에서 기록을 다시 가져온 뒤 쓰세요"))
        }
        if let expected = history.expectedLibraryID {
            var actual: String?
            try db.query("SELECT DBID FROM djmdProperty LIMIT 1") { actual = $0.string(0) }
            guard actual.flatMap({ Int64($0) }).map({ String($0) }) == expected else {
                throw HistoryBlocked(reason: String(ui: "기록의 짝을 확인한 라이브러리와 쓰기 대상이 다르니 새 스냅샷을 읽은 뒤 다시 쓰세요"))
            }
        }
        var identities: [String: HistoryImport.TrackIdentity] = [:]
        for identity in history.trackIdentities {
            if let previous = identities[identity.contentID], previous != identity {
                throw HistoryBlocked(reason: String(ui: "보존 기록의 곡 원본 식별이 서로 다르니 USB를 다시 연결해 기록을 확인한 뒤 쓰세요"))
            }
            identities[identity.contentID] = identity
        }

        // 곡: 컬렉션에 없는 곡(행 없음·지운 곡)은 rekordbox처럼 빼고, 남은 곡으로 막을지 본다.
        var tracks: [CheckedHistory.Track] = []
        var skipped = max(0, history.skippedBeforeMatching)
        var uuids: [String] = []
        var unsynced = true
        for contentID in history.contentIDs {
            var row: (deleted: Int?, status: Int?, plays: Int?, info: String?, uuid: String?, masterDb: String?, masterSong: String?, fileName: String?, path: String?)?
            try db.query("SELECT rb_local_deleted, rb_data_status, DJPlayCount, TrackInfoUpdated, UUID, MasterDBID, MasterSongID, FileNameL, FolderPath FROM djmdContent WHERE ID = ?",
                         [.text(contentID)]) { r in row = (r.int(0), r.int(1), r.int(2), r.string(3), r.string(4), r.string(5), r.string(6), r.string(7), r.string(8)) }
            guard let row, row.deleted == 0 else {
                skipped += 1
                continue
            }
            if !identities.isEmpty {
                guard let identity = identities[contentID], !identity.fileName.isEmpty,
                      let masterDb = UsbLibraryBuilder.sqliteInteger(row.masterDb) else {
                    throw HistoryBlocked(reason: String(ui: "보존 기록의 곡 원본 식별을 확인하지 못해 쓰지 않으니 USB를 다시 연결한 뒤 새 스냅샷을 읽으세요"))
                }
                let key = UsbTrackKey(masterDbId: identity.masterDbId, masterContentId: identity.masterContentId, fileName: identity.fileName)
                let local = UsbLocalTrackKey(contentID: contentID, masterSongID: row.masterSong ?? "", fileNameL: row.fileName ?? "", folderPath: row.path)
                guard UsbTrackMatch.match(key, localDBID: masterDb, local: [local]) == contentID else {
                    throw HistoryBlocked(reason: String(ui: "쓰기 대상의 곡 원본 식별이 보존 기록과 달라 쓰지 않으니 새 스냅샷을 읽은 뒤 다시 쓰세요"))
                }
            }
            tracks.append(CheckedHistory.Track(contentID: contentID, playCount: row.plays, trackInfoUpdated: row.info))
            uuids.append(row.uuid ?? "")
            if row.status != 0 { unsynced = false }
        }
        guard !tracks.isEmpty else {
            throw HistoryBlocked(reason: String(ui: "rekordbox 컬렉션에 있는 곡이 하나도 없는 기록이라 쓰지 않으니 곡을 컬렉션에 넣은 뒤 다시 쓰세요"))
        }
        let ids = tracks.map(\.contentID)
        var existing: [(id: String, name: String)] = []
        if let id = history.existingHistoryID {
            try db.query("SELECT ID, Name FROM djmdHistory WHERE ID = ? AND Attribute = 0 AND rb_local_deleted = 0", [.text(id)]) {
                existing.append(($0.string(0) ?? "", $0.string(1) ?? ""))
            }
        }
        try db.query("SELECT ID, Name FROM djmdHistory WHERE Name = ? AND substr(DateCreated, 1, 10) = ? AND Attribute = 0 AND rb_local_deleted = 0 ORDER BY Seq, ID",
                     [.text(history.name), .text(String(date.local.prefix(10)))]) {
            existing.append(($0.string(0) ?? "", $0.string(1) ?? ""))
        }
        for record in existing {
            var contentIDs: [String] = []
            try db.query("SELECT ContentID FROM djmdSongHistory WHERE HistoryID = ? AND rb_local_deleted = 0 ORDER BY TrackNo, ID", [.text(record.id)]) {
                contentIDs.append($0.string(0) ?? "")
            }
            if contentIDs == ids {
                throw HistoryPresent(outcome: HistoryOutcome(id: history.id, name: record.name, historyID: record.id, status: .unchanged,
                                                            reason: nil, entries: tracks.count, skipped: skipped))
            }
        }
        // 같은 곡을 두 번 튼 기록은 rekordbox가 DJPlayCount를 몇 올리는지 보지 못했다.
        guard Set(tracks.map(\.contentID)).count == tracks.count else {
            throw HistoryBlocked(reason: String(ui: "같은 곡이 두 번 이상 든 기록은 rekordbox 재생 횟수 규칙을 확인하지 않아 쓰지 않으니 rekordbox에서 USB를 연결해 직접 가져오세요"))
        }
        guard tracks.allSatisfy({ $0.playCount != nil }) else {
            throw HistoryBlocked(reason: String(ui: "재생 횟수가 비어 있는 곡의 기록은 쓰는 규칙을 확인하지 않아 쓰지 않으니 rekordbox에서 USB를 연결해 직접 가져오세요"))
        }
        // 실험 곡은 상태 0이었다. 동기화(256·257) 곡의 곡 행·상태 칸은 보지 못했다.
        guard unsynced else {
            throw HistoryBlocked(reason: String(ui: "클라우드 동기화 곡이 든 기록은 쓰는 규칙을 확인하지 않아 쓰지 않으니 rekordbox에서 USB를 연결해 직접 가져오세요"))
        }
        guard Set(uuids).isDisjoint(with: conflicts.merged) else {
            throw HistoryBlocked(reason: String(ui: "같은 곡의 중복 합치기와 함께 쓰지 않으니 합치기를 먼저 쓰거나 버린 뒤 기록을 다시 쓰세요"))
        }
        guard Set(uuids).isDisjoint(with: conflicts.edited) else {
            throw HistoryBlocked(reason: String(ui: "같은 곡의 곡 정보·앨범아트 초안과 함께 쓰면 곡 행을 두 번 고치게 되니 곡 정보·앨범아트를 먼저 쓴 뒤 기록을 다시 쓰세요"))
        }

        // 연·월 폴더 자리: 없으면 만들고, 있으면 그 자리에 맞는 살아 있는 폴더여야 한다.
        let yearID = String(format: "%04d", date.year)
        let monthID = yearID + String(format: "%02d", date.month)
        var slots: [String: (attribute: Int?, parentID: String?, deleted: Int?)] = [:]
        try db.query("SELECT ID, Attribute, ParentID, rb_local_deleted FROM djmdHistory WHERE ID IN (?, ?)", [.text(yearID), .text(monthID)]) { r in
            slots[r.string(0) ?? ""] = (r.int(1), r.string(2), r.int(3))
        }
        func folderReason(_ label: String) -> String {
            String(ui: "rekordbox Histories의 \(label) 폴더 자리에 다른 행이 있어 쓰지 않으니 rekordbox에서 그 폴더를 확인하세요")
        }
        let year = slots[yearID], month = slots[monthID]
        if let year, !(year.attribute == 1 && year.parentID == "root" && year.deleted == 0) { throw HistoryBlocked(reason: folderReason(yearID)) }
        let monthLabel = "\(yearID)/\(date.month)"
        if let month, !(month.attribute == 1 && month.parentID == yearID && month.deleted == 0) {
            throw HistoryBlocked(reason: folderReason(monthLabel))
        }
        if month != nil, year == nil {
            throw HistoryBlocked(reason: String(ui: "rekordbox Histories에 \(yearID) 폴더 없이 \(monthLabel) 폴더만 있어 쓰지 않으니 rekordbox에서 Histories를 확인하세요"))
        }
        guard year != nil else {
            throw HistoryBlocked(reason: String(ui: "새 연 폴더를 만드는 규칙을 확인하지 않아 쓰지 않으니 rekordbox에서 USB를 연결해 직접 가져오세요"))
        }

        // 이름: 같은 이름의 살아 있는 기록이 있으면 " (1)", " (2)" … 가장 작은 빈 번호(rekordbox가 한 번에 가져온 기록 셋의 이름)
        var taken: Set<String> = []
        try db.query("SELECT Name FROM djmdHistory WHERE rb_local_deleted = 0 AND ifnull(Attribute, 0) != 1") { r in
            if let name = r.string(0) { taken.insert(name) }
        }
        return CheckedHistory(name: historyName(history.name, taken: taken), dateCreated: date.local, yearID: yearID, monthID: monthID,
                              monthName: String(date.month), createsMonth: month == nil, tracks: tracks,
                              skipped: skipped)
    }

    /// 원하는 이름이 비었으면 그대로, 있으면 " (n)"을 붙인다. 원하는 이름이 이미 " (n)"으로 끝나면(DJCrate가 보존할 때 붙인 번호) 그 번호를 떼고
    /// 다시 매긴다("HISTORY … (1) (1)"이 되지 않게).
    static func historyName(_ requested: String, taken: Set<String>) -> String {
        guard taken.contains(requested) else { return requested }
        var base = requested
        if let suffix = requested.range(of: #" \([0-9]+\)$"#, options: .regularExpression) { base = String(requested[..<suffix.lowerBound]) }
        var number = 1
        while taken.contains("\(base) (\(number))") { number += 1 }
        return "\(base) (\(number))"
    }

    /// 로컬 시각 글자와 연·월. 연이 네 자리가 아니거나 시각이 유한하지 않으면 nil(폴더 ID "yyyy"를 만들 수 없다).
    static func historyDate(_ date: Date, timeZone: TimeZone) -> (local: String, year: Int, month: Int)? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, (1000...9999).contains(year), let month = c.month, let day = c.day, let hour = c.hour,
              let minute = c.minute, let second = c.second else { return nil }
        let local = String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
        return (local, year, month)
    }

    // MARK: - 쓰기

    /// 기록 하나를 쓴다(트랜잭션 안). 다시 확인한 뒤 폴더 → 기록 → 항목 → 곡 행 순서로 번호를 받고, 다시 읽어 비교한다.
    /// 막히면 `HistoryBlocked`(부르는 쪽이 SAVEPOINT로 되돌린다). `plays`는 이 쓰기에서 기록을 쓴 곡 행의 기대값이다.
    static func applyHistory(_ history: HistoryImport, db: CipherDatabase, usn: inout Int, stamp: (db: String, json: String),
                             conflicts: HistoryConflicts, environment: HistoryEnvironment, plays: inout [String: HistoryPlay])
        throws -> (checked: CheckedHistory, expectation: HistoryExpectation) {
        let checked = try checkHistory(history, db: db, conflicts: conflicts, environment: environment)
        var expectation = HistoryExpectation(name: checked.name, historyID: "")
        func insert(_ table: String, _ id: String, _ values: [String: CipherDatabase.Value]) throws {
            let row = values.merging(RekordboxTrackWriter.syncColumns(usn: usn, stamp: stamp)) { value, _ in value }
            try RekordboxTrackWriter.insert(db, table: table, row)
            expectation.rows.append((table, id, row))
        }
        // 폴더는 ID = UUID(실험의 월 폴더 "202610", 기존 연 폴더 "2020"~"2026"). DateCreated는 기록과 같은 초다.
        func folder(_ id: String, name: String, parentID: String) throws {
            let seq = try nextHistorySeq(db, parentID: parentID)
            usn += 1
            try insert("djmdHistory", id, ["ID": .text(id), "Seq": .int(seq), "Name": .text(name), "Attribute": .int(1),
                                           "ParentID": .text(parentID), "DateCreated": .text(checked.dateCreated), "UUID": .text(id)])
        }
        if checked.createsMonth { try folder(checked.monthID, name: checked.monthName, parentID: checked.yearID) }

        let historyID = try newHistoryID(db, environment: environment)
        let seq = try nextHistorySeq(db, parentID: checked.monthID)
        usn += 1
        try insert("djmdHistory", historyID, ["ID": .text(historyID), "Seq": .int(seq), "Name": .text(checked.name), "Attribute": .int(0),
                                              "ParentID": .text(checked.monthID), "DateCreated": .text(checked.dateCreated),
                                              "UUID": .text(environment.uuid())])
        expectation.historyID = historyID
        // 항목은 TrackNo 순서대로 하나씩 번호를 받는다(실험은 한 곡이었다).
        for (offset, track) in checked.tracks.enumerated() {
            let entryID = try newHistoryEntryID(db, environment: environment)
            usn += 1
            try insert("djmdSongHistory", entryID, ["ID": .text(entryID), "HistoryID": .text(historyID), "ContentID": .text(track.contentID),
                                                    "TrackNo": .int(offset + 1), "UUID": .text(environment.uuid())])
            expectation.entryIDs.append(entryID)
        }
        // 곡 행: 재생 횟수·곡 정보 변경 횟수 +1. 상태 0 곡만 오므로 상태 칸은 그대로다.
        var written: [String: HistoryPlay] = [:]
        for track in checked.tracks {
            usn += 1
            let play = HistoryPlay(playCount: (track.playCount ?? 0) + 1,
                                   trackInfoUpdated: String((Int(track.trackInfoUpdated ?? "0") ?? 0) + 1), usn: usn, updatedAt: stamp.db)
            guard try db.run("""
                UPDATE djmdContent SET DJPlayCount = ?, TrackInfoUpdated = ?, rb_local_usn = ?, updated_at = ?
                WHERE ID = ? AND rb_local_deleted = 0 AND rb_data_status = 0
                """, [.int(play.playCount), .text(play.trackInfoUpdated), .int(play.usn), .text(play.updatedAt), .text(track.contentID)]) == 1 else {
                throw DJCError.writeVerificationFailed(String(ui: "재생 기록 곡의 재생 횟수를 고치지 못했습니다 (ContentID \(track.contentID))"))
            }
            written[track.contentID] = play
        }
        try verifyHistory(db: db, expectation)
        try verifyHistoryPlays(db: db, written)
        plays.merge(written) { _, new in new }
        return (checked, expectation)
    }

    /// 부모 안 다음 Seq(살아 있는 자식의 가장 큰 Seq + 1). rekordbox 기존 행은 연 폴더 1…7, 월 폴더·기록 모두 1부터 이어진다.
    static func nextHistorySeq(_ db: CipherDatabase, parentID: String) throws -> Int {
        (try scalar(db, "SELECT max(Seq) FROM djmdHistory WHERE ParentID = ? AND rb_local_deleted = 0", [.text(parentID)]) ?? 0) + 1
    }

    /// 32비트 난수 숫자 글자(rekordbox 기록 ID 77개는 7~10자리였다). 지운 행까지 어느 행과도 겹치지 않게 하고, 7자리 미만은 연("yyyy")·
    /// 월("yyyyMM") 폴더 ID와 겹칠 수 있어 다시 뽑는다.
    static func newHistoryID(_ db: CipherDatabase, environment: HistoryEnvironment) throws -> String {
        for _ in 0..<100 {
            let id = environment.historyID()
            guard id.count > 6, !id.hasPrefix("0"), id.utf8.allSatisfy({ (48...57).contains($0) }) else { continue }
            if try scalar(db, "SELECT count(*) FROM djmdHistory WHERE ID = ?", [.text(id)]) == 0 { return id }
        }
        throw DJCError.writeVerificationFailed(String(ui: "새 재생 기록 ID를 만들지 못했습니다"))
    }

    /// 항목 ID: 소문자 v4 UUID(겹치지 않게)
    static func newHistoryEntryID(_ db: CipherDatabase, environment: HistoryEnvironment) throws -> String {
        for _ in 0..<100 {
            let id = environment.uuid()
            if try scalar(db, "SELECT count(*) FROM djmdSongHistory WHERE ID = ?", [.text(id)]) == 0 { return id }
        }
        throw DJCError.writeVerificationFailed(String(ui: "새 재생 기록 항목 ID를 만들지 못했습니다"))
    }

    // MARK: - 검증

    /// 넣은 폴더·기록·항목 행이 칸마다(형식까지) 쓴 그대로이고 그 기록의 항목이 쓴 것뿐인지(트랜잭션 안과 커밋 뒤)
    static func verifyHistory(db: CipherDatabase, _ expected: HistoryExpectation) throws {
        do {
            for row in expected.rows { try RekordboxTrackWriter.verify(db, table: row.table, id: row.id, row.values) }
            var entries: [String] = []
            try db.query("SELECT ID FROM djmdSongHistory WHERE HistoryID = ? ORDER BY TrackNo, ID", [.text(expected.historyID)]) {
                entries.append($0.string(0) ?? "")
            }
            guard entries == expected.entryIDs else { throw DJCError.writeVerificationFailed(String(ui: "재생 기록 항목이 쓴 것과 다릅니다")) }
        } catch DJCError.writeVerificationFailed {
            throw DJCError.writeVerificationFailed("\(String(ui: "재생 기록 확인 실패")) (\(expected.name))")
        }
    }

    /// 기록을 쓴 곡 행의 재생 횟수·곡 정보 변경 횟수·변경 번호·상태(트랜잭션 안과 커밋 뒤)
    static func verifyHistoryPlays(db: CipherDatabase, _ plays: [String: HistoryPlay]) throws {
        for (contentID, play) in plays.sorted(by: { $0.key < $1.key }) {
            do {
                try RekordboxTrackWriter.verify(db, table: "djmdContent", id: contentID, [
                    "DJPlayCount": .int(play.playCount), "TrackInfoUpdated": .text(play.trackInfoUpdated), "rb_local_usn": .int(play.usn),
                    "updated_at": .text(play.updatedAt), "rb_data_status": .int(0), "rb_local_deleted": .int(0),
                ])
            } catch DJCError.writeVerificationFailed {
                throw DJCError.writeVerificationFailed("\(String(ui: "재생 기록 곡의 재생 횟수·변경 번호가 쓴 것과 다릅니다")) (ContentID \(contentID))")
            }
        }
    }
}
