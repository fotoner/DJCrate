import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Synchronization
import Testing

/// rekordbox 실행 감시(#323): 처음 한 번, 신호가 올 때, 느린 간격마다 다시 읽고 판정이 바뀔 때만 알린다.
/// 가짜 감시·가짜 시계(`FakeRekordboxProcesses`)로 시험한다. 이 Mac의 프로세스는 읽지 않는다
@Suite("rekordbox 실행 감시")
struct RekordboxRunWatchTests {
    /// 받은 판정을 모은다
    final class States: Sendable {
        let values = Mutex<[RekordboxRunState]>([])
        func append(_ state: RekordboxRunState) { values.withLock { $0.append(state) } }
        var all: [RekordboxRunState] { values.withLock { $0 } }
    }

    /// 조건이 참이 될 때까지 기다린다(TEST-30·32: 걸린 시간으로 판정하지 않는다. 300초는 멈추지 않게 하는 안전망이다)
    static func wait(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(300))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    static func start(_ fake: FakeRekordboxProcesses) -> (Task<Void, Never>, States) {
        let states = States()
        let watch = RekordboxRunWatch(source: fake.source)
        let task = Task { await watch.run { states.append($0) } }
        return (task, states)
    }

    @Test func 처음_판정을_알리고_신호가_오면_다시_읽는다() async {
        let fake = FakeRekordboxProcesses(.stopped)
        let (task, states) = Self.start(fake)
        defer { task.cancel() }
        #expect(await Self.wait { states.all == [.stopped] })
        #expect(await Self.wait { fake.subscribers == 1 })
        fake.set(.running)
        fake.signal()
        #expect(await Self.wait { states.all == [.stopped, .running] })
        fake.set(.agentOnly)
        fake.signal()
        #expect(await Self.wait { states.all == [.stopped, .running, .agentOnly] })
        #expect(fake.reads == 3, "시계가 가지 않으면 처음과 신호 때만 읽는다")
    }

    @Test func 신호가_없어도_느린_간격마다_다시_읽는다() async {
        let fake = FakeRekordboxProcesses(.stopped)
        let (task, states) = Self.start(fake)
        defer { task.cancel() }
        #expect(await Self.wait { states.all == [.stopped] })
        fake.set(.agentOnly)
        #expect(await Self.wait { fake.sleeping == 1 })
        fake.tick()
        #expect(await Self.wait { states.all == [.stopped, .agentOnly] })
        #expect(fake.sleeps.allSatisfy { $0 == RekordboxRunWatch.poll })
    }

    @Test func 같은_판정은_다시_알리지_않고_모름도_알린다() async {
        let fake = FakeRekordboxProcesses(.stopped)
        let (task, states) = Self.start(fake)
        defer { task.cancel() }
        #expect(await Self.wait { states.all == [.stopped] })
        #expect(await Self.wait { fake.subscribers == 1 })
        fake.signal()
        #expect(await Self.wait { fake.reads == 2 })
        fake.set(.unknown)
        fake.signal()
        #expect(await Self.wait { states.all == [.stopped, .unknown] })
        #expect(states.all == [.stopped, .unknown])
    }

    @Test func 멈추면_신호_흐름과_시계를_놓는다() async {
        let fake = FakeRekordboxProcesses(.stopped)
        let (task, states) = Self.start(fake)
        #expect(await Self.wait { states.all == [.stopped] && fake.subscribers == 1 && fake.sleeping == 1 })
        task.cancel()
        await task.value
        #expect(await Self.wait { fake.subscribers == 0 && fake.sleeping == 0 })
    }
}
