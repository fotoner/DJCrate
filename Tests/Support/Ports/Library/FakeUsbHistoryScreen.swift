import DJCApplication
import DJCDomain
import Foundation

/// USB 기록 보존 흐름(`ArchiveUsbHistories`)이 보는 재생 기록 화면의 가짜. 보존본·짝짓기 키·숨김·쓰기 대기를 메모리에 두고 받은 알림을 차례로 남긴다.
/// 보존본을 넣을 때마다 `refresh`로 숨김·쓰기 대기를 다시 고른다(앱의 재생 기록 조각이 `UsbHistoryRules.view`로 고르는 자리).
@MainActor
public final class FakeUsbHistoryScreen {
    public var state = UsbHistoryState()
    /// 보존본을 넣은 뒤 숨김·쓰기 대기를 다시 고른다(주지 않으면 그대로 둔다)
    public var refresh: ((inout UsbHistoryState) -> Void)?
    /// 받은 알림(차례대로): "archived <ID…>", "awaiting <ID…>", "loaded", "imported <보일 ID…>", "notice <제목>"
    public private(set) var events: [String] = []
    /// 받은 알림 문구(차례대로, 읽기·가져오기에 붙은 것 포함)
    public private(set) var notices: [UsbHistoryNotice] = []
    /// 마지막으로 알린 "새로 보존한 기록"
    public private(set) var imported: (shown: [String], saved: Set<String>)?

    public init() {}

    public var port: UsbHistoryScreen {
        UsbHistoryScreen(state: { [weak self] in self?.state ?? UsbHistoryState() }, apply: { [weak self] in self?.apply($0) })
    }

    private func apply(_ change: UsbHistoryChange) {
        switch change {
        case let .archived(histories):
            state.archived = histories
            refresh?(&state)
            events.append("archived \(histories.map(\.id).joined(separator: ","))")
        case let .awaitingReload(ids):
            events.append("awaiting \(ids.sorted().joined(separator: ","))")
        case let .loaded(notice):
            events.append("loaded")
            if let notice { notices.append(notice) }
        case let .imported(shown, saved, notice):
            imported = (shown, saved)
            events.append("imported \(shown.joined(separator: ","))")
            if let notice { notices.append(notice) }
        case let .notice(notice):
            notices.append(notice)
            events.append("notice \(notice.title)")
        }
    }
}
