/// 파형을 끄는 스크럽의 기준점(#133). 끈 거리(곡 시간, 초)를 곡 위치로 바꾼다.
/// 끄는 도중 핫큐로 자리를 옮기면 그 자리를 새 기준으로 삼아, 다음 끌기가 옮긴 자리에서 이어진다(끌기 시작 자리로 튀지 않게).
public struct ScrubAnchor: Equatable, Sendable {
    /// 끈 거리 0에 해당하는 곡 위치
    public private(set) var origin: Double
    /// 마지막으로 받은 끈 거리
    public private(set) var offset: Double = 0

    public init(at time: Double) {
        origin = time
    }

    /// 끈 거리 → 곡 위치(곡 길이로 자르는 것은 부른 쪽)
    public mutating func position(dragged offset: Double) -> Double {
        self.offset = offset
        return origin + offset
    }

    /// 끄는 도중 `time`으로 옮겼다: 지금 끈 거리에서 그 자리가 되도록 기준을 옮긴다.
    public mutating func move(to time: Double) {
        origin = time - offset
    }
}
