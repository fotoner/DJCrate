import Foundation

/// 앱 안 글자 배율(보기 › 글자 크게·작게, ⌘+/⌘−). macOS는 Dynamic Type을 지원하지 않아 앱이 직접 키운다.
/// 1배 밑으로는 내리지 않는다: 가장 작은 글자(10pt)가 macOS 최소 글자 크기보다 작아지지 않게.
public enum TextScale {
    /// 한 번에 한 단계씩 움직인다. 저장된 값도 이 가운데 가장 가까운 값으로 읽는다.
    public static let steps: [Double] = [1, 1.15, 1.3, 1.5]
    /// macOS 최소 글자 크기(HIG Typography)
    public static let minimumPointSize = 10.0

    /// 가장 가까운 단계. 수가 아니면 1배.
    public static func nearest(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return steps.min { abs($0 - value) < abs($1 - value) } ?? 1
    }

    /// 한 단계 키우거나(+1) 줄인다(−1). 끝에서는 그대로다.
    public static func stepped(_ scale: Double, by direction: Int) -> Double {
        let next = direction > 0 ? steps.first { $0 > scale + 0.001 } : steps.last { $0 < scale - 0.001 }
        return next ?? nearest(scale)
    }

    public static func canStep(_ scale: Double, by direction: Int) -> Bool {
        direction > 0 ? scale < steps[steps.count - 1] - 0.001 : scale > steps[0] + 0.001
    }

    /// 글자 크기: 기준 pt × 배율(0.5pt 단위), 최소 10pt
    public static func pointSize(_ base: Double, scale: Double) -> Double {
        max(minimumPointSize, (base * scale * 2).rounded() / 2)
    }

    /// 줄 높이·칸 크기: 기준 pt × 배율(정수 pt)
    public static func length(_ base: Double, scale: Double) -> Double {
        (base * scale).rounded()
    }

    /// 컨트롤 크기를 몇 단계 키울지. 작은 컨트롤 글자(11pt)는 1.3배부터 보통 컨트롤(13pt)이 더 가깝다.
    public static func controlSizeBoost(_ scale: Double) -> Int {
        scale >= 1.3 - 0.001 ? 1 : 0
    }
}
