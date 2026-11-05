import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// 시점 스냅샷 되돌리기를 쓰기 흐름에 이은 순서(가짜 포트, USB 없이): 끊긴 뒤 회복의 다시 미리 보기·되돌리기 취소 백업·알림 종류.
/// 계획·판정 규칙은 `UsbPointSnapshotsFlowTests`, 확인 창·토스트 연결은 DJCrateTests `UsbPointSnapshotsModelTests`
@MainActor
@Suite("USB 시점 스냅샷 되돌리기 쓰기 흐름")
struct UsbPointRestoreFlowTests {
    static let restoreBackup = "/private/tmp/djc-fixture/usb-backups/B1/p1"
    static let migrationBackup = URL(filePath: "/private/tmp/djc-fixture/usb-backups/B0/m1")
    static let directory = UsbPointSnapshotsFlowTests.directory

    /// 스냅샷 뒤 DJCrate 쓰기만 있었고(동의 없이 쓴다) 바꿀 것이 있는 USB. 쓰면 백업 `restoreBackup`을 남긴다
    static func ports(plan: UsbPointRestoreResult = UsbPointSnapshotsFlowTests.planned()) -> FakeUsbPorts {
        FakeUsbPorts {
            $0.fingerprints = [UsbPointSnapshotsFlowTests.fingerprint("쓴 결과")]
            $0.volumeEvents = [UsbPointSnapshotsFlowTests.ourWrite]
            $0.pointPlan = plan
            $0.writeResult = .success(UsbWriteReport(outcome: .written, session: "p1", backup: restoreBackup))
        }
    }

    static var restoreTitle: String {
        UsbWriteFlow.pointRestoreConfirmation(FakeUsbVolume.diskImageFAT32(), entry: UsbPointSnapshotsFlowTests.entry(),
                                              summary: UsbPointRestoreSummary(result: UsbPointSnapshotsFlowTests.planned(), blocks: [],
                                                                              deviceChanged: false)).title
    }

    enum PriorWrite: CaseIterable { case export, migration }

    @Test("시점 되돌리기가 끊긴 뒤 회복의 다시 미리 보기는 앞서 한 쓰기가 아니라 그 시점 되돌리기를 다시 연다", arguments: PriorWrite.allCases)
    func replanFollowsThePointRestore(prior: PriorWrite) async throws {
        let world = UsbWriteWorld()
        let ports = Self.ports()
        let snapshots = ports.pointSnapshots(directory: Self.directory)
        let entry = UsbPointSnapshotsFlowTests.entry()
        let key = world.volume.usbKey
        // 같은 실행에서 앞서 한 쓰기: 내보내기·OneLibrary 더하기 기록이 남는다
        switch prior {
        case .export: #expect(await world.flow.export(world.job()) == true)
        case .migration: world.session.lastMigrations.insert(key)
        }
        let exportPreviews = world.service.calls.filter { $0 == "preview" }.count
        // 시점 되돌리기를 쓰는 중 볼륨이 빠졌다
        ports.update { $0.writeResult = .failure(.volumeLost(volumeName: "DJCTEST")) }
        #expect(await world.flow.restorePointSnapshot(world.volume, entry: entry, snapshots: snapshots) == false)
        // 다시 연결: 끝나지 않은 쓰기를 회복하라는 알림에서 [회복하기]. 기기가 USB를 바꿔 이어 쓰지 못한다
        world.service.state.withLock {
            $0.journal = .state(.committing)
            $0.recoverResult = .success(UsbWriteReport(outcome: .needsReplan, session: "p1"))
        }
        ports.update { $0.writeResult = .success(UsbWriteReport(outcome: .written, session: "p2", backup: Self.restoreBackup)) }
        world.choice = .confirm
        let plansBefore = ports.calls.filter { $0 == "pointPlan" }.count
        await world.flow.offerRecovery(world.volume)

        #expect(world.prompts.contains(UsbWriteFlow.replanPrompt))
        #expect(world.exportSheet == nil, "내보내기 시트를 열지 않는다")
        #expect(!world.service.calls.contains("previewMigration"), "OneLibrary 더하기를 다시 미리 보지 않는다")
        #expect(world.service.calls.filter { $0 == "preview" }.count == exportPreviews, "내보내기를 다시 미리 보지 않는다")
        // 지금 USB 상태로 그 시점 되돌리기를 다시 미리 보고 묻고 쓴다
        #expect(ports.calls.filter { $0 == "pointPlan" }.count == plansBefore + 2, "미리 보기와 쓰기 준비가 각각 계획한다")
        #expect(world.prompts.filter { $0.title == Self.restoreTitle }.count == 2)
        #expect(ports.current.writes.map(\.verification) == ["pointRestore", "pointRestore"])
        #expect(world.toasts.last == .success(title: "USB를 시점 스냅샷으로 되돌렸습니다", detail: entry.displayName, ejectVolumeKey: key))
        #expect(world.session.busyVolumes.isEmpty)
    }

    @Test("회복이 다른 쓰기를 마저 쓰거나 끊긴 되돌리기를 마치면, 되돌리기 취소용 백업(시점 복원·옮기기)을 놓는다",
          arguments: [UsbWriteReport.Outcome.recovered, .restored])
    func recoveryDropsUndoBackups(outcome: UsbWriteReport.Outcome) async throws {
        let world = UsbWriteWorld()
        let ports = Self.ports()
        let snapshots = ports.pointSnapshots(directory: Self.directory)
        let key = world.volume.usbKey
        // 시점 복원 성공: 되돌리기 취소 백업이 남는다. 옮기기 백업도 이 실행에 남아 있다
        #expect(await world.flow.restorePointSnapshot(world.volume, entry: UsbPointSnapshotsFlowTests.entry(), snapshots: snapshots) == true)
        world.session.migrationBackups[key] = Self.migrationBackup
        #expect(world.session.pointRestoreBackups[key] == URL(filePath: Self.restoreBackup))
        // 다른 쓰기(내보내기)가 볼륨이 빠져 끊겼다
        world.service.state.withLock { $0.writeResult = .failure(.volumeLost(volumeName: "DJCTEST")) }
        #expect(await world.flow.export(world.job()) == false)
        #expect(world.session.pointRestoreBackups[key] != nil && world.session.migrationBackups[key] != nil, "끊긴 것만으로는 놓지 않는다")
        // 다시 연결해 [회복하기]: 그 쓰기를 마저 썼다
        world.service.state.withLock {
            $0.journal = .state(.committing)
            $0.recoverResult = .success(UsbWriteReport(outcome: outcome, session: "w1"))
        }
        world.choice = .confirm
        await world.flow.offerRecovery(world.volume)

        #expect(world.service.calls.suffix(1) == ["recover"])
        #expect(world.session.pointRestoreBackups[key] == nil, "되돌리기 취소…가 남으면 기기 변경 동의로 잘못 묻는다")
        #expect(world.session.migrationBackups[key] == nil)
    }

    @Test("끊긴 되돌리기를 [되돌리기]로 마치면 되돌리기 취소용 백업을 놓고, 끊긴 쓰기를 되돌렸을 뿐이면 그대로 둔다",
          arguments: [UsbWriteReport.Outcome.restored, .rolledBack])
    func revertDropsUndoBackupsOnlyWhenRestoreFinished(outcome: UsbWriteReport.Outcome) async throws {
        let world = UsbWriteWorld()
        let key = world.volume.usbKey
        world.session.pointRestoreBackups[key] = URL(filePath: Self.restoreBackup)
        world.session.migrationBackups[key] = Self.migrationBackup
        world.service.state.withLock {
            $0.journal = .state(.committing)
            $0.recoverResult = .success(UsbWriteReport(outcome: outcome, session: "w1"))
        }
        world.choice = .alternate
        await world.flow.offerRecovery(world.volume)
        #expect(world.toasts.last == .success(title: UsbWriteFlow.Text.restoredTitle))
        let kept = outcome == .rolledBack
        #expect((world.session.pointRestoreBackups[key] != nil) == kept && (world.session.migrationBackups[key] != nil) == kept)
    }

    @Test("회복이 끊긴 쓰기를 되돌렸거나 회복할 것이 없었으면 되돌리기 취소용 백업을 그대로 둔다")
    func recoveryThatWritesNothingKeepsBackups() async throws {
        // 저널 없음(다른 곳에서 이미 닫았다)은 세션이 빈 `.recovered`로 온다
        for report in [UsbWriteReport(outcome: .rolledBack, session: "w1"), UsbWriteReport(outcome: .recovered, session: "")] {
            let world = UsbWriteWorld()
            let key = world.volume.usbKey
            world.session.pointRestoreBackups[key] = URL(filePath: Self.restoreBackup)
            world.session.migrationBackups[key] = Self.migrationBackup
            world.service.state.withLock {
                $0.journal = .state(.committing)
                $0.recoverResult = .success(report)
            }
            world.choice = .confirm
            await world.flow.offerRecovery(world.volume)
            #expect(world.service.calls.suffix(1) == ["recover"])
            #expect(world.session.pointRestoreBackups[key] == URL(filePath: Self.restoreBackup), "\(report.outcome)")
            #expect(world.session.migrationBackups[key] == Self.migrationBackup, "\(report.outcome)")
        }
    }

    @Test("USB가 이미 시점 스냅샷과 같으면 성공 토스트가 아니라 USB에 손대지 않은 안내로 알린다")
    func alreadyEqualIsNotice() async throws {
        let world = UsbWriteWorld()
        let ports = Self.ports(plan: UsbPointRestoreResult())
        let snapshots = ports.pointSnapshots(directory: Self.directory)
        #expect(await world.flow.restorePointSnapshot(world.volume, entry: UsbPointSnapshotsFlowTests.entry(), snapshots: snapshots) == false)
        #expect(world.toasts == [.notice(title: UsbWriteFlow.Text.nothingToWriteTitle, text: "USB가 이미 시점 스냅샷과 같습니다")])
        #expect(world.prompts.isEmpty && ports.current.writes.isEmpty, "묻지도 쓰지도 않는다")
        #expect(world.session.busyVolumes.isEmpty && world.session.pointRestoreBackups.isEmpty)
    }
}
