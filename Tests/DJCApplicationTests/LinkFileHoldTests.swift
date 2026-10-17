@testable import DJCApplication
import Synchronization
import Testing

/// CDJ가 못 읽는 원본을 바꾸는 동안 그 파일 요청의 답을 미룬다(#277). 다 바꾼 뒤 다시 온 요청에 WAV로 답하면 첫 싣기부터 실린다
@Suite("LINK 파일 요청 보류")
struct LinkFileHoldTests {
    /// 손으로 돌리는 시계
    final class Clock: Sendable {
        private let instant = Mutex(ContinuousClock.now)
        func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
        func advance(_ duration: Duration) { instant.withLock { $0 += duration } }
    }

    static let flac = "/Users/dj/Music/20.flac"

    @Test func 못_읽는_기종이_후보를_요청하면_풀_때까지_보류한다() {
        let hold = LinkFileHold()
        hold.reset(candidates: [Self.flac])
        #expect(hold.shouldHold(path: Self.flac, playerModel: "CDJ-2000nexus"))
        // 기종을 모르면 바꾸는 쪽으로 둔다(LinkPlayerFormats)
        #expect(hold.shouldHold(path: Self.flac, playerModel: ""))
        #expect(!hold.shouldHold(path: Self.flac, playerModel: "CDJ-3000"))
        #expect(!hold.shouldHold(path: "/Users/dj/Music/10.mp3", playerModel: "CDJ-2000nexus"))
        #expect(!hold.shouldHold(path: "/Users/dj/Music/DJCrate/LINK/x.wav", playerModel: "CDJ-2000nexus"))
        #expect(hold.release(Self.flac))
        #expect(!hold.shouldHold(path: Self.flac, playerModel: "CDJ-2000nexus"))
    }

    @Test func 오래_걸리면_원본으로_답하고_풀_때_다시_실어야_한다고_알린다() {
        let clock = Clock()
        let hold = LinkFileHold(now: { clock.now() })
        hold.reset(candidates: [Self.flac])
        #expect(hold.shouldHold(path: Self.flac, playerModel: "CDJ-2000nexus"))
        clock.advance(LinkFileHold.limit)
        #expect(hold.shouldHold(path: Self.flac, playerModel: "CDJ-2000nexus"))
        clock.advance(.seconds(1))
        #expect(!hold.shouldHold(path: Self.flac, playerModel: "CDJ-2000nexus"))
        #expect(!hold.release(Self.flac))
    }

    @Test func 다시_연결하면_앞_연결의_기록을_비운다() {
        let hold = LinkFileHold()
        hold.reset(candidates: [Self.flac])
        hold.release(Self.flac)
        hold.reset(candidates: [Self.flac])
        #expect(hold.shouldHold(path: Self.flac, playerModel: "CDJ-2000nexus"))
    }
}
