import AppKit
import SwiftUI

/// 이 자리의 AppKit 뷰를 알려 준다(떼어 둔 화면 안에서도 창 좌표로 마우스 위치를 확인하려고).
struct HitProbe: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        onView(view)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 개발용 자가 테스트가 창 안에서 컨트롤 위치를 찾게 이름 붙인 자리(SwiftUI 버튼은 NSView가 아니다).
@MainActor
enum SelfTestFrames {
    /// 이름 → 창 좌표 사각형(`.global`, 위 왼쪽 원점)
    static var frames: [String: CGRect] = [:]
}

extension View {
    /// 디버그 빌드에서만 자리를 기록한다(릴리스에서는 아무것도 하지 않는다).
    @ViewBuilder func selfTestFrame(_ name: String) -> some View {
        #if DEBUG
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SelfTestFrames.frames[name] = $0 }
        #else
        self
        #endif
    }
}
