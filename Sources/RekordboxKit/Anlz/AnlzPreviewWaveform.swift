import DJCDomain
import Foundation

/// 목록용 미리 보기(값은 DJCDomain `AnlzPreviewWaveform`)를 분석 파일의 PWAV·PWV4에서 읽는다.
extension AnlzPreviewWaveform {
    public init?(file: AnlzFile) throws {
        let colors = try AnlzColorWaveform.entries(file: file, tag: "PWV4", size: 6)
        let colorColumns: [WaveformColumn]? = colors.flatMap { bytes in
            guard !bytes.isEmpty else { return nil }
            // PWV4: 채널 하위 7비트, 두 번째 바이트는 밝기 배율(pyrekordbox, MIT).
            return stride(from: 0, to: bytes.count, by: 6).map { index in
                let low = Double(bytes[index + 3] & 127), mid = Double(bytes[index + 4] & 127)
                let high = Double(bytes[index + 5] & 127), intensity = Double(bytes[index + 2] & 127)
                let gain = Double(bytes[index + 1]) / 127 / 255
                var column = WaveformColumn(low: low / 127, mid: mid / 127, high: high / 127)
                column.height = max(intensity, low, mid, high) / 127
                column.rgb = WaveformRGB(red: min(1, low * gain), green: min(1, mid * gain), blue: min(1, high * gain))
                return column
            }
        }
        guard let tag = file.tag("PWAV") else {
            guard let colorColumns else { return nil }
            self.init(blue: colorColumns, color: colorColumns)
            return
        }
        let bytes = [UInt8](tag.bytes)
        guard bytes.count >= 20 else { throw DJCError.invalidAnalysisFile(String(ui: "PWAV 머리가 짧음")) }
        let header = Int(AnlzFile.u32(bytes, 4)), count = Int(AnlzFile.u32(bytes, 12))
        guard header >= 20, header <= bytes.count, count <= bytes.count - header else {
            throw DJCError.invalidAnalysisFile(String(ui: "PWAV 길이가 맞지 않음"))
        }
        guard count > 0 || colorColumns != nil else { return nil }
        self.init(heights: bytes[header..<header + count].map { $0 & 0x1F },
                  blue: bytes[header..<header + count].map(AnlzColorWaveform.blue), color: colorColumns)
    }

    /// DAT·EXT 중 한쪽이 없거나 손상돼도 다른 쪽의 사용 가능한 자료는 남긴다.
    public static func readAnalysis(at url: URL?) -> Self? {
        let dat = url.flatMap { try? AnlzFile(url: $0) }.flatMap { try? Self(file: $0) }
        let ext = url.flatMap { try? AnlzFile(url: $0.deletingPathExtension().appendingPathExtension("EXT")) }
        let colors = ext.flatMap { try? Self(file: $0) }?.colorColumns
        let blue = dat?.blueColumns ?? ext.flatMap { try? AnlzColorWaveform(file: $0, mode: .blue) }?.columns
        guard let blue = blue ?? colors else { return nil }
        return Self(blue: blue, color: colors).downsampled(to: 400)
    }
}
