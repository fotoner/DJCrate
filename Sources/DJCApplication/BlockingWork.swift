import Foundation

/// 동기 입출력(파일·USB·DB, 포트 호출)을 GCD 스레드에서 돌리고 기다린다. 기다리는 동안 협력 스레드 풀을 붙잡지 않는다.
/// 협력 풀은 코어 수만큼만 있다. 오래 걸리거나 끝을 알 수 없는 동기 일(USB 쓰기, 잠든 볼륨의 파일 확인)이 풀 스레드를 차지하면
/// 코어가 적은 기계에서 다른 비동기 일과 메인 액터에서 돌아오는 일까지 멈춘다(dev CI가 앱 시험에서 30분에 잘렸다).
/// `Task.detached`와 같이 부른 쪽의 취소를 넘기지 않는다.
public enum BlockingWork {
    public static func run<Value: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                            _ operation: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(returning: operation()) }
        }
    }

    public static func run<Value: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                            _ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(with: Result(catching: operation)) }
        }
    }
}
