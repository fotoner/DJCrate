import Foundation

/// 재생 중에 루프를 걸기·바꾸기·풀 때, 재생 노드에 예약할 버퍼와 새 조각을 정한다(샘플 단위로 이어지게).
///
/// AVAudioPlayerNode 오프라인 렌더 실험(2026-09-26)으로 확인한 제약을 따른다:
/// - 시각을 정한 `interrupts` 예약은 이미 그린 곳보다 앞서야 한다 → `ahead`(지금 + 여유)보다 뒤에 둔다.
///   그러면 되풀이(`loops`) 버퍼도 바퀴 중간에서 샘플 단위로 끊긴다(렌더 블록 441·512·1024 모두).
/// - `interrupts` 버퍼 뒤에 시각 없이 줄 세운 버퍼는 지워진다 → 이어 붙이는 버퍼도 모두 시각을 정한다.
///
/// 동작은 CDJ를 따른다: 나가기는 이번 바퀴를 끝까지 흘려보내고 곡으로, 늘리기는 옛 끝에서 새 끝까지 이어 가고,
/// 줄이기는 바로(이번 바퀴의 새 끝에서, 이미 지났으면 새 길이만큼 뒤로 뛰어) 새 길이가 된다.
public enum LoopPlanner {
    public struct Buffer: Equatable, Sendable {
        /// 곡 프레임 구간(`to`가 nil이면 곡 끝까지)
        public var from: Int64
        public var to: Int64?
        /// 재생 노드 샘플 시각
        public var at: Int64
        public var interrupts: Bool
        public var loops: Bool

        public init(from: Int64, to: Int64?, at: Int64, interrupts: Bool, loops: Bool) {
            self.from = from; self.to = to; self.at = at; self.interrupts = interrupts; self.loops = loops
        }
    }

    public enum Kind: Equatable, Sendable { case engage, resize, exit, none }

    public struct Plan: Equatable, Sendable {
        public var kind: Kind
        public var buffers: [Buffer]
        /// 지금 조각들 뒤에 붙일 조각
        public var pieces: [PlaybackPiece]
    }

    /// - Parameters:
    ///   - now: 재생 노드가 그려 낸 샘플
    ///   - ahead: 예약해도 되는 가장 이른 샘플(`now` + 렌더 여유)
    ///   - loop: 걸 루프(곡 프레임, nil이면 푼다)
    /// - Returns: 계획. nil이면 샘플 단위로 이어 붙일 수 없다(부른 쪽이 지금 위치에서 다시 재생한다).
    public static func plan(pieces: [PlaybackPiece], now: Int64, ahead: Int64, loop: (start: Int64, end: Int64)?) -> Plan? {
        guard let index = pieces.lastIndex(where: { $0.node <= ahead }), index == pieces.count - 1 else { return nil }
        let piece = pieces[index]
        if let oldLength = piece.loop, oldLength > 0 {
            let boundary = piece.node + ((ahead - piece.node) / oldLength + 1) * oldLength
            let oldEnd = piece.frame + oldLength
            guard let loop else {
                // 나가기: 이번 바퀴 끝에서 루프 끝 다음으로
                return Plan(kind: .exit, buffers: [Buffer(from: oldEnd, to: nil, at: boundary, interrupts: true, loops: false)],
                            pieces: [PlaybackPiece(node: boundary, frame: oldEnd, loop: nil)])
            }
            guard loop.start == piece.frame, loop.end - loop.start > 16 else { return nil }
            if loop.end > oldEnd {
                // 늘리기: 옛 끝 → 새 끝을 이어 붙이고 새 루프
                let bodyAt = boundary + (loop.end - oldEnd)
                return Plan(kind: .resize,
                            buffers: [Buffer(from: oldEnd, to: loop.end, at: boundary, interrupts: true, loops: false),
                                      Buffer(from: loop.start, to: loop.end, at: bodyAt, interrupts: false, loops: true)],
                            pieces: [PlaybackPiece(node: boundary, frame: oldEnd, loop: nil),
                                     PlaybackPiece(node: bodyAt, frame: loop.start, loop: loop.end - loop.start)])
            }
            // 줄이기(CDJ처럼 바로): 이번 바퀴에서 아직 새 끝 전이면 그 끝에서 새 길이로 되풀이한다.
            // 새 끝을 이미 지났으면 지금 새 길이의 배수만큼 뒤로 뛰어 박자 위치를 지킨다.
            let newLength = loop.end - loop.start
            let turnStart = boundary - oldLength
            let phase = ahead - turnStart
            if phase <= newLength {
                let at = turnStart + newLength
                return Plan(kind: .resize, buffers: [Buffer(from: loop.start, to: loop.end, at: at, interrupts: true, loops: true)],
                            pieces: [PlaybackPiece(node: at, frame: loop.start, loop: newLength)])
            }
            let offset = phase % newLength
            let bodyAt = ahead + (newLength - offset)
            return Plan(kind: .resize,
                        buffers: [Buffer(from: loop.start + offset, to: loop.end, at: ahead, interrupts: true, loops: false),
                                  Buffer(from: loop.start, to: loop.end, at: bodyAt, interrupts: false, loops: true)],
                        pieces: [PlaybackPiece(node: ahead, frame: loop.start + offset, loop: nil),
                                 PlaybackPiece(node: bodyAt, frame: loop.start, loop: newLength)])
        }
        guard let loop else {
            // 아직 닿지 않은 루프가 예약돼 있으면 다시 재생해 지운다
            return pieces.contains(where: { $0.loop != nil && $0.node > now }) ? nil : Plan(kind: .none, buffers: [], pieces: [])
        }
        // 흐름 중에 걸기: 루프 끝 지점에서 정확히 넘어간다
        let at = piece.node + (loop.end - piece.frame)
        guard loop.end - loop.start > 16, at > ahead else { return nil }
        return Plan(kind: .engage, buffers: [Buffer(from: loop.start, to: loop.end, at: at, interrupts: true, loops: true)],
                    pieces: [PlaybackPiece(node: at, frame: loop.start, loop: loop.end - loop.start)])
    }
}
