import Foundation

/// 조성 글자를 목록 표기(Camelot, "8A")로 맞춘다. 목록의 키 칸은 rekordbox 키를 Camelot으로 보여 준다.
public enum KeyNotation {
    /// rekordbox에 쓸 수 있는 키 이름: Camelot 스물네 개(1A, 1B, 2A … 12B). 이 라이브러리의 `djmdKey`에 살아 있는 줄로 있는 이름이다(#5).
    public static let camelotNames: [String] = (1...12).flatMap { ["\($0)A", "\($0)B"] }

    /// 입력("8a"·" 08B ")을 정확한 Camelot 이름으로 다듬는다. 다른 표기("Am"·Open Key)는 바꾸지 않고 nil이다:
    /// 어느 줄에 이을지 짐작하지 않는다.
    public static func normalizedCamelotName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = trimmed.last, letter == "A" || letter == "B", let number = Int(trimmed.dropLast()),
              (1...12).contains(number), trimmed.dropLast().allSatisfy(\.isASCII), !trimmed.dropLast().hasPrefix("+") else { return nil }
        return "\(number)\(letter)"
    }

    /// 키 고르기에 보일 이름. 현재 값이 Camelot이 아니면(옛 표기 줄·삭제 표시 줄의 이름) 맨 앞에 그대로 보여 주되 쓰는 값은 아니다.
    public static func pickerChoices(current: String) -> [String] {
        current.isEmpty || camelotNames.contains(current) ? camelotNames : [current] + camelotNames
    }

    /// 조표(장조 으뜸음 음이름, 0 = C … 11 = B)와 장·단 → Camelot. C장조·A단조 = 8.
    public static func camelot(signature: Int, minor: Bool) -> String {
        let tonic = (signature % 12 + 12) % 12
        let number = (tonic * 7 % 12 + 7) % 12 + 1
        return "\(number)\(minor ? "A" : "B")"
    }

    /// Camelot("10B" 등) → (조표, 단조인가). `camelot(signature:minor:)`의 반대
    public static func signature(camelot: String) -> (signature: Int, minor: Bool)? {
        let text = camelot.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = text.last, letter == "A" || letter == "B", let number = Int(text.dropLast()), (1...12).contains(number) else { return nil }
        guard let signature = (0..<12).first(where: { self.camelot(signature: $0, minor: false) == "\(number)B" }) else { return nil }
        return (signature, letter == "A")
    }

    /// 음원 태그의 키(ID3 TKEY 등) → Camelot. 음이름("Am"·"F# major"·"B♭")·Camelot("8A")·Open Key("1m")를 읽는다.
    /// "8A - Am"처럼 두 표기를 함께 적었으면 앞쪽 조각부터 본다. 읽지 못하면 nil.
    public static func camelot(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let whole = parse(trimmed) { return whole }
        let pieces = trimmed.split { $0.isWhitespace || "/,;|()[]-".contains($0) }
        guard pieces.count > 1 else { return nil }
        return pieces.lazy.compactMap { parse(String($0)) }.first
    }

    private static func parse(_ text: String) -> String? {
        guard let first = text.first else { return nil }
        if first.isNumber { return numbered(text) }
        // 음이름: 으뜸음 글자 + 올림·내림 + 장·단
        let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let natural = letters[Character(first.uppercased())] else { return nil }
        var rest = text.dropFirst()
        var tonic = natural
        if let accidental = rest.first {
            if accidental == "#" || accidental == "♯" { tonic += 1; rest = rest.dropFirst() }
            else if accidental == "b" || accidental == "♭" { tonic -= 1; rest = rest.dropFirst() }
        }
        let mode = rest.trimmingCharacters(in: .whitespaces)
        let minor: Bool
        switch mode.lowercased() {
        case "": minor = false
        // "M" 하나는 장조로 쓰는 표기가 있다(소문자 m은 단조).
        case "m" where mode == "M": minor = false
        case "m", "min", "minor", "moll": minor = true
        case "maj", "major", "dur": minor = false
        default: return nil
        }
        let signature = minor ? tonic + 3 : tonic
        return camelot(signature: (signature % 12 + 12) % 12, minor: minor)
    }

    /// "8A"·"08B"(Camelot) 또는 "1m"·"1d"(Open Key)
    private static func numbered(_ text: String) -> String? {
        guard let letter = text.last?.uppercased(), let number = Int(text.dropLast()), (1...12).contains(number) else { return nil }
        switch letter {
        case "A", "B": return "\(number)\(letter)"
        // Open Key 1 = C장조·A단조(Camelot 8)
        case "M": return "\((number + 6) % 12 + 1)A"
        case "D": return "\((number + 6) % 12 + 1)B"
        default: return nil
        }
    }
}
