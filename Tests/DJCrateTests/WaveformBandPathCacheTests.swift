@testable import DJCrate
@testable import DJCAnalysis
import SwiftUI
import DJCDomain
import Testing

@MainActor
@Suite("전체 파형 반복 배치 경로", .serialized)
struct WaveformBandPathCacheTests {
    private let rect = CGRect(x: 3, y: 2, width: 2, height: 20)
    private var waveform: Waveform { Waveform(rate: 1, duration: 4, low: [0, 255, 128, 64], mid: [255, 0, 0, 0], high: [0, 0, 255, 0]) }

    @Test(.tags(.perfContract)) func 같은_파형과_크기의_반복_배치는_경로를_한_번만_만든다() {
        let previous = PerfProbe.countsBodies
        defer { PerfProbe.countsBodies = previous; PerfProbe.resetBodyCounts() }
        PerfProbe.countsBodies = true
        PerfProbe.resetBodyCounts()
        let cache = WaveformBandPathCache(), wave = waveform
        let first = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        for _ in 0..<4 { #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect) == first) }
        #expect(PerfProbe.bodyCount("WaveformBandPath.build") == 1)
    }

    @Test func 경로는_구간_최댓값과_양끝_빈_구간을_보존한다() {
        let paths = WaveformBandPathCache().paths(waveform: waveform, from: 0, to: 4, in: rect)
        var expected = Path()
        let second = Double(128) / 255 * 10
        expected.addLines([CGPoint(x: 3, y: 2), CGPoint(x: 4, y: 12 - second), CGPoint(x: 5, y: 12), CGPoint(x: 6, y: 12),
                           CGPoint(x: 6, y: 12), CGPoint(x: 5, y: 12), CGPoint(x: 4, y: 12 + second), CGPoint(x: 3, y: 22)])
        expected.closeSubpath()
        #expect(paths.count == 3)
        #expect(paths.first == expected)
    }

    @Test func 크기와_시간축과_원본_변경은_캐시를_잘못_재사용하지_않는다() {
        let cache = WaveformBandPathCache()
        var wave = waveform
        let original = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        #expect(cache.paths(waveform: wave, from: -1, to: 3, in: rect) != original)
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect.offsetBy(dx: 1, dy: 1)) != original)
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: CGRect(x: 3, y: 2, width: 3, height: 20)) != original)
        wave.low[1] = 0
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect) != original)
        wave.rate = 2
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect) == WaveformBandPathCache().paths(waveform: wave, from: 0, to: 4, in: rect))
    }

    @Test func 배열_길이만_줄여도_새_경로를_만든다() {
        let cache = WaveformBandPathCache()
        var wave = waveform
        let original = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        wave.low.removeLast(2)
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect) != original)
        wave.mid.removeLast(3)
        wave.high.removeLast(3)
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect) == WaveformBandPathCache.makePaths(waveform: wave, from: 0, to: 4, in: rect))
    }

    @Test func 중음과_고음_변경과_빈_원본도_반영한다() {
        let cache = WaveformBandPathCache()
        var wave = waveform
        var previous = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        wave.mid[0] = 0
        var next = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        #expect(previous != next)
        previous = next
        wave.high[2] = 0
        next = cache.paths(waveform: wave, from: 0, to: 4, in: rect)
        #expect(previous != next)
        wave.low = []
        #expect(cache.paths(waveform: wave, from: 0, to: 4, in: rect).isEmpty)
        #expect(cache.paths(waveform: waveform, from: 4, to: 0, in: rect).isEmpty)
    }

    @Test func 여러_크기를_오가도_보관_범위는_네_개다() {
        let previous = PerfProbe.countsBodies
        defer { PerfProbe.countsBodies = previous; PerfProbe.resetBodyCounts() }
        PerfProbe.countsBodies = true
        PerfProbe.resetBodyCounts()
        let cache = WaveformBandPathCache(), wave = waveform
        for width in 2...5 {
            _ = cache.paths(waveform: wave, from: 0, to: 4, in: CGRect(x: 0, y: 0, width: width, height: 20))
        }
        for width in 2...5 {
            _ = cache.paths(waveform: wave, from: 0, to: 4, in: CGRect(x: 0, y: 0, width: width, height: 20))
        }
        #expect(PerfProbe.bodyCount("WaveformBandPath.build") == 4)
        _ = cache.paths(waveform: wave, from: 0, to: 4, in: CGRect(x: 0, y: 0, width: 6, height: 20))
        _ = cache.paths(waveform: wave, from: 0, to: 4, in: CGRect(x: 0, y: 0, width: 2, height: 20))
        #expect(PerfProbe.bodyCount("WaveformBandPath.build") == 6)
    }

    @Test func 폭이_바뀌어도_원본_최댓값_색인은_한_번만_만든다() {
        let previous = PerfProbe.countsBodies
        defer { PerfProbe.countsBodies = previous; PerfProbe.resetBodyCounts() }
        PerfProbe.countsBodies = true
        PerfProbe.resetBodyCounts()
        let cache = WaveformBandPathCache(), wave = waveform
        for width in 2...21 {
            let size = CGRect(x: 3, y: 2, width: width, height: 20)
            #expect(cache.paths(waveform: wave, from: -0.3, to: 4.7, in: size)
                    == referencePaths(waveform: wave, from: -0.3, to: 4.7, in: size))
        }
        #expect(PerfProbe.bodyCount("WaveformBandPath.build") == 20)
        #expect(PerfProbe.bodyCount("WaveformBandPeaks.build") == 1)
    }

    @Test func 원본이_바뀔_때만_최댓값_색인을_다시_만든다() {
        let previous = PerfProbe.countsBodies
        defer { PerfProbe.countsBodies = previous; PerfProbe.resetBodyCounts() }
        PerfProbe.countsBodies = true
        PerfProbe.resetBodyCounts()
        let cache = WaveformBandPathCache()
        var wave = waveform
        func check(_ start: Double = 0, _ end: Double = 4, _ size: CGRect? = nil) {
            let size = size ?? rect
            #expect(cache.paths(waveform: wave, from: start, to: end, in: size)
                    == referencePaths(waveform: wave, from: start, to: end, in: size))
        }
        check()
        check(-0.3, 4.7, rect.offsetBy(dx: 0.5, dy: 1))
        check(1, 3, CGRect(x: 0, y: 0, width: 3.5, height: 31))
        #expect(PerfProbe.bodyCount("WaveformBandPeaks.build") == 1)
        wave.low[1] = 0; check()
        wave.mid[0] = 0; check()
        wave.high[2] = 0; check()
        wave.rate = 2; check()
        wave.low.removeLast(); check()
        wave.mid.removeLast(2); check()
        wave.high = []; check()
        #expect(PerfProbe.bodyCount("WaveformBandPeaks.build") == 8)
    }

    @Test func 소수_폭과_시간축의_경로는_원래_표본_최댓값과_같다() {
        let wave = Waveform(rate: 32, duration: 8.03125,
                            low: (0..<257).map { UInt8(($0 * 73 + 17) % 256) },
                            mid: (0..<129).map { UInt8(($0 * 31 + 9) % 256) },
                            high: (0..<256).map { UInt8(($0 * 11 + 3) % 256) })
        let cache = WaveformBandPathCache()
        for width in [1.0, 2, 3.5, 7.25, 31.75, 98.25, 257, 512.5] {
            for (start, end) in [(-0.73, 6.4), (0, 8.03125), (1.25, 2.5), (5.8, 9), (-2, -1), (10, 11)] {
                let size = CGRect(x: 3.25, y: 2.5, width: width, height: 37.5)
                #expect(cache.paths(waveform: wave, from: start, to: end, in: size)
                        == referencePaths(waveform: wave, from: start, to: end, in: size))
            }
        }
    }

    /// 변경 전의 구간·좌표를 고정하고 밴드별 표본 최댓값을 직접 읽는다.
    private func referencePaths(waveform: Waveform, from start: Double, to end: Double, in rect: CGRect) -> [Path] {
        let columns = max(1, Int(rect.width)), span = end - start
        guard span > 0, waveform.count > 0 else { return [] }
        let binDuration = span / Double(columns)
        let firstBin = Int((start / binDuration).rounded(.down))
        return zip([waveform.low, waveform.mid, waveform.high], [1.0, 0.78, 0.5]).map { band, scale in
            var top: [CGPoint] = [], bottom: [CGPoint] = []
            for k in 0...(columns + 1) {
                let t0 = Double(firstBin + k) * binDuration
                let a = Int((t0 * waveform.rate).rounded(.down))
                let b = max(a + 1, Int(((t0 + binDuration) * waveform.rate).rounded(.down)))
                let peak = a < band.count && b > 0 ? band[max(0, a)..<min(band.count, b)].max() ?? 0 : 0
                let amplitude = Double(peak) / 255 * rect.height / 2 * scale
                let x = rect.minX + CGFloat((t0 - start) / span) * rect.width
                top.append(CGPoint(x: x, y: rect.midY - amplitude))
                bottom.append(CGPoint(x: x, y: rect.midY + amplitude))
            }
            var path = Path()
            path.addLines(top + bottom.reversed())
            path.closeSubpath()
            return path
        }
    }
}
