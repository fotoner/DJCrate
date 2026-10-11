import Foundation

/// 조건 계산에서 rekordbox와 맞춰 보지 않은 해석(#68). 아래 기본값(`provisional`)은 추정이고, 묶음 3 M1에서 rekordbox가 보여 주는 곡 수와
/// 견줘 맞는 쪽으로 정한다(계산 의미 U3). 다른 해석이 맞으면 이 값만 바꾸면 되고, 각 값은 시험이 양쪽 해석의 결과를 못 박아 둔다.
public struct SmartPlaylistSemantics: Sendable, Equatable {
    /// 글자 비교(같음·포함·시작·끝)에서 대소문자를 가리지 않는다.
    public var ignoresCase = true
    /// '보다 큼'이 같은 값을 포함한다(≥)
    public var greaterIncludesEqual = false
    /// '보다 작음'이 같은 값을 포함한다(≤)
    public var lessIncludesEqual = false
    /// '범위'가 양끝 값을 포함한다
    public var rangeIncludesEnds = true
    /// '같지 않음'·'포함하지 않음'이 빈 값(아티스트 없음·연도 없음)을 가진 곡을 포함한다
    public var negationMatchesEmpty = true

    public init() {}

    /// 확인 전 기본 해석
    public static let provisional = SmartPlaylistSemantics()
}

/// 계산 결과. 계산하지 못하는 조건이 하나라도 있으면 곡을 보이지 않는다(틀린 곡을 보이는 것보다 낫다).
public enum SmartPlaylistResult: Sendable, Equatable {
    /// 조건에 맞는 곡 ID(입력 곡 순서)
    case tracks([String])
    /// 계산하지 못한 조건마다 이유(사용자에게 보이는 한 문장, 같은 이유는 한 번)
    case unsupported([String])

    public var trackIDs: [String] {
        if case let .tracks(ids) = self { ids } else { [] }
    }

    public var unsupportedReasons: [String] {
        if case let .unsupported(reasons) = self { reasons } else { [] }
    }
}

/// 인텔리전트 재생 목록 조건 계산기(입출력 없음).
///
/// 계산하는 조건(지금): 글자 항목 `name`(제목)·`artist`·`album`·`albumArtist`·`comments`의 같음·같지 않음·포함·포함하지 않음·시작·끝, 그리고
/// 숫자 항목 `year`의 같음·같지 않음·큼·작음·범위. 값 단위(`ValueUnit`)는 빈 글자만 받는다.
/// 그 밖의 항목·연산자·단위·값 모양은 추측하지 않고 "지원하지 않는 조건"으로 둔다. 항목마다 이유가 다르다:
/// - `bpm`·`duration`: 값이 DB 정수(BPM ×100·초)인지 화면 값인지 확인하지 않았다.
/// - `genre`·`key`·`myTag`·`grouping`: 값이 이름인지 번호인지 확인하지 않았다.
/// - `rating`·`grouping`(곡 색)·`myTag`: 곡 행·태그 칸 읽기가 #65·#67 쪽에서 들어온다(연결 자리: `supportedTextFields`·`numberField`).
/// - `stockDate`·`dateCreated`·`dateReleased`와 최근 N일(`inLast`·`notInLast`): 날짜 칸을 읽지 않고 기준 시각의 뜻을 확인하지 않았다.
/// - `counter`·`label`·`remixedBy`·`mixName`·`fileName`·`producer`·`originalArtist`: 아직 읽지 않는 칸이다.
public enum SmartPlaylistEvaluator {
    public static func evaluate(_ source: SmartPlaylistSource, tracks: [Track],
                                semantics: SmartPlaylistSemantics = .provisional) -> SmartPlaylistResult {
        switch source {
        case let .unreadable(reason):
            return .unsupported([reason])
        case let .definition(definition):
            return evaluate(definition, tracks: tracks, semantics: semantics)
        }
    }

    public static func evaluate(_ definition: SmartPlaylistDefinition, tracks: [Track],
                                semantics: SmartPlaylistSemantics = .provisional) -> SmartPlaylistResult {
        guard !definition.conditions.isEmpty else { return .unsupported([String(ui: "조건이 하나도 없습니다")]) }
        var predicates: [(Track) -> Bool] = []
        var reasons: [String] = []
        for condition in definition.conditions {
            switch compile(condition, semantics) {
            case let .success(predicate): predicates.append(predicate)
            case let .failure(reason): if !reasons.contains(reason.text) { reasons.append(reason.text) }
            }
        }
        guard reasons.isEmpty else { return .unsupported(reasons) }
        let ids = tracks.lazy.filter { track in
            guard !track.isDeleted else { return false }
            switch definition.match {
            case .all: return predicates.allSatisfy { $0(track) }
            case .any: return predicates.contains { $0(track) }
            }
        }.map(\.id)
        return .tracks(Array(ids))
    }

    /// 계산하지 못하는 이유. 빈 배열이면 계산한다.
    public static func unsupportedReasons(_ definition: SmartPlaylistDefinition) -> [String] {
        evaluate(definition, tracks: []).unsupportedReasons
    }

    // MARK: - 조건 하나

    private struct Unsupported: Error {
        let text: String
    }

    /// 글자 항목이 읽는 곡 칸. 새 항목을 계산하게 되면 여기에 더한다.
    private static func supportedTextFields(_ property: SmartPlaylistProperty) -> ((Track) -> String)? {
        switch property {
        case .name: { $0.title }
        case .artist: { $0.artist ?? "" }
        case .album: { $0.album ?? "" }
        case .albumArtist: { $0.albumArtist ?? "" }
        case .comments: { $0.comment }
        default: nil
        }
    }

    /// 숫자 항목이 읽는 곡 칸(없으면 nil).
    private static func numberField(_ property: SmartPlaylistProperty) -> ((Track) -> Int?)? {
        switch property {
        case .year: { $0.releaseYear }
        default: nil
        }
    }

    private static let textOperators: Set<SmartPlaylistOperator> = [.equal, .notEqual, .contains, .notContains, .startsWith, .endsWith]
    private static let numberOperators: Set<SmartPlaylistOperator> = [.equal, .notEqual, .greater, .less, .inRange]

    private static func compile(_ condition: SmartPlaylistDefinition.Condition,
                                _ semantics: SmartPlaylistSemantics) -> Result<(Track) -> Bool, Unsupported> {
        let name = condition.propertyName
        guard let property = condition.property else {
            return .failure(Unsupported(text: String(ui: "알 수 없는 조건 항목입니다(\(name))")))
        }
        let text = supportedTextFields(property), number = numberField(property)
        guard text != nil || number != nil else {
            return .failure(Unsupported(text: String(ui: "‘\(name)’ 조건은 아직 계산하지 않습니다")))
        }
        guard let op = condition.operator else {
            return .failure(Unsupported(text: String(ui: "알 수 없는 연산자입니다(\(condition.operatorCode))")))
        }
        guard (text != nil ? textOperators : numberOperators).contains(op) else {
            return .failure(Unsupported(text: String(ui: "‘\(name)’ 조건에서 이 연산자는 계산하지 않습니다(\(condition.operatorCode))")))
        }
        guard condition.unit.isEmpty else {
            return .failure(Unsupported(text: String(ui: "‘\(name)’ 조건의 값 단위를 알 수 없습니다(\(condition.unit))")))
        }
        guard !condition.left.isEmpty else {
            return .failure(Unsupported(text: String(ui: "‘\(name)’ 조건의 값이 비어 있습니다")))
        }
        if let text { return .success(textPredicate(text, op, condition.left, semantics)) }
        guard let number else { return .failure(Unsupported(text: String(ui: "‘\(name)’ 조건은 아직 계산하지 않습니다"))) }
        guard let left = Int(condition.left) else {
            return .failure(Unsupported(text: String(ui: "‘\(name)’ 조건의 값을 숫자로 읽지 못했습니다")))
        }
        var right = 0
        if op == .inRange {
            guard let value = Int(condition.right), left <= value else {
                return .failure(Unsupported(text: String(ui: "‘\(name)’ 조건의 범위가 올바르지 않습니다")))
            }
            right = value
        }
        return .success(numberPredicate(number, op, left, right, semantics))
    }

    /// 같은 글자는 같다: 합성·분해 형태(NFC·NFD)를 맞추고, 설정이면 대소문자도 접는다. 전각·반각 같은 호환 변형은 맞추지 않는다.
    private static func normalized(_ text: String, _ semantics: SmartPlaylistSemantics) -> String {
        let composed = text.precomposedStringWithCanonicalMapping
        return semantics.ignoresCase ? composed.folding(options: .caseInsensitive, locale: nil) : composed
    }

    private static func textPredicate(_ field: @escaping (Track) -> String, _ op: SmartPlaylistOperator, _ target: String,
                                      _ semantics: SmartPlaylistSemantics) -> (Track) -> Bool {
        let needle = normalized(target, semantics)
        return { track in
            let value = normalized(field(track), semantics)
            switch op {
            case .equal: return value == needle
            case .notEqual: return value.isEmpty ? semantics.negationMatchesEmpty : value != needle
            case .contains: return !value.isEmpty && value.range(of: needle, options: .literal) != nil
            case .notContains: return value.isEmpty ? semantics.negationMatchesEmpty : value.range(of: needle, options: .literal) == nil
            case .startsWith: return !value.isEmpty && value.hasPrefix(needle)
            case .endsWith: return !value.isEmpty && value.hasSuffix(needle)
            default: return false
            }
        }
    }

    private static func numberPredicate(_ field: @escaping (Track) -> Int?, _ op: SmartPlaylistOperator, _ left: Int, _ right: Int,
                                        _ semantics: SmartPlaylistSemantics) -> (Track) -> Bool {
        { track in
            guard let value = field(track) else { return op == .notEqual && semantics.negationMatchesEmpty }
            switch op {
            case .equal: return value == left
            case .notEqual: return value != left
            case .greater: return semantics.greaterIncludesEqual ? value >= left : value > left
            case .less: return semantics.lessIncludesEqual ? value <= left : value < left
            case .inRange: return semantics.rangeIncludesEnds ? (left...right).contains(value) : (value > left && value < right)
            default: return false
            }
        }
    }
}
