import DJCApplication
import DJCDomain
import Foundation
import Testing

/// USB 쓰기 흐름의 판정(`UsbWriteDecision`): 앱 쓰기 흐름이 실패·저널·회복 보고를 무엇으로 보는지
@Suite("USB 쓰기 흐름 판정")
struct UsbWriteDecisionTests {
    static let recoveryBlock = UsbBlock(code: "recoveryNeeded", scope: .volume, message: "회복 먼저")

    @Test("쓰기 실패: 취소·끝나지 않은 쓰기(오류 또는 쓰기 전 막힘)·그 밖")
    func afterWrite() {
        #expect(UsbWriteDecision.afterWrite(UsbError.cancelled) == .cancelled)
        #expect(UsbWriteDecision.afterWrite(UsbError.recoveryNeeded(volumeName: "B")) == .recoveryNeeded)
        // 확인 뒤·쓰기 전에 다른 곳(CLI 등)이 저널을 열면 쓰기 절차는 막힘으로 알린다
        #expect(UsbWriteDecision.afterWrite(UsbError.writeRefused([Self.recoveryBlock])) == .recoveryNeeded)
        #expect(UsbWriteDecision.afterWrite(UsbError.writeRefused([UsbBlock(code: "physicalDisabled", scope: .volume, message: "실물")])) == .failed)
        #expect(UsbWriteDecision.afterWrite(UsbError.volumeLost(volumeName: "B")) == .failed)
        #expect(UsbWriteDecision.afterWrite(CocoaError(.fileNoSuchFile)) == .failed)
    }

    @Test("미리 보기 실패: 볼륨이 빠지거나 바뀐 것은 쓰기 실패처럼, 취소는 취소, 그 밖은 미리 보기 실패")
    func afterPreview() {
        #expect(UsbWriteDecision.afterPreview(UsbError.volumeLost(volumeName: "B")) == .volumeGone)
        #expect(UsbWriteDecision.afterPreview(UsbError.volumeChanged(volumeName: "B")) == .volumeGone)
        #expect(UsbWriteDecision.afterPreview(UsbError.cancelled) == .cancelled)
        #expect(UsbWriteDecision.afterPreview(UsbError.readFailed(detail: "x")) == .previewFailed)
        #expect(UsbWriteDecision.afterPreview(UsbError.writeRefused([Self.recoveryBlock])) == .previewFailed)
    }

    @Test("쓰기 직전 저널: 닫힌 상태(드라이 런·다시 계획 포함)는 지나가고, 열린 저널은 회복부터, 읽지 못하면 멈춘다")
    func journalCheck() {
        #expect(UsbWriteDecision.journalCheck(.none) == .proceed)
        for state in UsbJournalState.closed { #expect(UsbWriteDecision.journalCheck(.state(state)) == .proceed) }
        for state in UsbJournalState.allCases where !UsbJournalState.closed.contains(state) {
            #expect(UsbWriteDecision.journalCheck(.state(state)) == .recoveryNeeded)
        }
        #expect(UsbWriteDecision.journalCheck(.unreadable) == .unreadable)
    }

    @Test("회복 보고: 다시 계획·되돌림·되돌리기 마침·마저 씀, 저널이 없던 회복은 한 일이 없다")
    func recovery() {
        func report(_ outcome: UsbWriteReport.Outcome, session: String = "s1") -> UsbWriteReport { UsbWriteReport(outcome: outcome, session: session) }
        #expect(UsbWriteDecision.recovery(report(.needsReplan)) == .needsReplan)
        #expect(UsbWriteDecision.recovery(report(.rolledBack)) == .rolledBack)
        #expect(UsbWriteDecision.recovery(report(.restored)) == .restored)
        #expect(UsbWriteDecision.recovery(report(.recovered)) == .recovered)
        #expect(UsbWriteDecision.recovery(report(.recovered, session: "")) == .nothingToRecover)
        #expect(UsbWriteDecision.recovery(report(.written)) == .nothingToRecover)
    }

    @Test("되돌리기: 회복이 이미 되돌렸으면 끝, 그 쓰기의 백업이 있을 때만 그 백업으로, 저널·백업이 없으면 다른 백업을 고르지 않는다")
    func revertStep() {
        #expect(UsbWriteDecision.revertStep(afterRecover: UsbWriteReport(outcome: .rolledBack, session: "s1")) == .alreadyRestored)
        #expect(UsbWriteDecision.revertStep(afterRecover: UsbWriteReport(outcome: .restored, session: "s1")) == .alreadyRestored)
        let backup = "/private/tmp/djc-fixture/usb-backups/K/s1"
        #expect(UsbWriteDecision.revertStep(afterRecover: UsbWriteReport(outcome: .recovered, session: "s1", backup: backup))
            == .restore(backup: URL(filePath: backup)))
        #expect(UsbWriteDecision.revertStep(afterRecover: UsbWriteReport(outcome: .recovered, session: "", backup: backup)) == .backupMissing)
        #expect(UsbWriteDecision.revertStep(afterRecover: UsbWriteReport(outcome: .recovered, session: "s1", backup: "")) == .backupMissing)
        #expect(UsbWriteDecision.revertStep(afterRecover: UsbWriteReport(outcome: .recovered, session: "s1")) == .backupMissing)
    }

    @Test("되돌리기가 기기 변경으로 막히면 한 번만 버릴지 묻는다")
    func discardDeviceChanges() {
        let changed = UsbError.writeRefused([UsbBlock(code: "deviceChanged", scope: .volume, message: "기기 변경")])
        #expect(UsbWriteDecision.asksToDiscardDeviceChanges(changed, discarding: false))
        #expect(!UsbWriteDecision.asksToDiscardDeviceChanges(changed, discarding: true))
        #expect(!UsbWriteDecision.asksToDiscardDeviceChanges(UsbError.writeRefused([Self.recoveryBlock]), discarding: false))
        #expect(!UsbWriteDecision.asksToDiscardDeviceChanges(UsbError.cancelled, discarding: false))
    }
}
