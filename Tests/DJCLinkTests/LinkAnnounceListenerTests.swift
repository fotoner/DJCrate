import DJCLink
import Testing

/// 알림 포트 열기(#272). 시험 프로세스에서는 DJLinkKit이 실제 소켓을 만들지 않으므로, 포트를 열지 않고 오류로 끝나는지만 본다.
@Suite("LINK 알림 포트")
struct LinkAnnounceListenerTests {
    @Test func 시험_프로세스에서는_소켓을_열지_않고_오류로_끝난다() async {
        await #expect(throws: (any Error).self) {
            for try await _ in LinkAnnounceListener.devices() {}
        }
    }
}
