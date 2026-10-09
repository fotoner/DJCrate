import DJCDomain
import Foundation
import RekordboxFixtures
import Testing
@testable import RekordboxKit

struct AnlzPreviewWaveformTests {
    @Test func decodesHeightWithoutWhiteness() throws {
        let file = try AnlzFile(data: AnlzBuilder.file([AnlzBuilder.pwav([0, 31, 0xE0, 0xFF, 0xA7])]))
        #expect(try AnlzPreviewWaveform(file: file)?.heights == [0, 31, 0, 31, 7])
    }

    @Test func keepsPeaksAndLastSampleWhenDownsampling() throws {
        let file = try AnlzFile(data: AnlzBuilder.file([AnlzBuilder.pwav([1, 20, 2, 3, 4, 5, 31])]))
        let preview = try #require(try AnlzPreviewWaveform(file: file))
        #expect(preview.downsampled(to: 3).heights == [20, 3, 31])
        #expect(preview.downsampled(to: 1).heights == [31])
        #expect(preview.downsampled(to: 10) == preview)
        #expect(preview.downsampled(to: 0).heights.isEmpty)
    }

    @Test func missingAndEmptyPreviewAreBlank() throws {
        #expect(try AnlzPreviewWaveform(file: AnlzFile(data: AnlzBuilder.file([]))) == nil)
        #expect(try AnlzPreviewWaveform(file: AnlzFile(data: AnlzBuilder.file([AnlzBuilder.pwav([])]))) == nil)
    }

    @Test func rejectsTruncatedAndOversizedHeaders() throws {
        for (offset, value) in [(4, UInt32(12)), (4, UInt32.max), (12, UInt32.max)] {
            var tag = AnlzBuilder.pwav([1, 2, 3])
            withUnsafeBytes(of: value.bigEndian) { tag.replaceSubrange(offset..<offset + 4, with: $0) }
            let file = try AnlzFile(data: AnlzBuilder.file([tag]))
            #expect(throws: (any Error).self) { try AnlzPreviewWaveform(file: file) }
        }
        let short = Data("PWAV".utf8) + Data([0, 0, 0, 12, 0, 0, 0, 12])
        let file = try AnlzFile(data: AnlzBuilder.file([short]))
        #expect(throws: (any Error).self) { try AnlzPreviewWaveform(file: file) }
    }
}
