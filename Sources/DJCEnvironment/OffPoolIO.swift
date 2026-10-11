import Foundation
import Synchronization

/// 인프라 안의 오래 막는 입출력(사본 뜨기·폴더 훑기)을 GCD 스레드에서 돌리고 기다린다. 기다리는 동안 협력 스레드 풀을 붙잡지 않는다(#247).
/// 핵심부의 `BlockingWork.run`과 같은 일이다. 인프라는 핵심부를 import하지 못해 여기 둔다.
/// `BlockingWork`와 달리 부른 작업의 취소를 `CancellationCheck`로 넘긴다. GCD 스레드에는 지금 작업이 없어 `Task.isCancelled`가 늘 거짓이기 때문이다.
public enum OffPoolIO {
    public static func run<Value: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                            _ operation: @escaping @Sendable (CancellationCheck) throws -> Value) async throws -> Value {
        let check = CancellationCheck()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: qos).async { continuation.resume(with: Result { try operation(check) }) }
            }
        } onCancel: {
            check.cancel()
        }
    }
}

/// 풀 밖 작업에 넘기는 취소 신호. 단계 사이에서 `check()`를 부른다.
public final class CancellationCheck: Sendable {
    private let cancelled = Atomic(false)

    /// 신호를 받지 않는 동기 호출(시험·CLI)도 지금 작업의 취소는 본다.
    public init() {}

    public var isCancelled: Bool { cancelled.load(ordering: .acquiring) || Task.isCancelled }

    /// 취소됐으면 `CancellationError`를 던진다(`Task.checkCancellation`과 같은 오류).
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }

    func cancel() { cancelled.store(true, ordering: .releasing) }
}
