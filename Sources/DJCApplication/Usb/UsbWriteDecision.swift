import DJCDomain
import Foundation

/// USB 쓰기 흐름의 판정: 실패·저널·회복 보고를 무엇으로 볼지. 앱 쓰기 흐름(`UsbWriteCoordinator`)은 순서·잠금·창을 맡고
/// 판정은 여기서 받는다(순수 규칙, 시험은 DJCApplicationTests)
public enum UsbWriteDecision {
    /// 쓰기·옮기기 실패를 무엇으로 볼지
    public enum WriteFailure: Equatable, Sendable {
        case cancelled
        /// 끝나지 않은 쓰기가 있다(회복 알림으로)
        case recoveryNeeded
        case failed
    }

    /// 확인 뒤·쓰기 전에 다른 곳(CLI 등)이 저널을 열었으면 쓰기 절차는 막힘(`recoveryNeeded` code)으로 알린다
    public static func afterWrite(_ error: any Error) -> WriteFailure {
        switch error as? UsbError {
        case .cancelled?: .cancelled
        case .recoveryNeeded?: .recoveryNeeded
        case let .writeRefused(blocks)? where blocks.contains(where: { $0.code == "recoveryNeeded" }): .recoveryNeeded
        default: .failed
        }
    }

    /// 미리 보기(Mac 사본에서 계획) 실패를 무엇으로 볼지
    public enum PreviewFailure: Equatable, Sendable {
        /// 볼륨이 빠지거나 바뀌었다: 쓰기 실패처럼 알린다(동기화 초안 사본을 놓는다)
        case volumeGone
        case cancelled
        /// USB에는 쓰지 않았다: 미리 보기 실패로 알린다(되돌림으로 알리지 않는다)
        case previewFailed
    }

    public static func afterPreview(_ error: any Error) -> PreviewFailure {
        switch error as? UsbError {
        case .volumeLost?, .volumeChanged?: .volumeGone
        case .cancelled?: .cancelled
        default: .previewFailed
        }
    }

    /// 쓰기 직전 저널: 끝나지 않은 쓰기(닫힌 상태가 아닌 저널)가 생겼으면 회복부터, 읽지 못하면 멈춘다
    public enum JournalCheck: Equatable, Sendable {
        case proceed
        case recoveryNeeded
        case unreadable
    }

    public static func journalCheck(_ journal: UsbJournalInfo) -> JournalCheck {
        if journal.isPending { return .recoveryNeeded }
        if journal == .unreadable { return .unreadable }
        return .proceed
    }

    /// 회복 보고 → 알릴 결과
    public enum Recovery: Equatable, Sendable {
        /// 기기가 USB를 바꿔 이어 쓰지 않았다: 지금 USB 상태로 다시 미리 보기를 권한다
        case needsReplan
        /// 끊긴 쓰기를 되돌렸다
        case rolledBack
        /// 끊긴 되돌리기를 마쳤다
        case restored
        /// 끊긴 쓰기를 마저 썼다
        case recovered
        /// 저널이 없었다(다른 곳에서 이미 닫았다)
        case nothingToRecover
    }

    public static func recovery(_ report: UsbWriteReport) -> Recovery {
        switch report.outcome {
        case .needsReplan: .needsReplan
        case .rolledBack: .rolledBack
        case .restored: .restored
        case .recovered where !report.session.isEmpty: .recovered
        default: .nothingToRecover
        }
    }

    /// 되돌리기: 끝나지 않은 저널을 회복으로 닫은 뒤 할 일. 그 쓰기의 백업으로만 되돌린다
    /// (저널이 없었거나 백업이 없으면 다른 쓰기의 백업을 고르지 않는다)
    public enum RevertStep: Equatable, Sendable {
        /// 회복이 이미 쓰기 전으로 되돌렸다(끊긴 쓰기 되돌림·끊긴 되돌리기 마침)
        case alreadyRestored
        case restore(backup: URL)
        case backupMissing
    }

    public static func revertStep(afterRecover report: UsbWriteReport) -> RevertStep {
        if report.outcome == .rolledBack || report.outcome == .restored { return .alreadyRestored }
        guard !report.session.isEmpty, let path = report.backup, !path.isEmpty else { return .backupMissing }
        return .restore(backup: URL(filePath: path))
    }

    /// 되돌리기가 기기가 그 뒤에 바꾼 것 때문에 막혔고 아직 버리기를 묻지 않았으면 한 번 더 묻는다
    public static func asksToDiscardDeviceChanges(_ error: any Error, discarding: Bool) -> Bool {
        guard !discarding, case let .writeRefused(blocks)? = error as? UsbError else { return false }
        return blocks.contains { $0.code == "deviceChanged" }
    }
}
