import DJCDomain
import SwiftUI

/// 같은 Canvas 크기를 여러 번 배치할 때 3밴드의 구간 최대값과 경로를 다시 만들지 않는다.
@MainActor
final class WaveformBandPathCache {
    private struct Key: Equatable {
        var start: Double
        var end: Double
        var rect: CGRect
    }
    private struct Source: Equatable {
        var rate: Double
        var buffers: [UInt]
        var counts: [Int]

        init(_ waveform: Waveform) {
            rate = waveform.rate
            counts = [waveform.low.count, waveform.mid.count, waveform.high.count]
            buffers = [waveform.low, waveform.mid, waveform.high].map { band in
                band.withUnsafeBufferPointer { $0.baseAddress.map { UInt(bitPattern: $0) } ?? 0 }
            }
        }
    }
    private var source: Source?
    // 원본 배열을 보관해 주소 재사용을 막고 수정 시 COW로 다른 원본임을 확인한다.
    private var retainedWaveform: Waveform?
    private var peaks: [PeakTree] = []
    private var entries: [(key: Key, paths: [Path])] = []

    func paths(waveform: Waveform, from start: Double, to end: Double, in rect: CGRect) -> [Path] {
        let nextSource = Source(waveform)
        if source != nextSource {
            entries.removeAll(keepingCapacity: true)
            source = nextSource
            retainedWaveform = waveform
            PerfProbe.count("WaveformBandPeaks.build")
            peaks = [waveform.low, waveform.mid, waveform.high].map(PeakTree.init)
        }
        let key = Key(start: start, end: end, rect: rect)
        if let entry = entries.first(where: { $0.key == key }) { return entry.paths }
        PerfProbe.count("WaveformBandPath.build")
        let paths = Self.makePaths(waveform: waveform, from: start, to: end, in: rect, peaks: peaks)
        // 예측 배치에서 번갈아 쓰는 크기만 보관해 메모리가 계속 늘지 않게 한다.
        if entries.count == 4 { entries.removeFirst() }
        entries.append((key, paths))
        return paths
    }

    nonisolated static func makePaths(waveform: Waveform, from start: Double, to end: Double, in rect: CGRect,
                                     scales: (Double, Double, Double) = (1, 0.78, 0.5)) -> [Path] {
        makePaths(waveform: waveform, from: start, to: end, in: rect, scales: scales,
                  peaks: [waveform.low, waveform.mid, waveform.high].map(PeakTree.init))
    }

    private nonisolated static func makePaths(waveform: Waveform, from start: Double, to end: Double, in rect: CGRect,
                                             scales: (Double, Double, Double) = (1, 0.78, 0.5), peaks: [PeakTree]) -> [Path] {
        let columns = max(1, Int(rect.width))
        let span = end - start
        guard span > 0, waveform.count > 0 else { return [] }
        let binDuration = span / Double(columns)
        let firstBin = Int((start / binDuration).rounded(.down))
        let cy = rect.midY, half = rect.height / 2
        return zip(peaks, [scales.0, scales.1, scales.2]).map { band, scale in
            var top: [CGPoint] = [], bottom: [CGPoint] = []
            top.reserveCapacity(columns + 2); bottom.reserveCapacity(columns + 2)
            for k in 0...(columns + 1) {
                let t0 = Double(firstBin + k) * binDuration
                let a = Int((t0 * waveform.rate).rounded(.down))
                let b = max(a + 1, Int(((t0 + binDuration) * waveform.rate).rounded(.down)))
                let peak = band.maximum(from: a, to: b)
                let amplitude = Double(peak) / 255 * half * scale
                let x = rect.minX + CGFloat((t0 - start) / span) * rect.width
                top.append(CGPoint(x: x, y: cy - amplitude))
                bottom.append(CGPoint(x: x, y: cy + amplitude))
            }
            var path = Path()
            path.addLines(top + bottom.reversed())
            path.closeSubpath()
            return path
        }
    }

    /// 폭마다 전체 표본을 다시 훑지 않고, 정확한 구간 최댓값을 원본의 두 배 공간에서 찾는다.
    private struct PeakTree {
        let count: Int
        private var maxima: [UInt8]

        init(_ band: [UInt8]) {
            count = band.count
            maxima = [UInt8](repeating: 0, count: count * 2)
            guard count > 0 else { return }
            maxima.replaceSubrange(count..<(count * 2), with: band)
            for i in stride(from: count - 1, through: 1, by: -1) {
                maxima[i] = max(maxima[i * 2], maxima[i * 2 + 1])
            }
        }

        func maximum(from lower: Int, to upper: Int) -> UInt8 {
            guard lower < count, upper > 0 else { return 0 }
            var left = max(0, lower) + count, right = min(count, upper) + count
            var peak: UInt8 = 0
            while left < right {
                if !left.isMultiple(of: 2) { peak = max(peak, maxima[left]); left += 1 }
                if !right.isMultiple(of: 2) { right -= 1; peak = max(peak, maxima[right]) }
                left /= 2; right /= 2
            }
            return peak
        }
    }
}
