import Foundation

/// 편집 창 한 줄(원곡·결과)의 보이는 자리(#134): 줄 전체 중 창 폭에 보이는 구간. 확대·가로 스크롤·재생선 따라가기.
///
/// 보이는 길이(초)를 들고 있어 결과가 늘거나 줄어도 마디 폭이 그대로다. 줄이 짧아져 밖을 보게 되면 읽을 때 줄 안으로 당긴다.
public struct EditViewport: Sendable, Equatable {
    /// 창 폭에 보이는 길이(초). nil이면 줄 전체를 폭에 맞춘다.
    public private(set) var span: Double?
    /// 보이는 구간의 왼쪽 끝(초)
    public private(set) var start: Double

    public init() {
        span = nil
        start = 0
    }

    /// 줄 길이에 맞춘 보이는 구간
    public func visible(length: Double) -> ClosedRange<Double> {
        let length = max(length, 0)
        let span = min(max(self.span ?? length, 0), length)
        let start = min(max(self.start, 0), length - span)
        return start...(start + span)
    }

    /// 배율(1 = 줄 전체)
    public func scale(length: Double) -> Double {
        let visible = visible(length: length)
        let span = visible.upperBound - visible.lowerBound
        return span > 0 ? length / span : 1
    }

    public func isZoomed(length: Double) -> Bool { scale(length: length) > 1 + 1e-9 }

    /// 시각 → 줄 안 가로 위치(폭 `width`)
    public func x(of time: Double, width: Double, length: Double) -> Double {
        let visible = visible(length: length)
        let span = visible.upperBound - visible.lowerBound
        return span > 0 ? (time - visible.lowerBound) / span * width : 0
    }

    /// 줄 안 가로 위치 → 시각. 줄 밖도 그대로 잇는다(끌기가 줄 밖으로 나가도 계속 센다).
    public func time(atX x: Double, width: Double, length: Double) -> Double {
        let visible = visible(length: length)
        return visible.lowerBound + x / max(width, 1) * (visible.upperBound - visible.lowerBound)
    }

    /// `anchor`(초) 자리를 화면에서 그대로 두고 `factor`배 확대한다(1보다 작으면 축소).
    /// 보이는 길이는 `minimumSpan`에서 멈추고, 줄보다 넓히면 줄 전체로 돌아간다.
    public mutating func zoom(by factor: Double, around anchor: Double, length: Double, minimumSpan: Double) {
        let visible = visible(length: length)
        let span = visible.upperBound - visible.lowerBound
        guard length > 0, span > 0, factor > 0, factor.isFinite else { return }
        let next = min(max(span / factor, min(minimumSpan, length)), length)
        guard next < length - 1e-9 else { fit(); return }
        let fraction = min(max((anchor - visible.lowerBound) / span, 0), 1)
        self.span = next
        start = min(max(anchor - fraction * next, 0), length - next)
    }

    public mutating func fit() {
        span = nil
        start = 0
    }

    /// 보이는 자리를 `seconds`만큼 옮긴다. 줄 끝에서 멈춘다.
    public mutating func scroll(by seconds: Double, length: Double) {
        scroll(to: visible(length: length).lowerBound + seconds, length: length)
    }

    /// 왼쪽 끝을 `time`에 둔다(스크롤 막대).
    public mutating func scroll(to time: Double, length: Double) {
        guard span != nil else { return }
        let visible = visible(length: length)
        start = min(max(time, 0), length - (visible.upperBound - visible.lowerBound))
    }

    /// 시각이 보이지 않으면 넘긴다: 오른쪽 밖이면 왼쪽 10% 자리에(재생을 따라 다음 쪽으로), 왼쪽 밖이면 오른쪽 90% 자리에.
    public mutating func reveal(_ time: Double, length: Double) {
        let visible = visible(length: length)
        let span = visible.upperBound - visible.lowerBound
        guard self.span != nil, span < length else { return }
        if time > visible.upperBound {
            scroll(to: time - span * 0.1, length: length)
        } else if time < visible.lowerBound {
            scroll(to: time - span * 0.9, length: length)
        }
    }
}
