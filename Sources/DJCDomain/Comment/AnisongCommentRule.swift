import Foundation

/// 애니송 프리셋. 기존 컨벤션의 파싱·분류는 이 구현 안에서 유지한다.
public struct AnisongCommentRule: CommentRule {
    public init() {}

    public func parse(_ text: String) -> ConventionComment? { ConventionParser.parse(text) }

    public func evaluate(normalized text: String) -> CommentEvaluation {
        let classification = CommentClassifier.classify(normalized: text)
        let parsed = ConventionParser.parse(normalized: text)
        let display: (String, CommentEvaluation.Tone) = switch classification {
        case .convention: (String(ui: "규칙"), .matched)
        case .legacy: (String(ui: "구형"), .info)
        case .residue: (String(ui: "잔재"), .residue)
        case .credit: (String(ui: "크레딧"), .info)
        case .empty: (String(ui: "빈 값"), .empty)
        case .other: (String(ui: "기타"), .secondary)
        }
        var usages = parsed?.usages.map { $0.kind.rawValue } ?? []
        if parsed?.isCharacterSong == true { usages.append("CS") }
        return CommentEvaluation(classification: classification.rawValue, displayName: display.0, tone: display.1,
                                 isMatch: classification == .convention, isEmpty: classification == .empty,
                                 summary: parsed.map(summary) ?? (classification == .empty ? "" : String(ui: "규칙(분류 접두어 + 작품명 + 용도)에 맞지 않습니다")),
                                 prefix: parsed?.prefix.rawValue, usages: usages)
    }

    private func summary(_ c: ConventionComment) -> String {
        var parts = [c.prefix.rawValue, c.workName]
        if let season = c.season { parts.append(String(ui: "\(season)기")) }
        if !c.abbreviations.isEmpty { parts.append(String(ui: "약칭 \(c.abbreviations.joined(separator: ", "))")) }
        parts += c.usages.map { $0.kind.rawValue + ($0.numbers.isEmpty ? "" : " " + $0.numbers.map(String.init).joined(separator: ",")) }
        if c.isCharacterSong { parts.append("CS") }
        if c.isTVSize { parts.append("TVSIZE") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public enum CommentClass: String, Sendable, CaseIterable {
    /// 분류 접두어로 시작하는 사용자 컨벤션.
    case convention
    /// `神様のメモ帳 OP, 하느님의 메모장, 카미메모` 같은 구형 콤마 스타일.
    case legacy
    /// 리핑·업로더·레이블 태그 잔재.
    case residue
    /// `가수 (…): 캐릭터 (…); …` 형태의 크레딧 문자열.
    case credit
    case empty
    case other
}

public enum CommentClassifier {
    public static func classify(_ raw: String) -> CommentClass {
        classify(normalized: CommentText.normalize(raw))
    }

    /// 정규식 없이 분류한다(7천 곡 로딩에서 정규식이 병목이었다).
    public static func classify(normalized text: String) -> CommentClass {
        if text.isEmpty { return .empty }
        if ConventionParser.prefix(of: text) != nil { return .convention }
        if isResidue(text) { return .residue }
        if text.contains(";"), text.contains(":") { return .credit }
        let lower = text.lowercased()
        if ["lyrics", "arranged", "composed"].contains(where: { keywordFollowedByColon(lower, $0) }) { return .credit }
        if text.contains(","), hasLegacyHint(text) { return .legacy }
        return .other
    }

    /// 리핑·업로더·레이블 태그 잔재.
    static func isResidue(_ text: String) -> Bool {
        if ["JASRAC", "ExactAudioCopy", "NIPPONSEI", "SoftWarez"].contains(where: text.contains) { return true }
        let lower = text.lowercased()
        if ["uploaded by", "ripped by", "encoded by", "tagged by", "brought to you", "recorded using",
            "http://", "https://", "www."].contains(where: lower.contains) { return true }
        if words(text).contains("EAC") { return true }
        for tld in [".com", ".net", ".info", ".org"] {
            var search = lower.startIndex..<lower.endIndex
            while let range = lower.range(of: tld, range: search) {
                let next = range.upperBound < lower.endIndex ? lower[range.upperBound] : nil
                if next == nil || !(next!.isLetter || next!.isNumber || next! == "_") { return true }
                search = range.upperBound..<lower.endIndex
            }
        }
        return false
    }

    /// `OP` · `ED 1,` · `IN3` 같은 용도 토큰, `[CS]`, 또는 한글이 있으면 구형 콤마 스타일로 본다.
    static func hasLegacyHint(_ text: String) -> Bool {
        if text.contains("[CS]") { return true }
        if text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) { return true }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        for (i, token) in tokens.enumerated() {
            for kind in ["OP", "ED", "IN"] where token.hasPrefix(kind) {
                var rest = token.dropFirst(kind.count)
                // `OP` 다음 토큰이 숫자인 경우(`OP 3,`)도 OP 자체가 공백 앞이라 이미 성립한다.
                rest = rest.drop(while: { $0.wholeNumberValue != nil })
                if rest.isEmpty || rest.first == "," { return true }
                _ = i
            }
        }
        return false
    }

    private static func keywordFollowedByColon(_ lower: String, _ keyword: String) -> Bool {
        var search = lower.startIndex..<lower.endIndex
        while let range = lower.range(of: keyword, range: search) {
            let after = lower[range.upperBound...].drop(while: \.isWhitespace)
            if after.first == ":" { return true }
            search = range.upperBound..<lower.endIndex
        }
        return false
    }

    /// 영숫자 단어 경계로 나눈 단어들(`\bEAC\b` 대체).
    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
    }
}
