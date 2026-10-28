import AppKit
import DJCApplication
import DJCDomain
import RekordboxKit

extension RekordboxProcessSource {
    /// 이 Mac: 커널 프로세스 목록을 읽어 판정한다(`RekordboxProcessList`, 프로세스를 띄우지 않는다. 읽지 못하면 모름).
    /// 앱 실행·종료 알림은 다시 읽으라는 신호로만 쓴다. 판정은 늘 목록으로 한다.
    /// - Parameter workspace: 실행·종료 알림을 받을 곳. 앱은 `NSWorkspace.shared.notificationCenter`, 시험은 새 알림 센터를 준다
    public static func live(workspace: NotificationCenter) -> Self {
        Self(read: { RekordboxProcessList.state() }, changes: { launches(in: workspace) })
    }

    static func launches(in center: NotificationCenter) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in continuation.yield() }
        }
        let tokens = ObserverTokens(observers)
        continuation.onTermination = { _ in tokens.values.forEach(center.removeObserver) }
        return stream
    }
}

/// 알림 관찰 표지. 만든 뒤 바꾸지 않고 흐름이 끝날 때 한 번 떼기만 한다
private final class ObserverTokens: @unchecked Sendable {
    let values: [any NSObjectProtocol]
    init(_ values: [any NSObjectProtocol]) { self.values = values }
}
