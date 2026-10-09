import Foundation

/// 스냅샷의 재생 기록. 반복 재생은 서로 다른 기록 행으로 보존한다.
public struct RekordboxHistory: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let dateCreated: String?
    public let entries: [Entry]

    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: String
        public let contentID: String
        public let trackNumber: Int

        public init(id: String, contentID: String, trackNumber: Int) {
            self.id = id
            self.contentID = contentID
            self.trackNumber = trackNumber
        }
    }

    public init(id: String, name: String, dateCreated: String?, entries: [Entry]) {
        self.id = id
        self.name = name
        self.dateCreated = dateCreated
        self.entries = entries
    }

    /// 사이드바 제목: 만든 날짜(없으면 "날짜 없음")와 이름. 이름이 비었거나 날짜와 같으면 날짜만.
    public var title: String {
        let date = dateCreated.map { String($0.prefix(10)) } ?? String(ui: "날짜 없음")
        return name.isEmpty || name == date ? date : "\(date) · \(name)"
    }
}
