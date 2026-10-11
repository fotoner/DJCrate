import Foundation
import Synchronization

/// 스냅샷 작업은 차례로 실행하고, 합쳐서 대기한 호출도 자기 작업이 끝날 때 깨운다(사본 뜨기 요청 합치기, `LibraryReadFlow`).
@MainActor
public final class SnapshotRequestQueue {
    private final class Request: Sendable {
        private struct Cancellation: Sendable {
            var cancelled = false
            var handler: (@Sendable () -> Void)?
        }
        let force: Bool
        let quiet: Bool
        let operation: @MainActor (Bool, Bool) async -> Task<Void, Never>?
        private let cancellation = Mutex(Cancellation())

        init(force: Bool, quiet: Bool, operation: @escaping @MainActor (Bool, Bool) async -> Task<Void, Never>?) {
            self.force = force
            self.quiet = quiet
            self.operation = operation
        }
        var isCancelled: Bool { cancellation.withLock { $0.cancelled } }
        func cancel() {
            let handler = cancellation.withLock { $0.cancelled = true; return $0.handler }
            handler?()
        }
        func setCancellationHandler(_ handler: (@Sendable () -> Void)?) {
            let cancelled = cancellation.withLock { $0.handler = handler; return $0.cancelled }
            if cancelled { handler?() }
        }
    }

    private struct Pending {
        let refreshITunes: Bool
        let synchronizingDrafts: Bool
        var requests: [Request]
        var waiters: [CheckedContinuation<Task<Void, Never>?, Never>]
    }

    public private(set) var isRunning = false
    public var waitingCount: Int { pending.reduce(0) { $0 + $1.waiters.count } }
    private var pending: [Pending] = []

    public init() {}

    public func run(force: Bool, quiet: Bool, operation: @escaping @MainActor (Bool, Bool) async -> Void) async {
        await runWithFollowUp(force: force, quiet: quiet, refreshITunes: false) { force, quiet in
            await operation(force, quiet)
            return nil
        }
    }

    /// DB 작업만 직렬화한다. 후속 Music 작업은 대기열 밖에서 기다리되 병합한 호출도 완료를 기다린다.
    public func runWithFollowUp(force: Bool, quiet: Bool, refreshITunes: Bool, synchronizingDrafts: Bool = false,
                         operation: @escaping @MainActor (Bool, Bool) async -> Task<Void, Never>?) async {
        let request = Request(force: force, quiet: quiet, operation: operation)
        await withTaskCancellationHandler {
            let followUp = await runWork(request, refreshITunes: refreshITunes, synchronizingDrafts: synchronizingDrafts)
            await followUp?.value
        } onCancel: { request.cancel() }
        request.setCancellationHandler(nil)
    }

    private func runWork(_ request: Request, refreshITunes: Bool, synchronizingDrafts: Bool) async -> Task<Void, Never>? {
        guard !request.isCancelled else { return nil }
        if isRunning {
            return await withCheckedContinuation { continuation in
                if let last = pending.indices.last, pending[last].refreshITunes == refreshITunes,
                   pending[last].synchronizingDrafts == synchronizingDrafts {
                    var queued = pending[last]
                    queued.requests.append(request)
                    queued.waiters.append(continuation)
                    pending[last] = queued
                } else {
                    pending.append(Pending(refreshITunes: refreshITunes, synchronizingDrafts: synchronizingDrafts,
                                           requests: [request], waiters: [continuation]))
                }
            }
        }

        isRunning = true
        let followUp = await execute([request])
        while !pending.isEmpty {
            let queued = pending.removeFirst()
            let queuedFollowUp = await execute(queued.requests)
            for waiter in queued.waiters { waiter.resume(returning: queuedFollowUp) }
        }
        isRunning = false
        return followUp
    }

    private func execute(_ requests: [Request]) async -> Task<Void, Never>? {
        let active = requests.filter { !$0.isCancelled }
        guard let latest = active.last else { return nil }
        // 다음 요청은 앞 요청의 취소 문맥을 물려받지 않는다.
        let task = Task { await latest.operation(active.contains { $0.force }, active.allSatisfy { $0.quiet }) }
        let cancelWork = Mutex<@Sendable () -> Void>({ task.cancel() })
        let cancelIfAll: @Sendable () -> Void = {
            // 합쳐진 읽기는 한 호출이 취소돼도 다른 호출이 필요하면 끝낸다.
            if active.allSatisfy({ $0.isCancelled }) { cancelWork.withLock { $0 }() }
        }
        for request in active { request.setCancellationHandler(cancelIfAll) }
        cancelIfAll()
        let followUp = await task.value
        cancelWork.withLock { action in action = { followUp?.cancel() } }
        cancelIfAll()
        return followUp
    }
}
