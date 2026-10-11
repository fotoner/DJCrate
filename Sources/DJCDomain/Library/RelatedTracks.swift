import Foundation

/// 덱의 기준곡과 컬렉션 메타데이터만 비교한다. 점수 계산은 입출력이 없다.
/// BPM 50 · 키 30 · 장르 10 · #태그 교집합/합집합 10점. 없는 정보는 가점하지 않는다.
public enum RelatedTracks {
    public struct Score: Sendable, Equatable {
        public let bpm: Double
        public let key: Double
        public let genre: Double
        public let tags: Double
        public let tempoMultiplier: Double?
        public var total: Double { bpm + key + genre + tags }
    }

    public struct Match: Sendable, Identifiable, Equatable {
        public let id: String
        public let score: Score
    }

    /// BPM은 ±6%까지. 같은 속도 50점, 반·두 배 45점을 상한으로 차이에 따라 감점한다.
    public static func score(source: Track, candidate: Track) -> Score? {
        score(source: source, metadata: Metadata(source), candidate: candidate)
    }

    public static func rank(source: Track, candidates: [Track], limit: Int = 100) -> [Match] {
        guard limit > 0 else { return [] }
        let metadata = Metadata(source)
        return Array(candidates.compactMap { candidate -> Match? in
            guard let score = score(source: source, metadata: metadata, candidate: candidate) else { return nil }
            return Match(id: candidate.id, score: score)
        }.sorted {
            // 동점에서도 입력·DB 순서가 바뀔 때 목록이 흔들리지 않게 한다.
            $0.score.total == $1.score.total ? $0.id < $1.id : $0.score.total > $1.score.total
        }.prefix(limit))
    }

    private static func score(source: Track, metadata: Metadata, candidate: Track) -> Score? {
        guard source.id != candidate.id, !candidate.isDeleted, !candidate.isStreaming else { return nil }
        var bpm = 0.0
        var multiplier: Double?
        if let sourceBPM = validBPM(source.bpm), let candidateBPM = validBPM(candidate.bpm) {
            let best = [1.0, 0.5, 2.0].min {
                abs(candidateBPM * $0 - sourceBPM) < abs(candidateBPM * $1 - sourceBPM)
            }!
            let difference = abs(candidateBPM * best - sourceBPM) / sourceBPM
            guard difference <= 0.06 + 1e-12 else { return nil }
            bpm = (50 - 25 * min(difference / 0.06, 1)) * (best == 1 ? 1 : 0.9)
            multiplier = best
        }
        let other = Metadata(candidate)
        var key = 0.0
        if let first = metadata.key, let second = other.key {
            let distance = abs(first.number - second.number)
            if first == second { key = 30 }
            else if distance == 0 || (first.letter == second.letter && (distance == 1 || distance == 11)) { key = 24 }
        }
        let genre = !metadata.genre.isEmpty && metadata.genre == other.genre ? 10.0 : 0
        let union = metadata.tags.union(other.tags)
        let tags = union.isEmpty ? 0 : 10 * Double(metadata.tags.intersection(other.tags).count) / Double(union.count)
        let result = Score(bpm: bpm, key: key, genre: genre, tags: tags, tempoMultiplier: multiplier)
        return result.total > 0 ? result : nil
    }

    private static func validBPM(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private struct HarmonicKey: Equatable {
        let number: Int
        let letter: Character

        init?(_ value: String?) {
            let text = normalize(value ?? "").uppercased()
            guard let letter = text.last, letter == "A" || letter == "B",
                  let number = Int(text.dropLast()), (1...12).contains(number) else { return nil }
            self.number = number
            self.letter = letter
        }
    }

    private struct Metadata {
        let key: HarmonicKey?
        let genre: String
        let tags: Set<String>

        init(_ track: Track) {
            key = HarmonicKey(track.key)
            genre = normalize(track.genre ?? "")
            // 개인 코멘트 규칙을 강제하지 않고 명시적인 #태그만 비교한다.
            tags = Set(normalize(track.comment).split {
                !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" && $0 != "#"
            }.filter { $0.hasPrefix("#") && $0.count > 1 }.map { String($0.dropFirst()) })
        }
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
