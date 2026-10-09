@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Observation
import RekordboxKit
import Testing

@MainActor
@Suite("USB OneLibrary 더하기 앱 흐름")
struct UsbMigrateTests {
    let image = FakeUsbVolume.diskImageFAT32(name: "DJC191")
    let service = FakeUsbWriteService()
    let host = FakeUsbWriteHost()
    let prompter = ScriptedPrompter()

    func store() async -> (UsbStore, FakeUsbHost) {
        let usbHost = FakeUsbHost([image])
        usbHost.serve(image, library: UsbTestData.library(formats: [.deviceLibrary]))
        let usb = UsbTestData.store(usbHost)
        await usb.refresh()
        return (usb, usbHost)
    }

    func coordinator(_ usb: UsbStore, running: Bool = false) -> UsbWriteCoordinator {
        UsbWriteCoordinator(usb: usb, host: host, service: service, prompter: prompter, isRekordboxRunning: { running })
    }

    @Test("미리 보기·확인에는 곡·목록·새 아트워크·CDJ에서 확인하지 않은 항목이 있고 취소하면 쓰지 않는다")
    func previewAndCancel() async throws {
        let (usb, _) = await store()
        let c = coordinator(usb)
        let summary = try #require(await c.previewMigration(image))
        #expect(summary.trackCount == 3 && summary.playlistCount == 1 && summary.artworkFiles == 6)
        #expect(summary.rules.contains(.deviceLibraryMigration))
        #expect(service.current.migrationOnMain == [false])
        prompter.answer = false
        await c.migrate(image)
        let prompt = try #require(prompter.shown.last)
        #expect(prompt == UsbWriteFlow.migrationConfirmation(summary, volume: image))
        #expect(prompt.details.contains { $0.contains(UsbProvisionalRule.deviceLibraryMigration.summary) })
        #expect(service.current.previewed && !service.current.wrote)
        #expect(service.current.fileOperations == 0 && usb.busyVolumes.isEmpty && usb.activeWrite == nil)
    }

    @Test("성공하면 메인 액터 밖에서 쓰고 USB를 다시 읽으며 그 옮기기의 백업으로만 되돌린다")
    func writeReadAndRestore() async throws {
        let (usb, usbHost) = await store()
        let c = coordinator(usb)
        let backup = URL(filePath: "/tmp/djc-fixture/usb-backups/B/m1")
        await c.migrate(image)
        #expect(service.current.previewedBeforeWrite)
        #expect(service.current.migrationOnMain == [false, false])
        #expect(usbHost.libraryCalls.count == 2)
        #expect(host.toast?.title == UsbWriteFlow.Text.migratedTitle)
        #expect(host.toast?.action == .ejectUsb(volumeKey: image.usbKey))
        #expect(usb.migrationBackups[image.usbKey] == backup)
        #expect(usb.busyVolumes.isEmpty && usb.activeWrite == nil)
        await c.restoreMigration(image)
        #expect(service.current.restoredBackups == [backup])
        #expect(service.current.called("writeMigration", before: "restore"))
        #expect(host.toast?.title == UsbWriteFlow.Text.restoredTitle)
        #expect(usb.migrationBackups[image.usbKey] == nil && usbHost.libraryCalls.count == 3)
    }

    @Test("CLI의 막힘을 그대로 보이고 도움말에 남기며 쓰지 않는다", arguments: [
        UsbMigration.Blocks.oneLibraryExists,
        UsbBlock(code: "carriedDeviceRows", scope: .format(.deviceLibrary), message: "CDJ가 쓴 기록·목록이 있어 아직 옮길 수 없습니다. rekordbox에서 USB를 다시 내보내세요", rule: .carriedDeviceRows),
        UsbTestData.physicalBlock,
    ])
    func blocksUseServiceMessage(_ block: UsbBlock) async throws {
        let (usb, _) = await store()
        service.update { $0.migrationSummary.blocks = [block] }
        await coordinator(usb).migrate(image)
        #expect(service.current.previewed && !service.current.wrote)
        #expect(service.current.fileOperations == 0)
        #expect(prompter.shown.last?.title == UsbWriteFlow.Text.cannotMigrateTitle)
        #expect(prompter.shown.last?.text == block.message)
        let row = try #require(UsbSidebarModel.volumes(usb).first)
        #expect(row.showsMigration && !row.canMigrate && row.migrationHelp == block.message)
        await usb.refresh()
        #expect(usb.migrationBlockReasons[image.usbKey] == nil)
    }

    @Test("rekordbox·볼륨 잠금·열린 저널·읽지 못한 저널은 미리 보기 전에 멈춘다")
    func existingGuards() async {
        let (usb, _) = await store()
        await coordinator(usb, running: true).migrate(image)
        #expect(service.current.calls.isEmpty)
        #expect(prompter.shown.isEmpty && host.toast?.title == UsbWriteFlow.Text.rekordboxRunningTitle)
        _ = usb.beginWrite(image, title: "시험")
        await coordinator(usb).migrate(image)
        #expect(service.current.calls.isEmpty)
        #expect(prompter.shown.isEmpty && host.toast?.title == UsbWriteFlow.Text.busyTitle)
        usb.endWrite(image.usbKey)
        service.update { $0.journal = .state(.filesWritten) }
        prompter.choices = [.cancel]
        await coordinator(usb).migrate(image)
        #expect(service.current.calls.isEmpty)
        #expect(prompter.shown.last == UsbWriteFlow.pendingPrompt(image))
        service.update { $0.journal = .unreadable }
        await coordinator(usb).migrate(image)
        #expect(service.current.calls.isEmpty)
        #expect(prompter.shown.last?.text == UsbWriteFlow.journalUnreadableText)
    }

    @Test("확인 뒤 저널이 열리면 쓰기 대신 회복을 알린다")
    func journalChangesAfterPreview() async {
        let (usb, _) = await store()
        service.update { $0.journalAfterPreview = .state(.committing) }
        prompter.choices = [.cancel]
        await coordinator(usb).migrate(image)
        #expect(service.current.previewed && !service.current.wrote)
        #expect(prompter.shown.last == UsbWriteFlow.pendingPrompt(image))
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("DB 교체 전 취소와 정상 진행은 관찰한 파일 단계에서 결정한다", arguments: [true, false])
    func cancelOrContinue(cancel: Bool) async {
        let (usb, _) = await store()
        let release = DispatchSemaphore(value: 0)
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        service.update {
            $0.writeProgress = [UsbProgress(phase: .files, completedItems: 1, totalItems: 7, cancellable: true)]
            $0.onWrite = { release.wait() }
        }
        let c = coordinator(usb)
        let task = Task {
            await c.migrate(image)
            continuation.finish()
        }
        var iterator = changes.makeAsyncIterator()
        while true {
            let progress = withObservationTracking { usb.activeWrite?.progress } onChange: { continuation.yield(()) }
            if progress?.phase == .files { break }
            guard await iterator.next() != nil else { break }
        }
        #expect(usb.activeWrite?.progress?.phase == .files && usb.busyVolumes == [image.usbKey])
        if cancel { usb.cancelWrite() }
        release.signal()
        await task.value
        #expect(service.current.fileOperations == (cancel ? 0 : 1))
        #expect(host.toast?.title == (cancel ? UsbWriteFlow.Text.cancelledTitle : UsbWriteFlow.Text.migratedTitle))
        #expect(usb.busyVolumes.isEmpty && usb.activeWrite == nil)
    }

    @Test("옮기기 오류는 기존 USB 복원·연결 끊김 안내를 사용한다")
    func writeFailureAndPreviewFailure() async {
        let (usb, _) = await store()
        service.update { $0.migrationWriteResult = .failure(.volumeLost(volumeName: "DJC191")) }
        prompter.answers = [true, false]
        await coordinator(usb).migrate(image)
        #expect(prompter.shown.last == UsbWriteFlow.interruptedPrompt(.volumeLost(volumeName: "DJC191")))
        #expect(usb.busyVolumes.isEmpty)
        service.update { $0.migrationPreviewError = .formatUnsupported(detail: "fixture") }
        #expect(await coordinator(usb).previewMigration(image) == nil)
        #expect(prompter.shown.last?.title == UsbWriteFlow.Text.previewFailedTitle)
        #expect(usb.busyVolumes.isEmpty)
    }

    @Test("옮기기 회복이 재계획을 권하면 내보내기 시트 대신 다시 옮기기를 확인한다")
    func replanMigration() async {
        let (usb, _) = await store()
        service.update {
            $0.migrationWriteResult = .failure(.volumeLost(volumeName: "DJC191"))
            $0.journalAfterWrite = .state(.filesWritten)
        }
        prompter.answers = [true, false]
        let c = coordinator(usb)
        await c.migrate(image)
        service.update {
            $0.migrationWriteResult = .success(UsbWriteReport(outcome: .written, session: "m1"))
            $0.recoverResult = .success(UsbWriteReport(outcome: .needsReplan, session: "m1"))
            $0.journalAfterRecover = .state(.needsReplan)
            $0.journalAfterWrite = .state(.verified)
        }
        prompter.choices = [.confirm]
        prompter.answers = [true, false]
        service.update { $0.calls = [] }
        await c.offerRecovery(image)
        // 회복 뒤 옮기기를 다시 미리 보고 확인 창에서 멈춘다(쓰지 않음)
        #expect(service.current.called("recover", before: "previewMigration") && !service.current.wrote)
        #expect(prompter.shown.last == UsbWriteFlow.migrationConfirmation(service.current.migrationSummary, volume: image))
        #expect(usb.exportSheet == nil)
    }

    @Test("뒤에 다른 USB 편집을 쓰면 옮기기 백업·재계획 진입을 남기지 않는다")
    func subsequentEditClearsMigrationContext() async {
        let (usb, _) = await store()
        let c = coordinator(usb)
        await c.migrate(image)
        await c.writeDraft(volumeKey: image.usbKey, database: nil, share: nil)
        #expect(usb.migrationBackups[image.usbKey] == nil)
        #expect(!usb.lastMigrations.contains(image.usbKey))
    }

    @Test("옮기기 되돌리기에서 취소하거나 기기 변경을 버리지 않으면 백업과 USB 상태를 보존한다")
    func restoreCancelPreservesBackup() async {
        let (usb, _) = await store()
        let c = coordinator(usb)
        await c.migrate(image)
        let backup = usb.migrationBackups[image.usbKey]
        prompter.answer = false
        await c.restoreMigration(image)
        #expect(service.current.restoredBackups.isEmpty && usb.migrationBackups[image.usbKey] == backup)
        prompter.answers = [true, false]
        service.update { $0.deviceChanged = true }
        await c.restoreMigration(image)
        // 기기 변경을 버리지 않았다(되돌리기는 한 번 막히고 끝남)
        #expect(service.current.restored && !service.current.calls.contains("restore(discard)"))
        #expect(usb.migrationBackups[image.usbKey] == backup && usb.busyVolumes.isEmpty)
    }
}
