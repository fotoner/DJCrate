import AppKit
import Observation

/// 시스템이 스크롤 막대를 늘 보이게 둘 때(마우스 연결·"항상") 세로 막대가 목록 폭에서 가져가는 폭.
/// 겹쳐 그리는 막대("스크롤할 때")면 0이다. 마우스를 꽂고 뽑으면 시스템이 막대 방식을 바꾸므로 알림을 따라 갱신한다.
@MainActor @Observable
final class ScrollerGutter {
    static let system = ScrollerGutter()

    private(set) var width: CGFloat
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        width = Self.systemWidth()
        observer = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.width = Self.systemWidth() }
        }
    }

    /// 시험이 막대 폭을 정해 넣는다.
    init(fixed width: CGFloat) { self.width = width }

    static func systemWidth() -> CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}
