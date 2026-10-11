import Foundation

/// USB의 기기 재생 기록 중 아직 보존하지 않은 것을 고른다(입출력 없음).
/// - 같은 USB 기록(볼륨·형식·번호·이름과 곡의 안정 식별·순서가 같음)을 다시 읽으면 새로 만들지 않고, 로컬 짝을 새로 알게 된 곡만 채운다.
///   rekordbox도 이름·내용이 같은 기록은 다시 가져오지 않는다.
/// - 번호·이름이 같아도 곡 순서가 조금이라도 다르면 다른 기록으로 새로 보존한다. 기기는 꽂을 때마다 새 기록을 만들어 같은 기록이
///   늘거나 줄 까닭이 없고, rekordbox가 기록을 지운 뒤 기기가 같은 번호·이름을 다시 쓰면 첫 곡들이 같을 수 있다
///   (앞부분이 같다고 이어 붙이거나 건너뛰면 다른 날의 기록을 잃는다). 보존본은 지우지 않는다.
public enum UsbHistoryImport {
    /// USB에서 읽은 기록 하나(항목은 재생 순서)
    public struct Candidate: Sendable, Hashable {
        public var source: ArchivedHistory.Source
        public var entries: [ArchivedHistory.Entry]

        public init(source: ArchivedHistory.Source, entries: [ArchivedHistory.Entry]) {
            self.source = source
            self.entries = entries
        }
    }

    public struct Plan: Sendable, Equatable {
        /// 새로 보존할 기록
        public var added: [ArchivedHistory] = []
        /// 로컬 짝을 채운 보존본(같은 ID로 덮어쓴다)
        public var updated: [ArchivedHistory] = []

        public init(added: [ArchivedHistory] = [], updated: [ArchivedHistory] = []) {
            self.added = added
            self.updated = updated
        }

        public var isEmpty: Bool { added.isEmpty && updated.isEmpty }
    }

    /// - existing: 이미 보존한 기록 전부
    /// - candidates: 이번에 USB에서 읽은 기록(이 순서로 이름의 " (n)"을 붙인다). 곡이 없는 기록은 건너뛴다
    /// - reservedNames: rekordbox 기록 이름(같은 이름을 짓지 않는다)
    /// - makeID: 새 기록 ID 뒷부분(앱은 UUID)
    public static func plan(existing: [ArchivedHistory], candidates: [Candidate], reservedNames: Set<String>,
                            now: Date, calendar: Calendar, makeID: () -> String) -> Plan {
        // 저장 파일(ISO 8601)은 초 아래를 버린다. 다시 읽은 값과 같게 초 단위로 맞춘다
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        var plan = Plan()
        var taken = reservedNames.union(existing.map(\.name))
        var nextSequence = (existing.map(\.sequence).max() ?? 0) + 1
        // 같은 USB 기록 키의 보존본들(번호를 다시 쓴 USB면 여럿)
        var saved: [ArchivedHistory.Source.Key: [ArchivedHistory]] = [:]
        for history in existing { saved[history.source.key, default: []].append(history) }
        var updatedIndex: [String: Int] = [:]
        for candidate in candidates where !candidate.entries.isEmpty {
            let key = candidate.source.key
            let entries = numbered(candidate.entries)
            if let position = saved[key]?.firstIndex(where: { sameEntries($0.entries, entries) }), let same = saved[key]?[position] {
                let merged = merge(same, with: entries)
                if merged != same {
                    if let index = updatedIndex[merged.id] {
                        plan.updated[index] = merged
                    } else {
                        updatedIndex[merged.id] = plan.updated.count
                        plan.updated.append(merged)
                    }
                    saved[key]?[position] = merged
                }
                continue
            }
            let name = HistoryNaming.name(for: now, calendar: calendar, taken: taken)
            taken.insert(name)
            let history = ArchivedHistory(id: ArchivedHistory.idPrefix + makeID(), name: name, importedAt: now, sequence: nextSequence,
                                          source: candidate.source, entries: entries)
            nextSequence += 1
            plan.added.append(history)
            saved[key, default: []].append(history)
        }
        return plan
    }

    /// USB 재구성 뒤 번호를 재사용할 수 있어 번호·순서뿐 아니라 원래 곡 식별도 견준다. 표시 정보·로컬 짝은 바뀔 수 있다
    private static func sameEntries(_ saved: [ArchivedHistory.Entry], _ current: [ArchivedHistory.Entry]) -> Bool {
        saved.count == current.count && zip(saved, current).allSatisfy { left, right in
            left.usbContentID == right.usbContentID && left.masterDbId == right.masterDbId
                && left.masterContentId == right.masterContentId && left.path == right.path && left.fileName == right.fileName
        }
    }

    /// 순번을 1부터 다시 매긴다(USB의 순번 칸은 빈틈이 있을 수 있다)
    static func numbered(_ entries: [ArchivedHistory.Entry]) -> [ArchivedHistory.Entry] {
        entries.enumerated().map { offset, entry in
            var entry = entry
            entry.trackNumber = offset + 1
            return entry
        }
    }

    /// 보존본의 곡 정보는 그대로 두고 모르던 로컬 짝만 채운다(곡 순서가 같은 기록끼리)
    static func merge(_ saved: ArchivedHistory, with entries: [ArchivedHistory.Entry]) -> ArchivedHistory {
        var result = saved
        for (index, entry) in entries.enumerated() where index < result.entries.count {
            if result.entries[index].contentID == nil, let contentID = entry.contentID {
                result.entries[index].contentID = contentID
            }
        }
        return result
    }
}

/// rekordbox가 USB 기록을 가져올 때 짓는 이름: "HISTORY yyyy-MM-dd"(가져온 날), 이미 있으면 " (1)", " (2)" …
/// 실제 라이브러리에서 한 번에 가져온 기록 셋이 같은 시각에 "HISTORY 2026-08-01", "(1)", "(2)"로 만들어져 있었다.
public enum HistoryNaming {
    public static let prefix = "HISTORY"

    public static func name(for date: Date, calendar: Calendar, taken: Set<String>) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let base = "\(prefix) \(pad(parts.year ?? 0, 4))-\(pad(parts.month ?? 0, 2))-\(pad(parts.day ?? 0, 2))"
        guard taken.contains(base) else { return base }
        var number = 1
        while taken.contains("\(base) (\(number))") { number += 1 }
        return "\(base) (\(number))"
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

/// 같은 USB 기록임을 확인한 rekordbox 기록과 보존본을 일대일로 짝지어 숨긴다. 파일은 지우지 않는다.
/// 짝 없는 항목은 rekordbox가 가져오지 않으므로, 그 항목이 든 보존본은 계속 표시한다.
public enum HistoryDuplicates {
    public struct Record: Sendable, Hashable {
        public var id: String
        public var name: String
        public var dateCreated: String?
        /// 재생 순서·반복을 그대로 담는다
        public var contentIDs: [String]

        public init(id: String, name: String, dateCreated: String?, contentIDs: [String]) {
            self.id = id
            self.name = name
            self.dateCreated = dateCreated
            self.contentIDs = contentIDs
        }
    }

    /// rekordbox가 USB 기록을 가져올 때 짓는 이름 모양("HISTORY "로 시작). PERFORMANCE 기록도 같은 모양이라 가르지 못한다
    public static func isUsbImportName(_ name: String) -> Bool {
        name.hasPrefix(HistoryNaming.prefix + " ")
    }

    /// 쓴 ID는 호출자가 현재 라이브러리의 쓰기 표시인지 확인한 뒤 넘긴다. 미확정 날짜·이름·곡 짝은 숨기지 않는다
    public static func shadowedArchiveIDs(archived: [ArchivedHistory], rekordbox: [Record]) -> Set<String> {
        let ordered = archived.sorted { ($0.importedAt, $0.sequence, $0.id) < ($1.importedAt, $1.sequence, $1.id) }
        let records = rekordbox.sorted { $0.id < $1.id }
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recordsByName = Dictionary(grouping: records, by: \.name)
        var consumed: Set<String> = []
        var hidden: Set<String> = []
        // 쓴 ID의 짝을 먼저 확보해 같은 곡 순서의 다른 보존본이 가져가지 않게 한다
        for history in ordered {
            guard let writtenID = history.rekordboxHistoryID,
                  let record = recordsByID[writtenID], consumed.insert(record.id).inserted else { continue }
            if coversAllEntries(history, record: record) { hidden.insert(history.id) }
        }
        for history in ordered where history.rekordboxHistoryID == nil {
            // 같은 날의 다른 세트나 과거 기록을 곡 배열만으로 같은 기록으로 보지 않는다
            guard isUsbImportName(history.name), let day = dateDay(String(history.name.dropFirst(HistoryNaming.prefix.count + 1))),
                  let record = recordsByName[history.name]?.first(where: {
                      !consumed.contains($0.id) && $0.name == history.name
                          && $0.dateCreated.flatMap(dateDay) == day && coversAllEntries(history, record: $0)
                  }) else { continue }
            consumed.insert(record.id)
            hidden.insert(history.id)
        }
        return hidden
    }

    private static func coversAllEntries(_ history: ArchivedHistory, record: Record) -> Bool {
        !history.entries.isEmpty && history.entries.allSatisfy { $0.contentID.map { !$0.isEmpty } ?? false }
            && history.matchedContentIDs == record.contentIDs
    }

    /// 이름 날짜와 DateCreated 날짜를 견준다(초·시간대 표기에는 의존하지 않는다)
    private static func dateDay(_ value: String) -> String? {
        let characters = Array(value.prefix(10))
        guard characters.count == 10, characters[4] == "-", characters[7] == "-",
              characters.enumerated().allSatisfy({ index, character in index == 4 || index == 7 || "0123456789".contains(character) }),
              let year = Int(String(characters[0..<4])), let month = Int(String(characters[5..<7])), let day = Int(String(characters[8..<10])),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return String(characters)
    }
}
