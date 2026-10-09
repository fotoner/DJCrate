import DJCDomain
import Foundation

/// rekordbox 시간축의 상세 파형. 1초 = 150칸, PWV3는 높이·흰 정도, PWV5는 RGB·높이.
public struct AnlzColorWaveform: Sendable {
    public let columns: [WaveformColumn]
    public let rate = 150.0

    public init?(file: AnlzFile, mode: WaveformColorMode) throws {
        guard mode != .threeBand else { return nil }
        let name = mode == .blue ? "PWV3" : "PWV5", size = mode == .blue ? 1 : 2
        guard let bytes = try Self.entries(file: file, tag: name, size: size), !bytes.isEmpty else { return nil }
        columns = stride(from: 0, to: bytes.count, by: size).map { index in
            if mode == .blue { return Self.blue(bytes[index]) }
            let value = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            var column = WaveformColumn(low: Double((value >> 13) & 7) / 7,
                                        mid: Double((value >> 10) & 7) / 7,
                                        high: Double((value >> 7) & 7) / 7)
            // 저장된 채널은 이미 색이므로 한 번 더 정규화하지 않는다.
            column.rgb = WaveformRGB(red: column.low, green: column.mid, blue: column.high)
            column.height = Double((value >> 2) & 31) / 31
            return column
        }
    }

    static func blue(_ byte: UInt8) -> WaveformColumn {
        var column = WaveformColumn(low: Double(byte & 31) / 31, mid: 0, high: 0)
        column.whiteness = Double(byte >> 5) / 7
        return column
    }

    static func entries(file: AnlzFile, tag name: String, size: Int) throws -> [UInt8]? {
        guard let tag = file.tag(name) else { return nil }
        let bytes = [UInt8](tag.bytes)
        guard bytes.count >= 24 else { throw DJCError.invalidAnalysisFile(String(ui: "\(name) 머리가 짧음")) }
        let header = Int(AnlzFile.u32(bytes, 4)), stride = Int(AnlzFile.u32(bytes, 12))
        let count = Int(AnlzFile.u32(bytes, 16))
        guard header >= 24, header <= bytes.count, stride == size, count <= (bytes.count - header) / size else {
            throw DJCError.invalidAnalysisFile(String(ui: "\(name) 칸 크기나 길이가 맞지 않음"))
        }
        return Array(bytes[header..<header + count * size])
    }
}
