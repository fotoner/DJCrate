import AppKit
import DJCAdapters
import DJCApplication
import PortTestKit
import Testing

/// rekordbox 실행 감시의 실제 구현(#323): 계약(PortTestKit)과 실행·종료 알림을 신호로 주는지. 알림은 새 알림 센터로만 보낸다.
/// 판정 값은 이 Mac의 프로세스를 따르므로 보지 않는다(목록 읽기·판정은 RekordboxKitTests가 고유한 이름의 프로세스로 본다)
@Suite("rekordbox 실행 감시(실제)")
struct RekordboxProcessSourceLiveTests {
    @Test func 계약() async throws {
        try await rekordboxProcessSourceContract(.live(workspace: NotificationCenter()))
    }

    @Test func 앱_실행_종료_알림을_다시_읽으라는_신호로_준다() async {
        let center = NotificationCenter()
        var signals = RekordboxProcessSource.live(workspace: center).changes().makeAsyncIterator()
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        #expect(await signals.next() != nil)
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        #expect(await signals.next() != nil)
    }
}
