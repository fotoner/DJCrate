import DJCDomain
import Foundation

public enum PdbStringDecoder {
    /// 행 시작 기준 offset에서 DeviceSQL 문자열 하나를 읽는다. `isrcAllowed`는 트랙 문자열 0(ISRC)에서만 참으로 준다
    /// (그 밖의 칸에서 `90 … 00 03`은 첫 글자 아래 바이트가 3인 UTF-16이다. 그래서 기본은 거짓).
    /// 모르는 첫 바이트·행 밖으로 나가는 길이·잘못된 글자는 `UsbError.readFailed`.
    public static func decode(_ row: Data, at offset: Int, isrcAllowed: Bool = false) throws -> (value: String, kind: PdbStringKind, byteLength: Int) {
        let bytes = [UInt8](row)
        guard offset >= 0, offset < bytes.count else { throw failure("offset \(offset) outside row \(bytes.count)") }
        let first = bytes[offset]
        if first & 1 == 1 {
            let length = Int(first >> 1) - 1
            guard length >= 0 else { throw failure("short ASCII header 0x01") }
            guard offset + 1 + length <= bytes.count else { throw failure("short ASCII past row end") }
            let body = bytes[(offset + 1)..<(offset + 1 + length)]
            guard body.allSatisfy({ $0 < 0x80 }) else { throw failure("short ASCII has non-ASCII byte") }
            return (String(decoding: body, as: UTF8.self), .shortASCII, 1 + length)
        }
        guard first == 0x40 || first == 0x90 else { throw failure(String(format: "unknown string byte 0x%02X", first)) }
        guard offset + 4 <= bytes.count else { throw failure("long string header past row end") }
        let length = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8
        guard length >= 4, offset + length <= bytes.count else { throw failure("long string length \(length) past row end") }
        let body = Array(bytes[(offset + 4)..<(offset + length)])
        if first == 0x40 {
            guard body.allSatisfy({ $0 < 0x80 }) else { throw failure("long ASCII has non-ASCII byte") }
            return (String(decoding: body, as: UTF8.self), .longASCII, length)
        }
        if isrcAllowed, body.first == 0x03 {
            guard body.count >= 2, body.last == 0x00 else { throw failure("ISRC string without terminator") }
            let text = body[1..<(body.count - 1)]
            guard text.allSatisfy({ $0 < 0x80 }) else { throw failure("ISRC has non-ASCII byte") }
            return (String(decoding: text, as: UTF8.self), .isrc, length)
        }
        guard body.count % 2 == 0 else { throw failure("UTF-16 string has odd length") }
        let units = stride(from: 0, to: body.count, by: 2).map { UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8 }
        guard let value = String(validating: units, as: UTF16.self) else { throw failure("invalid UTF-16") }
        return (value, .utf16LE, length)
    }

    static func failure(_ detail: String) -> UsbError {
        .readFailed(detail: "pdb string: \(detail)")
    }
}

/// DeviceSQL 문자열 만들기. UTF-16·긴 ASCII 문자열을 행 안 4바이트 경계에 두는 것은 행을 만드는 쪽 몫이다.
public enum PdbStringEncoder {
    /// 짧은 ASCII 최대 글자 수
    public static let shortASCIIMaxLength = 126

    /// 짧은 ASCII 첫 바이트 `((n+1)<<1)+1`
    public static func shortASCIIHeader(length: Int) -> UInt8 {
        precondition((0...shortASCIIMaxLength).contains(length), "짧은 ASCII는 126자까지")
        return UInt8(((length + 1) << 1) + 1)
    }

    /// 값에 맞는 모양으로 만든다. 126자까지의 순수 ASCII는 짧은 ASCII, 127자 이상 순수 ASCII는 긴 ASCII(0x40),
    /// ASCII가 아닌 글자가 있으면 UTF-16LE.
    /// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기): 짧은 ASCII·UTF-16LE.
    /// rekordbox 7.2.x 경계 실험(2026-10-08, 한 곡의 아티스트·앨범을 'A' × 126·127·236·244·250으로 바꿔 USB 동기화): 126자는 짧은 ASCII,
    /// 127자부터 긴 ASCII. 트랙 행 경로(문자열 20)의 127자 이상 ASCII도 같은 모양이었다.
    public static func encode(_ value: String) -> Data {
        let ascii = Array(value.utf8)
        guard ascii.allSatisfy({ $0 < 0x80 }) else { return encodeUTF16(value) }
        guard ascii.count <= shortASCIIMaxLength else { return encodeLongASCII(ascii) }
        return Data([shortASCIIHeader(length: ascii.count)] + ascii)
    }

    /// 긴 ASCII: `40`, u16 길이 = 4 + n(머리 포함), `00`, ASCII n바이트(끝 표시 없음).
    /// rekordbox 7.2.x 경계 실험(2026-10-08) 관찰. 행 안 4바이트 경계에 두는 것은 행을 만드는 쪽 몫이다
    static func encodeLongASCII(_ ascii: [UInt8]) -> Data {
        let length = 4 + ascii.count
        return Data([0x40, UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8), 0x00] + ascii)
    }

    /// 늘 UTF-16LE(메뉴 이름처럼 ASCII여도 UTF-16인 칸)
    public static func encodeUTF16(_ value: String) -> Data {
        var data = Data([0x90])
        let length = 4 + value.utf16.count * 2
        data.append(contentsOf: [UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8), 0])
        for unit in value.utf16 { data.append(contentsOf: [UInt8(truncatingIfNeeded: unit), UInt8(truncatingIfNeeded: unit >> 8)]) }
        return data
    }

    /// 트랙 ISRC 특수형: `90`, u16 길이 = 4 + 1 + k + 1, `00`, `03`, ASCII k, `00`
    public static func encodeISRC(_ value: String) -> Data {
        let ascii = Array(value.utf8)
        let length = 4 + 1 + ascii.count + 1
        return Data([0x90, UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8), 0x00, 0x03] + ascii + [0x00])
    }
}

// MARK: - 쓰기용 모양 고르기

extension PdbStringEncoder {
    /// 쓸 바이트, 고른 모양, 그 모양이 필요로 하는 확인 안 된 규칙
    public struct Encoded: Sendable, Hashable {
        public var bytes: Data
        public var kind: PdbStringKind
        public var rules: Set<UsbProvisionalRule>

        public init(bytes: Data, kind: PdbStringKind, rules: Set<UsbProvisionalRule> = []) {
            self.bytes = bytes
            self.kind = kind
            self.rules = rules
        }

        /// UTF-16(ISRC 특수형 포함)과 긴 ASCII는 행 안 4바이트 경계에 둔다.
        /// 긴 ASCII: rekordbox 7.2.x 경계 실험(2026-10-08)의 아티스트·앨범 행과 트랙 행 경로에서 앞을 0으로 채워 4바이트 경계에 있었다
        var needsAlignment: Bool { bytes.first == 0x90 || bytes.first == 0x40 }
    }

    /// 작성기가 쓰는 모양(`encode`와 같다). 판정 기준은 `UsbTrackRules.pdbStringRules`와 같다.
    /// 긴 ASCII는 rekordbox에서 본 칸(트랙 행 문자열·아티스트·앨범 이름)에서만 확인한 모양이라, 그 밖의 칸(장르·레이블·키·재생 목록·
    /// 아트워크·My Tag 등)에 쓸 때는 `pdbLongAscii`를 붙인다. `longASCIIObserved`는 본 칸을 만드는 쪽만 참으로 준다.
    public static func encoded(_ value: String, longASCIIObserved: Bool = false) -> Encoded {
        let data = encode(value)
        switch data.first {
        case 0x90: return Encoded(bytes: data, kind: .utf16LE)
        case 0x40: return Encoded(bytes: data, kind: .longASCII, rules: longASCIIObserved ? [] : [.pdbLongAscii])
        default: return Encoded(bytes: data, kind: .shortASCII)
        }
    }

    /// 사람이 읽는 문자열 칸(이름·제목 등, `PdbRowEncoder` 칸 표 참고). NFC로 바꿔 `encoded`로 만들고,
    /// 철자가 바뀌었으면 `pdbStringNFC`를 붙인다(`UsbNameSpelling.deviceLibraryText`, #233). 파일 경로 칸에는 쓰지 않는다
    public static func encodedText(_ value: String, longASCIIObserved: Bool = false) -> Encoded {
        let text = UsbNameSpelling.deviceLibraryText(value)
        var result = encoded(text, longASCIIObserved: longASCIIObserved)
        if !UsbNameSpelling.sameScalars(text, value) { result.rules.insert(.pdbStringNFC) }
        return result
    }

    /// 트랙 문자열 0(ISRC). 값이 있으면 특수형, 없으면 짧은 ASCII `03`.
    /// ASCII가 아닌 ISRC는 특수형에 담을 수 없어 UTF-16LE로 돌려준다(작성기가 그 곡을 막는다).
    public static func encodedISRC(_ value: String) -> Encoded {
        if value.isEmpty { return Encoded(bytes: Data([shortASCIIHeader(length: 0)]), kind: .shortASCII) }
        guard value.utf8.allSatisfy({ $0 < 0x80 }) else { return Encoded(bytes: encodeUTF16(value), kind: .utf16LE) }
        return Encoded(bytes: encodeISRC(value), kind: .isrc)
    }

    /// columns 이름: U+FFFA + 이름 + U+FFFB를 늘 UTF-16LE로. 이름은 다른 사람이 읽는 문자열처럼 NFC로 쓴다
    public static func encodedMenuName(_ name: String) -> Encoded {
        let text = UsbNameSpelling.deviceLibraryText(name)
        return Encoded(bytes: encodeUTF16("\u{FFFA}\(text)\u{FFFB}"), kind: .utf16LE,
                       rules: UsbNameSpelling.sameScalars(text, name) ? [] : [.pdbStringNFC])
    }
}
