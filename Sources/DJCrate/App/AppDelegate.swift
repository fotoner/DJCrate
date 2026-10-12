import AppKit
import DJCDomain

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: LibraryStore?
    var inform: (String) -> Void = { message in
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(ui: "확인"))
        alert.runModal()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 외장 디스크를 연결하거나 빼면 파일이 없는 곡을 다시 확인한다(#126).
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let store = self?.store, case .loaded = store.phase else { return }
                    store.checkMissingFiles()
                }
            }
        }
    }

    /// rekordbox·USB에 쓰는 중이면 끄지 않는다. 앱 업데이트(#59)의 다시 켜기·끌 때 설치도 이 입구를 지난다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let reason = store?.writeActivity.quitBlockedReason else { return .terminateNow }
        inform(reason)
        return .terminateCancel
    }
}
