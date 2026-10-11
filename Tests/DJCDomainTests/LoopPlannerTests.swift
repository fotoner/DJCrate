@testable import DJCDomain
import Testing

/// 재생 중 루프 전환 계획(재생 노드에 예약할 버퍼와 새 조각). 44.1kHz, 1초에서 재생 시작.
/// 예약은 렌더보다 앞서야 하고, 시각을 정한 interrupts는 되풀이 버퍼도 바퀴 중간에서 정확히 끊는다(2026-09-26 오프라인 렌더 실험).
@Suite("루프 전환 계획")
struct LoopPlannerTests {
    let sr: Int64 = 44_100
    var straight: [PlaybackPiece] { [PlaybackPiece(node: 0, frame: sr, loop: nil)] }
    /// 2.0~2.5초 루프가 노드 44100(곡 2초)부터 도는 중
    var looping: [PlaybackPiece] { straight + [PlaybackPiece(node: sr, frame: 2 * sr, loop: sr / 2)] }

    @Test func 흐름_중에_걸면_루프_끝_지점에서_넘어간다() throws {
        let plan = try #require(LoopPlanner.plan(pieces: straight, now: 0, ahead: sr / 10, loop: (2 * sr, 5 * sr / 2)))
        #expect(plan.kind == .engage)
        #expect(plan.buffers == [.init(from: 2 * sr, to: 5 * sr / 2, at: 3 * sr / 2, interrupts: true, loops: true)])
        #expect(plan.pieces == [PlaybackPiece(node: 3 * sr / 2, frame: 2 * sr, loop: sr / 2)])
    }

    @Test func 루프_끝을_이미_지났으면_이어_붙일_수_없다() {
        #expect(LoopPlanner.plan(pieces: straight, now: 2 * sr, ahead: 2 * sr, loop: (2 * sr, 5 * sr / 2)) == nil)
    }

    @Test func 나가기는_이번_바퀴_끝에서_곡으로_이어_간다() throws {
        // 세 바퀴째 도는 중(노드 = 44100 + 2바퀴 + 1000)
        let ahead = sr + 2 * (sr / 2) + 1000
        let plan = try #require(LoopPlanner.plan(pieces: looping, now: ahead - 100, ahead: ahead, loop: nil))
        let boundary = sr + 3 * (sr / 2)
        #expect(plan.kind == .exit)
        #expect(plan.buffers == [.init(from: 5 * sr / 2, to: nil, at: boundary, interrupts: true, loops: false)])
        #expect(plan.pieces == [PlaybackPiece(node: boundary, frame: 5 * sr / 2, loop: nil)])
    }

    @Test func 늘리기는_옛_끝에서_새_끝까지_이어_붙이고_새_루프() throws {
        let plan = try #require(LoopPlanner.plan(pieces: looping, now: sr + 100, ahead: sr + 200, loop: (2 * sr, 3 * sr)))
        let boundary = sr + sr / 2
        #expect(plan.kind == .resize)
        #expect(plan.buffers == [.init(from: 5 * sr / 2, to: 3 * sr, at: boundary, interrupts: true, loops: false),
                                 .init(from: 2 * sr, to: 3 * sr, at: boundary + sr / 2, interrupts: false, loops: true)])
        #expect(plan.pieces == [PlaybackPiece(node: boundary, frame: 5 * sr / 2, loop: nil),
                                PlaybackPiece(node: boundary + sr / 2, frame: 2 * sr, loop: sr)])
    }

    @Test func 줄이기는_이번_바퀴의_새_끝에서_바로() throws {
        // 셋째 바퀴(노드 88200부터) 앞쪽 200샘플에서 ½ → 이번 바퀴의 새 끝(88200 + 11025)에서 새 길이로
        let turn = sr + 2 * (sr / 2)
        let plan = try #require(LoopPlanner.plan(pieces: looping, now: turn + 100, ahead: turn + 200, loop: (2 * sr, 9 * sr / 4)))
        #expect(plan.kind == .resize)
        #expect(plan.buffers == [.init(from: 2 * sr, to: 9 * sr / 4, at: turn + sr / 4, interrupts: true, loops: true)])
        #expect(plan.pieces == [PlaybackPiece(node: turn + sr / 4, frame: 2 * sr, loop: sr / 4)])
    }

    @Test func 새_끝을_이미_지났으면_새_길이만큼_뒤로_뛰어_박자를_지킨다() throws {
        // 새 끝보다 1000샘플 뒤에서 ½ → 지금(ahead) 곧바로 루프 시작 + 1000으로, 남은 만큼 뒤 새 루프
        let ahead = sr + sr / 4 + 1000
        let plan = try #require(LoopPlanner.plan(pieces: looping, now: ahead - 100, ahead: ahead, loop: (2 * sr, 9 * sr / 4)))
        #expect(plan.kind == .resize)
        #expect(plan.buffers == [.init(from: 2 * sr + 1000, to: 9 * sr / 4, at: ahead, interrupts: true, loops: false),
                                 .init(from: 2 * sr, to: 9 * sr / 4, at: ahead + sr / 4 - 1000, interrupts: false, loops: true)])
        #expect(plan.pieces == [PlaybackPiece(node: ahead, frame: 2 * sr + 1000, loop: nil),
                                PlaybackPiece(node: ahead + sr / 4 - 1000, frame: 2 * sr, loop: sr / 4)])
    }

    @Test func 새_끝에_딱_닿았으면_바로_새_루프() throws {
        let ahead = sr + sr / 4
        let plan = try #require(LoopPlanner.plan(pieces: looping, now: ahead - 100, ahead: ahead, loop: (2 * sr, 9 * sr / 4)))
        #expect(plan.buffers == [.init(from: 2 * sr, to: 9 * sr / 4, at: ahead, interrupts: true, loops: true)])
    }

    @Test func 시작이_다른_루프로는_바로_못_바꾼다() {
        #expect(LoopPlanner.plan(pieces: looping, now: sr, ahead: sr + 200, loop: (3 * sr, 4 * sr)) == nil)
    }

    @Test func 아직_오지_않은_조각이_있으면_다시_재생한다() {
        // 루프 조각(노드 44100)이 아직 앞에 있다 → 계획 못 함
        #expect(LoopPlanner.plan(pieces: looping, now: 100, ahead: 200, loop: nil) == nil)
    }

    @Test func 걸린_루프가_없으면_할_일이_없다() throws {
        let plan = try #require(LoopPlanner.plan(pieces: straight, now: 100, ahead: 200, loop: nil))
        #expect(plan.kind == .none && plan.buffers.isEmpty && plan.pieces.isEmpty)
    }

    @Test func 너무_짧은_루프는_이어_붙이지_않는다() {
        #expect(LoopPlanner.plan(pieces: straight, now: 0, ahead: 100, loop: (2 * sr, 2 * sr + 10)) == nil)
    }
}
