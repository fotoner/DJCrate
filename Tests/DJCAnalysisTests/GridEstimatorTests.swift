import DJCDomain
@testable import DJCAnalysis
import Foundation
import Testing

@Suite("그리드 추정")
struct GridEstimatorTests {
    /// 고정 BPM 박에 결정적 흔들림(±4ms)을 넣고, 몇 박은 빼고, 마디 시작은 `downbeatOffset`번째 박부터 4박마다.
    func beats(bpm: Double, count: Int, start: Double = 0.31, missing: Set<Int> = [], downbeatOffset: Int = 0) -> (beats: [Double], bars: [Double]) {
        let period = 60 / bpm
        var beats: [Double] = [], bars: [Double] = []
        for i in 0..<count where !missing.contains(i) {
            let jitter = Double((i * 37) % 9 - 4) / 1000
            beats.append(start + Double(i) * period + jitter)
        }
        for i in stride(from: downbeatOffset, to: count, by: 4) { bars.append(start + Double(i) * period) }
        return (beats, bars)
    }

    @Test func 고정_템포는_한_구간과_정확한_BPM() throws {
        let input = beats(bpm: 154, count: 400, missing: [50, 51, 200])
        let estimate = try #require(GridEstimator.estimate(beats: input.beats, bars: input.bars, duration: 170))
        #expect(estimate.segments.count == 1)
        #expect(abs(estimate.bpm - 154) < 0.02)
        #expect(estimate.isConfident)
        // 첫 박(0.31초 근처)이 1박
        let grid = GridDraft(trackUUID: "t", base: [], segments: estimate.segments).grid(duration: 170)
        let near = try #require(grid.beats.min { abs($0.time - 0.31) < abs($1.time - 0.31) })
        #expect(abs(near.time - 0.31) < 0.006)
        #expect(near.number == 1)
    }

    @Test func 마디_시작이_셋째_박이면_그_박이_1박() throws {
        let input = beats(bpm: 170, count: 300, downbeatOffset: 2)
        let estimate = try #require(GridEstimator.estimate(beats: input.beats, bars: input.bars, duration: 120))
        let grid = GridDraft(trackUUID: "t", base: [], segments: estimate.segments).grid(duration: 120)
        let third = 0.31 + 2 * 60 / 170
        let beat = try #require(grid.beats.min { abs($0.time - third) < abs($1.time - third) })
        #expect(beat.number == 1)
        #expect(estimate.downbeatConfidence > 0.9)
    }

    @Test func 절반_템포는_두_배로_옮긴다() throws {
        // MU가 178 BPM 곡을 89로 잡은 경우(라이브러리 BPM은 105~215)
        let input = beats(bpm: 89, count: 200)
        let estimate = try #require(GridEstimator.estimate(beats: input.beats, bars: input.bars, duration: 140))
        #expect(abs(estimate.bpm - 178) < 0.05)
    }

    @Test func 템포가_바뀌면_구간을_나눈다() throws {
        let first = beats(bpm: 120, count: 120)
        let switchTime = 0.31 + 120 * 0.5
        let second = beats(bpm: 150, count: 150, start: switchTime)
        let estimate = try #require(GridEstimator.estimate(beats: first.beats + second.beats, bars: first.bars + second.bars, duration: 130))
        #expect(estimate.segments.count == 2)
        #expect(abs(estimate.segments[0].bpm - 120) < 0.05)
        #expect(abs(estimate.segments[1].bpm - 150) < 0.05)
        // 경계 박(60.31초)은 두 템포 모두에 놓이므로 구간 시작은 그 박이나 다음 박일 수 있다. 만들어지는 박으로 본다.
        let grid = GridDraft(trackUUID: "t", base: [], segments: estimate.segments).grid(duration: 130)
        func has(_ time: Double) -> Bool { grid.beats.contains { abs($0.time - time) < 0.006 } }
        #expect(has(switchTime - 0.5) && has(switchTime) && has(switchTime + 0.4) && has(switchTime + 0.8))
        #expect(!has(switchTime + 0.5), "옛 템포 박이 변속 뒤에 남으면 안 된다")
    }

    @Test func 박이_너무_적으면_추정하지_않는다() {
        #expect(GridEstimator.estimate(beats: [0.5, 1.0, 1.5], bars: [], duration: 10) == nil)
    }
}
