import DJCDomain
import Foundation

/// 분석 파일 경로 태그(PPTH): `PPTH` · len_header 0x10 · len_tag · 경로 바이트 수 · UTF-16BE 경로 + 끝 NUL 2바이트.
/// 로컬은 `?/파일 이름`, USB는 `/Contents/…`(세 파일 같은 경로). rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기).
public enum AnlzPathTag {
    public static func encode(_ path: String) -> Data {
        var text = [UInt8]()
        for unit in path.utf16 { text += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        text += [0, 0]
        return RekordboxWaveforms.section("PPTH", headerLength: 0x10, RekordboxWaveforms.be32(UInt32(text.count)) + text)
    }

    public static func decode(_ tag: Data) throws -> String {
        let b = [UInt8](tag)
        guard b.count >= 18, b[0..<4].elementsEqual("PPTH".utf8), AnlzFile.u32(b, 4) == 0x10, Int(AnlzFile.u32(b, 8)) == b.count
        else { throw UsbError.readFailed(detail: "PPTH: bad header") }
        let length = Int(AnlzFile.u32(b, 12))
        guard length + 16 == b.count, length % 2 == 0, b[b.count - 2] == 0, b[b.count - 1] == 0
        else { throw UsbError.readFailed(detail: "PPTH: bad path length") }
        let units = stride(from: 16, to: b.count - 2, by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }
        return String(decoding: units, as: UTF16.self)
    }
}
