import Foundation

// gate를 기다리는 동기 캡처는 cooperative pool 밖에서 실행한다.
func iTunesBlockingTask<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
) -> Task<Value, Error> {
    Task {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }
}
