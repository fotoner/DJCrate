#if DEBUG
import AppKit
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// #191의 실제 앱 화면. 합성 디스크 이미지 한 개만 읽고 앱 활성화·물리 입력 없이 이 PID의 창만 기록한다.
@MainActor
enum UsbMigrateCapture {
    static func runIfRequested(store: LibraryStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let capture = args.first(where: { $0.hasPrefix("--usb-migrate-capture=") }),
              let target = args.first(where: { $0.hasPrefix("--usb-migrate-volume=") }),
              ProcessInfo.processInfo.environment["DJC_HOME"] != nil,
              ProcessInfo.processInfo.environment["DJC_REKORDBOX_DIR"] != nil else { return }
        let directory = String(capture.dropFirst("--usb-migrate-capture=".count))
        let mount = String(target.dropFirst("--usb-migrate-volume=".count))
        Task {
            do {
                _ = try UsbScratchPath.check(directory, as: .existingDirectory)
                _ = try UsbScratchPath.check(mount, as: .existingDirectory)
                for _ in 0..<200 {
                    if case .loaded = store.phase { break }
                    if case .failed = store.phase { throw UsbSelfTestScenario.Failure("합성 라이브러리 읽기 실패") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard case .loaded = store.phase, !NSApp.isActive,
                      let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else {
                    throw UsbSelfTestScenario.Failure("앱 비활성·주 창 조건을 확인하세요")
                }
                let volume = try await BlockingWork.run(qos: .default) { try UsbVolumes.info(root: URL(filePath: mount)) }
                guard volume.isDiskImage, volume.name == "DJC191" else { throw UsbSelfTestScenario.Failure("합성 디스크 이미지가 아님") }
                let (events, continuation) = AsyncStream.makeStream(of: [UsbVolumeInfo].self)
                defer { continuation.finish() }
                let snapshots = DJCPaths.userData.appending(path: "usb-migrate-capture-\(UUID().uuidString)")
                let host = SystemUsbHost(io: UsbAppComposition.hostIO(snapshots: snapshots), events: events, current: { [volume] })
                let usb = UsbStore(host: host, readPolicy: .diskImagesOnly, writeService: UsbAppComposition.writeService(), localLibrary: { nil })
                store.usb = usb
                await usb.refresh()
                guard usb.libraries[volume.usbKey]?.tracks.count == 3 else { throw UsbSelfTestScenario.Failure("합성 USB 읽기 실패") }
                store.sidebar = .usb(.collection(volumeKey: volume.usbKey))
                window.setContentSize(NSSize(width: 1440, height: 1000))
                try await Task.sleep(for: .milliseconds(600))
                try captureWindow(window, to: directory + "/sidebar.jpg")
                if args.contains("--usb-migrate-capture-write") {
                    let before = try await BlockingWork.run(qos: .default) { try UsbTree.fingerprint(UsbRoot(URL(filePath: mount))).files }
                    let prompter = CapturePrompter(directory: directory)
                    let coordinator = UsbWriteCoordinator(usb: usb, host: store, service: usb.writeService, prompter: prompter)
                    await coordinator.migrate(volume)
                    let after = try await BlockingWork.run(qos: .default) { try UsbTree.fingerprint(UsbRoot(URL(filePath: mount))).files }
                    guard prompter.failure == nil, usb.libraries[volume.usbKey]?.formats == UsbFormat.defaultSet,
                          usb.infos[volume.usbKey]?.warnings.isEmpty == true,
                          usb.infos[volume.usbKey]?.deviceLibrary?.roundTripOK == true,
                          before.allSatisfy({ after[$0.key] == $0.value }),
                          store.toast?.title == String(ui: "USB에 OneLibrary를 더했습니다"), usb.migrationBackups[volume.usbKey] != nil else {
                        throw UsbSelfTestScenario.Failure("옮기기 쓰기·원래 파일 보존·다시 읽기·창 캡처 조건 실패")
                    }
                    try await Task.sleep(for: .milliseconds(600))
                    try captureWindow(window, to: directory + "/written.jpg")
                    await coordinator.restoreMigration(volume)
                    let restored = try await BlockingWork.run(qos: .default) { try UsbTree.fingerprint(UsbRoot(URL(filePath: mount))).files }
                    guard prompter.failure == nil, before == restored, usb.libraries[volume.usbKey]?.formats == [.deviceLibrary],
                          usb.migrationBackups[volume.usbKey] == nil else { throw UsbSelfTestScenario.Failure("옮기기 되돌림·다시 읽기 실패") }
                    try await Task.sleep(for: .milliseconds(600))
                    try captureWindow(window, to: directory + "/restored.jpg")
                    FileHandle.standardOutput.write(Data("USB 옮기기 앱 통과: 원래 파일 SHA-256 그대로 · 두 형식 · 왕복 true · 경고 0 · 되돌림 지문 차이 0\n".utf8))
                }
                FileHandle.standardOutput.write(Data("USB 옮기기 화면: 앱 비활성 · 대상 창 캡처 통과\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("USB 옮기기 화면 실패: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    /// 확인 창을 실제 NSAlert로 그려 기록하고 합성 디스크 이미지에만 자동 확인한다. 모달·키 창·물리 입력은 쓰지 않는다.
    private final class CapturePrompter: HeadlessReflectionPrompter {
        let directory: String
        var failure: (any Error)?

        init(directory: String) { self.directory = directory }

        func show(_ prompt: ReflectionPrompt) -> Bool {
            let name: String
            if prompt.confirm == String(ui: "OneLibrary 더하기") { name = "preview" }
            else if prompt.confirm == String(ui: "되돌리기"), !prompt.critical { name = "restore-confirmation" }
            else { return false }
            let alert = AlertPrompter().makeAlert(prompt)
            alert.layout()
            alert.window.orderBack(nil)
            alert.window.displayIfNeeded()
            defer { alert.window.orderOut(nil) }
            do { try captureWindow(alert.window, to: directory + "/" + name + ".jpg") }
            catch { failure = error; return false }
            return true
        }

        func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice { .cancel }
    }

    static func captureWindow(_ window: NSWindow, to path: String) throws {
        guard !NSApp.isActive else { throw UsbSelfTestScenario.Failure("앱이 활성화됨") }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-t", "jpg", "-l", String(window.windowNumber), path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UsbSelfTestScenario.Failure("창 캡처 실패") }
    }
}
#endif
