import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// 끊긴 USB 쓰기를 회복한 뒤 흐름이 따르는 기록의 순서(가짜 포트, USB 없이, #275):
/// 다시 미리 보기는 그 볼륨에서 마지막으로 시작한 쓰기를 잇고, 되돌리기 안의 회복이 다른 쓰기를 마저 쓰면 되돌리기 취소용 백업을 놓는다.
/// 시점 되돌리기의 같은 규칙은 `UsbPointRestoreFlowTests`
@MainActor
@Suite("USB 끊긴 뒤 회복의 작업 기록·되돌리기 취소 백업")
struct UsbRecoveryRecordsFlowTests {
    static let database = URL(filePath: "/private/tmp/djc-flow/master-copy.db")
    static let share = URL(filePath: "/private/tmp/djc-flow/share")
    static let restoreBackup = UsbPointRestoreFlowTests.restoreBackup
    static let migrationBackup = UsbPointRestoreFlowTests.migrationBackup
    static let recoveredBackup = "/private/tmp/djc-fixture/usb-backups/B2/w1"

    /// 초안 편집 한 건을 쓰는 미리 보기 요약
    static let editSummary = UsbEditSummary(editCount: 1, outcomes: [1: .written], stopping: [], skipped: [],
                                            formats: [.init(format: .oneLibrary, written: true)], removals: 0, deferred: [], notes: [],
                                            warnings: [], rules: [], hasChanges: true, isTestVolume: true, formatDrift: false)

    static func editWritten(session: String) -> UsbEditWritten {
        UsbEditWritten(summary: editSummary, report: UsbWriteReport(outcome: .written, session: session))
    }

    static var editConfirmTitle: String { UsbWriteFlow.editConfirmation(editSummary, volume: FakeUsbVolume.diskImageFAT32()).title }

    /// 초안 쓰기를 시작한다. 쓰는 중 볼륨이 빠진다(그 쓰기는 끊긴다)
    static func interruptedDraftWrite(_ world: UsbWriteWorld) async {
        world.service.state.withLock {
            $0.editSummary = .success(editSummary)
            $0.editWriteResult = .failure(.volumeLost(volumeName: "DJCTEST"))
        }
        #expect(await world.flow.writeDraft(volumeKey: world.volume.usbKey, database: database, share: share) == false)
        #expect(world.session.busyVolumes.isEmpty)
    }

    /// 다시 연결해 끝나지 않은 쓰기를 [회복하기]로 회복했더니 기기가 USB를 바꿔 이어 쓰지 못했다
    static func recoverNeedingReplan(_ world: UsbWriteWorld) async {
        world.service.state.withLock {
            $0.journal = .state(.committing)
            $0.recoverResult = .success(UsbWriteReport(outcome: .needsReplan, session: "d1"))
        }
        world.choice = .confirm
        await world.flow.offerRecovery(world.volume)
    }

    enum PriorWrite: CaseIterable { case export, migration }

    @Test("초안 쓰기가 끊긴 뒤 회복의 다시 미리 보기는 앞서 한 쓰기가 아니라 그 초안 쓰기를 다시 미리 보고 묻고 쓴다", arguments: PriorWrite.allCases)
    func replanFollowsTheDraftWrite(prior: PriorWrite) async throws {
        let world = UsbWriteWorld()
        let key = world.volume.usbKey
        // 같은 실행에서 앞서 한 쓰기: 내보내기·OneLibrary 더하기 기록이 남는다
        switch prior {
        case .export: #expect(await world.flow.export(world.job()) == true)
        case .migration: world.session.lastMigrations.insert(key)
        }
        let exportPreviews = world.service.calls.filter { $0 == "preview" }.count
        await Self.interruptedDraftWrite(world)
        world.service.state.withLock { $0.editWriteResult = .success(Self.editWritten(session: "d2")) }
        await Self.recoverNeedingReplan(world)

        #expect(world.prompts.contains(UsbWriteFlow.replanPrompt))
        #expect(world.exportSheet == nil, "내보내기 시트를 열지 않는다")
        #expect(!world.service.calls.contains("previewMigration"), "OneLibrary 더하기를 다시 미리 보지 않는다")
        #expect(world.service.calls.filter { $0 == "preview" }.count == exportPreviews, "내보내기를 다시 미리 보지 않는다")
        // 지금 USB 상태로 그 초안을 다시 미리 보고 묻고 쓴다
        #expect(world.service.calls.filter { $0 == "previewEdit" }.count == 2)
        #expect(world.prompts.filter { $0.title == Self.editConfirmTitle }.count == 2)
        #expect(world.service.calls.filter { $0 == "writeEdit" }.count == 2)
        guard case let .success(title, _, eject)? = world.toasts.last else { Issue.record("쓴 알림"); return }
        #expect(title == UsbWriteFlow.Text.editWrittenTitle(count: Self.editSummary.writtenCount) && eject == key)
        #expect(world.session.busyVolumes.isEmpty)
    }

    enum LaterWrite: CaseIterable { case export, migration, pointRestore }

    @Test("초안 쓰기 뒤에 시작한 쓰기가 끊기면 회복의 다시 미리 보기는 초안 쓰기가 아니라 그 쓰기를 따라간다", arguments: LaterWrite.allCases)
    func laterWriteTakesTheReplan(later: LaterWrite) async throws {
        let world = UsbWriteWorld()
        let ports = UsbPointRestoreFlowTests.ports()
        let snapshots = ports.pointSnapshots(directory: UsbPointRestoreFlowTests.directory)
        await Self.interruptedDraftWrite(world)
        let draftPreviews = world.service.calls.filter { $0 == "previewEdit" }.count
        switch later {
        case .export:
            world.service.state.withLock { $0.writeResult = .failure(.volumeLost(volumeName: "DJCTEST")) }
            #expect(await world.flow.export(world.job()) == false)
        case .migration:
            await world.flow.migrate(world.volume)
        case .pointRestore:
            ports.update { $0.writeResult = .failure(.volumeLost(volumeName: "DJCTEST")) }
            #expect(await world.flow.restorePointSnapshot(world.volume, entry: UsbPointSnapshotsFlowTests.entry(), snapshots: snapshots) == false)
            ports.update { $0.writeResult = .success(UsbWriteReport(outcome: .written, session: "p2", backup: Self.restoreBackup)) }
        }
        let previewsBefore = (world.service.calls.filter { $0 == "preview" }.count, world.service.calls.filter { $0 == "previewMigration" }.count,
                              ports.calls.filter { $0 == "pointPlan" }.count)
        await Self.recoverNeedingReplan(world)

        #expect(world.service.calls.filter { $0 == "previewEdit" }.count == draftPreviews, "초안 쓰기를 다시 미리 보지 않는다")
        #expect(world.service.calls.filter { $0 == "writeEdit" }.count == 1, "초안 쓰기를 다시 쓰지 않는다")
        switch later {
        case .export:
            #expect(world.service.calls.filter { $0 == "preview" }.count == previewsBefore.0 + 1)
            #expect(world.exportSheet?.job != nil, "그 내보내기를 다시 미리 본 시트")
        case .migration:
            #expect(world.service.calls.filter { $0 == "previewMigration" }.count == previewsBefore.1 + 1)
        case .pointRestore:
            #expect(ports.calls.filter { $0 == "pointPlan" }.count == previewsBefore.2 + 2)
        }
    }

    @Test("초안 쓰기를 마친 뒤 다른 곳에서 끊긴 쓰기의 다시 미리 보기는 끝난 초안 쓰기를 되풀이하지 않는다")
    func finishedDraftWriteIsNotRetried() async throws {
        let world = UsbWriteWorld()
        world.service.state.withLock {
            $0.editSummary = .success(Self.editSummary)
            $0.editWriteResult = .success(Self.editWritten(session: "d1"))
        }
        #expect(await world.flow.writeDraft(volumeKey: world.volume.usbKey, database: Self.database, share: Self.share) == true)
        let writes = world.service.calls.filter { $0 == "writeEdit" }.count
        await Self.recoverNeedingReplan(world)

        #expect(world.prompts.contains(UsbWriteFlow.replanPrompt))
        #expect(world.service.calls.filter { $0 == "writeEdit" }.count == writes, "다시 쓰지 않는다")
        #expect(world.exportSheet?.volume == world.volume, "어느 쓰기도 이어 가지 않으니 빈 내보내기 시트를 연다")
    }

    @Test("내보내기 뒤 초안 쓰기를 마치면, 다른 곳에서 끊긴 쓰기의 다시 미리 보기는 앞서 한 내보내기도 되풀이하지 않는다")
    func finishedDraftWriteReplacesTheExportRecord() async throws {
        let world = UsbWriteWorld()
        #expect(await world.flow.export(world.job()) == true)
        world.service.state.withLock {
            $0.editSummary = .success(Self.editSummary)
            $0.editWriteResult = .success(Self.editWritten(session: "d1"))
        }
        #expect(await world.flow.writeDraft(volumeKey: world.volume.usbKey, database: Self.database, share: Self.share) == true)
        let exportPreviews = world.service.calls.filter { $0 == "preview" }.count
        await Self.recoverNeedingReplan(world)

        #expect(world.prompts.contains(UsbWriteFlow.replanPrompt))
        #expect(world.service.calls.filter { $0 == "preview" }.count == exportPreviews, "옛 내보내기를 다시 미리 보지 않는다")
        #expect(world.exportSheet?.job == nil && world.exportSheet?.volume == world.volume, "어느 쓰기도 이어 가지 않으니 빈 내보내기 시트를 연다")
    }

    @Test("확인 창에서 멈춘 초안 쓰기 뒤에 시점 되돌리기를 마치면, 다른 곳에서 끊긴 쓰기의 다시 미리 보기는 그 초안 쓰기를 되살리지 않는다")
    func pointRestoreReplacesAStoppedDraftRecord() async throws {
        let world = UsbWriteWorld()
        let ports = UsbPointRestoreFlowTests.ports()
        let snapshots = ports.pointSnapshots(directory: UsbPointRestoreFlowTests.directory)
        world.service.state.withLock { $0.editSummary = .success(Self.editSummary) }
        world.answers = [false]
        #expect(await world.flow.writeDraft(volumeKey: world.volume.usbKey, database: Self.database, share: Self.share) == false)
        #expect(!world.service.calls.contains("writeEdit"), "확인 창에서 멈췄다")
        #expect(await world.flow.restorePointSnapshot(world.volume, entry: UsbPointSnapshotsFlowTests.entry(), snapshots: snapshots) == true)
        let draftPreviews = world.service.calls.filter { $0 == "previewEdit" }.count
        await Self.recoverNeedingReplan(world)

        #expect(world.prompts.contains(UsbWriteFlow.replanPrompt))
        #expect(world.service.calls.filter { $0 == "previewEdit" }.count == draftPreviews, "멈춘 초안 쓰기를 다시 미리 보지 않는다")
        #expect(world.exportSheet?.volume == world.volume)
    }

    enum RestoreFailure: CaseIterable {
        /// 그 사이 기기가 USB를 바꿔 버리기 확인을 거부했다
        case deviceChangedDeclined
        /// 그 밖의 실패(예: 그 사이 rekordbox가 켜져 막힘)
        case otherFailure
        case succeeds
    }

    @Test("되돌리기 안의 회복이 다른 쓰기를 마저 썼으면, 뒤 복원이 거부·실패해도 되돌리기 취소용 백업(시점 복원·옮기기)을 놓는다",
          arguments: RestoreFailure.allCases)
    func revertThatRecoveredDropsUndoBackups(failure: RestoreFailure) async throws {
        let world = UsbWriteWorld()
        let key = world.volume.usbKey
        world.session.pointRestoreBackups[key] = URL(filePath: Self.restoreBackup)
        world.session.migrationBackups[key] = Self.migrationBackup
        world.service.state.withLock {
            $0.journal = .state(.committing)
            $0.recoverResult = .success(UsbWriteReport(outcome: .recovered, session: "w1", backup: Self.recoveredBackup))
            switch failure {
            case .deviceChangedDeclined:
                $0.restoreResult = .failure(.writeRefused([UsbBlock(code: "deviceChanged", scope: .volume, message: "기기가 USB를 바꿨습니다")]))
            case .otherFailure:
                $0.restoreResult = .failure(.writeRefused([UsbBlock(code: "rekordboxRunning", scope: .volume, message: "rekordbox가 켜져 있습니다")]))
            case .succeeds: break
            }
        }
        if failure == .deviceChangedDeclined { world.answers = [false] }
        world.choice = .alternate
        await world.flow.offerRecovery(world.volume)

        #expect(world.service.calls.suffix(2) == ["recover", "restore"], "회복한 뒤 그 쓰기의 백업으로 복원하러 갔다")
        #expect(world.session.pointRestoreBackups[key] == nil, "되돌리기 취소…가 남으면 기기 변경 동의로 잘못 묻는다")
        #expect(world.session.migrationBackups[key] == nil)
        #expect(world.session.busyVolumes.isEmpty)
    }

    @Test("되돌리기 안의 회복이 다른 쓰기를 쓰지 않았으면(다시 계획) 복원이 실패해도 되돌리기 취소용 백업을 그대로 둔다")
    func revertThatRecoveredNothingKeepsUndoBackups() async throws {
        let world = UsbWriteWorld()
        let key = world.volume.usbKey
        world.session.pointRestoreBackups[key] = URL(filePath: Self.restoreBackup)
        world.session.migrationBackups[key] = Self.migrationBackup
        world.service.state.withLock {
            $0.journal = .state(.committing)
            $0.recoverResult = .success(UsbWriteReport(outcome: .needsReplan, session: "w1", backup: Self.recoveredBackup))
            $0.restoreResult = .failure(.writeRefused([UsbBlock(code: "rekordboxRunning", scope: .volume, message: "rekordbox가 켜져 있습니다")]))
        }
        world.choice = .alternate
        await world.flow.offerRecovery(world.volume)

        #expect(world.service.calls.suffix(2) == ["recover", "restore"])
        #expect(world.session.pointRestoreBackups[key] == URL(filePath: Self.restoreBackup))
        #expect(world.session.migrationBackups[key] == Self.migrationBackup)
    }
}
