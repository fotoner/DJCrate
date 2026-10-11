import DJCDomain
import Foundation

/// rekordbox `contentCue.Cues` JSON을 rekordbox와 같은 모양으로 읽고 쓴다.
///
/// rekordbox는 큐 하나를 `djmdCue` 행과 같은 칸으로 JSON 객체에 담는다. 칸 순서는 고정이고, 값이 없는(NULL) 칸은
/// 빠진다. 공백 없이 쓰고, 시각은 `2026-09-25T16:39:01.005+00:00` 형식이다. 기존 큐는 순서를 유지하고
/// 새 큐는 끝에 붙인다(rekordbox가 직접 고친 결과를 비교해 확인했다).
public enum CueJSON {
    /// rekordbox가 쓰는 칸 순서
    public static let keyOrder = [
        "ID", "ContentID", "ContentUUID", "InMsec", "InFrame", "InMpegFrame", "InMpegAbs", "InPointSeekInfo",
        "OutMsec", "OutFrame", "OutMpegFrame", "OutMpegAbs", "OutPointSeekInfo", "Kind", "Color", "ColorTableIndex",
        "ActiveLoop", "Comment", "BeatLoopSize", "CueMicrosec", "UUID", "created_at", "updated_at",
    ]
    /// 문자열로 쓰는 칸(나머지는 정수)
    static let stringKeys: Set<String> = ["ID", "ContentID", "ContentUUID", "InPointSeekInfo", "OutPointSeekInfo",
                                          "Comment", "UUID", "created_at", "updated_at"]

    /// 큐 객체 하나. 칸 순서를 읽은 그대로 기억한다(옛 rekordbox가 쓴 JSON은 순서가 다르다).
    public struct Object: Hashable, Sendable {
        public var fields: [(key: String, value: Value)]

        public init(fields: [(key: String, value: Value)]) { self.fields = fields }

        public subscript(key: String) -> Value? {
            get { fields.first { $0.key == key }?.value }
            set {
                if let i = fields.firstIndex(where: { $0.key == key }) {
                    if let newValue { fields[i].value = newValue } else { fields.remove(at: i) }
                } else if let newValue {
                    // 없는 칸은 rekordbox 순서에 맞는 자리에 끼운다.
                    let rank = keyOrder.firstIndex(of: key) ?? keyOrder.count
                    let i = fields.firstIndex { (keyOrder.firstIndex(of: $0.key) ?? keyOrder.count) > rank } ?? fields.count
                    fields.insert((key, newValue), at: i)
                }
            }
        }

        public static func == (a: Object, b: Object) -> Bool {
            a.fields.count == b.fields.count && zip(a.fields, b.fields).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        }

        public func hash(into hasher: inout Hasher) {
            for field in fields { hasher.combine(field.key); hasher.combine(field.value) }
        }
    }

    public enum Value: Hashable, Sendable {
        case string(String)
        case int(Int)
    }

    /// `[{"칸":값,...},...]`를 순서대로 읽는다(값은 문자열 또는 정수, null은 칸째로 없는 것으로 본다).
    public static func parse(_ text: String) throws -> [Object] {
        var p = Parser(Array(text.unicodeScalars))
        return try p.array()
    }

    public static func serialize(_ objects: [Object]) -> String {
        "[" + objects.map(serialize).joined(separator: ",") + "]"
    }

    static func serialize(_ object: Object) -> String {
        "{" + object.fields.map { "\"\($0.key)\":" + value($0.value) }.joined(separator: ",") + "}"
    }

    /// 새 큐 객체(rekordbox 7이 쓰는 칸 순서).
    public static func newObject(_ pairs: [(String, Value?)]) -> Object {
        var object = Object(fields: [])
        for key in keyOrder {
            if let pair = pairs.first(where: { $0.0 == key }), let value = pair.1 { object.fields.append((key, value)) }
        }
        return object
    }

    struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func skip() { while i < s.count, [" ", "\n", "\r", "\t"].contains(s[i]) { i += 1 } }
        mutating func expect(_ c: Unicode.Scalar) throws {
            skip()
            guard i < s.count, s[i] == c else { throw DJCError.invalidCueJSON }
            i += 1
        }
        mutating func peek() -> Unicode.Scalar? { skip(); return i < s.count ? s[i] : nil }

        mutating func array() throws -> [Object] {
            try expect("[")
            var objects: [Object] = []
            if peek() == "]" { i += 1; return objects }
            while true {
                objects.append(try object())
                if peek() == "," { i += 1; continue }
                try expect("]")
                return objects
            }
        }

        mutating func object() throws -> Object {
            try expect("{")
            var fields: [(key: String, value: Value)] = []
            if peek() == "}" { i += 1; return Object(fields: fields) }
            while true {
                let key = try string()
                try expect(":")
                if let value = try value() { fields.append((key, value)) }
                if peek() == "," { i += 1; continue }
                try expect("}")
                return Object(fields: fields)
            }
        }

        mutating func value() throws -> Value? {
            guard let c = peek() else { throw DJCError.invalidCueJSON }
            if c == "\"" { return .string(try string()) }
            if c == "n" {
                guard i + 4 <= s.count, String(String.UnicodeScalarView(s[i..<i + 4])) == "null" else { throw DJCError.invalidCueJSON }
                i += 4
                return nil
            }
            var digits = ""
            while i < s.count, s[i] == "-" || ("0"..."9").contains(s[i]) { digits.unicodeScalars.append(s[i]); i += 1 }
            guard let n = Int(digits) else { throw DJCError.invalidCueJSON }
            return .int(n)
        }

        mutating func string() throws -> String {
            try expect("\"")
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]; i += 1
                if c == "\"" { return String(out) }
                if c == "\\" {
                    guard i < s.count else { break }
                    let e = s[i]; i += 1
                    switch e {
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        guard i + 4 <= s.count, let v = UInt32(String(String.UnicodeScalarView(s[i..<i + 4])), radix: 16),
                              let scalar = Unicode.Scalar(v) else { throw DJCError.invalidCueJSON }
                        out.append(scalar); i += 4
                    default: out.append(e)
                    }
                } else {
                    out.append(c)
                }
            }
            throw DJCError.invalidCueJSON
        }
    }

    static func value(_ value: Value) -> String {
        switch value {
        case let .int(n): return String(n)
        case let .string(s): return quote(s)
        }
    }

    /// JSON 문자열(비ASCII는 그대로 UTF-8, 제어 문자·따옴표·역슬래시만 이스케이프).
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// DB 칸 시각(`2026-09-25 16:39:01.005 +00:00`)과 JSON 시각(`2026-09-25T16:39:01.005+00:00`).
    public static func timestamps(_ date: Date) -> (db: String, json: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        let time = String(format: "%02d:%02d:%02d.%03d", c.hour!, c.minute!, c.second!, ms)
        return ("\(day) \(time) +00:00", "\(day)T\(time)+00:00")
    }
}
