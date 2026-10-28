import DJCDomain
import Foundation
import Observation

/// 창 아래 상태 줄의 화면 모델(#298): 오른쪽 활동 단추의 읽지 않은 수와 활동 팝오버(최근 알림·펼친 항목).
/// 읽지 않은 알림은 읽음 기준 시각보다 늦게 뜬 경고·실패와 띄우지 못한 알림이다. 팝오버나 활동 기록 창을 열고 닫을 때 기준을 옮긴다.
/// 기준은 설정(`SettingKeys.activitySeenThrough`)에 두어 앱을 다시 켜도 이어진다. 조립 지점(`AppComposition.statusBar`)이 한 번 만든다.
@MainActor
@Observable
final class StatusBarModel {
    /// 팝오버에 보이는 최근 항목 수
    static let recentLimit = 10
    @ObservationIgnored let log: ActivityLog
    /// 자가 테스트·시험이 상태 줄 자리를 찾는 이름(`SelfTestFrames`)
    @ObservationIgnored let frameKey = "statusBar.\(UUID().uuidString)"
    @ObservationIgnored private let settings: SettingsStore
    /// 활동 기록 창을 연다(모두 보기·항목의 활동 기록에서 보기). 조립 지점이 주 창 모델에 잇는다
    @ObservationIgnored var showLog: (ActivityEntry.ID?) -> Void = { _ in }
    /// 같은 줄의 rekordbox 쓰기 상태(#324). 조립 지점이 한 번 붙인다. 주 창이 상태 줄을 이 모델 하나로 만들 수 있게 여기서 건넨다
    @ObservationIgnored var write: ReflectionStatusModel?
    /// 이 시각까지 뜬 알림은 읽었다
    private(set) var seenThrough: Date
    /// 팝오버를 연 동안 참. 열 때와 닫을 때 그때까지 뜬 알림을 읽음으로 본다(연 동안 뜬 알림도 팝오버에 보였다)
    var isPresented = false {
        didSet {
            guard isPresented != oldValue else { return }
            if isPresented {
                fresh = Set(log.entries.filter(isUnread).map(\.id))
            } else {
                fresh = []
                expanded = nil
            }
            markSeen()
        }
    }
    /// 팝오버에서 펼친 항목
    var expanded: ActivityEntry.ID?
    /// 이번에 팝오버를 열 때 읽지 않았던 항목(줄에 점을 단다)
    private(set) var fresh: Set<ActivityEntry.ID> = []

    init(log: ActivityLog, settings: SettingsStore) {
        self.log = log
        self.settings = settings
        seenThrough = Date(timeIntervalSinceReferenceDate: settings.value(SettingKeys.activitySeenThrough))
    }

    var recent: [ActivityEntry] { Array(log.entries.prefix(Self.recentLimit)) }
    var unreadCount: Int { log.entries.filter(isUnread).count }
    /// 읽지 않은 알림 가운데 가장 무거운 종류(점의 색). 없으면 nil
    var unreadKind: AppToast.Kind? {
        let kinds = Set(log.entries.filter(isUnread).map(\.kind))
        return [AppToast.Kind.failure, .warning, .success].first(where: kinds.contains)
    }

    func isUnread(_ entry: ActivityEntry) -> Bool { entry.needsAttention && entry.date > seenThrough }

    func togglePopover() { isPresented.toggle() }

    func toggleExpanded(_ entry: ActivityEntry.ID) { expanded = expanded == entry ? nil : entry }

    /// 알림의 [열기]: 팝오버를 열어 그 항목을 펼친다. 최근 항목 밖으로 밀려났으면 활동 기록 창에서 고른다
    func open(_ entry: ActivityEntry.ID?) {
        guard let entry, recent.contains(where: { $0.id == entry }) else {
            showAll(selecting: entry)
            return
        }
        isPresented = true
        expanded = entry
    }

    /// 활동 기록 창을 연다(팝오버는 닫는다). 항목을 주면 그 항목을 고른다
    func showAll(selecting entry: ActivityEntry.ID? = nil) {
        isPresented = false
        showLog(entry)
    }

    /// 지금까지 뜬 알림을 읽음으로 본다. 기준은 기록에서 가장 늦은 시각이다. 항목은 기록한 순서라 시계가 거꾸로 갔으면 맨 앞이 가장 늦지 않다.
    /// 지금 시각은 쓰지 않는다(시계가 앞서 있을 때 열면 기준이 미래로 가 그 뒤 알림을 놓친다). 기준은 뒤로 가지 않는다.
    /// 팝오버를 여닫을 때와 활동 기록 창을 여닫을 때(`LibraryWindowModel.activityLogSeen`) 부른다
    func markSeen() {
        let mark = max(log.entries.map(\.date).max() ?? .distantPast, seenThrough)
        guard mark > seenThrough else { return }
        seenThrough = mark
        settings.set(SettingKeys.activitySeenThrough, mark.timeIntervalSinceReferenceDate)
    }
}
