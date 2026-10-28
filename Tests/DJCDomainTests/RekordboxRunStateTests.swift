import DJCDomain
import Testing

/// rekordbox 실행 판정(#323): 관문(pgrep)과 감지 서비스(프로세스 목록)가 같은 이름 목록으로 판정한다. 꺼짐만 쓰기를 막지 않는다
@Suite("rekordbox 실행 판정")
struct RekordboxRunStateTests {
    @Test func 프로세스_이름으로_켜짐_Agent만_꺼짐을_가른다() {
        #expect(RekordboxRunState(runningNames: ["launchd", "rekordbox", "rekordboxAgent"]) == .running)
        #expect(RekordboxRunState(runningNames: ["rekordbox"]) == .running)
        #expect(RekordboxRunState(runningNames: ["launchd", "rekordboxAgent"]) == .agentOnly)
        #expect(RekordboxRunState(runningNames: ["launchd", "Finder"]) == .stopped)
        #expect(RekordboxRunState(runningNames: []) == .stopped)
    }

    @Test func 이름이_정확히_같은_것만_센다() {
        #expect(RekordboxRunState(runningNames: ["rekordbox helper", "Rekordbox", "rekordboxAgentX", "xrekordbox"]) == .stopped)
    }

    @Test func 꺼짐만_쓰기를_막지_않는다() {
        #expect(RekordboxRunState.running.blocksWrites)
        #expect(RekordboxRunState.agentOnly.blocksWrites)
        #expect(RekordboxRunState.unknown.blocksWrites)
        #expect(!RekordboxRunState.stopped.blocksWrites)
    }

    @Test func 본체를_먼저_본다() {
        #expect(RekordboxRunState.processNames == ["rekordbox", "rekordboxAgent"])
    }
}
