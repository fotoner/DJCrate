import Foundation

/// 재생 조각: 재생 노드 샘플 `node`부터 곡 프레임 `frame`을 낸다. `loop`가 있으면 그 길이(프레임)로 되풀이한다.
public struct PlaybackPiece: Equatable, Sendable {
    public var node: Int64
    public var frame: Int64
    public var loop: Int64?

    public init(node: Int64, frame: Int64, loop: Int64?) {
        self.node = node
        self.frame = frame
        self.loop = loop
    }
}

/// 한 번의 재생(재생 노드에 예약한 조각들)을 시간으로 옮긴다.
///
/// - 노드 샘플: 재생 노드가 낸 샘플 수(0부터).
/// - 직선 시간: 재생을 시작한 곡 위치에서 곡 속도로 쭉 흘러가는 시간(루프가 없으면 곡 위치와 같다). 메트로놈 클릭을 이 축에 예약한다.
/// - 곡 위치: rekordbox 시간축(음원 시각 + `timelineOffset`).
public struct PlaybackSchedule: Sendable {
    public var sampleRate: Double
    public var timelineOffset: Double
    /// 재생을 시작한 직선 시간(= 그때의 곡 위치)
    public var startLinear: Double
    /// 곡 앞 지연 구간에서 시작했을 때 재생 노드가 늦게 시작한 만큼(프레임)
    public var leadInFrames: Int64
    public var pieces: [PlaybackPiece]

    public init(sampleRate: Double, timelineOffset: Double, startLinear: Double, leadInFrames: Int64 = 0, pieces: [PlaybackPiece]) {
        self.sampleRate = sampleRate
        self.timelineOffset = timelineOffset
        self.startLinear = startLinear
        self.leadInFrames = leadInFrames
        self.pieces = pieces
    }

    public func linear(ofNode node: Double) -> Double {
        startLinear + (node + Double(leadInFrames)) / sampleRate
    }

    public func node(ofLinear linear: Double) -> Double {
        (linear - startLinear) * sampleRate - Double(leadInFrames)
    }

    /// 재생 노드 샘플 → 곡 위치(초)
    public func songPosition(atNode node: Double) -> Double {
        guard let piece = pieces.last(where: { Double($0.node) <= node }) ?? pieces.first else {
            return linear(ofNode: node)
        }
        var offset = node - Double(piece.node)
        if let loop = piece.loop, loop > 0, offset >= 0 { offset = offset.truncatingRemainder(dividingBy: Double(loop)) }
        return (Double(piece.frame) + offset) / sampleRate + timelineOffset
    }

    public struct Click: Equatable, Sendable {
        /// 직선 시간
        public var linear: Double
        public var downbeat: Bool
    }

    /// 직선 시간 `[range.lowerBound, range.upperBound)` 안에서 칠 박. 반열린 구간이라 이어지는 창으로 나눠 물어도
    /// 박이 빠지거나 두 번 나오지 않는다(예전에는 창 사이에 0.5ms 틈이 있어 가끔 클릭이 씹혔다).
    public func clicks(in range: Range<Double>, grid: BeatGrid) -> [Click] {
        guard !range.isEmpty, !pieces.isEmpty else { return [] }
        var result: [Click] = []
        for (i, piece) in pieces.enumerated() {
            // 첫 조각은 곡 앞 지연 구간(재생 시작 ~ 노드 0)까지 포함한다.
            let pieceStart = i == 0 ? startLinear : linear(ofNode: Double(piece.node))
            let pieceEnd = i + 1 < pieces.count ? linear(ofNode: Double(pieces[i + 1].node)) : .infinity
            let lo = max(range.lowerBound, pieceStart), hi = min(range.upperBound, pieceEnd)
            guard lo < hi else { continue }
            let pieceSong = Double(piece.frame) / sampleRate + timelineOffset
            // 조각 첫 샘플의 직선 시간
            let origin = linear(ofNode: Double(piece.node))
            if let loop = piece.loop, loop > 0 {
                let length = Double(loop) / sampleRate
                var turn = max(0, ((lo - origin) / length).rounded(.down))
                while origin + turn * length < hi {
                    let turnStart = origin + turn * length
                    var index = grid.firstIndex(atOrAfter: pieceSong - 0.0005)
                    // 루프 끝 박은 다음 바퀴의 첫 박과 같은 자리라 넣지 않는다.
                    while index < grid.beats.count, grid.beats[index].time < pieceSong + length - 0.0005 {
                        let t = turnStart + (grid.beats[index].time - pieceSong)
                        if t >= lo, t < hi { result.append(Click(linear: t, downbeat: grid.beats[index].isDownbeat)) }
                        index += 1
                    }
                    turn += 1
                }
            } else {
                var index = grid.firstIndex(atOrAfter: pieceSong + (lo - origin) - 0.001)
                while index < grid.beats.count {
                    let t = origin + (grid.beats[index].time - pieceSong)
                    if t >= hi { break }
                    if t >= lo { result.append(Click(linear: t, downbeat: grid.beats[index].isDownbeat)) }
                    index += 1
                }
            }
        }
        return result.sorted { $0.linear < $1.linear }
    }
}
