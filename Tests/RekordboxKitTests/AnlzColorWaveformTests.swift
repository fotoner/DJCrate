import Foundation
import RekordboxFixtures
import Testing
import DJCDomain
@testable import RekordboxKit

struct AnlzColorWaveformTests {
    @Test func readsBlueHeightAndWhitenessAt150Hz() throws {
        let file = try AnlzFile(data: AnlzBuilder.file([AnlzBuilder.waveform("PWV3", entryBytes: 1,
            samples: [0, 31, 0xE0, 0xFF, 0xA7])]))
        let wave = try #require(try AnlzColorWaveform(file: file, mode: .blue))
        #expect(wave.rate == 150)
        #expect(wave.columns.map(\.height) == [0, 1, 0, 1, 7.0 / 31])
        #expect(wave.columns.map(\.whiteness) == [0, 0, 1, 1, 5.0 / 7])
    }

    @Test func readsBigEndianRGBAndIgnoresReservedBits() throws {
        // 빨강·초록·파랑과 서로 다른 높이, 맨 아래 두 비트는 색·높이와 무관하다.
        let values: [UInt16] = [0xE07C, 0x1C3E, 0x0387]
        let bytes = values.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
        let file = try AnlzFile(data: AnlzBuilder.file([AnlzBuilder.waveform("PWV5", entryBytes: 2, samples: bytes)]))
        let wave = try #require(try AnlzColorWaveform(file: file, mode: .rgb))
        #expect(wave.columns.map(\.height) == [1, 15.0 / 31, 1.0 / 31])
        #expect(wave.columns.map(\.rgb) == [WaveformRGB(red: 1, green: 0, blue: 0),
            WaveformRGB(red: 0, green: 1, blue: 0), WaveformRGB(red: 0, green: 0, blue: 1)])
    }

    @Test func readsColorPreviewHeightChannelsAndLuminance() throws {
        let file = try AnlzFile(data: AnlzBuilder.file([AnlzBuilder.waveform("PWV4", entryBytes: 6,
            samples: [0, 254, 0xFF, 0xFF, 64, 32])]))
        let preview = try #require(try AnlzPreviewWaveform(file: file))
        let column = try #require(preview.colorColumns?.first)
        #expect(column.height == 1)
        #expect(column.low == 1)
        #expect(column.mid == 64.0 / 127)
        #expect(column.high == 32.0 / 127)
        #expect(column.rgb == WaveformRGB(red: 254.0 / 255, green: 128.0 / 255, blue: 64.0 / 255))
    }

    @Test func rejectsMalformedEntrySizesAndCounts() throws {
        for (tag, size) in [("PWV3", 1), ("PWV5", 2), ("PWV4", 6)] {
            for offset in [4, 12, 16] {
                var bytes = AnlzBuilder.waveform(tag, entryBytes: size, samples: Array(repeating: 0, count: size))
                withUnsafeBytes(of: UInt32.max.bigEndian) { bytes.replaceSubrange(offset..<offset + 4, with: $0) }
                let file = try AnlzFile(data: AnlzBuilder.file([bytes]))
                #expect(throws: (any Error).self) {
                    if tag == "PWV4" { _ = try AnlzPreviewWaveform(file: file) }
                    else { _ = try AnlzColorWaveform(file: file, mode: tag == "PWV3" ? .blue : .rgb) }
                }
            }
        }
        let empty = try AnlzFile(data: AnlzBuilder.file([]))
        #expect(try AnlzColorWaveform(file: empty, mode: .rgb) == nil)
        #expect(try AnlzColorWaveform(file: empty, mode: .threeBand) == nil)
    }
}
