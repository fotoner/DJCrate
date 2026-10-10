import Foundation

/// '재생 목록에 넣기…'에서 고를 목록(#249). 이름과 폴더 경로로 찾는다. 찾지 않을 때는 최근에 곡을 넣은 목록이 위에 온다.
public struct PlaylistChoices: Sendable, Equatable {
    public struct Choice: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        /// 위 폴더 이름들을 ` › `로 이은 것(맨 위 목록은 빈 문자열)
        public var path: String
        /// 찾지 않을 때 최근 목록으로 위에 놓인 줄
        public var recent: Bool
    }

    /// 곡을 넣을 수 있는 목록(트리 순서)
    public var playlists: [Choice]
    /// 최근에 곡을 넣은 목록 ID(최근 것부터)
    public var recentIDs: [String]

    /// - Parameters:
    ///   - playlists: 곡을 넣을 수 있는 목록과 위 폴더 이름들(트리 순서)
    ///   - recentIDs: 최근에 곡을 넣은 목록 ID(최근 것부터). 지금 `playlists`에 없는 ID는 무시한다
    public init(playlists: [(item: PlaylistLayout.Item, path: [String])], recentIDs: [String]) {
        self.playlists = playlists.map { Choice(id: $0.item.id, name: $0.item.name, path: $0.path.joined(separator: " › "), recent: false) }
        self.recentIDs = recentIDs
    }

    /// 찾는 말(앞뒤 공백 무시, 대소문자 무시)이 경로·이름에 든 목록. 빈 말이면 최근 목록을 먼저, 나머지는 트리 순서로 둔다.
    public func choices(matching query: String) -> [Choice] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.isEmpty else {
            return playlists.filter { ($0.path + " " + $0.name).lowercased().contains(needle) }
        }
        let recent = recentIDs.compactMap { id in playlists.first { $0.id == id } }.map { choice in
            var choice = choice
            choice.recent = true
            return choice
        }
        let recentIDs = Set(recent.map(\.id))
        return recent + playlists.filter { !recentIDs.contains($0.id) }
    }
}
