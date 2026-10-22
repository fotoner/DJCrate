import Foundation
import Observation

/// 활동 기록 시트의 화면 모델(#296): 최근 것부터의 목록과 고른 항목. 띄울 때마다 새로 만든다(`LibraryWindowModel.showActivityLog`).
@MainActor
@Observable
final class ActivityLogModel: Identifiable {
    @ObservationIgnored let log: ActivityLog
    /// 고른 항목. 처음에는 연 곳이 가리킨 항목(알림의 결과 보기), 없거나 이미 밀려났으면 맨 위 항목이다
    var selection: ActivityEntry.ID?

    init(log: ActivityLog, selection: ActivityEntry.ID? = nil) {
        self.log = log
        self.selection = log.entries.contains { $0.id == selection } ? selection : log.entries.first?.id
    }

    var entries: [ActivityEntry] { log.entries }
    var selected: ActivityEntry? { log.entries.first { $0.id == selection } }
    var storageError: String? { log.storageError }
}
