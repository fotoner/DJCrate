import SwiftUI

#if DEBUG
/// 하위 뷰에 같은 제안 크기를 넘기는 진단 경계. SwiftUI 측정·배치의 포함 시간을 따로 기록한다.
private struct PerfMeasuredLayout: Layout {
    let name: String

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard Thread.isMainThread else { return subviews[0].sizeThatFits(proposal) }
        return MainActor.assumeIsolated { PerfProbe.measure("\(name).size") { subviews[0].sizeThatFits(proposal) } }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard Thread.isMainThread else {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
            return
        }
        MainActor.assumeIsolated { PerfProbe.measure("\(name).place") { subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal) } }
    }
}
#endif

extension View {
    @ViewBuilder func perfMeasuredLayout(_ name: String) -> some View {
        #if DEBUG
        if PerfProbe.enabled { PerfMeasuredLayout(name: name) { self } }
        else { self }
        #else
        self
        #endif
    }
}
