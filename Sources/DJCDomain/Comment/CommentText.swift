import Foundation

public enum CommentText {
    /// P0 전처리: NFC → 제어문자(U+0000–U+001F) 제거 → trim → 연속 공백을 한 칸으로.
    public static func normalize(_ raw: String) -> String {
        let nfc = raw.precomposedStringWithCanonicalMapping
        let scalars = nfc.unicodeScalars.filter { $0.value > 0x1F }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// R11 비교 키: NFKC, 소문자, 공백·기호 제거. (`귀여울 리가` == `귀여울리가`)
    public static func matchKey(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { $0.isLetter || $0.isNumber })
    }
}
