import Foundation

/// 사이드바 재생 기록 트리: rekordbox Histories처럼 연 › 월 › 기록, 모두 오래된 것부터.
/// rekordbox 기록과 USB에서 보존한 기록(`ArchivedHistory`)을 한 트리에 섞는다.
/// rekordbox는 연 폴더(이름 "2026", 부모 root)와 월 폴더(이름 "8", 부모 연 폴더) 아래에 기록을 둔다(실제 라이브러리에서 확인).
public struct HistoryTree: Sendable, Equatable {
    public struct Item: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var year: Int?
        public var month: Int?
        /// 같은 달 안 순서: 만든 시각 "yyyy-MM-dd HH:mm:ss"(문자열로 견준다), 같으면 `sequence`
        public var sortKey: String
        public var sequence: Int

        public init(id: String, name: String, year: Int?, month: Int?, sortKey: String, sequence: Int) {
            self.id = id
            self.name = name
            self.year = year
            self.month = month
            self.sortKey = sortKey
            self.sequence = sequence
        }
    }

    public struct Month: Sendable, Hashable, Identifiable {
        public var year: Int
        public var month: Int
        public var items: [Item]
        public var id: String { HistoryTree.monthID(year: year, month: month) }
    }

    public struct Year: Sendable, Hashable, Identifiable {
        public var year: Int
        public var months: [Month]
        public var id: String { HistoryTree.yearID(year) }
    }

    public var years: [Year]
    /// 연·월을 알 수 없는 기록(맨 아래)
    public var undated: [Item]

    public init(years: [Year] = [], undated: [Item] = []) {
        self.years = years
        self.undated = undated
    }

    public var isEmpty: Bool { years.isEmpty && undated.isEmpty }

    public static func yearID(_ year: Int) -> String { "history-year-\(year)" }
    public static func monthID(year: Int, month: Int) -> String { "history-month-\(year)-\(month)" }

    public static func build(_ items: [Item]) -> HistoryTree {
        let ordered = items.sorted { ($0.sortKey, $0.sequence, $0.name, $0.id) < ($1.sortKey, $1.sequence, $1.name, $1.id) }
        var byYear: [Int: [Int: [Item]]] = [:]
        var undated: [Item] = []
        for item in ordered {
            guard let year = item.year, let month = item.month else {
                undated.append(item)
                continue
            }
            byYear[year, default: [:]][month, default: []].append(item)
        }
        let years = byYear.keys.sorted().map { year in
            let months = byYear[year] ?? [:]
            return Year(year: year, months: months.keys.sorted().map { Month(year: year, month: $0, items: months[$0] ?? []) })
        }
        return HistoryTree(years: years, undated: undated)
    }

    /// 처음 열 때 펼칠 폴더: 가장 최근 연과 그 연의 가장 최근 월
    public var latestFolderIDs: [String] {
        guard let year = years.last else { return [] }
        return [year.id] + (year.months.last.map { [$0.id] } ?? [])
    }

    /// 기록이 든 폴더(연·월) ID. 고른 기록이 보이게 펼칠 때 쓴다
    public func folderIDs(containing id: String) -> [String] {
        for year in years {
            for month in year.months where month.items.contains(where: { $0.id == id }) {
                return [year.id, month.id]
            }
        }
        return []
    }

    /// rekordbox 기록의 연·월: 부모 폴더 이름이 [연, 월] 숫자면 그것, 아니면 DateCreated("yyyy-MM-dd …")
    public static func yearMonth(folderNames: [String], dateCreated: String?) -> (year: Int, month: Int)? {
        if folderNames.count >= 2, let year = Int(folderNames[folderNames.count - 2]), let month = Int(folderNames[folderNames.count - 1]),
           (1...12).contains(month), (1000...9999).contains(year) {
            return (year, month)
        }
        guard let date = dateCreated, date.count >= 7 else { return nil }
        let characters = Array(date)
        guard characters[4] == "-", let year = Int(String(characters[0..<4])), let month = Int(String(characters[5..<7])),
              (1...12).contains(month) else { return nil }
        return (year, month)
    }

    /// 보존 기록의 정렬 키(rekordbox DateCreated와 같은 모양, 그 달력의 시각)
    public static func sortKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?, _ width: Int) -> String { HistoryNaming.pad(value ?? 0, width) }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2)) \(pad(parts.hour, 2)):\(pad(parts.minute, 2)):\(pad(parts.second, 2))"
    }
}
