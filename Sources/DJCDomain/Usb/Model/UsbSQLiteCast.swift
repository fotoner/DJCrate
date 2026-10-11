import Foundation

/// 로컬 rekordbox DB의 글자 칸을 SQLite처럼 정수로 읽는다(USB 곡 대응·내보내기 빌더가 함께 쓴다)
public enum UsbSQLiteCast {
    /// SQLite `CAST(x AS INTEGER)`처럼 앞 공백 뒤의 부호·숫자만 읽는다(숫자가 없으면 0, NULL이면 nil)
    public static func integer(_ text: String?) -> Int64? {
        guard let text else { return nil }
        var scalars = Substring(text).drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        var negative = false
        if let sign = scalars.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            scalars = scalars.dropFirst()
        }
        let digits = scalars.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return 0 }
        guard let value = Int64(digits) else { return negative ? Int64.min : Int64.max }
        return negative ? -value : value
    }
}
