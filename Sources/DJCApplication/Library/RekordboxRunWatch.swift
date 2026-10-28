import DJCDomain
import Foundation

/// rekordbox 실행 감시 포트(#323). 실제 구현은 프로세스를 띄우지 않고 프로세스 목록을 읽는다(쓰기 관문의 pgrep과 다른 길).
public struct RekordboxProcessSource: Sendable {
    /// 지금 프로세스 목록을 읽어 판정한다. 읽지 못하면 `.unknown`이다. 막는 일이라 메인 밖에서 부른다
    public var read: @Sendable () -> RekordboxRunState
    /// 다시 읽을 때라는 신호(앱 실행·종료 알림). 신호로 판정하지 않는다. 흐름을 버리면 알림 받기를 그만둔다
    public var changes: @Sendable () -> AsyncStream<Void>
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(read: @escaping @Sendable () -> RekordboxRunState, changes: @escaping @Sendable () -> AsyncStream<Void>,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.read = read
        self.changes = changes
        self.sleep = sleep
    }

    /// 프로세스 목록을 읽지 않는 자리(화면 시험의 조립). 늘 모름이다
    public static let none = RekordboxProcessSource(read: { .unknown }, changes: { AsyncStream { $0.finish() } })
}

/// 앱이 켜져 있는 동안 rekordbox·rekordboxAgent 실행을 지켜본다(#323). 처음 한 번, 신호가 올 때, 느린 간격마다 다시 읽고
/// 판정이 바뀔 때만 알린다. 화면 표시용이다: 쓸지 말지는 이 값을 보지 않고 쓰기 관문이 그때그때 다시 확인한다.
public struct RekordboxRunWatch: Sendable {
    /// 신호 없이 다시 읽는 간격. 실행 알림이 오지 않는 프로세스도 이 안에 잡는다
    public static let poll: Duration = .seconds(5)

    public let source: RekordboxProcessSource

    public init(source: RekordboxProcessSource) {
        self.source = source
    }

    /// 취소될 때까지 판정이 바뀔 때마다 알린다. 첫 판정은 바로 알린다
    public func run(update: @escaping @Sendable (RekordboxRunState) async -> Void) async {
        // 읽는 동안 온 신호·틱은 하나로 합친다(한 번 더 읽으면 된다)
        let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let source = source
        let signals = Task {
            for await _ in source.changes() { wake.yield() }
        }
        let ticker = Task {
            while !Task.isCancelled {
                do { try await source.sleep(Self.poll) } catch { return }
                wake.yield()
            }
        }
        defer {
            signals.cancel()
            ticker.cancel()
            wake.finish()
        }
        wake.yield()
        var last: RekordboxRunState?
        for await _ in wakes {
            let state = await BlockingWork.run(qos: .utility) { source.read() }
            guard !Task.isCancelled else { return }
            guard state != last else { continue }
            last = state
            await update(state)
        }
    }
}
