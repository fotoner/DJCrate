import AppKit
import DJCApplication
import DJCDomain
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: LibraryStore? {
        didSet { if let store { connect(to: store) } }
    }
    /// 끄지 않는 이유를 알린다(USB에 쓰는 중)
    var inform: (String) -> Void = { message in
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(ui: "확인"))
        alert.runModal()
    }
    /// 미룬 종료에 답한다(Mac을 끄는 중일 때만 미룬다, 시험은 가짜로 바꾼다)
    var replyToTermination: (Bool) -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }
    /// 미루지 않은 종료를 쓰기가 끝난 뒤 다시 요청한다(시험은 가짜로 바꾼다)
    var terminateApp: () -> Void = { NSApplication.shared.terminate(nil) }
    /// 쓰는 동안 시스템이 앱을 예고 없이 끝내지 못하게 막는다(시험은 가짜로 바꾼다)
    var systemGuard = WriteSystemGuard(hooks: .live)
    /// rekordbox 실행 판정. 조립 지점이 감지 서비스에 잇는다(읽기 전·잇지 않았으면 nil = 모름). 켜진 채 종료 시트(#326)가 읽는다
    var rekordboxRunState: @MainActor () -> RekordboxRunState? = { nil }
    /// 지금 처리 중인 종료 요청의 이유(Apple 이벤트 `quit`의 「why?」). 이벤트가 없거나 이유가 없으면 nil(시험은 바꿔 끼운다)
    var quitReason: @MainActor () -> UInt32? = { AppDelegate.currentQuitReason() }
    /// 업데이트 설치 뒤 다시 켜려는 종료인가. 읽으면 표시를 지운다(조립 지점이 업데이트 도구에 잇는다)
    var consumeUpdateRelaunch: @MainActor () -> Bool = { false }
    /// 켜진 채 종료 시트를 띄운다(시험은 가짜로 바꾼다)
    var presentQuitConfirmation: @MainActor (QuitConfirmation, @escaping @MainActor (Bool) -> Void) -> Void = {
        QuitConfirmationAlert.present($0, completion: $1)
    }
    private var quit: AppQuitController?
    private weak var connectedStore: LibraryStore?
    private var watchingWrites = false

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
        observePowerOff()
    }

    /// 로그아웃·재시작·전원 끔(#300): 알림을 받은 뒤에는 새 쓰기를 시작하지 않는다. 쓰는 중이면 종료 요청이 오면 끝날 때까지 기다린다.
    /// 취소된 로그아웃은 알리는 곳이 없다. 앱이 다시 활성화되면 쓰기를 다시 연다.
    func observePowerOff(center: NotificationCenter = NSWorkspace.shared.notificationCenter, activation: NotificationCenter = .default) {
        center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store?.isPoweringOff = true }
        }
        activation.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store?.isPoweringOff = false }
        }
    }

    /// 쓰는 중이면 rekordbox는 끝날 때까지 기다렸다 끄고, 아직 쓰지 않은 단계는 취소하고 바로 끄고, USB는 끄지 않는다.
    /// 앱 업데이트(#59)의 다시 켜기·끌 때 설치도 이 입구를 지난다. 판정은 `AppQuitPolicy`가 하고 여기서는 얇게 잇기만 한다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let quit else { return .terminateNow }
        // 로그아웃·재시작·전원 끔 중에는 종료를 미룬다(취소로 답하면 그 일이 통째로 취소된다). 그 밖에는 미루지 않는다(`AppQuitController`)
        let poweringOff = store?.isPoweringOff == true
        // 켜진 채 종료 시트(#326)는 사용자가 고른 종료에서만 묻는다. 누가 골랐는지는 Apple 이벤트의 종료 이유와 Mac을 끄는 중 알림, 업데이트 표시로 가른다
        let cause = AppQuitCause.classify(quitReason: quitReason(), isPoweringOff: poweringOff, isUpdateRelaunch: consumeUpdateRelaunch())
        return quit.requestTermination(nested: poweringOff, cause: cause)
    }

    /// 지금 처리 중인 Apple 이벤트가 종료(`quit`)면 그 이유(「why?」, `kAEQuitReason`)를 읽는다. ⌘Q·메뉴 종료는 Apple 이벤트가 아니라 nil이다.
    /// 이유는 이벤트의 매개변수라고 헤더(AERegistry.h)에 적혀 있으나 속성으로 읽는 구현도 있어 둘 다 본다. 값이 enum 코드가 아니면 0이라 모르는 이유로 다룬다.
    static func currentQuitReason() -> UInt32? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == AppQuitCause.fourCC("quit") else { return nil }
        let keyword = AEKeyword(AppQuitCause.quitReasonKeyword)
        guard let descriptor = event.paramDescriptor(forKeyword: keyword) ?? event.attributeDescriptor(forKeyword: keyword) else { return nil }
        return descriptor.enumCodeValue
    }

    private func connect(to store: LibraryStore) {
        // 창을 닫았다 다시 열면 같은 저장소를 다시 알려 온다. 기다리는 중인 컨트롤러를 바꾸면 [종료 취소]가 끊기므로 그대로 둔다.
        guard connectedStore !== store || quit == nil else { return }
        connectedStore = store
        quit = AppQuitController(
            model: store.quitWait,
            activity: { [weak store] in store?.writeActivity ?? .idle },
            cancelPreparation: { [weak store] in store?.cancelWritePreparation() },
            flushDrafts: { [weak store] in store?.useCases.watch.flush() },
            reply: { [weak self] in self?.replyToTermination($0) },
            terminate: { [weak self] in self?.terminateApp() },
            inform: { [weak self] in self?.inform($0) },
            // 종료를 취소로 끝냈으면 Mac을 끄는 일도 멈췄다. 취소된 로그아웃은 알림이 없으니 여기서 푼다
            terminationCancelled: { [weak store] in store?.isPoweringOff = false },
            bringForward: { NSApplication.shared.activate() },
            runState: { [weak self] in self?.rekordboxRunState() },
            pending: { [weak store] in store?.pendingWriteSummary ?? PendingWriteCount(items: 0, playlistEdits: 0) },
            present: { [weak self] confirmation, answer in self?.presentQuitConfirmation(confirmation, answer) })
        watchWrites(of: store)
    }

    /// 쓰기 활동이 있는 동안 시스템 보호를 건다. 쓰기 상태가 바뀔 때마다 다시 걸어 지켜본다.
    private func watchWrites(of store: LibraryStore) {
        guard !watchingWrites else { return }
        watchingWrites = true
        systemGuard.update(writing: store.writeActivity.isWritingNow)
        withObservationTracking { _ = store.writeActivity } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self else { return }
                self.watchingWrites = false
                guard let store = store ?? self.store else { return }
                self.watchWrites(of: store)
            }
        }
    }
}
