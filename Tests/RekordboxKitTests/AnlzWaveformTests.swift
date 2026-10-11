import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 파형 태그 생성기(RekordboxWaveforms). 규칙 자체는 실제 라이브러리와 `djc lab waveform-eval`로 맞춘다.
@Suite("파형 태그 만들기")
struct AnlzWaveformTests {
    func tone(seconds: Double, hz: Double, amplitude: Float, rate: Double = 44_100) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    @Test func 칸_수와_태그_크기는_rekordbox_모양() throws {
        let w = RekordboxWaveforms.analyze(mono: tone(seconds: 2, hz: 440, amplitude: 0.5), sampleRate: 44_100)
        #expect(w.columns == 300 && w.pwv5.count == 300 && w.pwv7.count == 900)
        #expect((w.pwav.count, w.pwv2.count, w.pwv6.count, w.pwv4.count) == (400, 100, 3600, 7200))
        #expect((w.pwavTag.count, w.pwv2Tag.count, w.pwv3Tag.count, w.pwv5Tag.count) == (420, 120, 24 + 300, 24 + 600))
        #expect((w.pwv4Tag.count, w.pwv7Tag.count, w.pwv6Tag.count, w.pwvcTag.count) == (7224, 24 + 900, 3620, 20))
        #expect(RekordboxWaveforms.body(of: w.pwv3Tag) == w.pwv3)
    }

    @Test func 센_고음은_희고_저음은_어둡고_무음은_0() {
        let high = RekordboxWaveforms.analyze(mono: tone(seconds: 1, hz: 8000, amplitude: 0.8), sampleRate: 48_000)
        #expect(high.pwv3.dropFirst(10).allSatisfy { $0 >> 5 == 7 && $0 & 31 >= 29 })
        let bass = RekordboxWaveforms.analyze(mono: tone(seconds: 1, hz: 60, amplitude: 0.8), sampleRate: 48_000)
        #expect(bass.pwv3.dropFirst(10).allSatisfy { $0 >> 5 <= 1 })
        #expect(bass.pwv7[20 * 3] > bass.pwv7[20 * 3 + 2], "저음은 저역 밴드가 크다")
        let silence = RekordboxWaveforms.analyze(mono: [Float](repeating: 0, count: 44_100), sampleRate: 44_100)
        #expect(silence.pwv3.allSatisfy { $0 == 0xE0 } && silence.gains == [80, 80, 95])
    }

    @Test func DAT를_바탕으로_rekordbox_순서의_EXT와_2EX() throws {
        // .DAT: 경로·큐 목록 태그만 있으면 된다
        let ppth = RekordboxWaveforms.section("PPTH", headerLength: 0x10, RekordboxWaveforms.be32(4) + [0, 0x3F, 0, 0x2F])
        let pcob = { (kind: UInt32) in RekordboxWaveforms.section("PCOB", headerLength: 0x18, RekordboxWaveforms.be32(kind) + [0, 0, 0xFF, 0xFF, 0xFF, 0xFF].map { $0 }) }
        let header = Data([0x50, 0x4D, 0x41, 0x49] + RekordboxWaveforms.be32(0x1C) + RekordboxWaveforms.be32(0) + [0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        let dat = AnlzFile(header: header, tags: [ppth, pcob(1), pcob(0)])
        let w = RekordboxWaveforms.analyze(mono: tone(seconds: 1, hz: 440, amplitude: 0.5), sampleRate: 44_100)
        let (extData, twoData) = try w.files(dat: dat)
        let ext = try AnlzFile(data: extData), two = try AnlzFile(data: twoData)
        #expect(ext.tags.map(\.fourcc) == ["PPTH", "PWV3", "PCOB", "PCOB", "PCO2", "PCO2", "PQT2", "PWV5", "PWV4"])
        #expect(two.tags.map(\.fourcc) == ["PPTH", "PWV7", "PWV6", "PWVC"])
        #expect(ext.tag("PWV3")?.bytes == w.pwv3Tag && ext.header.prefix(8) == header.prefix(8))
        // 빈 PCO2는 rekordbox 7.2 파일과 바이트까지 같다
        #expect(ext.tags.filter { $0.fourcc == "PCO2" }.map { [UInt8]($0.bytes) }
            == [[0x50, 0x43, 0x4F, 0x32, 0, 0, 0, 0x14, 0, 0, 0, 0x14, 0, 0, 0, 1, 0, 0, 0, 0],
                [0x50, 0x43, 0x4F, 0x32, 0, 0, 0, 0x14, 0, 0, 0, 0x14, 0, 0, 0, 0, 0, 0, 0, 0]])
    }

    @Test func 파형_오차는_길이_차이와_빈_자료를_숨기지_않는다() {
        let same = RekordboxWaveforms.compare(reference: [1, 2, 3], generated: [1, 2, 3])
        #expect(same.matchingPercent == 100 && same.meanAbsoluteError == 0 && same.maxAbsoluteError == 0)
        let different = RekordboxWaveforms.compare(reference: [10, 20, 30], generated: [10, 24])
        #expect(different.referenceBytes == 3 && different.generatedBytes == 2 && different.comparedBytes == 2)
        #expect(abs((different.matchingPercent ?? 0) - 100.0 / 3) < 0.0001)
        #expect(different.meanAbsoluteError == 2 && different.maxAbsoluteError == 4)
        let missing = RekordboxWaveforms.compare(reference: [1], generated: [])
        #expect(missing.matchingPercent == 0 && missing.meanAbsoluteError == nil && missing.maxAbsoluteError == nil)
        let empty = RekordboxWaveforms.compare(reference: [], generated: [])
        #expect(empty.matchingPercent == nil && empty.meanAbsoluteError == nil)
    }

    @Test func 색_미리보기는_양음_피크를_부호_있는_8비트로_양자화한다() {
        // 2026-09-26 rekordbox 분석 사본 비교: PWV4 앞 두 칸은 밴드 색과 독립인 PCM 양·음 피크다.
        let samples: [Float] = Array(repeating: [0.5, -0.25, 0.499, -0.249], count: 1200).flatMap { $0 }
        let w = RekordboxWaveforms.analyze(mono: samples, sampleRate: 48_000)
        #expect(stride(from: 0, to: w.pwv4.count, by: 6).allSatisfy { w.pwv4[$0] == 64 && w.pwv4[$0 + 1] == 224 })
        let louder = RekordboxWaveforms.analyze(mono: samples.map { $0 * 2 }, sampleRate: 48_000)
        #expect(louder.pwv4[0] == 127 && louder.pwv4[1] == 192)
    }

    @Test func 색_미리보기는_작은_피크를_버리고_짧은_음원과_무음을_처리한다() {
        let w = RekordboxWaveforms.analyze(mono: [0.499, -0.249], sampleRate: 44_100)
        #expect(w.pwv4[0] == 63 && w.pwv4[1] == 0)
        #expect(w.pwv4[1199 * 6] == 0 && w.pwv4[1199 * 6 + 1] == 225)
        let silence = RekordboxWaveforms.analyze(mono: [], sampleRate: 44_100)
        #expect(silence.pwv4.allSatisfy { $0 == 0 })
    }

    @Test func 색_미리보기_세번째_성분은_400Hz_저역_피크다() {
        // 2026-09-26 rekordbox 7.2.18, probe-frequency.wav 정상 구간의 세 번째 바이트.
        // 8kHz의 값이 0이므로 RGB 에너지 합이 아니다. 곡 최대값이나 PWVC 게인에도 무관하다.
        let frequencies: [Double] = [60, 150, 300, 1000, 2500, 8000, 16000]
        let expected: [UInt8] = [63, 63, 55, 10, 1, 0, 0]
        var samples = [Float](repeating: 0, count: 30 * 44_100)
        for (index, hz) in frequencies.enumerated() {
            let start = (2 + index * 4) * 44_100
            samples.replaceSubrange(start..<start + 2 * 44_100, with: tone(seconds: 2, hz: hz, amplitude: 0.5))
        }
        let w = RekordboxWaveforms.analyze(mono: samples, sampleRate: 44_100)
        for (index, value) in expected.enumerated() {
            #expect(w.pwv4[(3 + index * 4) * 40 * 6 + 2] == value, "\(frequencies[index])Hz의 저역 피크")
        }
    }

    @Test func 색_미리보기_저역_피크는_절대_진폭을_버림한다() {
        // 같은 날 probe-amplitude.wav의 1kHz, 진폭 1/64·1/16·1/4·1/2·1 구간.
        var samples = [Float](repeating: 0, count: 22 * 44_100)
        let amplitudes: [Float] = [1.0 / 64, 1.0 / 16, 0.25, 0.5, 1]
        for (index, amplitude) in amplitudes.enumerated() {
            let start = (2 + index * 4) * 44_100
            samples.replaceSubrange(start..<start + 2 * 44_100, with: tone(seconds: 2, hz: 1000, amplitude: amplitude))
        }
        let w = RekordboxWaveforms.analyze(mono: samples, sampleRate: 44_100)
        for (index, value) in [UInt8(0), 1, 5, 10, 20].enumerated() {
            #expect(w.pwv4[Int(Double(3 + index * 4) * 1200 / 22) * 6 + 2] == value)
        }
    }

    @Test func 색_파형의_완전한_무음은_흰색에_높이_0이다() {
        // 2026-09-26 rekordbox 7.2.18, probe 3곡 모두 앞쪽 무음의 PWV5가 FF80이었다.
        let w = RekordboxWaveforms.analyze(mono: [Float](repeating: 0, count: 44_100), sampleRate: 44_100)
        #expect(w.pwv5.allSatisfy { $0 == 0xFF80 })
    }
}
