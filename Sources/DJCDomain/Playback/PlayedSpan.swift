import Foundation

/// 끊김 없이 들린 곡 구간(rekordbox 시간축, 초). Flip 기록이 모은다.
public struct PlayedSpan: Sendable, Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// 한 번의 재생(재생 노드를 시작해 멈추거나 다시 시작하기까지)에서 들린 구간들(들린 순서).
public struct PlayedRun: Sendable, Equatable {
    public var spans: [PlayedSpan]
    /// 멈추지 않고 다른 자리에서 다시 재생해 끝났다(핫큐·탐색 이동). 다음 재생의 시작이 이 끝에서 넘어간 점프 착지다.
    public var continuing: Bool

    public init(spans: [PlayedSpan], continuing: Bool) {
        self.spans = spans
        self.continuing = continuing
    }
}

public extension PlaybackSchedule {
    /// 재생 노드 샘플 `[from, to)`에서 들린 곡 구간(들린 순서). 루프는 바퀴마다 나누고, 이어지는 구간도 합치지 않는다.
    /// 첫 조각은 곡 앞 지연 구간(재생 시작 ~ 노드 0)부터 센다. 아직 닿지 않은 조각(예약한 점프·루프)은 빠진다.
    func playedSpans(from: Double, to: Double) -> [PlayedSpan] {
        guard to > from else { return [] }
        var spans: [PlayedSpan] = []
        for (index, piece) in pieces.enumerated() {
            let node = Double(piece.node)
            let pieceStart = index == 0 ? node - Double(leadInFrames) : node
            let pieceEnd = index + 1 < pieces.count ? Double(pieces[index + 1].node) : .infinity
            let lo = max(from, pieceStart), hi = min(to, pieceEnd)
            guard lo < hi else { continue }
            func song(_ offset: Double) -> Double { (Double(piece.frame) + offset) / sampleRate + timelineOffset }
            if let loop = piece.loop, loop > 0 {
                let length = Double(loop)
                var turn = node + max(0, ((lo - node) / length).rounded(.down)) * length
                while turn < hi {
                    let a = max(lo, turn), b = min(hi, turn + length)
                    if b > a { spans.append(PlayedSpan(start: song(a - turn), end: song(b - turn))) }
                    turn += length
                }
            } else {
                spans.append(PlayedSpan(start: song(lo - node), end: song(hi - node)))
            }
        }
        return spans
    }
}
