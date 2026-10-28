import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// rekordbox 실행 감시(`RekordboxProcessSource`)의 가짜(#323): 판정·신호·시계를 시험이 정한다.
/// `sleep`은 시험이 `tick()`을 부를 때까지 멈춘다(가짜 시계). 읽기는 실제처럼 막는 일이라 메인·협력 풀 밖에서 불려야 한다.
public final class FakeRekordboxProcesses: Sendable {
    struct State {
        var current: RekordboxRunState
        var reads = 0
        var feeds: [Int: AsyncStream<Void>.Continuation] = [:]
        var sleepers: [Int: CheckedContinuation<Void, any Error>] = [:]
        var sleeps: [Duration] = []
        var nextID = 0
    }

    private let state: Mutex<State>

    public init(_ current: RekordboxRunState = .stopped) {
        state = Mutex(State(current: current))
    }

    /// 다음 읽기가 돌려줄 판정
    public func set(_ current: RekordboxRunState) { state.withLock { $0.current = current } }
    /// 읽은 횟수
    public var reads: Int { state.withLock { $0.reads } }
    /// 열려 있는 신호 흐름 수
    public var subscribers: Int { state.withLock { $0.feeds.count } }
    /// 시계를 기다리는 수
    public var sleeping: Int { state.withLock { $0.sleepers.count } }
    /// 기다리기를 부른 간격들
    public var sleeps: [Duration] { state.withLock { $0.sleeps } }

    /// 열린 신호 흐름 모두에 "다시 읽어라"를 보낸다
    public func signal() {
        for feed in state.withLock({ Array($0.feeds.values) }) { feed.yield() }
    }

    /// 시계를 한 칸 움직인다: 기다리던 것을 모두 깨운다
    public func tick() {
        for sleeper in state.withLock({ state in defer { state.sleepers = [:] }; return Array(state.sleepers.values) }) { sleeper.resume() }
    }

    public var source: RekordboxProcessSource {
        RekordboxProcessSource(
            read: { [self] in
                expectBlockingOffPool()
                #expect(!Thread.isMainThread, "프로세스 목록 읽기는 메인 밖에서 한다")
                return state.withLock { $0.reads += 1; return $0.current }
            },
            changes: { [self] in
                let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
                let id = state.withLock { $0.nextID += 1; $0.feeds[$0.nextID] = continuation; return $0.nextID }
                continuation.onTermination = { [self] _ in _ = state.withLock { $0.feeds.removeValue(forKey: id) } }
                return stream
            },
            sleep: { [self] duration in try await sleep(duration) })
    }

    private func sleep(_ duration: Duration) async throws {
        let id = state.withLock { $0.nextID += 1; $0.sleeps.append(duration); return $0.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.sleepers[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}

/// rekordbox 실행 감시(`RekordboxProcessSource`): 읽기는 메인 밖에서 돌아온다. 감시를 멈추면 신호 흐름과 기다리기가 끝난다
/// (취소한 흐름·기다리기가 남아 알림 받기나 시계를 붙들지 않는다).
public func rekordboxProcessSourceContract(_ source: RekordboxProcessSource) async throws {
    _ = await BlockingWork.run(qos: .utility) { source.read() }
    let listening = Task { for await _ in source.changes() {} }
    listening.cancel()
    await listening.value
    let sleeping = Task { try await source.sleep(.seconds(3600)) }
    sleeping.cancel()
    await #expect(throws: CancellationError.self) { try await sleeping.value }
}
