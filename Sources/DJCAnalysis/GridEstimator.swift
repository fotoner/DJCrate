import DJCDomain
import Foundation

/// Music Understanding의 박·마디로 rekordbox식 비트 그리드(템포 구간)를 추정한다.
///
/// MU 박은 조금씩 흔들리고, 브레이크에서 빠지거나 한두 개 튀기도 한다. rekordbox 그리드는 구간마다
/// 고정 간격이므로, 박에 번호를 매긴 뒤(빠진 박은 간격으로 건너뛴다) 직선으로 맞추고
/// 직선에서 계속 벗어나는 곳(실제 변속·위상 점프)에서만 구간을 나눈다. 1박은 MU 마디 시작의 다수결이다.
public enum GridEstimator {
    /// 추정 결과 값은 DJCDomain에 있다(#167, 덱이 제안으로 들고 있다)
    public typealias Estimate = GridEstimate

    /// rekordbox 라이브러리의 BPM은 거의 모두 105~215 안에 있다(분석 범위 설정). 추정도 이 범위로 옮긴다.
    public static let defaultRange: ClosedRange<Double> = 105...215

    /// 박 목록에서 그리드를 추정한다(DJCrate 시간축). `bpmRange` 밖이면 두 배·절반으로 옮긴다.
    /// `onset`이 있으면 반 박 밀림을 바로잡고 어택에 맞춰 위상을 다듬는다.
    public static func estimate(beats rawBeats: [Double], bars: [Double], duration: Double,
                                onset: OnsetEnvelope? = nil,
                                bpmRange: ClosedRange<Double> = defaultRange) -> Estimate? {
        let beats = Array(Set(rawBeats.filter { $0.isFinite && $0 >= 0 && $0 <= duration + 1 })).sorted()
        guard beats.count >= 16 else { return nil }
        let indexed = number(beats)
        var fits = piecewiseFit(indexed)
        guard !fits.isEmpty else { return nil }
        fits = fits.map { normalizeTempo($0, range: bpmRange, bars: bars) }
        if let onset { fits = refineWithOnsets(fits, onset: onset) }

        var residuals: [Double] = []
        var segments: [GridSegment] = []
        var votesWon = 0, votesTotal = 0
        for original in fits {
            // 박 고르기(잔차)는 MU 박 기준으로, 위상은 어택으로 다듬은 뒤의 직선으로 본다.
            for point in original.points { residuals.append(abs(point.time - original.time(at: point.index)) * 1000) }
            let fit = original
            let (firstNumber, won, total) = downbeat(fit, bars: bars)
            votesWon += won; votesTotal += total
            segments.append(GridSegment(start: fit.time(at: fit.firstIndex), bpm: 60 / fit.period, firstBeatNumber: firstNumber))
        }
        residuals.sort()
        let median = residuals[residuals.count / 2]
        let inliers = Double(residuals.filter { $0 <= 25 }.count) / Double(residuals.count)
        return Estimate(segments: segments, medianResidualMs: median, inlierRatio: inliers,
                        downbeatConfidence: votesTotal > 0 ? Double(votesWon) / Double(votesTotal) : 0)
    }

    // MARK: - 박 번호

    struct Point { var index: Int; var time: Double }

    /// 연속한 박에 정수 번호를 준다. 간격이 박 두 개쯤이면 하나를 건너뛴 것으로 센다.
    /// 기준 간격은 최근 박 간격의 중앙값이라 템포가 바뀌어도 따라간다.
    static func number(_ beats: [Double]) -> [Point] {
        var points = [Point(index: 0, time: beats[0])]
        var recent: [Double] = []
        let globalMedian = median(zip(beats.dropFirst(), beats).map { $0 - $1 })
        for i in 1..<beats.count {
            let gap = beats[i] - beats[i - 1]
            let period = recent.count >= 4 ? median(recent) : globalMedian
            let steps = max(1, Int((gap / period).rounded()))
            if steps == 1 {
                recent.append(gap)
                if recent.count > 8 { recent.removeFirst() }
            }
            points.append(Point(index: points[i - 1].index + steps, time: beats[i]))
        }
        return points
    }

    // MARK: - 직선 맞춤

    struct Fit {
        var intercept: Double
        var period: Double
        var points: [Point]
        var firstIndex: Int { points.first?.index ?? 0 }
        var lastIndex: Int { points.last?.index ?? 0 }
        func time(at index: Int) -> Double { intercept + period * Double(index) }
    }

    /// 최소제곱 직선. 30ms 넘게 벗어난 박을 빼고 두 번 더 맞춘다.
    static func robustFit(_ points: [Point]) -> Fit? {
        var used = points
        var fit: Fit?
        for _ in 0..<3 {
            guard used.count >= 8, let line = leastSquares(used) else { break }
            fit = Fit(intercept: line.a, period: line.b, points: points)
            let kept = points.filter { abs($0.time - (line.a + line.b * Double($0.index))) <= 0.030 }
            if kept.count == used.count { break }
            used = kept
        }
        return fit
    }

    static func leastSquares(_ points: [Point]) -> (a: Double, b: Double)? {
        let n = Double(points.count)
        guard n >= 2 else { return nil }
        let mx = points.reduce(0) { $0 + Double($1.index) } / n
        let my = points.reduce(0) { $0 + $1.time } / n
        var sxx = 0.0, sxy = 0.0
        for p in points {
            let dx = Double(p.index) - mx
            sxx += dx * dx
            sxy += dx * (p.time - my)
        }
        guard sxx > 0 else { return nil }
        let b = sxy / sxx
        guard b > 0 else { return nil }
        return (my - b * mx, b)
    }

    /// 곡 전체를 한 직선으로 맞춰 보고, 박 대부분이 맞으면 구간 하나로 끝낸다.
    /// 아니면 앞에서부터 구간을 늘려 가다 새 박이 연속으로 벗어나는 곳에서 끊는다.
    static func piecewiseFit(_ points: [Point]) -> [Fit] {
        // rekordbox 변속곡은 드물다(표본 37곡 중 1곡). MU 박이 조금 흔들려도 대부분 한 직선에 들면 한 구간으로 둔다.
        if let whole = robustFit(points) {
            let good = points.filter { abs($0.time - whole.time(at: $0.index)) <= 0.035 }.count
            if Double(good) / Double(points.count) >= 0.8 { return [whole] }
        }
        var fits: [Fit] = []
        var start = 0
        while start < points.count {
            var end = min(points.count, start + 16)
            guard end - start >= 8, var current = robustFit(Array(points[start..<end])) else {
                // 남은 박이 너무 적으면 앞 구간에 붙인다.
                if var last = fits.popLast() {
                    last.points += points[start...]
                    fits.append(robustFit(last.points) ?? last)
                }
                break
            }
            var misses = 0
            while end < points.count {
                let p = points[end]
                if abs(p.time - current.time(at: p.index)) <= 0.035 {
                    misses = 0
                } else {
                    misses += 1
                    if misses >= 4 { end -= 3; break }
                }
                end += 1
                if (end - start) % 16 == 0, let refit = robustFit(Array(points[start..<end])) { current = refit }
            }
            if let refit = robustFit(Array(points[start..<end])) { current = refit }
            fits.append(current)
            start = end
        }
        return merge(fits)
    }

    /// 템포가 거의 같고 위상도 이어지는 이웃 구간은 하나로 합친다.
    static func merge(_ fits: [Fit]) -> [Fit] {
        var merged: [Fit] = []
        for fit in fits {
            if let last = merged.last,
               abs(last.period - fit.period) / last.period < 0.005,
               abs(last.time(at: fit.firstIndex) - fit.time(at: fit.firstIndex)) < 0.035,
               let joined = robustFit(last.points + fit.points) {
                merged[merged.count - 1] = joined
            } else {
                merged.append(fit)
            }
        }
        return merged
    }

    // MARK: - 어택으로 다듬기

    /// MU는 BPM을 정수 쪽으로 둥글게 잡는 경향이 있다(rekordbox 144.80 → MU 145). 그러면 박이 조금씩 밀리고
    /// MU가 중간에 위상을 다시 맞추면서 구간이 쪼개진다. 어택 곡선으로 템포를 0.01 BPM 단위로 다시 찾고,
    /// 한 구간으로 봐도 여러 구간만큼 어택과 잘 맞으면 한 구간을 택한다.
    static func refineWithOnsets(_ fits: [Fit], onset: OnsetEnvelope) -> [Fit] {
        let piecewise = fits.map { refinePhase(refineTempo($0, onset: onset), onset: onset) }
        guard fits.count > 1 else { return piecewise }
        let periods = fits.map(\.period).sorted()
        let middle = periods[periods.count / 2]
        guard periods.allSatisfy({ abs($0 - middle) / middle < tempoSpread }) else { return piecewise }
        var combined = Fit(intercept: 0, period: middle, points: fits.flatMap(\.points))
        combined.intercept = circularIntercept(combined)
        let single = refinePhase(refineTempo(combined, onset: onset, span: 0.01), onset: onset)
        return onsetScore([single], onset: onset) >= singleSegmentRatio * onsetScore(piecewise, onset: onset) ? [single] : piecewise
    }

    /// 주기를 고정했을 때 박들이 가장 많이 모이는 위상(원형 중앙값). 위상 점프가 섞여 있어도 다수 쪽을 따른다.
    /// 결과는 박 번호가 원래대로 유지되도록 첫 박 근처로 펼친 값이다(주기의 배수만큼 튀지 않게).
    static func circularIntercept(_ fit: Fit) -> Double {
        let raw = fit.points.map { $0.time - fit.period * Double($0.index) }
        guard let reference = raw.first else { return fit.intercept }
        let unwrapped = raw.map { r -> Double in
            var d = (r - reference).truncatingRemainder(dividingBy: fit.period)
            if d > fit.period / 2 { d -= fit.period } else if d < -fit.period / 2 { d += fit.period }
            return reference + d
        }.sorted()
        return unwrapped[unwrapped.count / 2]
    }

    /// 템포만 다시 찾는다. 후보 주기마다 어택 곡선을 한 주기로 접어(위상 히스토그램) 봉우리가 가장 높은 주기를 고른다.
    /// 위상은 원래 직선(MU 박)에 맞춰 둔다. 봉우리 위상은 뒷박일 수도 있어서 쓰지 않는다.
    static func refineTempo(_ fit: Fit, onset: OnsetEnvelope, span: Double = 0.008) -> Fit {
        let rate = onset.rate
        let from = fit.time(at: fit.firstIndex) - fit.period, to = fit.time(at: fit.lastIndex) + fit.period
        let a = max(0, Int(from * rate)), b = min(onset.values.count, Int(to * rate))
        guard b - a > Int(rate * 16) else { return fit }
        let bpm0 = 60 / fit.period
        var bestPeriod = fit.period, bestPeak = -1.0
        var step = 0
        while true {
            let bpm = (bpm0 * (1 - span) * 100).rounded() / 100 + Double(step) * 0.01
            if bpm > bpm0 * (1 + span) { break }
            step += 1
            let periodFrames = 60 / bpm * rate
            let bins = max(8, Int(periodFrames / 2))
            var histogram = [Double](repeating: 0, count: bins)
            for i in a..<b {
                let v = onset.values[i]
                guard v > 0 else { continue }
                let phase = Double(i).truncatingRemainder(dividingBy: periodFrames) / periodFrames
                histogram[min(bins - 1, Int(phase * Double(bins)))] += Double(v)
            }
            for j in 0..<bins {
                let peak = histogram[(j + bins - 1) % bins] + histogram[j] + histogram[(j + 1) % bins]
                if peak > bestPeak { bestPeak = peak; bestPeriod = 60 / bpm }
            }
        }
        var refined = fit
        refined.period = bestPeriod
        refined.intercept = circularIntercept(refined)
        return refined
    }

    /// 박 위치의 평균 어택(구간마다 자기 박 범위만).
    static func onsetScore(_ fits: [Fit], onset: OnsetEnvelope) -> Double {
        var sum = 0.0, count = 0
        for fit in fits {
            for index in fit.firstIndex...max(fit.firstIndex, fit.lastIndex) {
                sum += Double(onset.value(at: fit.time(at: index)))
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    // MARK: - 위상

    /// 어택 곡선으로 위상을 다듬는다. 박을 반 박 옮겼을 때 어택이 15% 넘게 세면 MU가 뒷박을 잡은 것으로 보고
    /// 반 박 옮긴 뒤, ±25ms 안에서 어택 합이 가장 큰 자리로 맞춘다.
    /// 한 구간 후보가 여러 구간 대비 이 비율 이상 어택과 맞으면 한 구간을 택한다. 평가로 정한다.
    nonisolated(unsafe) public static var singleSegmentRatio: Double = 0.95
    /// 구간들의 템포가 이 비율 안에서 모두 같으면 한 구간 후보를 만들어 본다.
    nonisolated(unsafe) public static var tempoSpread: Double = 0.01

    /// 반 박 옮김 판정 문턱(0이면 끈다). 평가로 정한다.
    nonisolated(unsafe) public static var halfBeatRatio: Double = 0

    static func refinePhase(_ fit: Fit, onset: OnsetEnvelope) -> Fit {
        var fit = fit
        let indices = Array(fit.firstIndex...max(fit.firstIndex, fit.lastIndex))
        func score(_ intercept: Double) -> Double {
            indices.reduce(0) { $0 + Double(onset.value(at: intercept + fit.period * Double($1))) }
        }
        if halfBeatRatio > 0, score(fit.intercept + fit.period / 2) > score(fit.intercept) * halfBeatRatio {
            fit.intercept += fit.period / 2
        }
        let base = fit.intercept
        var best = base, bestScore = score(base)
        for step in -50...50 {
            let candidate = base + Double(step) * 0.0005
            let value = score(candidate)
            if value > bestScore { best = candidate; bestScore = value }
        }
        fit.intercept = best
        return fit
    }

    // MARK: - 템포 범위 · 1박

    /// 범위 밖 템포를 두 배·절반으로 옮긴다. 절반으로 줄일 때는 마디 시작에 더 잘 맞는 쪽 박을 남긴다.
    static func normalizeTempo(_ fit: Fit, range: ClosedRange<Double>, bars: [Double]) -> Fit {
        var fit = fit
        while 60 / fit.period < range.lowerBound, 120 / fit.period <= range.upperBound {
            fit.period /= 2
            fit.points = fit.points.map { Point(index: $0.index * 2, time: $0.time) }
            fit.intercept = fit.points.first.map { $0.time - fit.period * Double($0.index) } ?? fit.intercept
            if let refit = robustFit(fit.points) { fit = refit }
        }
        while 60 / fit.period > range.upperBound, 30 / fit.period >= range.lowerBound {
            // 짝수·홀수 번째 박 중 마디 시작과 더 가까운 쪽을 남긴다.
            let even = fit.points.filter { $0.index % 2 == 0 }, odd = fit.points.filter { $0.index % 2 != 0 }
            let keepOdd = barDistance(odd, bars: bars) < barDistance(even, bars: bars)
            let shift = keepOdd ? 1 : 0
            let kept = keepOdd ? odd : even
            let halved = kept.map { Point(index: ($0.index - shift) / 2, time: $0.time) }
            guard let refit = robustFit(halved) else { break }
            fit = refit
        }
        return fit
    }

    static func barDistance(_ points: [Point], bars: [Double]) -> Double {
        guard !bars.isEmpty, !points.isEmpty else { return .infinity }
        let times = points.map(\.time)
        return bars.reduce(0) { sum, bar in
            sum + (times.map { abs($0 - bar) }.min() ?? 1)
        }
    }

    /// 구간 첫 박의 박 번호(1~4)와 다수결 표(이긴 표, 전체 표).
    static func downbeat(_ fit: Fit, bars: [Double]) -> (Int, Int, Int) {
        let from = fit.time(at: fit.firstIndex) - fit.period / 2
        let to = fit.time(at: fit.lastIndex) + fit.period / 2
        var votes = [0, 0, 0, 0]
        for bar in bars where bar >= from && bar <= to {
            let k = Int(((bar - fit.intercept) / fit.period).rounded())
            // 마디 시작이 박에서 반 박 가까이 벗어나 있으면 표로 치지 않는다.
            guard abs(bar - fit.time(at: k)) <= fit.period * 0.25 else { continue }
            votes[((k - fit.firstIndex) % 4 + 4) % 4] += 1
        }
        let total = votes.reduce(0, +)
        guard total > 0, let winner = votes.indices.max(by: { votes[$0] < votes[$1] }) else { return (1, 0, 0) }
        // winner번째 박이 1박이면 첫 박은 (4 - winner) % 4 + 1번
        return ((4 - winner) % 4 + 1, votes[winner], total)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
