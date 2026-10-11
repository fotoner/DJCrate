import Foundation

/// Flip 기록: 재생하며 쓴 점프(핫큐·메모리 큐·탐색 이동)와 루프 되풀이만 모아, 원곡 처음부터 끝까지 이어 듣는 경로로 만든다.
///
/// 재생을 어디서 시작했는지는 보지 않는다. 경로는 곡 시작(0초)에서 시작해 첫 점프 출발점에서 끊고 착지점에서 잇는 식으로
/// 점프마다 끊어 이어지고, 마지막 착지점부터 곡 끝까지 간다. 멈췄다가 다른 자리에서 다시 재생한 것은 점프가 아니다.
/// 다시 재생한 자리가 경로의 마지막 착지점보다 앞이면 그 자리가 든 가장 최근 경로 구간부터 다시 쓴다(그 뒤 점프는 버린다).
public struct FlipRecording: Sendable, Equatable {
    /// 경로 한 칸(원곡 구간). 마지막 칸은 끝이 열려 있다(곡 끝까지).
    public struct Segment: Sendable, Equatable {
        public var start: Double
        public var end: Double?

        public init(start: Double, end: Double?) {
            self.start = start
            self.end = end
        }
    }

    /// 이만큼 안쪽 차이는 같은 자리로 본다(다시 재생할 때의 µs 어긋남·프레임 반올림)
    public static let tolerance = 0.001

    public private(set) var path: [Segment] = [Segment(start: 0, end: nil)]
    /// 마지막 재생이 들린 끝
    private var lastEnd: Double?
    /// 앞 재생이 멈추지 않고 다시 재생으로 끝났다: 다음 재생 시작이 `lastEnd`에서 넘어간 착지다.
    private var linked = false

    public init() {}

    /// 경로에 남은 점프 수(루프 되풀이 한 바퀴도 하나)
    public var jumpCount: Int { path.count - 1 }

    /// 점프가 하나라도 있는지(없으면 원곡과 같다)
    public var isEmpty: Bool { path.count < 2 }

    /// 재생 한 번을 더한다: 재생 안의 점프(조각 사이 끊김·루프 되풀이)와, 이어진 재생이면 앞 재생 끝에서 넘어온 점프.
    public mutating func record(_ run: PlayedRun) {
        guard let first = run.spans.first, let last = run.spans.last else {
            if !run.continuing { linked = false }
            return
        }
        if linked, let lastEnd { jump(from: lastEnd, to: first.start) }
        for (before, after) in zip(run.spans, run.spans.dropFirst()) { jump(from: before.end, to: after.start) }
        lastEnd = last.end
        linked = run.continuing
    }

    /// 재생 중에 끌기로 멈췄다가 손을 떼 다시 재생할 때: 다음 재생 시작을 점프 착지로 본다.
    public mutating func linkNextRun() {
        linked = lastEnd != nil
    }

    /// 다시 재생하지 못했을 때(곡 끝·출력 장치): 다음 재생은 새로 시작한 재생이다.
    public mutating func breakLink() {
        linked = false
    }

    mutating func jump(from departure: Double, to landing: Double) {
        guard abs(departure - landing) > Self.tolerance else { return }
        // 출발점이 들 수 있는 가장 최근 경로 칸(시작이 출발점 앞). 그 뒤 칸은 앞 자리로 돌아가 다시 쓴 것으로 보고 버린다.
        let index = path.lastIndex { $0.start <= departure + Self.tolerance } ?? 0
        path.removeSubrange((index + 1)...)
        path[index].end = max(path[index].start, departure)
        path.append(Segment(start: max(0, landing), end: nil))
    }
}
