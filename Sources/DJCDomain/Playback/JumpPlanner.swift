import Foundation

/// 재생 퀀타이즈 핫큐(`PlayQuantize`)를 재생 노드에 예약할 버퍼와 새 조각을 정한다(점프가 샘플 단위로 경계에 맞게).
///
/// `LoopPlanner`와 같은 제약을 따른다: 시각을 정한 `interrupts` 버퍼를 `ahead`(렌더 여유)보다 뒤에 두면
/// 지금 흐르는(되풀이 중인) 버퍼를 그 샘플에서 끊고 넘어간다. 나중에 예약한 `interrupts` 버퍼는 그 시각에
/// 앞서 예약한 미래 버퍼(아직 넘어가지 않은 점프·루프 몸통)를 모두 지우고, 같은 시각이면 나중 것이 이긴다
/// (2026-09-27 오프라인 렌더 실험). 그래서 넘어가기 전에 다른 핫큐를 눌러도 새 점프만 다시 예약하면 된다.
public enum JumpPlanner {
    /// 이미 렌더한 지점에서 출력 버퍼 두 개만큼 앞에 예약한다. 출력 프레임을 곡의 샘플레이트·속도로 바꾼다.
    public static func renderLeadFrames(bufferFrames: UInt32, outputSampleRate: Double, sampleRate: Double, rate: Double) -> Int64 {
        Int64((Double(bufferFrames) * 2 * sampleRate / outputSampleRate * rate).rounded(.up))
    }

    public struct Plan: Equatable, Sendable {
        /// 넘어가는 곡 위치와 착지 곡 위치
        public var jump: PlayQuantize.Jump
        public var buffers: [LoopPlanner.Buffer]
        /// 새 조각 전체(점프 뒤에 있던 조각은 지워진다)
        public var pieces: [PlaybackPiece]
    }

    /// - Parameters:
    ///   - schedule: 지금 재생(조각·샘플레이트·시간축 차이)
    ///   - ahead: 예약해도 되는 가장 이른 노드 샘플(지금 + 렌더 여유)
    ///   - cue: 핫큐 위치(곡 위치)
    ///   - loop: 루프 핫큐면 그 구간(곡 위치). 착지 뒤 루프 끝까지 흘리고 되풀이한다.
    ///   - frameCount: 곡 길이(프레임)
    /// - Returns: 계획. nil이면 샘플 단위로 예약할 수 없다(부른 쪽이 화면 틱으로 넘긴다).
    public static func plan(schedule: PlaybackSchedule, ahead: Int64, quantize: PlayQuantize, cue: Double,
                            loop: ClosedRange<Double>?, frameCount: Int64) -> Plan? {
        let pieces = schedule.pieces
        guard let first = pieces.lastIndex(where: { $0.node <= ahead }) else { return nil }
        func seconds(_ frame: Int64) -> Double { Double(frame) / schedule.sampleRate + schedule.timelineOffset }
        func frame(_ time: Double) -> Int64 { Int64(((time - schedule.timelineOffset) * schedule.sampleRate).rounded()) }

        // 지금 조각부터 차례로 보며 `ahead` 뒤 첫 경계가 흐르는 노드 샘플을 찾는다.
        var found: (node: Int64, time: Double, phase: Double)?
        var start = ahead
        for index in first..<pieces.count where found == nil {
            let piece = pieces[index]
            // 다음 조각이 시작하는 샘플(그 샘플에 딱 닿는 경계는 이 조각 흐름으로 본다)
            let end = index + 1 < pieces.count ? pieces[index + 1].node : Int64.max
            if let length = piece.loop, length > 0 {
                let offset = (start - piece.node) % length
                let loopEnd = piece.frame + length
                let here = quantize.boundary(atOrAfter: seconds(piece.frame + offset))
                if frame(here.time) < loopEnd {
                    found = (start + frame(here.time) - (piece.frame + offset), here.time, here.phase)
                } else {
                    // 이번 바퀴에 경계가 없으면 다음 바퀴에서. 루프 안에 경계가 아예 없으면 바퀴가 끝날 때 큐로.
                    let turn = start + (length - offset)
                    let next = quantize.boundary(atOrAfter: seconds(piece.frame))
                    found = frame(next.time) < loopEnd ? (turn + frame(next.time) - piece.frame, next.time, next.phase)
                        : (turn, seconds(piece.frame), 0)
                }
                if let candidate = found, candidate.node > end { found = nil }
            } else {
                let from = piece.frame + (start - piece.node)
                let here = quantize.boundary(atOrAfter: seconds(from))
                let boundaryFrame = frame(here.time)
                guard boundaryFrame < frameCount else { return nil }
                let node = start + boundaryFrame - from
                if node <= end { found = (node, here.time, here.phase) }
            }
            start = end
        }
        guard let found else { return nil }

        let landing = quantize.landing(cue: cue, phase: found.phase, loopEnd: loop?.upperBound)
        let landingFrame = frame(landing)
        guard landingFrame >= 0, landingFrame < frameCount else { return nil }
        let jump = PlayQuantize.Jump(at: found.time, to: landing)
        var kept = pieces.filter { $0.node < found.node }
        guard let loop else {
            kept.append(PlaybackPiece(node: found.node, frame: landingFrame, loop: nil))
            return Plan(jump: jump, buffers: [.init(from: landingFrame, to: nil, at: found.node, interrupts: true, loops: false)], pieces: kept)
        }
        let loopStart = frame(loop.lowerBound), loopEnd = frame(loop.upperBound)
        guard loopEnd - loopStart > 16, loopEnd <= frameCount else { return nil }
        if landingFrame == loopStart {
            kept.append(PlaybackPiece(node: found.node, frame: loopStart, loop: loopEnd - loopStart))
            return Plan(jump: jump, buffers: [.init(from: loopStart, to: loopEnd, at: found.node, interrupts: true, loops: true)], pieces: kept)
        }
        // 착지 → 루프 끝, 그다음 루프 되풀이(샘플 단위로 이어진다)
        let bodyAt = found.node + (loopEnd - landingFrame)
        kept += [PlaybackPiece(node: found.node, frame: landingFrame, loop: nil), PlaybackPiece(node: bodyAt, frame: loopStart, loop: loopEnd - loopStart)]
        return Plan(jump: jump,
                    buffers: [.init(from: landingFrame, to: loopEnd, at: found.node, interrupts: true, loops: false),
                              .init(from: loopStart, to: loopEnd, at: bodyAt, interrupts: false, loops: true)],
                    pieces: kept)
    }
}
