import Testing
@testable import DJCDomain

struct WaveformColorTests {
    @Test func fallbackUsesTotalHeightAndHighFrequencyWhiteness() {
        let low = WaveformColumn(low: 1, mid: 0, high: 0)
        let high = WaveformColumn(low: 0, mid: 0, high: 1)
        #expect(low.height == 1)
        #expect(low.whiteness == 0)
        #expect(high.whiteness == 1)
        #expect(low.rgb == WaveformRGB(red: 1, green: 0, blue: 0))
        #expect(high.rgb == WaveformRGB(red: 0, green: 0, blue: 1))
        let mixed = WaveformColumn(low: 0.8, mid: 0.4, high: 0.2)
        #expect(mixed.height == 0.8)
        #expect(abs(mixed.whiteness - 1 / 7) < 0.0001)
        #expect(mixed.rgb == WaveformRGB(red: 1, green: 0.5, blue: 0.25))
        let silence = WaveformColumn(low: 0, mid: 0, high: 0)
        #expect(silence.height == 0)
        #expect(silence.whiteness == 0)
        #expect(silence.rgb == WaveformRGB(red: 0, green: 0, blue: 0))
    }

    @Test func modeDefaultsAndInvalidStoredValuesPreserveThreeBand() {
        #expect(SettingKeys.waveformColorMode.defaultValue == "threeBand")
        #expect(SettingKeys.waveformColorMode.value(from: "invalid") == "threeBand")
        for mode in WaveformColorMode.allCases {
            #expect(SettingKeys.waveformColorMode.value(from: mode.rawValue) == mode.rawValue)
        }
    }

    @Test func downsamplingKeepsPeaksAndTheirColor() {
        let samples = [WaveformColumn(low: 0.1, mid: 0, high: 0),
                       WaveformColumn(low: 0, mid: 1, high: 0),
                       WaveformColumn(low: 0, mid: 0, high: 0.8)]
        let reduced = WaveformColumn.downsample(samples, to: 1)
        #expect(reduced.count == 1)
        #expect(reduced[0].height == 1)
        #expect(reduced[0].rgb == samples[1].rgb)
        #expect(reduced[0].low == 0.1)
        #expect(reduced[0].high == 0.8)
        #expect(WaveformColumn.downsample(samples, to: 0).isEmpty)
    }
}
