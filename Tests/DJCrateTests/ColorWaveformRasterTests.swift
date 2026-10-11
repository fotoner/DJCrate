import AppKit
import DJCApplication
import Foundation
import Testing
import DJCDomain
@testable import DJCAnalysis
@testable import DJCrate

struct ColorWaveformRasterTests {
    static var waveform: Waveform {
        Waveform(rate: 2, duration: 2, low: [0, 255, 0, 80], mid: [0, 0, 255, 40], high: [0, 0, 0, 160])
    }

    @Test func fallbackUsesAudioTimelineAndBandColors() throws {
        for mode in [WaveformColorMode.blue, .rgb] {
            let raster = try #require(ColorWaveformRaster.make(waveform: Self.waveform, source: nil,
                                                               mode: mode, audioOffset: 0.04))
            #expect(raster.offset == 0.04)
            #expect(raster.rate == 2)
            #expect(raster.duration == 2)
            #expect(raster.detail.width == 4)
            let bitmap = NSBitmapImageRep(cgImage: raster.detail)
            #expect(bitmap.colorAt(x: 0, y: 64)?.alphaComponent == 0)
            let low = try #require(bitmap.colorAt(x: 1, y: 64))
            if mode == .rgb { #expect(low.redComponent > low.blueComponent) }
            else { #expect(low.blueComponent > low.redComponent) }
        }
    }

    /// rekordbox 분석 파일의 색 파형(읽기는 DJCAdaptersTests `TrackAssetReaderLiveTests`)은 이미 rekordbox 시간축이다.
    @Test func analysisDetailAlreadyUsesRekordboxTimeline() throws {
        let source = ColorWaveformColumns(columns: Array(repeating: WaveformColumn(low: 1, mid: 0, high: 0), count: 300), rate: 150)
        let raster = try #require(ColorWaveformRaster.make(waveform: Self.waveform, source: source, mode: .blue, audioOffset: 0.04))
        #expect(raster.offset == 0)
        #expect(raster.rate == 150)
        #expect(raster.detail.width == 300)
        #expect(raster.duration == 2)
    }

    @Test @MainActor func changingModeDiscardsOldRasterAndCancelledResults() async throws {
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        deck.waveform = Self.waveform
        deck.waveformColorMode = .rgb
        await deck.colorWaveformTask?.value
        #expect(deck.colorWaveform != nil)
        deck.waveformColorMode = .blue
        let pending = deck.colorWaveformTask
        deck.waveformColorMode = .threeBand
        await pending?.value
        #expect(deck.colorWaveform == nil)
        deck.waveformColorMode = .rgb
        deck.waveform = nil
        await deck.colorWaveformTask?.value
        #expect(deck.colorWaveform == nil)
    }
}
