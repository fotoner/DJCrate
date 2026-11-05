import AppKit
import DJCDomain

/// 켜진 채 종료 시트(#326)를 AppKit 경고창으로 띄운다. 내용과 문구는 DJCDomain `QuitConfirmation`이 정한다.
/// 단추는 [취소](기본, Return·Esc)와 [그냥 종료]다. 편집은 DJCrate에 남으므로 종료해도 잃는 것은 없지만, 한 번 멈춰 rekordbox를 끌 기회를 준다.
/// 주 창에 시트로 붙이고, 붙일 창이 없거나 이미 다른 시트가 붙어 있으면 앱 전체 경고창으로 띄운다.
@MainActor
enum QuitConfirmationAlert {
    static func makeAlert(_ confirmation: QuitConfirmation) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: QuitConfirmation.cancelTitle)
        alert.addButton(withTitle: QuitConfirmation.quitAnywayTitle)
        return alert
    }

    static func isQuitAnyway(_ response: NSApplication.ModalResponse) -> Bool { response == .alertSecondButtonReturn }

    /// 시트를 띄운다. 답은 지금 이벤트 처리가 끝난 뒤에 온다(종료 요청 안에서 다시 종료를 요청하지 않게)
    static func present(_ confirmation: QuitConfirmation, completion: @escaping @MainActor (Bool) -> Void) {
        let alert = makeAlert(confirmation)
        let window = NSApp.windows.first { $0.isMainWindow && $0.isVisible } ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { response in
                Task { @MainActor in completion(isQuitAnyway(response)) }
            }
        } else {
            Task { @MainActor in completion(isQuitAnyway(alert.runModal())) }
        }
    }
}
