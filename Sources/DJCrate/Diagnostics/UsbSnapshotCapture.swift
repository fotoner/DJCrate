#if DEBUG
import AppKit
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit
import SwiftUI

/// #226: 지정한 합성 디스크 이미지 한 개만 주입해 이 PID의 창을 기록한다.
@MainActor
enum UsbSnapshotCapture {
    nonisolated static func startupRefusal(arguments: [String], environment: [String: String]) -> String? {
        if let refusal = UsbSelfTest.launchRefusal(arguments: arguments, environment: environment) { return refusal }
        guard let database = UsbSelfTest.explicitDatabase(arguments: arguments, environment: environment),
              let rekordbox = environment["DJC_REKORDBOX_DIR"] else { return "USB 스냅샷 시험 실패: 합성 rekordbox 폴더를 주세요" }
        do {
            _ = try UsbScratchPath.check(database, as: .existingFile)
            _ = try UsbScratchPath.check(rekordbox, as: .existingDirectory)
            return nil
        } catch { return "USB 스냅샷 시험 실패: 합성 사본은 임시 폴더에 두세요" }
    }

    static func runIfRequested(store: LibraryStore) {
        let args = CommandLine.arguments
        guard let capture = args.first(where: { $0.hasPrefix("--usb-snapshot-capture=") }),
              let target = args.first(where: { $0.hasPrefix("--usb-snapshot-volume=") }) else { return }
        let directory = String(capture.dropFirst("--usb-snapshot-capture=".count))
        let mount = String(target.dropFirst("--usb-snapshot-volume=".count))
        Task {
            do {
                if let refusal = startupRefusal(arguments: args, environment: ProcessInfo.processInfo.environment) {
                    throw UsbSelfTestScenario.Failure(refusal)
                }
                _ = try UsbScratchPath.check(directory, as: .existingDirectory)
                _ = try UsbScratchPath.check(mount, as: .existingDirectory)
                for _ in 0..<300 {
                    if case .loaded = store.phase { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard case .loaded = store.phase,
                      let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else {
                    throw UsbSelfTestScenario.Failure("합성 라이브러리·주 창을 확인하세요")
                }
                let volume = try await BlockingWork.run { try UsbVolumes.info(root: URL(filePath: mount)) }
                guard volume.isDiskImage, volume.name == "DJC226" else { throw UsbSelfTestScenario.Failure("합성 디스크 이미지가 아님") }
                let (events, continuation) = AsyncStream.makeStream(of: [UsbVolumeInfo].self)
                defer { continuation.finish() }
                let host = SystemUsbHost(io: UsbAppComposition.hostIO(snapshots: DJCPaths.userData.appending(path: "usb-snapshot-capture-read")),
                                         events: events, current: { [volume] })
                let service = UsbAppComposition.writeService(policy: .diskImagesOnly)
                let usb = UsbStore(host: host, readPolicy: .diskImagesOnly, writeService: service, localLibrary: { nil })
                usb.drafts = .live(directory: DJCPaths.usbDrafts)
                let points = UsbAppComposition.pointSnapshots(service: service)
                usb.pointSnapshots = points
                store.usb = usb
                await usb.refresh()
                guard usb.volumes.count == 1, usb.libraries[volume.usbKey] != nil else { throw UsbSelfTestScenario.Failure("시험 USB 읽기 실패") }
                store.sidebar = .usb(.collection(volumeKey: volume.usbKey))
                window.setContentSize(NSSize(width: 1440, height: 1000))
                try await Task.sleep(for: .milliseconds(600))
                try UsbMigrateCapture.captureWindow(window, to: directory + "/volume.jpg")
                try await exercise(store: store, usb: usb, volume: volume, points: points, service: service, window: window, directory: directory)
                let storage = StorageSettingsModel(paths: DJCCachePaths(root: DJCPaths.userData,
                                                                       snapshots: DJCPaths.userData.appending(path: "snapshots")), files: .live)
                await storage.refresh()
                let settings = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 720),
                                        styleMask: [.titled], backing: .buffered, defer: false)
                settings.title = String(ui: "저장 공간")
                settings.contentView = NSHostingView(rootView: StorageSettingsView(model: storage))
                settings.orderBack(nil)
                try await Task.sleep(for: .milliseconds(600))
                try UsbMigrateCapture.captureWindow(settings, to: directory + "/storage.jpg")
                settings.orderOut(nil)
                UsbSelfTest.log("USB 스냅샷 시험 통과 · 만들기·목록·고정·풀기·지우기 · 편집→되돌리기 · 기기 변경 거부·동의 · 취소 뒤 지문 같음 · 시험 볼륨 1개")
                exit(0)
            } catch {
                UsbSelfTest.log("USB 스냅샷 캡처 실패: \(error)")
                exit(1)
            }
        }
    }

    private static func exercise(store: LibraryStore, usb: UsbStore, volume: UsbVolumeInfo, points: UsbPointSnapshots,
                                 service: UsbWriteService, window: NSWindow, directory: String) async throws {
        let key = volume.usbKey, root = UsbRoot(URL(filePath: volume.mountPoint))
        let before = try await BlockingWork.run { try UsbTree.fingerprint(root).files }
        let prompter = CapturePrompter(directory: directory)
        let coordinator = UsbWriteCoordinator(usb: usb, host: store, service: service, prompter: prompter)
        let model = UsbPointSnapshotsModel(volume: volume, usb: usb, snapshots: points, coordinator: coordinator)
        model.name = "공연 전"
        await model.create()
        guard let entry = model.entries.first, !model.isError else { throw UsbSelfTestScenario.Failure("스냅샷 만들기 실패: \(model.message ?? "")") }
        await model.togglePinned(entry)
        guard model.entries.first?.metadata.pinned == true else { throw UsbSelfTestScenario.Failure("고정 실패") }
        usb.pointSnapshotSheet = model
        try await Task.sleep(for: .milliseconds(600))
        guard let sheet = window.sheets.first else { throw UsbSelfTestScenario.Failure("스냅샷 목록 시트 없음") }
        try UsbMigrateCapture.captureWindow(sheet, to: directory + "/snapshots.jpg")

        func edit(_ name: String, using writer: UsbWriteCoordinator) async throws {
            guard let playlist = usb.libraries[key]?.playlists.first(where: { $0.attribute == 0 }) else {
                throw UsbSelfTestScenario.Failure("합성 재생 목록 없음")
            }
            let actions = UsbEditActions(usb: usb, host: store, prompter: prompter, namePrompter: UsbSelfTestNamePrompter(answers: [name]))
            await actions.renamePlaylist(playlist.id, volumeKey: key)
            guard await writer.writeDraft(volumeKey: key, database: nil, share: nil) else {
                throw UsbSelfTestScenario.Failure("합성 USB 편집 실패")
            }
        }
        try await edit("공연 뒤", using: coordinator)
        await model.restore(entry)
        guard model.undoBackup != nil, prompter.devicePrompts == 0,
              try await BlockingWork.run({ try UsbTree.fingerprint(root).files }) == before else {
            throw UsbSelfTestScenario.Failure("DJCrate 편집 뒤 스냅샷 복원 실패")
        }
        try await Task.sleep(for: .milliseconds(600))
        guard usb.pointSnapshotSheet?.id == model.id, let restoredSheet = window.sheets.first else {
            throw UsbSelfTestScenario.Failure("복원 뒤 스냅샷 목록 시트가 닫힘")
        }
        try UsbMigrateCapture.captureWindow(restoredSheet, to: directory + "/undo-available.jpg")

        // 기기처럼 이 유스케이스의 기록 밖에서 바뀐 DB를 흉내 낸다. 쓰기는 같은 Writer·관문을 지나고 기록만 별도 임시 폴더다.
        let external = DJCPaths.userData.appending(path: "device-simulation")
        var externalService = service
        externalService.paths = UsbWritePaths(backups: external.appending(path: "backups"), sessions: external.appending(path: "sessions"),
                                             staging: external.appending(path: "staging"))
        let externalWriter = UsbWriteCoordinator(usb: usb, host: store, service: externalService, prompter: prompter)
        try await edit("기기에서 바뀐 목록", using: externalWriter)
        let deviceState = try await BlockingWork.run { try UsbTree.fingerprint(root).files }
        guard deviceState != before else { throw UsbSelfTestScenario.Failure("기기 변경 흉내 실패") }
        prompter.discard = false
        await model.restore(entry)
        guard prompter.devicePrompts == 1,
              try await BlockingWork.run({ try UsbTree.fingerprint(root).files }) == deviceState else {
            throw UsbSelfTestScenario.Failure("기기 변경 거부 뒤 USB가 바뀜")
        }
        prompter.discard = true
        await model.restore(entry)
        guard prompter.devicePrompts == 2, model.undoBackup != nil,
              try await BlockingWork.run({ try UsbTree.fingerprint(root).files }) == before else {
            throw UsbSelfTestScenario.Failure("기기 변경 동의 뒤 복원 실패")
        }
        await model.undoRestore()
        guard model.undoBackup == nil,
              try await BlockingWork.run({ try UsbTree.fingerprint(root).files }) == deviceState else {
            throw UsbSelfTestScenario.Failure("되돌리기 취소 실패")
        }
        await model.restore(entry)
        guard try await BlockingWork.run({ try UsbTree.fingerprint(root).files }) == before else {
            throw UsbSelfTestScenario.Failure("최종 복원 실패")
        }
        model.name = "지우기 시험"
        await model.create()
        guard let disposable = model.entries.first(where: { $0.displayName == "지우기 시험" }) else { throw UsbSelfTestScenario.Failure("지울 스냅샷 없음") }
        await model.delete(disposable)
        guard model.entries.count == 1 else { throw UsbSelfTestScenario.Failure("지우기 실패") }
        if let pinned = model.entries.first { await model.togglePinned(pinned) }
        guard model.entries.first?.metadata.pinned == false else { throw UsbSelfTestScenario.Failure("고정 풀기 실패") }
        if let unpinned = model.entries.first { await model.togglePinned(unpinned) }
        guard prompter.failure == nil else { throw prompter.failure! }
        usb.pointSnapshotSheet = nil
        try await Task.sleep(for: .milliseconds(600))
        try UsbMigrateCapture.captureWindow(window, to: directory + "/restored.jpg")
    }

    private final class CapturePrompter: HeadlessReflectionPrompter {
        let directory: String
        var discard = true
        var devicePrompts = 0
        var failure: (any Error)?
        private var captured: Set<String> = []

        init(directory: String) { self.directory = directory }

        func show(_ prompt: ReflectionPrompt) -> Bool {
            let file: String?
            if prompt.title == String(ui: "스냅샷 뒤의 기기 변경을 버릴까요?") {
                devicePrompts += 1
                file = "device-changes-consent"
            } else if prompt.title.hasPrefix("USB를 ‘") {
                // 첫 확인 창은 기기 변경이 있어도 똑같다(기기 변경은 다음 동의 창에서 따로 묻는다). 한 장만 남긴다
                file = "restore-confirmation"
            }
            else if prompt.confirm == String(ui: "USB에 쓰기") || prompt.confirm == String(ui: "되돌리기 취소") || prompt.confirm == String(ui: "지우기") { return true }
            else {
                failure = UsbSelfTestScenario.Failure("뜻밖의 확인 창: \(prompt.title) · \(prompt.text)")
                return false
            }
            if captured.contains(file!) { return file == "device-changes-consent" ? discard : true }
            let alert = AlertPrompter().makeAlert(prompt)
            alert.layout()
            alert.window.orderFrontRegardless()
            alert.window.displayIfNeeded()
            defer { alert.window.orderOut(nil) }
            do { try UsbMigrateCapture.captureWindow(alert.window, to: directory + "/" + file! + ".jpg") }
            catch { failure = error; return false }
            captured.insert(file!)
            return file == "device-changes-consent" ? discard : true
        }

        func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice { .cancel }
    }
}
#endif
