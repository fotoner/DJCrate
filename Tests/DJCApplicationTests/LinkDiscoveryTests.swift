import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// LINK 장치 찾기 흐름(#272): 알림 → 목록, 만료, rekordbox 켜짐에 멈춤, 포트 실패. 가짜 포트만 쓰고 소켓을 열지 않는다.
@Suite("LINK 장치 찾기")
struct LinkDiscoveryTests {
    static let cdj1 = LinkDevice(number: 1, name: "CDJ-2000nexus", kind: .player, address: "169.254.86.192")
    static let djm = LinkDevice(number: 33, name: "DJM-900NXS2", kind: .mixer, address: "169.254.98.242")

    /// 시험이 움직이는 가짜 환경: 알림 스트림, 시계, rekordbox 실행 여부. `sleep`은 바로 돌아와 틱을 빨리 돌린다.
    /// 포트를 열 때마다 새 스트림을 준다(실제 포트처럼 닫으면 끝나고, 다시 열면 새로 받는다)
    final class Fake: Sendable {
        struct PortInUse: Error {}

        let clock = Mutex(Date(timeIntervalSinceReferenceDate: 1_000))
        let rekordbox = Mutex(false)
        let portInUse = Mutex(false)
        let opened = Mutex(0)
        private let feed = Mutex<AsyncThrowingStream<LinkDevice, any Error>.Continuation?>(nil)

        var source: LinkDiscoverySource {
            LinkDiscoverySource(
                announcements: { [self] in
                    let (stream, continuation) = AsyncThrowingStream.makeStream(of: LinkDevice.self, throwing: (any Error).self)
                    if portInUse.withLock({ $0 }) { continuation.finish(throwing: PortInUse()) }
                    feed.withLock { $0 = continuation }
                    opened.withLock { $0 += 1 }
                    return stream
                },
                isRekordboxRunning: { [self] in rekordbox.withLock { $0 } },
                now: { [self] in clock.withLock { $0 } },
                sleep: { _ in try await Task.sleep(for: .milliseconds(2)) })
        }

        /// 지금 열린 포트로 알림 하나를 보낸다
        func announce(_ device: LinkDevice) { _ = feed.withLock { $0?.yield(device) } }
        /// 포트가 n번 열릴 때까지 기다린다(열기 전에 보낸 알림은 사라진다)
        func waitOpened(_ count: Int) async -> Bool {
            await LinkDiscoveryTests.poll { opened.withLock { $0 } >= count }
        }

        func advance(_ seconds: TimeInterval) { clock.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    /// 받은 상태를 모은다
    final class States: Sendable {
        let values = Mutex<[LinkDiscoveryState]>([])
        func append(_ state: LinkDiscoveryState) { values.withLock { $0.append(state) } }
        var all: [LinkDiscoveryState] { values.withLock { $0 } }

        /// 조건을 만족할 때까지 기다린다
        func wait(until condition: ([LinkDiscoveryState]) -> Bool) async -> Bool {
            await LinkDiscoveryTests.poll { condition(all) }
        }
    }

    /// 상태가 올 때까지 기다린다(TEST-30·32). 걸린 시간으로 판정하지 않고, 300초는 판정이 오지 않을 때 시험이 멈추지 않게 하는 안전망이다
    static func poll(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(300))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    static func start(_ fake: Fake) -> (Task<Void, Never>, States) {
        let states = States()
        let discovery = LinkDiscovery(source: fake.source)
        let task = Task { await discovery.run { states.append($0) } }
        return (task, states)
    }

    @Test func 알림을_받으면_장치_목록을_알린다() async {
        let fake = Fake()
        let (task, states) = Self.start(fake)
        defer { task.cancel() }
        #expect(await states.wait { $0.first == .listening([]) })
        #expect(await fake.waitOpened(1))
        fake.announce(Self.djm)
        fake.announce(Self.cdj1)
        #expect(await states.wait { $0.last == .listening([Self.cdj1, Self.djm]) })
    }

    @Test func 알림이_끊긴_장치는_틱에서_뺀다() async {
        let fake = Fake()
        let (task, states) = Self.start(fake)
        defer { task.cancel() }
        #expect(await fake.waitOpened(1))
        fake.announce(Self.cdj1)
        #expect(await states.wait { $0.last == .listening([Self.cdj1]) })
        fake.advance(LinkRoster.timeout + 1)
        #expect(await states.wait { $0.last == .listening([]) })
    }

    @Test func rekordbox가_켜져_있으면_포트를_열지_않고_멈춘다() async {
        let fake = Fake()
        fake.rekordbox.withLock { $0 = true }
        let (task, states) = Self.start(fake)
        defer { task.cancel() }
        #expect(await states.wait { $0 == [.blockedByRekordbox] })
        #expect(fake.opened.withLock { $0 } == 0)
    }

    @Test func 듣는_중에_rekordbox가_켜지면_멈췄다가_꺼지면_다시_연다() async {
        let fake = Fake()
        let (task, states) = Self.start(fake)
        defer { task.cancel() }
        #expect(await fake.waitOpened(1))
        fake.announce(Self.cdj1)
        #expect(await states.wait { $0.last == .listening([Self.cdj1]) })
        fake.rekordbox.withLock { $0 = true }
        fake.advance(LinkDiscovery.rekordboxCheck.components.seconds.asInterval + 1)
        #expect(await states.wait { $0.last == .blockedByRekordbox })
        fake.rekordbox.withLock { $0 = false }
        #expect(await fake.waitOpened(2))
        #expect(await states.wait { $0.last == .listening([]) })
    }

    @Test func 포트를_열지_못하면_쓸_수_없다고_알린다() async {
        let fake = Fake()
        fake.portInUse.withLock { $0 = true }
        let (task, states) = Self.start(fake)
        defer { task.cancel() }
        #expect(await states.wait { $0.contains(.unavailable) })
    }

    @Test func 취소하면_끝난다() async {
        let fake = Fake()
        let (task, states) = Self.start(fake)
        #expect(await states.wait { !$0.isEmpty })
        task.cancel()
        // 취소가 전달되지 않으면 멈추지 않고 실패하게 안전망과 겨룬다
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(300)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(ended)
    }
}

private extension Int64 {
    var asInterval: TimeInterval { TimeInterval(self) }
}
