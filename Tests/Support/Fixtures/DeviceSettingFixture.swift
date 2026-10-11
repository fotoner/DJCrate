import Foundation
import RekordboxKit

/// 기기 설정 파일(MYSETTING 등)을 지어낸 본문으로 만드는 시험 도우미.
/// 크기·CRC 범위는 제품 코드의 상수를 쓰지 않고 여기서 따로 적어 시험이 제 답을 베끼지 않게 한다.
public enum DeviceSettingFixture {
    /// 종류별 파일 크기와 CRC가 파일 처음부터인지
    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    public static func layout(_ kind: DeviceSettingFile.Kind) -> (size: Int, crcFromStart: Bool) {
        switch kind {
        case .mySetting, .mySetting2: (148, false)
        case .djmMySetting: (160, true)
        case .devSetting: (140, false)
        }
    }

    /// 지어낸 본문 바이트(0이 아닌 값이 섞이게)
    public static func syntheticBody(count: Int, seed: UInt8 = 7) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ Int(seed)) | 0x01 }
    }

    /// 머리(문자열 길이 u32 · 문자열 32바이트 셋 · 본문 길이 u32) + 본문 + CRC u16 + 0 u16.
    /// 기본값은 올바른 파일이다. 고장 난 파일은 인자로 칸 하나씩 틀리게 만든다.
    public static func make(
        _ kind: DeviceSettingFile.Kind,
        body: [UInt8]? = nil,
        brand: String = "SYNTHBRAND",
        software: String = "synthsoft",
        version: String = "9.876",
        stringsLength: UInt32 = 0x60,
        dataLength: UInt32? = nil,
        size: Int? = nil,
        crc: UInt16? = nil,
        trailer: UInt16 = 0
    ) -> Data {
        let (kindSize, crcFromStart) = layout(kind)
        let total = size ?? kindSize
        let bodyCount = max(0, total - 0x68 - 4)
        var bytes = [UInt8]()
        bytes += le32(stringsLength)
        bytes += field(brand) + field(software) + field(version)
        bytes += le32(dataLength ?? UInt32(bodyCount))
        var content = body ?? syntheticBody(count: bodyCount)
        content = Array(content.prefix(bodyCount)) + [UInt8](repeating: 0, count: max(0, bodyCount - content.count))
        bytes += content
        let covered = crcFromStart ? bytes : Array(bytes[0x68...])
        bytes += le16(crc ?? CRC16XModem.checksum(covered))
        bytes += le16(trailer)
        return Data(bytes)
    }

    /// 32바이트 문자열 칸(뒤는 0)
    public static func field(_ text: String) -> [UInt8] {
        let raw = Array(text.utf8.prefix(31))
        return raw + [UInt8](repeating: 0, count: 32 - raw.count)
    }

    /// 종류별 범위로 CRC를 다시 계산해 끝에 넣는다(시험에서 칸을 고친 뒤 올바른 파일로 되돌릴 때)
    public static func resealed(_ data: Data, as kind: DeviceSettingFile.Kind) -> Data {
        var bytes = [UInt8](data)
        let end = bytes.count - 4
        let covered = layout(kind).crcFromStart ? Array(bytes[0..<end]) : Array(bytes[0x68..<end])
        let crc = CRC16XModem.checksum(covered)
        bytes[end] = UInt8(crc & 0xFF)
        bytes[end + 1] = UInt8(crc >> 8)
        return Data(bytes)
    }

    /// `folder`에 종류별 파일 이름으로 쓴다.
    public static func write(_ data: Data, as kind: DeviceSettingFile.Kind, in folder: URL) throws {
        try data.write(to: folder.appending(path: kind.fileName))
    }

    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
}
