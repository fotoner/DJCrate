import DJCDomain
import Foundation

extension UsbWriteFlow {
    /// 1단계의 판정·계획을 그대로 받아 기존 쓰기 세션의 잠금·진행·확인·실패 처리를 잇는다.
    @discardableResult
    public func restorePointSnapshot(_ volume: UsbVolumeInfo, entry: UsbPointSnapshotEntry, snapshots: UsbPointSnapshots) async -> Bool {
        guard await ready(volume), let flag = begin(volume, title: String(ui: "USB에 쓸 내용을 확인하는 중…")) else { return false }
        let key = volume.usbKey, root = URL(filePath: volume.mountPoint)
        let options = UsbWriteService.writeOptions(volume)
        // 끊긴 뒤 회복의 다시 미리 보기가 앞서 한 내보내기·옮기기·초안 쓰기를 따라가지 않게, 지난 쓰기 기록을 이 되돌리기로 바꾼다
        session.lastPointRestores[key] = UsbPointRestoreRetry(entry: entry, snapshots: snapshots)
        session.lastExports[key] = nil
        session.lastMigrations.remove(key)
        session.lastDraftWrites[key] = nil
        var ended = false
        defer { if !ended { session.end(key) } }
        do {
            let summary = try await BlockingWork.run { try snapshots.previewRestore(root: root, entry: entry, options: options) }
            guard !flag.isSet else { return false }
            guard summary.blocks.isEmpty else {
                inform(Text.notRestoredTitle, summary.blocks.map(Self.pointSnapshotBlockText).joined(separator: "\n"))
                return false
            }
            guard !summary.result.isUnchanged else {
                notify(Text.nothingToWriteTitle, String(ui: "USB가 이미 시점 스냅샷과 같습니다"))
                return false
            }
            guard confirmation.confirm(Self.pointRestoreConfirmation(volume, entry: entry, summary: summary)) else { return false }
            var discard = summary.deviceChanged
            if discard, !confirmation.confirm(Self.pointDeviceChangesPrompt(volume)) { return false }
            while true {
                let consented = discard
                let result = await perform(key) { progress in
                    try snapshots.restore(root: root, entry: entry, discardDeviceChanges: consented, options: options,
                                          progress: progress, isCancelled: { flag.isSet })
                }
                switch result {
                case let .success(written):
                    guard written.report?.outcome == .written else { return false }
                    session.migrationBackups[key] = nil
                    session.lastPointRestores[key] = nil
                    session.pointRestoreBackups[key] = written.report?.backup.map { URL(filePath: $0) }
                    session.end(key)
                    ended = true
                    results.show(.success(title: String(ui: "USB를 시점 스냅샷으로 되돌렸습니다"),
                                          detail: entry.displayName, ejectVolumeKey: key))
                    await screen.refresh()
                    return true
                case let .failure(error) where UsbWriteDecision.asksToDiscardDeviceChanges(error, discarding: discard):
                    // 미리 보기 뒤 기기가 바꾼 경우에도 1단계의 거부 판정으로 다시 동의를 받는다.
                    guard confirmation.confirm(Self.pointDeviceChangesPrompt(volume)) else { return false }
                    discard = true
                case let .failure(error): throw error
                }
            }
        } catch {
            session.end(key)
            ended = true
            switch UsbWriteDecision.afterWrite(error) {
            case .cancelled: results.show(.success(title: Text.cancelledTitle, detail: Text.unchangedDetail))
            case .recoveryNeeded: await offerRecovery(volume)
            case .failed: await failWrite(error, volumeKey: key, otherwise: Text.notRestoredTitle)
            }
            return false
        }
    }

    /// 되돌리기 자체도 쓰기 전 백업을 남긴다. 그 백업만 기존 USB 복원 흐름으로 돌린다.
    @discardableResult
    public func undoPointRestore(_ volume: UsbVolumeInfo) async -> Bool {
        let key = volume.usbKey
        guard let backup = session.pointRestoreBackups[key], await ready(volume) else { return false }
        guard confirmation.confirm(Self.pointUndoConfirmation(volume)) else { return false }
        guard begin(volume, title: String(ui: "USB를 되돌리는 중…"), cancellable: false) != nil else { return false }
        return await restore(volume, backup: backup)
    }

    public static func pointRestoreConfirmation(_ volume: UsbVolumeInfo, entry: UsbPointSnapshotEntry,
                                                summary: UsbPointRestoreSummary) -> ReflectionPrompt {
        let result = summary.result
        var details = volumeLines(volume, isTestVolume: volume.isDiskImage)
        details.append(String(ui: "바꿀 DB \(result.databases)개 · 만들 파일 \(result.created)개 · 덮을 파일 \(result.overwritten)개 · 지울 파일 \(result.removed)개"))
        details += result.notes
        return ReflectionPrompt(title: String(ui: "USB를 ‘\(entry.displayName)’ 시점으로 되돌릴까요?"),
                                text: String(ui: "\(volume.name)의 라이브러리 파일을 이 스냅샷으로 바꿉니다. 음원과 동기화 선택은 그대로 두며, 쓰기 전 백업으로 되돌리기를 취소할 수 있습니다."),
                                confirm: String(ui: "되돌리기"), destructive: true, details: details)
    }

    public static func pointDeviceChangesPrompt(_ volume: UsbVolumeInfo) -> ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "스냅샷 뒤의 기기 변경을 버릴까요?"),
                         text: String(ui: "\(volume.name)을 되돌리면 스냅샷 뒤에 DJCrate가 모르게 바뀐 내용(기기의 재생 기록 등)을 잃습니다(버려도 될 때만 동의하세요)."),
                         confirm: String(ui: "변경을 버리고 되돌리기"), critical: true, destructive: true)
    }

    static func pointSnapshotBlockText(_ block: UsbBlock) -> String {
        if block.code == "pointSnapshotNewDatabase" {
            return String(ui: "스냅샷 뒤 새 DB가 생겨 되돌릴 수 없으니, 그 DB를 만든 쓰기를 `djc usb-restore`로 먼저 되돌리세요")
        }
        return block.message
    }
}
