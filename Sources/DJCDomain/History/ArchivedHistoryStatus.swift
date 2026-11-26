import Foundation

/// 보존 기록 하나의 rekordbox 저장 상태(입출력 없음, 사이드바 기록 줄이 읽는다, #311).
/// USB 기기 기록과 LINK 기록이 같은 상태를 쓴다. 판정은 `of`의 위에서 아래 순서다.
public enum ArchivedHistoryStatus: Sendable, Equatable, CaseIterable {
    /// LINK로 내어 주는 동안 곡이 계속 붙는 기록(LINK를 끄면 저장 대기에 오른다)
    case recording
    /// rekordbox 저장 대기에 올라 있다
    case pending
    /// 사용자가 저장 대기에서 뺐다
    case excluded
    /// rekordbox에 저장했고 지금 라이브러리에도 있다
    case written
    /// 같은 곡이 두 번 이상 들어 DJCrate가 저장하지 않는다(`HistoryWriteQueue.hasRepeatedTracks`)
    case repeatedTracks
    /// 컬렉션에 있는 곡이 하나도 없어 저장하지 않는다
    case noCollectionTracks
    /// 위 어디도 아니다: 저장 대기에 오르지 않았고 rekordbox에도 없다
    case notInRekordbox

    /// - Parameters:
    ///   - isPending: 쓰기 대기에 오른 기록인지(`UsbHistoryView.pending`)
    ///   - openLinkSessions: 연결 중인 LINK 세션(`LinkHistory.isOpen`)
    ///   - rekordboxHasHistory: 그 ID의 기록이 지금 rekordbox 라이브러리(스냅샷)에 있는지
    public static func of(_ history: ArchivedHistory, isPending: Bool, openLinkSessions: Set<String>,
                          rekordboxHasHistory: (String) -> Bool) -> ArchivedHistoryStatus {
        if LinkHistory.isOpen(history, openSessions: openLinkSessions) { return .recording }
        if isPending { return .pending }
        if history.excludedFromRekordbox { return .excluded }
        if let id = history.rekordboxHistoryID, rekordboxHasHistory(id) { return .written }
        if HistoryWriteQueue.hasRepeatedTracks(history) { return .repeatedTracks }
        if history.matchedContentIDs.isEmpty { return .noCollectionTracks }
        return .notInRekordbox
    }
}
