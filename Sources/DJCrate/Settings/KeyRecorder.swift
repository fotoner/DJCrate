import AppKit
import SwiftUI

/// 키를 기다리는 동안 첫 응답자가 되어 키 하나를 받는다(키 코드와 조합 키). Esc나 다른 곳을 누르면 취소.
/// ⌘ 조합은 메뉴가 먼저 받는다(설정 창을 닫는 ⌘W 등이 그대로 동작한다).
struct KeyRecorder: NSViewRepresentable {
    var onKey: (UInt16, NSEvent.ModifierFlags) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onKey = onKey
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onKey = onKey
        view.onCancel = onCancel
    }

    final class CaptureView: NSView {
        var onKey: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // 뷰를 붙이는 중에 응답자를 바꾸면 SwiftUI 갱신과 겹친다. 다음 차례에 잡는다.
            Task { @MainActor [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {   // Esc
                onCancel?()
            } else {
                onKey?(event.keyCode, event.modifierFlags)
            }
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                let cancel = onCancel
                Task { @MainActor in cancel?() }
            }
            return resigned
        }
    }
}
