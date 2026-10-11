@testable import DJCDomain
import Foundation
import Testing

@Suite("재생 조각·메트로놈 계획")
struct PlaybackScheduleTests {
    /// 120 BPM, 0.5초부터 박. 곡 앞 지연 없음.
    let grid = BeatGrid(beats: (0..<400).map { .init(number: $0 % 4 + 1, bpm: 120, time: 0.5 + Double($0) * 0.5) })
    let rate = 44_100.0

    func straight(from position: Double) -> PlaybackSchedule {
        PlaybackSchedule(sampleRate: rate, timelineOffset: 0, startLinear: position,
                         pieces: [PlaybackPiece(node: 0, frame: Int64((position * rate).rounded()), loop: nil)])
    }

    @Test func 이어지는_창으로_나눠_물어도_박이_빠지거나_겹치지_않는다() {
        let schedule = straight(from: 1.0)
        // 창 경계가 박 바로 앞(0.3ms)·박 위·박 바로 뒤에 걸리게 쪼갠다(예전 0.5ms 틈 버그 재현).
        let bounds = [1.0, 1.4997, 2.0, 2.5003, 2.9996, 3.7, 4.4999, 6.0]
        var got: [Double] = []
        for (a, b) in zip(bounds, bounds.dropFirst()) {
            got += schedule.clicks(in: a..<b, grid: grid).map(\.linear)
        }
        let expected = grid.beats.map(\.time).filter { $0 >= 1.0 && $0 < 6.0 }
        #expect(got.count == expected.count)
        for (x, y) in zip(got, expected) { #expect(abs(x - y) < 1e-6) }
    }

    @Test func 루프는_바퀴마다_같은_박을_친다() {
        // 1.0초부터 재생, 2.0초(노드 1초)에 2.0~3.0초 루프 시작
        let start = Int64(1.0 * rate), loopStart = Int64(2.0 * rate), loopLength = Int64(1.0 * rate)
        let schedule = PlaybackSchedule(sampleRate: rate, timelineOffset: 0, startLinear: 1.0, pieces: [
            PlaybackPiece(node: 0, frame: start, loop: nil),
            PlaybackPiece(node: loopStart - start, frame: loopStart, loop: loopLength),
        ])
        let clicks = schedule.clicks(in: 1.0..<5.0, grid: grid).map(\.linear)
        // 직선 시간 1.0~2.0: 곡 1.0, 1.5 / 2.0~5.0: 바퀴마다 곡 2.0, 2.5 (3.0은 다음 바퀴 시작과 같다)
        let expected = [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5]
        #expect(clicks.count == expected.count)
        for (x, y) in zip(clicks, expected) { #expect(abs(x - y) < 1e-6) }
        // 두 번째 바퀴 첫 박의 곡 위치는 루프 시작
        #expect(abs(schedule.songPosition(atNode: Double(3 * Int64(rate) - start + 10)) - (2.0 + 10 / rate)) < 1e-6)
    }

    @Test func 루프_안에서도_창을_쪼개면_빠지지_않는다() {
        let start = Int64(2.0 * rate), loopLength = Int64(0.5 * rate)
        let schedule = PlaybackSchedule(sampleRate: rate, timelineOffset: 0, startLinear: 2.0, pieces: [
            PlaybackPiece(node: 0, frame: start, loop: loopLength),
        ])
        var got: [Double] = []
        let bounds = stride(from: 2.0, through: 6.0, by: 0.0137).map { $0 }
        for (a, b) in zip(bounds, bounds.dropFirst()) { got += schedule.clicks(in: a..<b, grid: grid).map(\.linear) }
        // 0.5초 루프 = 박 하나(2.0) → 바퀴마다 한 번
        let turns = Int(((bounds.last! - 2.0) / 0.5).rounded(.up))
        #expect(got.count == turns)
    }

    @Test func 곡_앞_지연_구간에서_시작해도_곡_위치가_맞다() {
        // rekordbox 시간축이 음원보다 0.05초 늦다(인코더 지연). 0.0초에서 재생 → 음원 0프레임은 노드 0에서 나온다.
        let offset = 0.05
        let schedule = PlaybackSchedule(sampleRate: rate, timelineOffset: offset, startLinear: 0,
                                        leadInFrames: Int64((offset * rate).rounded()),
                                        pieces: [PlaybackPiece(node: 0, frame: 0, loop: nil)])
        #expect(abs(schedule.songPosition(atNode: 0) - offset) < 1e-6)
        #expect(abs(schedule.linear(ofNode: 0) - offset) < 1e-6)
        let clicks = schedule.clicks(in: 0..<1.2, grid: grid).map(\.linear)
        #expect(clicks.count == 2 && abs(clicks[0] - 0.5) < 1e-6)
    }
}
