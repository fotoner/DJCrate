@testable import DJCDomain
import Testing

@Suite("비트 점프")
struct BeatJumpTests {
    /// 120 BPM(0.5초 간격), 0.5초에서 시작하는 100박(마지막 박 50초). 곡 길이 60초.
    let grid = BeatGrid(beats: (0..<100).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 120, time: 0.5 + Double($0) * 0.5) })
    let duration = 60.0

    func jump(_ time: Double, _ beats: Int, keepsPhase: Bool = false, grid: BeatGrid? = nil) -> Double {
        BeatJump.target(from: time, beats: beats, grid: grid ?? self.grid, duration: duration, keepsPhase: keepsPhase)
    }

    @Test func 박_위에서는_그_박부터_센다() {
        #expect(jump(10, 1) == 10.5)
        #expect(jump(10, -1) == 9.5)
        #expect(jump(10, BeatJump.beatsPerBar) == 12)
        #expect(jump(10, -BeatJump.beatsPerBar) == 8)
    }

    @Test func 박에서_5ms_안이면_박_위로_본다() {
        #expect(jump(10.004, 1) == 10.5)
        #expect(jump(9.996, -1) == 9.5)
    }

    @Test func 박_사이에서는_가까운_쪽_박이_첫_박이다() {
        // 멈춰 있을 때: 박에 붙인다(그 자리에 큐를 찍을 수 있게)
        #expect(jump(10.2, 1) == 10.5)
        #expect(jump(10.2, -1) == 10)
        #expect(jump(10.2, BeatJump.beatsPerBar) == 12)
        #expect(jump(10.2, -BeatJump.beatsPerBar) == 8.5)
    }

    @Test func 재생_중에는_박_안의_위치를_지킨다() {
        // CDJ 비트 점프처럼 박자가 끊기지 않게 정확히 1박·1마디만큼
        #expect(abs(jump(10.2, 1, keepsPhase: true) - 10.7) < 1e-9)
        #expect(abs(jump(10.2, -1, keepsPhase: true) - 9.7) < 1e-9)
        #expect(abs(jump(10.2, BeatJump.beatsPerBar, keepsPhase: true) - 12.2) < 1e-9)
        #expect(jump(10, 1, keepsPhase: true) == 10.5)
    }

    @Test func 재생_중_템포가_바뀌어도_박_안의_비율을_지킨다() {
        // 1초까지 120 BPM, 그 뒤 60 BPM(1초 간격)
        let changing = BeatGrid(beats: [
            .init(number: 1, bpm: 120, time: 0), .init(number: 2, bpm: 120, time: 0.5),
            .init(number: 3, bpm: 60, time: 1), .init(number: 4, bpm: 60, time: 2), .init(number: 1, bpm: 60, time: 3),
        ])
        // 0.25초 = 첫 박의 절반 → 다음 박(0.5~1)의 절반 = 0.75, 두 박 뒤(1~2)의 절반 = 1.5
        #expect(abs(jump(0.25, 1, keepsPhase: true, grid: changing) - 0.75) < 1e-9)
        #expect(abs(jump(0.25, 2, keepsPhase: true, grid: changing) - 1.5) < 1e-9)
        // 마지막 박 뒤는 그 박의 BPM으로 한 박
        #expect(abs(jump(3.5, 1, keepsPhase: true, grid: changing) - 4.5) < 1e-9)
    }

    @Test func 첫_박_앞으로_넘으면_첫_박_거기서_더_가면_곡_처음() {
        #expect(jump(1.0, -4) == 0.5, "첫 박을 넘기면 첫 박에서 멈춘다")
        #expect(jump(0.5, -1) == 0, "첫 박에서 앞으로는 곡 처음(첫 박 앞 인트로)")
        #expect(jump(0.3, -1) == 0)
        #expect(jump(0.3, 1) == 0.5, "첫 박 앞에서 뒤로는 첫 박")
        #expect(jump(0.1, -1, keepsPhase: true) == 0)
    }

    @Test func 마지막_박을_넘으면_마지막_박_거기서는_그대로() {
        #expect(jump(49, 4) == 50)
        #expect(jump(50, 1) == 50)
        #expect(jump(55, 1) == 55)
        #expect(jump(55, -1) == 50)
    }

    @Test func 그리드가_없으면_박당_0점5초_곡_안에서() {
        #expect(BeatJump.target(from: 10, beats: 1, grid: nil, duration: duration, keepsPhase: false) == 10.5)
        #expect(BeatJump.target(from: 10, beats: -BeatJump.beatsPerBar, grid: nil, duration: duration, keepsPhase: true) == 8)
        #expect(BeatJump.target(from: 0.2, beats: -1, grid: nil, duration: duration, keepsPhase: false) == 0)
        #expect(BeatJump.target(from: 59.8, beats: 1, grid: nil, duration: duration, keepsPhase: false) == 60)
        let empty = BeatGrid(beats: [])
        #expect(BeatJump.target(from: 10, beats: 1, grid: empty, duration: duration, keepsPhase: false) == 10.5)
    }

    @Test func 영_박은_제자리() {
        #expect(jump(10.2, 0) == 10.2)
        #expect(jump(10.2, 0, keepsPhase: true) == 10.2)
    }
}
