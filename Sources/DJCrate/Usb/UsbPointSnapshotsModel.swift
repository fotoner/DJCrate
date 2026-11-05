import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 볼륨별 시점 스냅샷 화면. 파일 일은 기존 유스케이스가, USB 쓰기 확인·진행·복원은 쓰기 흐름이 맡는다.
@MainActor @Observable
final class UsbPointSnapshotsModel: Identifiable {
    let id = UUID()
    let volume: UsbVolumeInfo
    var name = ""
    private(set) var entries: [UsbPointSnapshotEntry] = []
    private(set) var isWorking = false
    private(set) var message: String?
    private(set) var isError = false
    @ObservationIgnored private let usb: UsbStore
    @ObservationIgnored private let snapshots: UsbPointSnapshots
    @ObservationIgnored private let coordinator: UsbWriteCoordinator
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(volume: UsbVolumeInfo, usb: UsbStore, snapshots: UsbPointSnapshots, coordinator: UsbWriteCoordinator) {
        self.volume = volume
        self.usb = usb
        self.snapshots = snapshots
        self.coordinator = coordinator
    }

    var canUseVolume: Bool { usb.volume(volume.usbKey)?.matchesSyncWriteVolume(volume) == true }
    var isBusy: Bool { isWorking || usb.activeWrite != nil }
    var undoBackup: URL? { usb.write.pointRestoreBackups[volume.usbKey] }
    var activeWrite: UsbActiveWrite? { usb.activeWrite }
    func cancelWrite() { usb.cancelWrite() }

    func startCreate() { task = Task { await create() } }
    func startTogglePinned(_ entry: UsbPointSnapshotEntry) { task = Task { await togglePinned(entry) } }
    func startDelete(_ entry: UsbPointSnapshotEntry) { task = Task { await delete(entry) } }
    func startRestore(_ entry: UsbPointSnapshotEntry) { task = Task { await restore(entry) } }
    func startUndoRestore() { task = Task { await undoRestore() } }

    func refresh() async {
        let snapshots = snapshots, key = volume.usbKey
        entries = await BlockingWork.run { snapshots.entries(volumeKey: key) }
    }

    func create() async {
        guard !isBusy, canUseVolume else { return }
        isWorking = true
        defer { isWorking = false }
        let snapshots = snapshots, volume = volume, name = name, service = coordinator.service
        do {
            _ = try await BlockingWork.run {
                let current = try service.currentVolume(volume)
                guard current.matchesSyncWriteVolume(volume) else { throw UsbError.volumeChanged(volumeName: volume.name) }
                return try snapshots.create(root: URL(filePath: current.mountPoint), name: name)
            }
            self.name = ""
            await refresh()
            show(String(ui: "USB 시점 스냅샷을 남겼습니다."))
        } catch { show(error) }
    }

    func togglePinned(_ entry: UsbPointSnapshotEntry) async {
        guard !isBusy else { return }
        isWorking = true
        defer { isWorking = false }
        let snapshots = snapshots
        do {
            _ = try await BlockingWork.run { try snapshots.setPinned(!entry.metadata.pinned, entry) }
            await refresh()
            show(entry.metadata.pinned ? String(ui: "고정을 풀었습니다.") : String(ui: "고정했습니다. 자동 정리에서 지우지 않습니다."))
        } catch { show(error) }
    }

    func delete(_ entry: UsbPointSnapshotEntry) async {
        guard !isBusy, !entry.metadata.pinned else { return }
        guard coordinator.prompter.show(ReflectionPrompt(title: String(ui: "USB 시점 스냅샷을 지울까요?"),
                                                         text: String(ui: "‘\(entry.displayName)’을 지우면 되살릴 수 없습니다."),
                                                         confirm: String(ui: "지우기"), destructive: true)) else { return }
        isWorking = true
        defer { isWorking = false }
        let snapshots = snapshots
        do {
            try await BlockingWork.run { try snapshots.delete(entry) }
            await refresh()
            show(String(ui: "USB 시점 스냅샷을 지웠습니다."))
        } catch { show(error) }
    }

    func restore(_ entry: UsbPointSnapshotEntry) async {
        guard !isBusy, canUseVolume else { return }
        isWorking = true
        defer { isWorking = false }
        if await coordinator.restorePointSnapshot(volume, entry: entry, snapshots: snapshots) {
            show(String(ui: "USB를 시점 스냅샷으로 되돌렸습니다."))
        }
        await refresh()
    }

    func undoRestore() async {
        guard !isBusy, canUseVolume else { return }
        isWorking = true
        defer { isWorking = false }
        if await coordinator.undoPointRestore(volume) { show(String(ui: "USB 시점 스냅샷 되돌리기를 취소했습니다.")) }
    }

    private func show(_ text: String) { message = text; isError = false }

    private func show(_ error: any Error) {
        isError = true
        if case let UsbError.writeRefused(blocks) = error {
            message = blocks.map(\.message).joined(separator: "\n")
        } else if let usbError = error as? UsbError {
            message = usbError.errorDescription
        } else {
            AppErrorMessage.log(error)
            message = AppErrorMessage.message(for: error)
        }
    }
}
