import Foundation

/// USB 쓰기 저널의 단계(`UsbJournal.State`, 저장 형식은 원시값 그대로). 유스케이스가 저널 상태를 보고 막거나 알리도록 값만 DJCDomain에 둔다
public enum UsbJournalState: String, Codable, Sendable, CaseIterable {
    case planned, staged, backedUp, filesWritten, committing, committed, cleaned, verified
    case rolledBack, restoreFailed, restorePending, needsReplan, dryRun, recovered, restored

    /// 닫힌 상태. 닫힌 저널은 다음 쓰기를 막지 않는다(드라이 런·다시 계획 포함). 앱·회복·백업 정리도 이것만 본다
    public static let closed: Set<UsbJournalState> = [.verified, .rolledBack, .restored, .recovered, .dryRun, .needsReplan]

    public var isClosed: Bool { Self.closed.contains(self) }
}
