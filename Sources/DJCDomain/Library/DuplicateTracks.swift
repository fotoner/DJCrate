import Foundation

/// 메타데이터로 찾는 읽기 전용 중복 후보. 같은 음원임을 보장하지 않는다.
public enum DuplicateTracks {
    public static let lengthToleranceSeconds = 2

    public struct Group: Sendable, Equatable, Identifiable {
        public let trackIDs: [String]
        public var id: String { trackIDs[0] }
    }

    public static func groups(in tracks: [Track]) -> [Group] {
        struct Key: Hashable {
            let title: String
            let artist: String
        }
        var buckets: [Key: [Track]] = [:]
        var seen = Set<String>()
        for track in tracks {
            guard !track.isDeleted, !track.isStreaming, track.lengthSeconds > 0,
                  !track.title.hasPrefix("$A7:"), seen.insert(track.id).inserted else { continue }
            let key = Key(title: normalize(track.title), artist: normalize(track.artist ?? ""))
            guard !key.title.isEmpty, !key.artist.isEmpty else { continue }
            buckets[key, default: []].append(track)
        }
        var groups: [Group] = []
        for bucket in buckets.values where bucket.count > 1 {
            let sorted = bucket.sorted { ($0.lengthSeconds, $0.id) < ($1.lengthSeconds, $1.id) }
            var end = 0, previousEnd = 0
            for start in sorted.indices {
                while end < sorted.count,
                      sorted[end].lengthSeconds - sorted[start].lengthSeconds <= lengthToleranceSeconds { end += 1 }
                // 최대 차이 2초의 가장 큰 구간만 남긴다. 180·182·184초는 겹치는 두 묶음이다.
                if end > previousEnd, end - start > 1 {
                    groups.append(Group(trackIDs: sorted[start..<end].map(\.id)))
                    previousEnd = end
                }
            }
        }
        return groups.sorted { $0.id < $1.id }
    }

    private static func normalize(_ text: String) -> String {
        // 버전·악센트·문장부호를 지우면 다른 편집본까지 같은 곡으로 오인한다.
        text.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .precomposedStringWithCanonicalMapping
    }
}
