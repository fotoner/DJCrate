import Foundation

/// 기기 설정 파일의 아는 칸만 바꾸고 CRC를 다시 계산한다.
/// 구조체로 다시 쓰면 모르는 칸이 0으로 지워지므로, 읽은 바이트를 그대로 옮기고 바꾼 칸과 CRC만 덮는다.
public enum DeviceSettingPatch {
    /// MYSETTING2의 새 칸 두 바이트. 옛 rekordbox가 쓴 로컬 파일은 0이고, rekordbox 7 내보내기는 채워 쓴다
    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    public static let mySetting2NewFieldOffsets = [0x6D, 0x6E]
    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    public static let mySetting2NewFieldValue: UInt8 = 0x80

    /// 아는 칸 한 바이트를 `value`로 바꾼다. 다른 종류의 칸이면 nil
    public static func setting(_ field: DeviceSettingField, to value: UInt8, in file: DeviceSettingFile) -> DeviceSettingFile? {
        guard field.kind == file.kind else { return nil }
        return try? patched(file, [field.offset: value])
    }

    /// 내보내기용으로 고친 파일. 만들지 못하면 nil(이유는 `exportedFile(from:)`이 던진다)
    public static func forExport(_ file: DeviceSettingFile) -> DeviceSettingFile? {
        try? exportedFile(from: file)
    }

    /// 내보내기용으로 고친 파일. MYSETTING2의 새 칸이 둘 다 0이면 둘 다 채우고, 둘 다 채운 값이면 그대로 둔다(CRC만 다시).
    /// 새 칸이 그 밖의 모양이면 rekordbox가 쓴 적을 보지 못한 모양이라 만들지 않는다.
    /// 내보내기로 옮기지 않는 종류(DEVSETTING)도 만들지 않는다
    public static func exportedFile(from file: DeviceSettingFile) throws -> DeviceSettingFile {
        guard DeviceSettingFile.Kind.exported.contains(file.kind) else { throw DeviceSettingError.notExported(fileName: file.kind.fileName) }
        var changes: [Int: UInt8] = [:]
        if file.kind == .mySetting2 {
            let current = mySetting2NewFieldOffsets.map { file.bytes[$0] }
            if current.allSatisfy({ $0 == 0 }) {
                for offset in mySetting2NewFieldOffsets { changes[offset] = mySetting2NewFieldValue }
            } else if !current.allSatisfy({ $0 == mySetting2NewFieldValue }) {
                throw DeviceSettingError.unconfirmedNewField(current[0], current[1])
            }
        }
        return try patched(file, changes)
    }

    /// 로컬 rekordbox 설정 파일 하나를 읽어(읽기만) 내보내기용 바이트를 만든다.
    /// 세 이름(MYSETTING·MYSETTING2·DJMMYSETTING) 밖이거나, 읽지 못하거나, 검증에 실패하면 nil — 그 파일은 만들지 않는다
    public static func forExport(localFile: URL) -> Data? {
        try? readForExport(localFile: localFile).output.bytes
    }

    /// `forExport(localFile:)`와 같되 만들지 못한 이유를 던진다(보고용). 이름을 먼저 보고, 세 이름일 때만 파일을 연다
    public static func readForExport(localFile: URL) throws -> (source: DeviceSettingFile, output: DeviceSettingFile) {
        let name = localFile.lastPathComponent
        guard let kind = DeviceSettingFile.Kind(fileName: name), DeviceSettingFile.Kind.exported.contains(kind) else {
            throw DeviceSettingError.notExported(fileName: name)
        }
        let source = try DeviceSettingFile(kind: kind, bytes: Data(contentsOf: localFile))
        return (source, try exportedFile(from: source))
    }

    /// 바이트를 바꾸고 종류별 범위로 CRC를 다시 넣은 뒤, 다시 읽어 검증을 통과할 때만 돌려준다
    static func patched(_ file: DeviceSettingFile, _ changes: [Int: UInt8]) throws -> DeviceSettingFile {
        var bytes = file.bytes
        for (offset, value) in changes { bytes[offset] = value }
        let crcOffset = bytes.count - DeviceSettingFile.trailerLength
        let crc = CRC16XModem.checksum(bytes[DeviceSettingFile.crcRange(kind: file.kind, count: bytes.count)])
        bytes[crcOffset] = UInt8(crc & 0xFF)
        bytes[crcOffset + 1] = UInt8(crc >> 8)
        return try DeviceSettingFile(kind: file.kind, bytes: bytes)
    }
}
