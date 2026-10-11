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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.writeLockPolicy.allowsTermination == false else { return .terminateNow }
        inform(WriteLockPolicy.terminationMessage)
        return .terminateCancel
    }
}
