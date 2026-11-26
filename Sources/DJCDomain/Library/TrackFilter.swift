import Foundation

/// BPM 범위 조건(#351). 양끝을 포함하고, 한쪽을 비우면 그쪽은 열려 있다. 둘 다 비우면 조건이 아니다.
/// 순서를 몰래 바꾸지 않는다: 최소 칸에 값을 치는 도중에도 값 그대로 판정한다(최소가 최대보다 크면 맞는 곡이 없다).
public struct BPMRange: Sendable, Hashable {
    public var lower: Double?
    public var upper: Double?

    public init(lower: Double? = nil, upper: Double? = nil) {
        self.lower = lower
        self.upper = upper
    }

    /// CLI `--bpm 120-130`의 범위
    public init(_ range: ClosedRange<Double>) {
        self.init(lower: range.lowerBound, upper: range.upperBound)
    }

    public var isEmpty: Bool { lower == nil && upper == nil }

    /// BPM을 모르는 곡(nil)은 조건이 있으면 맞지 않는다.
    public func contains(_ bpm: Double?) -> Bool {
        guard !isEmpty else { return true }
        guard let bpm else { return false }
        return (lower.map { bpm >= $0 } ?? true) && (upper.map { bpm <= $0 } ?? true)
    }

    /// 화면 글자: 정수는 소수점 없이, 아니면 소수 둘째 자리까지(끝의 0은 뗀다). 128 · 127.5 · 127.25. 소수점은 화면 문구 언어를 따른다
    public static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(UIStrings.locale))
    }
}

/// 키 조건(#351). 곡의 키 값과 조건은 `KeyNotation.camelot(from:)`로 Camelot 이름으로 바꿔 비교한다
/// (`8A` · `Am` · `A minor` · Open Key `1m`이 모두 같은 키). 바꿀 수 없는 값은 "같은 키"(글자 일치)로만 맞는다.
public struct KeyCondition: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        /// 고른 키와 같은 키
        case same
        /// 고른 키와 같은 키, 같은 번호의 A↔B, 번호 ±1의 같은 글자(12↔1 순환). 믹싱에서 어울리는 키
        case compatible
    }

    /// 사용자가 준 글자(앞뒤 공백을 뗀 것)
    public let text: String
    public let mode: Mode
    /// 조건을 Camelot 이름으로 바꾼 값(바꿀 수 없으면 nil)
    public let camelot: String?

    public init(_ text: String, mode: Mode = .same) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = trimmed
        self.mode = mode
        camelot = KeyNotation.camelot(from: trimmed)
    }

    /// 곡의 키 글자(`keyText`)와 그것을 Camelot으로 바꾼 값(`camelot`)으로 판정한다.
    /// 곡 줄은 `camelot`을 만들 때 한 번 바꿔 둔다(`TrackRow.camelotKey`).
    func matches(keyText: String?, camelot trackCamelot: String?) -> Bool {
        guard let keyText, !keyText.isEmpty else { return false }
        if let want = camelot, let have = trackCamelot {
            return mode == .same ? want == have : Self.isCompatible(want, have)
        }
        // 어느 한쪽이 Camelot으로 안 바뀌면 글자가 같을 때만 같은 키다(어울리는 키도 마찬가지)
        return TrackSearch.normalized(keyText.trimmingCharacters(in: .whitespacesAndNewlines)) == TrackSearch.normalized(text)
    }

    /// 같은 키, 같은 번호의 반대 글자(A↔B), 번호 ±1의 같은 글자(12와 1은 이웃)
    static func isCompatible(_ lhs: String, _ rhs: String) -> Bool {
        guard let (lhsNumber, lhsLetter) = split(lhs), let (rhsNumber, rhsLetter) = split(rhs) else { return false }
        if lhsNumber == rhsNumber { return true }
        guard lhsLetter == rhsLetter else { return false }
        let distance = abs(lhsNumber - rhsNumber)
        return distance == 1 || distance == 11
    }

    private static func split(_ camelot: String) -> (number: Int, letter: Character)? {
        guard let letter = camelot.last, let number = Int(camelot.dropLast()) else { return nil }
        return (number, letter)
    }
}

/// 곡 목록 필터 조건 묶음(#351). 조건끼리는 AND이고, 곡 색만 고른 색 가운데 하나이면 맞는다(곡 색은 곡마다 하나라서).
/// 판정은 여기 한 곳이다. 앱의 곡 목록(`TrackListProjection.filtered`)과 CLI `djc search --bpm/--key`가 같은 함수를 부른다.
/// 기준은 rekordbox 값(초안 전)이다: 정렬·사이드바 항목과 같다. USB 곡도 같은 칸으로 거른다.
public struct TrackFilter: Sendable, Equatable {
    /// 평점이 이 별 수 이상(0이면 끔)
    public var minimumRating: Int
    /// 고른 곡 색 ID. 비면 끔
    public var colorIDs: Set<String>
    public var bpm: BPMRange?
    public var key: KeyCondition?
    /// 장르 하나. 대소문자·NFC를 무시한 정확 일치. 빈 글자는 조건이 아니다
    public var genre: String? {
        didSet {
            genre = Self.cleaned(genre)
            normalizedGenre = genre.map(Self.genreKey)
        }
    }
    /// 곡마다 되풀이하지 않게 장르를 한 번만 맞춰 둔 글자
    private var normalizedGenre: String?

    public init(minimumRating: Int = 0, colorIDs: Set<String> = [], bpm: BPMRange? = nil, key: KeyCondition? = nil, genre: String? = nil) {
        self.minimumRating = minimumRating
        self.colorIDs = colorIDs
        self.bpm = bpm.flatMap { $0.isEmpty ? nil : $0 }
        self.key = key
        self.genre = Self.cleaned(genre)
        normalizedGenre = self.genre.map(Self.genreKey)
    }

    /// 장르를 비교하는 글자: 앞뒤 공백을 떼고 소문자·NFC로 맞춘다. 곡 줄(`TrackRow.genreKey`)과 조건이 같은 변환을 쓴다.
    public static func genreKey(_ genre: String?) -> String {
        TrackSearch.normalized((genre ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 켠 조건이 없으면 모든 곡이 맞는다
    public var isEmpty: Bool {
        minimumRating <= 0 && colorIDs.isEmpty && (bpm?.isEmpty ?? true) && key == nil && genre == nil
    }

    /// 앞뒤 공백을 떼고 빈 글자는 nil로(장르 칸에 공백뿐인 값이 들어와도 조건이 켜지지 않는다)
    private static func cleaned(_ genre: String?) -> String? {
        guard let trimmed = genre?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 곡 값으로 판정한다(CLI). 키·장르는 부를 때 바꾼다.
    public func matches(_ track: Track) -> Bool {
        guard !isEmpty else { return true }
        return matches(rating: track.rating, colorID: track.colorID, bpm: track.bpm, keyText: track.key,
                       camelot: key == nil ? nil : track.key.flatMap(KeyNotation.camelot(from:)),
                       genreKey: normalizedGenre == nil ? "" : Self.genreKey(track.genre))
    }

    /// 곡 줄로 판정한다(앱 곡 목록). 키·장르는 줄을 만들 때 바꿔 둔 값을 쓴다.
    public func matches(_ row: TrackRow) -> Bool {
        guard !isEmpty else { return true }
        return matches(rating: row.track.rating, colorID: row.track.colorID, bpm: row.track.bpm, keyText: row.track.key,
                       camelot: row.camelotKey, genreKey: row.genreKey)
    }

    private func matches(rating: Int, colorID: String?, bpm trackBPM: Double?, keyText: String?, camelot: String?, genreKey: String) -> Bool {
        if rating < minimumRating { return false }
        if !colorIDs.isEmpty, !(colorID.map(colorIDs.contains) ?? false) { return false }
        if let bpm, !bpm.contains(trackBPM) { return false }
        if let key, !key.matches(keyText: keyText, camelot: camelot) { return false }
        if let normalizedGenre, genreKey != normalizedGenre { return false }
        return true
    }
}

extension TrackFilter {
    /// 장르 고르기에 보일 이름: 줄들이 가진 장르를 대소문자·앞뒤 공백·NFC가 달라도 하나로 합치고(비교 글자 `genreKey`),
    /// 합친 표기 가운데 가장 많이 쓴 것(같으면 사전순 앞)을 보인다. 화면 문구 언어의 이름순(`UIStrings.standardOrder`)으로 돌려준다. 장르가 없는 곡은 세지 않는다.
    public static func genreChoices(in rows: [TrackRow]) -> [String] {
        var spellings: [String: [String: Int]] = [:]
        for row in rows where !row.genreKey.isEmpty {
            let shown = (row.track.genre ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            spellings[row.genreKey, default: [:]][shown, default: 0] += 1
        }
        let names = spellings.values.compactMap { counts in
            counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }
        // 순서는 시스템 로캘이 아니라 화면 문구 언어를 따른다(시험·CLI에서도 실행 환경과 상관없이 같다)
        return names.sorted { UIStrings.standardOrder($0, $1) == .orderedAscending }
    }
}
