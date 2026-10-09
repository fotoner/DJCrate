import AppKit
import DJCApplication
import DJCDomain
import Foundation

/// USB 쓰기 흐름의 화면 쪽: USB 화면(`UsbStore`)·결과 알림(`UsbWriteHost`의 토스트)·확인 창을 포트로 붙여 유스케이스(`UsbWriteFlow`)를 부른다.
/// 순서(잠금 → 미리 보기 → 확인 → 저널 → 쓰기 → 알림)와 판정은 유스케이스에 있고, 여기서는 앱의 값으로 바꾸기만 한다.
@MainActor
struct UsbWriteCoordinator {
    /// 사이드바 USB 상태(볼륨·초안·native 초안 소유권·시트). 앱은 `UsbStore`
    let usb: UsbStore
    let host: any UsbWriteHost
    /// USB 쓰기 유스케이스(앱은 조립 지점이 만든 `UsbWriteService`, 시험은 가짜)
    let service: any UsbWriting
    var prompter: any ReflectionPrompter = AlertPrompter()
    /// rekordbox·rekordboxAgent가 켜져 있는지(메인 액터 밖에서 부른다). nil이면 쓰기 창구의 가드가 보는 것과 같은 판정
    var isRekordboxRunning: (@Sendable () -> Bool)? = nil
    var openFolder: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// 지금 USB 화면·알림·확인 창을 붙인 쓰기 흐름
    var flow: UsbWriteFlow {
        let usb = usb, host = host, openFolder = openFolder
        return UsbWriteFlow(
            session: usb.session,
            screen: UsbWriteScreen(
                volume: { usb.volume($0) },
                isEjecting: { usb.ejecting.contains($0) },
                draftEdits: { usb.draftEdits[$0] },
                libraryFormats: { usb.libraries[$0]?.formats },
                savedSyncDraft: { key in
                    usb.syncDraftSources[key].map { UsbSavedSyncDraft(job: $0.job, edits: $0.edits, snapshotLease: $0.snapshotLease) }
                },
                rememberSyncDraft: { usb.rememberSyncDraft($0, edits: $1, sourceIsCurrent: $2) },
                invalidateSyncDraft: { usb.invalidateSyncDraft($0) },
                beginWrite: { usb.beginWrite($0, title: $1, cancellable: $2) },
                refresh: { await usb.refresh() },
                reloadDraft: { await usb.reloadDraft($0) },
                draftQueue: { key, body in await usb.draftQueue(key, body) },
                draftEditing: { usb.draftEditing },
                setExportSheet: { usb.exportSheet = $0 },
                eject: { await usb.eject($0) }),
            syncSourceIsCurrent: { [weak host] context, database, share in
                host?.usbSyncSourceIsCurrent(context, database: database, share: share) == true
            },
            service: service,
            confirmation: prompter.confirmation,
            results: UsbWriteResults(
                show: { [weak host] in host?.toast = Self.toast($0) },
                dismissEject: { [weak host] key in
                    if host?.toast?.action == .ejectUsb(volumeKey: key) { host?.toast = nil }
                },
                errorText: { AppErrorMessage.message(for: $0) },
                log: { AppErrorMessage.log($0) },
                openFolder: { openFolder($0) }),
            isRekordboxRunning: isRekordboxRunning)
    }

    /// 쓰기 흐름의 알림 → 앱의 토스트(USB 알림이라 결과 보기를 붙이지 않는다)
    static func toast(_ toast: UsbWriteToast) -> AppToast {
        switch toast {
        case let .success(title, detail, ejectVolumeKey):
            AppToast(kind: .success, title: title, detail: detail, action: ejectVolumeKey.map { .ejectUsb(volumeKey: $0) }, isUsb: true)
        case let .notice(title, text):
            .notice(title, text, isUsb: true)
        }
    }

    // MARK: - 내보내기

    /// 시트의 미리 보기. 막히면(rekordbox·잠금·끝나지 않은 쓰기·오류) 알리고 nil
    func preview(_ job: UsbExportJob) async -> UsbExportSummary? { await flow.preview(job) }

    /// 미리 보기 → 확인 창 → 쓰기 → 토스트. `consented`면 시트가 볼륨 줄과 미리 보기를 보인 뒤 누른 [USB에 쓰기]가 쓰기 동의다(#212)
    @discardableResult
    func export(_ job: UsbExportJob, reusing reused: UsbExportSummary? = nil, consented: Bool = false) async -> Bool {
        await flow.export(job, reusing: reused, consented: consented)
    }

    // MARK: - Device Library → OneLibrary

    func previewMigration(_ volume: UsbVolumeInfo) async -> UsbMigrationSummary? { await flow.previewMigration(volume) }
    func migrate(_ volume: UsbVolumeInfo) async { await flow.migrate(volume) }
    func restoreMigration(_ volume: UsbVolumeInfo) async { await flow.restoreMigration(volume) }

    // MARK: - 수정(초안)

    /// 동기화 모델이 저장한 초안의 인계. 확인 취소·실패 뒤에도 동일 초안은 UsbStore가 사본을 이어 소유한다.
    @discardableResult
    func writeSyncDraft(_ job: UsbEditJob, edits: [UsbLibraryEdit]) async -> Bool { await flow.writeSyncDraft(job, edits: edits) }

    /// 쓰기 대기 목록의 미리 보기
    func previewDraft(volumeKey: String, database: URL?, share: URL?, snapshotTime: String? = nil) async -> UsbEditSummary? {
        await flow.previewDraft(volumeKey: volumeKey, database: database, share: share, snapshotTime: snapshotTime)
    }

    /// 초안 쓰기: 미리 보기 → 확인 창 → 쓰기 → 토스트
    @discardableResult
    func writeDraft(volumeKey: String, database: URL?, share: URL?, snapshotTime: String? = nil, reusing reused: UsbEditSummary? = nil) async -> Bool {
        await flow.writeDraft(volumeKey: volumeKey, database: database, share: share, snapshotTime: snapshotTime, reusing: reused)
    }

    // MARK: - 끝나지 않은 쓰기

    /// 끝나지 않은 쓰기 알림: [회복하기] [되돌리기] [나중에]. 누를 때만 USB에 손댄다
    func offerRecovery(_ volume: UsbVolumeInfo) async { await flow.offerRecovery(volume) }

    // MARK: - 토스트 동작

    func perform(_ action: AppToast.Action) async {
        switch action {
        case let .ejectUsb(volumeKey): await flow.eject(volumeKey)
        }
    }
}
