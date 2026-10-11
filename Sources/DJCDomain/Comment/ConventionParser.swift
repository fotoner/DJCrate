import Foundation

/// 컨벤션 코멘트 파서.
///
/// 작품명 안에 숫자·기호가 섞일 수 있어서(`…게이트 0`, `22/7`) 뒤에서부터 구조 토큰을 떼어 낸다.
/// 토큰 순서가 흔들려도(`ED CS`, `IN 3 TVSIZE`, `(약칭) 1기`) 같은 구조로 흡수한다.
///
/// 정규식을 쓰지 않는다. 곡마다 수십 개의 Swift Regex를 돌리던 이전 구현은 7천 곡에
/// 약 20초가 걸렸다. 공백 기준 마지막 토큰을 보고 떼어 내는 방식으로 같은 규칙을 구현한다.
public enum ConventionParser {
    static let prefixes: [ConventionComment.Prefix] = [.tva, .ova, .mv, .gm, .pcGame, .vt, .vd, .nt, .adv]

    public static func prefix(of text: String) -> ConventionComment.Prefix? {
        for prefix in prefixes where text.hasPrefix(prefix.rawValue) {
            let rest = text.dropFirst(prefix.rawValue.count)
            if rest.isEmpty || rest.first!.isWhitespace { return prefix }
        }
        return nil
    }

    public static func parse(_ raw: String) -> ConventionComment? {
        parse(normalized: CommentText.normalize(raw))
    }

    /// 이미 정규화된 문자열을 파싱한다(로딩 때 정규화를 한 번만 하려고 분리).
    public static func parse(normalized text: String) -> ConventionComment? {
        guard let prefix = prefix(of: text) else { return nil }
        var result = ConventionComment(prefix: prefix)
        var rest = Tokens(String(text.dropFirst(prefix.rawValue.count)).trimmingCharacters(in: .whitespaces))
        stripTrailingTokens(&rest, into: &result)
        parseWorkRef(rest.text, into: &result)
        return result
    }

    // MARK: - 뒤쪽 구조 토큰

    private static let flagTokens: Set<String> = ["TVSIZE", "TVISZE", "TVIZE"]
    private static let variantTokens: Set<String> = ["CV", "RM", "MX", "MIX", "AR", "PV", "Short", "레뷰"]

    private static func stripTrailingTokens(_ rest: inout Tokens, into result: inout ConventionComment) {
        var tail = ConventionComment.Tail()
        var boombox: [Int] = []
        var usages: [ConventionComment.Usage] = []
        var episodes: [Int] = []
        var variants: [String] = []

        var progressed = true
        while progressed, !rest.isEmpty {
            progressed = false
            guard let last = rest.last else { break }

            // 툴 꼬리: BBnn(반복) / 구형 BB13,19
            if last.hasPrefix("BB"), !last.hasSuffix(","), let numbers = numberList(last.dropFirst(2)), !numbers.isEmpty {
                boombox.insert(contentsOf: numbers, at: 0)
                rest.dropLast(); progressed = true; continue
            }
            if let quarter = quarterToken(last), let year = rest.last(offset: 1).flatMap(year4) {
                tail.airingYear = year
                tail.airingQuarter = quarter
                rest.dropLast(2); progressed = true; continue
            }
            if last == "영화", let year = rest.last(offset: 1).flatMap(year4) {
                tail.movieYear = year
                rest.dropLast(2); progressed = true; continue
            }

            // 플래그
            if flagTokens.contains(last) {
                result.isTVSize = true
                rest.dropLast(); progressed = true; continue
            }
            if last == "SIZE", rest.last(offset: 1) == "TV" {
                result.isTVSize = true
                rest.dropLast(2); progressed = true; continue
            }
            if last == "CS" || last == "[CS]" {
                result.isCharacterSong = true
                rest.dropLast(); progressed = true; continue
            }
            if rest.text.hasSuffix("(한국)") {
                variants.insert("(한국)", at: 0)
                rest.dropSuffix("(한국)"); progressed = true; continue
            }
            if variantTokens.contains(last) {
                variants.insert(last, at: 0)
                rest.dropLast(); progressed = true; continue
            }

            // 회차: `3화`, `3화, 5화`, `3화,5화`, `EP 12`, `EP12`
            if let collected = trailingEpisodes(rest) {
                episodes.insert(contentsOf: collected.episodes, at: 0)
                rest.dropLast(collected.tokenCount); progressed = true; continue
            }
            if last.hasPrefix("EP"), let n = digits(last.dropFirst(2)) {
                episodes.insert(n, at: 0)
                rest.dropLast(); progressed = true; continue
            }
            if let n = digits(Substring(last)), rest.last(offset: 1) == "EP" {
                episodes.insert(n, at: 0)
                rest.dropLast(2); progressed = true; continue
            }

            // 용도: `OP`, `ED 1`, `IN9`, `IN 3 7 11 23`, `IN 8, 10`
            if let usage = usageClause(rest) {
                usages.insert(usage.usage, at: 0)
                rest.dropLast(usage.tokenCount); progressed = true; continue
            }
        }

        tail.boomboxVolumes = boombox
        result.tail = tail
        result.usages = usages
        result.episodes = episodes
        result.variants = variants
    }

    /// 끝에서부터 번호 토큰들을 모으고, 그 앞 토큰이 용도(OP·ED·IN)이면 받아들인다.
    /// 번호 사이 구분은 `, ` · `,` · ` ` 모두 허용하고, 목록은 쉼표로 끝날 수 없다.
    private static func usageClause(_ rest: Tokens) -> (usage: ConventionComment.Usage, tokenCount: Int)? {
        var numbers: [Int] = []
        var index = 0
        while let token = rest.last(offset: index), let list = numberList(token) {
            if index == 0, token.hasSuffix(",") { break }
            numbers.insert(contentsOf: list, at: 0)
            index += 1
        }
        guard let head = rest.last(offset: index) else { return nil }
        for kind in [ConventionComment.UsageKind.op, .ed, .insert] where head.hasPrefix(kind.rawValue) {
            let attached = head.dropFirst(kind.rawValue.count)
            if attached.isEmpty { return (.init(kind: kind, numbers: numbers), index + 1) }
            // 붙여 쓴 번호: `IN9`, `IN5,` + `8`, `IN5` + `8`
            if let list = numberList(attached) {
                if index == 0, attached.hasSuffix(",") { return nil }
                return (.init(kind: kind, numbers: list + numbers), index + 1)
            }
        }
        return nil
    }

    /// 끝의 회차 목록. 마지막 토큰은 쉼표로 끝나지 않고, 앞 토큰들은 `3화,` 형태다.
    private static func trailingEpisodes(_ rest: Tokens) -> (episodes: [Int], tokenCount: Int)? {
        var collected: [Int] = []
        var count = 0
        while let token = rest.last(offset: count) {
            var body = Substring(token)
            if count == 0 {
                if body.hasSuffix(",") { break }
            } else {
                guard body.hasSuffix(",") else { break }
                body = body.dropLast()
            }
            let parts = body.split(separator: ",", omittingEmptySubsequences: false)
            let values = parts.map(episodeToken)
            guard !parts.isEmpty, values.allSatisfy({ $0 != nil }) else { break }
            collected.insert(contentsOf: values.compactMap { $0 }, at: 0)
            count += 1
        }
        return count > 0 ? (collected, count) : nil
    }

    // MARK: - work_ref (작품명 + 기수 + 약칭)

    private static func parseWorkRef(_ ref: String, into result: inout ConventionComment) {
        result.workRef = ref
        var rest = ref

        if rest.hasSuffix("(구)") {
            rest = String(rest.dropLast(3)).trimmingCharacters(in: .whitespaces)
            result.isFormerAffiliation = true
        }

        // 기수와 약칭 순서가 흔들리므로 두 번까지 번갈아 뗀다.
        for _ in 0..<2 {
            if result.season == nil {
                if let (inner, before) = trailingParenthesized(rest), inner.hasSuffix("기"),
                   let n = digits(inner.dropLast()) {
                    result.season = n; result.seasonStyle = .parenthesized
                    rest = before; continue
                }
                if let space = rest.lastIndex(of: " ") {
                    let token = rest[rest.index(after: space)...]
                    if token.hasSuffix("기"), let n = digits(token.dropLast()) {
                        result.season = n; result.seasonStyle = .plain
                        rest = String(rest[..<space]).trimmingCharacters(in: .whitespaces); continue
                    }
                    if let n = digits(token) {
                        let before = rest[..<space].trimmingCharacters(in: .whitespaces)
                        if before.hasSuffix(" 시즌") {
                            result.season = n; result.seasonStyle = .season
                            rest = String(before.dropLast(3)).trimmingCharacters(in: .whitespaces); continue
                        }
                    }
                    if token.hasPrefix("시즌"), let n = digits(token.dropFirst(2)) {
                        result.season = n; result.seasonStyle = .season
                        rest = String(rest[..<space]).trimmingCharacters(in: .whitespaces); continue
                    }
                }
            }
            if result.abbreviations.isEmpty, let (inner, before) = trailingParenthesized(rest) {
                result.abbreviations = inner
                    .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                rest = before
                continue
            }
            break
        }
        result.workName = rest
    }

    // MARK: - helpers

    /// 끝의 `(…)` 한 쌍(안에 괄호가 없는 것)과 그 앞 부분.
    private static func trailingParenthesized(_ text: String) -> (inner: Substring, before: String)? {
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard !inner.isEmpty, !inner.contains("("), !inner.contains(")") else { return nil }
        return (inner, String(text[..<open]).trimmingCharacters(in: .whitespaces))
    }

    /// `13`, `13,19`, `8,` → [13] / [13, 19] / [8]. 숫자와 쉼표 외 글자가 있으면 nil.
    private static func numberList(_ text: Substring) -> [Int]? {
        guard let first = text.first, first.wholeNumberValue != nil,
              text.allSatisfy({ $0.wholeNumberValue != nil || $0 == "," }), !text.contains(",,") else { return nil }
        return text.split(separator: ",").compactMap { digits($0) }
    }

    private static func numberList(_ text: String) -> [Int]? { numberList(Substring(text)) }

    private static func year4(_ token: String) -> Int? {
        token.count == 4 ? digits(Substring(token)) : nil
    }

    private static func quarterToken(_ token: String) -> Int? {
        guard token.count == 3, token.hasSuffix("분기"), let q = token.first?.wholeNumberValue, (1...4).contains(q) else { return nil }
        return q
    }

    private static func episodeToken(_ token: Substring) -> Int? {
        guard token.hasSuffix("화") else { return nil }
        return digits(token.dropLast())
    }

    /// 부호 없는 10진수(`+3` 같은 것은 거부).
    private static func digits(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber && $0.wholeNumberValue != nil }) else { return nil }
        return Int(String(text.compactMap { $0.wholeNumberValue.map(String.init) }.joined()))
    }
}

/// 공백으로 나눈 토큰을 끝에서부터 떼어 내는 작은 도우미.
struct Tokens {
    private(set) var tokens: [String]

    init(_ text: String) {
        tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    var isEmpty: Bool { tokens.isEmpty }
    var last: String? { tokens.last }
    var text: String { tokens.joined(separator: " ") }

    func last(offset: Int) -> String? {
        let index = tokens.count - 1 - offset
        return tokens.indices.contains(index) ? tokens[index] : nil
    }

    mutating func dropLast(_ count: Int = 1) {
        tokens.removeLast(min(count, tokens.count))
    }

    /// 마지막 토큰 끝에 붙은 접미사를 뗀다(`35(한국)` → `35`). 토큰이 비면 없앤다.
    mutating func dropSuffix(_ suffix: String) {
        guard var lastToken = tokens.popLast(), lastToken.hasSuffix(suffix) else { return }
        lastToken.removeLast(suffix.count)
        let trimmed = lastToken.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { tokens.append(trimmed) }
    }
}
