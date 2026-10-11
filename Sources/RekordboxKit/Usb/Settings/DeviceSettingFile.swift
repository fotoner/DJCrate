import Foundation

/// USB `PIONEER/`의 기기 설정 파일(MYSETTING.DAT 등)을 칸 단위로 읽고 검증한다.
/// 모양(모두 리틀엔디언): 문자열 길이 u32 · 문자열 32바이트 셋(제조사·소프트웨어·버전) · 본문 길이 u32 · 본문 · CRC u16 · 0 u16.
/// 모르는 칸이 많아 구조체로 다시 만들지 않는다. 읽은 바이트를 그대로 들고, 고칠 때는 아는 칸만 바꾼다(`DeviceSettingPatch`).
public struct DeviceSettingFile: Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable {
        case mySetting = "MYSETTING.DAT"
        case mySetting2 = "MYSETTING2.DAT"
        case djmMySetting = "DJMMYSETTING.DAT"
        /// 읽기·검증만 한다. rekordbox 내보내기도 만들지 않아 내보내기로 옮기지 않는다
        case devSetting = "DEVSETTING.DAT"

        public var fileName: String { rawValue }

        /// 이름이 정확히 같을 때만(대소문자 그대로)
        public init?(fileName: String) { self.init(rawValue: fileName) }

        /// 내보내기로 옮기는 파일
        public static let exported: [Kind] = [.mySetting, .mySetting2, .djmMySetting]

        // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
        public var size: Int {
            switch self {
            case .mySetting, .mySetting2: 148
            case .djmMySetting: 160
            case .devSetting: 140
            }
        }

        /// CRC가 파일 처음부터인지(아니면 본문만)
        // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
        public var crcIncludesHeader: Bool { self == .djmMySetting }
    }

    /// 첫 u32 칸 값: 문자열 셋의 길이
    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    public static let stringsLength = 0x60
    /// 본문이 시작하는 위치(본문 길이 u32 칸 바로 뒤)
    public static let bodyOffset = 0x68
    static let dataLengthOffset = 0x64
    static let stringOffsets = (brand: 0x04, software: 0x24, version: 0x44)
    static let stringFieldLength = 32
    /// 끝의 CRC u16 + 0 u16
    static let trailerLength = 4

    public let kind: Kind
    /// 검증을 통과한 파일 전체(시작 위치 0)
    public let bytes: Data

    /// 하나라도 어긋나면 던진다: 크기, 문자열 길이 칸, 본문 길이 칸, 종류별 범위 CRC, 끝 2바이트 0
    public init(kind: Kind, bytes input: Data) throws {
        let data = Data(input)
        guard data.count == kind.size else { throw DeviceSettingError.wrongSize(expected: kind.size, actual: data.count) }
        let strings = Int(Self.u32(data, at: 0))
        guard strings == Self.stringsLength else { throw DeviceSettingError.wrongStringsLength(strings) }
        let expectedData = data.count - Self.bodyOffset - Self.trailerLength
        let dataLength = Int(Self.u32(data, at: Self.dataLengthOffset))
        guard dataLength == expectedData else { throw DeviceSettingError.wrongDataLength(expected: expectedData, actual: dataLength) }
        if let pair = Self.crcPair(kind: kind, bytes: data), pair.stored != pair.computed {
            throw DeviceSettingError.crcMismatch(stored: pair.stored, computed: pair.computed)
        }
        let trailer = Self.u16(data, at: data.count - 2)
        guard trailer == 0 else { throw DeviceSettingError.trailerNotZero(trailer) }
        self.kind = kind
        bytes = data
    }

    public var brand: String { Self.string(bytes, at: Self.stringOffsets.brand) }
    public var software: String { Self.string(bytes, at: Self.stringOffsets.software) }
    public var version: String { Self.string(bytes, at: Self.stringOffsets.version) }
    public var body: Data { Data(bytes[Self.bodyOffset..<(bytes.count - Self.trailerLength)]) }
    public var storedCRC: UInt16 { Self.u16(bytes, at: bytes.count - Self.trailerLength) }

    /// 아는 칸 값. 다른 종류의 칸이면 nil
    public func value(_ field: DeviceSettingField) -> UInt8? {
        field.kind == kind ? bytes[field.offset] : nil
    }

    /// CRC를 계산하는 범위: DJMMYSETTING은 파일 처음부터, 나머지는 본문만. 둘 다 끝의 4바이트 앞까지
    static func crcRange(kind: Kind, count: Int) -> Range<Int> {
        (kind.crcIncludesHeader ? 0 : bodyOffset)..<(count - trailerLength)
    }

    /// 끝에 적힌 CRC와 종류별 범위로 계산한 CRC. 본문 자리보다 짧으면 nil(크기가 틀린 파일을 보고할 때 쓴다)
    public static func crcPair(kind: Kind, bytes input: Data) -> (stored: UInt16, computed: UInt16)? {
        let data = Data(input)
        guard data.count >= bodyOffset + trailerLength else { return nil }
        return (u16(data, at: data.count - trailerLength), CRC16XModem.checksum(data[crcRange(kind: kind, count: data.count)]))
    }

    static func u32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }

    static func u16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    /// 32바이트 칸에서 첫 0 앞까지. 0 뒤의 바이트는 보존만 하고 읽지 않는다
    static func string(_ data: Data, at offset: Int) -> String {
        String(decoding: data[offset..<(offset + stringFieldLength)].prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// 뜻을 아는 설정 칸(1바이트, 이슈 #45)
public struct DeviceSettingField: Sendable, Hashable {
    public let kind: DeviceSettingFile.Kind
    public let offset: Int
    public let name: String

    public static let quantize = Self(kind: .mySetting, offset: 0x72, name: "quantize")
    public static let quantizeBeatValue = Self(kind: .mySetting, offset: 0x80, name: "quantizeBeatValue")
    public static let hotcueAutoload = Self(kind: .mySetting, offset: 0x81, name: "hotcueAutoload")
    public static let beatJumpBeatValue = Self(kind: .mySetting2, offset: 0x74, name: "beatJumpBeatValue")
    public static let beatFxQuantize = Self(kind: .djmMySetting, offset: 0x78, name: "beatFxQuantize")

    public static let all: [DeviceSettingField] = [.quantize, .quantizeBeatValue, .hotcueAutoload, .beatJumpBeatValue, .beatFxQuantize]
}

/// 설정 파일을 읽지 않거나 만들지 않은 이유. 설명은 번역하지 않는 기술 정보다
public enum DeviceSettingError: Error, Equatable, Sendable, CustomStringConvertible {
    case wrongSize(expected: Int, actual: Int)
    case wrongStringsLength(Int)
    case wrongDataLength(expected: Int, actual: Int)
    case crcMismatch(stored: UInt16, computed: UInt16)
    case trailerNotZero(UInt16)
    /// 내보내기로 옮기지 않는 파일 이름(세 파일 밖)
    case notExported(fileName: String)
    /// MYSETTING2 새 칸 두 바이트가 둘 다 0도, 둘 다 채운 값도 아니다(확인하지 않은 모양)
    case unconfirmedNewField(UInt8, UInt8)

    public var description: String {
        switch self {
        case let .wrongSize(expected, actual): "크기 \(actual)바이트(\(expected)바이트여야 함)"
        case let .wrongStringsLength(value):
            "문자열 길이 칸 \(Self.hex(value))(\(Self.hex(DeviceSettingFile.stringsLength))이어야 함)"
        case let .wrongDataLength(expected, actual): "본문 길이 칸 \(actual)(\(expected)이어야 함)"
        case let .crcMismatch(stored, computed): "CRC 어긋남: 적힌 값 \(Self.hex(stored, digits: 4)), 계산한 값 \(Self.hex(computed, digits: 4))"
        case let .trailerNotZero(value): "끝 2바이트가 0이 아님(\(Self.hex(value, digits: 4)))"
        case let .notExported(fileName): "\(fileName)은 내보내기로 옮기지 않는 파일"
        case let .unconfirmedNewField(first, second):
            "새 칸 값 \(Self.hex(first)) \(Self.hex(second))은 확인하지 않은 모양(둘 다 0이나 둘 다 "
                + "\(Self.hex(DeviceSettingPatch.mySetting2NewFieldValue))일 때만 옮김)"
        }
    }

    static func hex(_ value: some BinaryInteger, digits: Int = 2) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
