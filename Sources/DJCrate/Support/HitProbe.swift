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
    /// `clearsOnDisappear`면 뷰가 사라질 때 그 자리를 지운다(폭에 따라 나타났다 사라지는 뷰가 옛 자리를 남기지 않게).
    /// 환경 값 `selfTestFrameScope`를 주면 그 글자를 이름 앞에 붙여 기록한다. 같은 화면을 여럿 띄워 따로 재는 시험이 쓴다.
    @ViewBuilder func selfTestFrame(_ name: String, clearsOnDisappear: Bool = false) -> some View {
        #if DEBUG
        modifier(SelfTestFrameModifier(name: name, clearsOnDisappear: clearsOnDisappear))
        #else
        self
        #endif
    }
}

#if DEBUG
extension EnvironmentValues {
    /// 자리 이름 앞에 붙일 글자. 비어 있으면 이름 그대로 기록한다
    @Entry var selfTestFrameScope = ""
}

private struct SelfTestFrameModifier: ViewModifier {
    @Environment(\.selfTestFrameScope) private var scope
    let name: String
    let clearsOnDisappear: Bool

    /// 이름과 자리를 함께 비교해, 자리는 그대로이고 이름만 바뀐 뷰도 새 이름으로 기록한다
    private struct NamedFrame: Equatable {
        var key: String
        var rect: CGRect
    }

    func body(content: Content) -> some View {
        let key = scope + name
        return content
            .onGeometryChange(for: NamedFrame.self) { NamedFrame(key: key, rect: $0.frame(in: .global)) } action: {
                SelfTestFrames.frames[$0.key] = $0.rect
            }
            .onDisappear { if clearsOnDisappear { SelfTestFrames.frames[scope + name] = nil } }
            // 같은 자리의 뷰가 이름만 바꿀 수 있다(줄인 칩의 글이 「BPM 120–130 외 5」에서 「… 외 2」로). 옛 이름의 자리는 지운다
            .onChange(of: name) { old, _ in if clearsOnDisappear { SelfTestFrames.frames[scope + old] = nil } }
    }
}
#endif
