import Foundation
import Testing

/// 지금 스레드가 Swift 동시성의 협력 스레드 풀인지. 풀은 코어 수만큼만 있어, 여기서 다른 일을 기다리며 막으면
/// 코어가 적은 기계(CI 러너)에서 풀이 바닥나 메인 액터 시험까지 돌아오지 못한다(dev CI가 30분에 잘렸다).
public func isOnCooperativePool() -> Bool {
    String(cString: __dispatch_queue_get_label(nil)).hasSuffix(".cooperative")
}

/// 앱·핵심부가 동기 포트를 부르는 자리(시험 가짜의 클로저)나 시험이 풀어 줄 때까지 막기 직전에 부른다.
/// 협력 스레드 풀에서 막으면 풀을 붙잡는 것이므로 실패로 기록한다(막는 일은 `BlockingWork.run`으로 풀 밖에서 돌려야 한다).
public func expectBlockingOffPool(sourceLocation: SourceLocation = #_sourceLocation) {
    guard isOnCooperativePool() else { return }
    FileHandle.standardError.write(Data("✘ 협력 풀에서 막음: \(sourceLocation)\n".utf8))
    Issue.record("협력 스레드 풀에서 막았습니다. 앱 코드가 이 동기 작업을 풀 밖(GCD)에서 돌려야 합니다", sourceLocation: sourceLocation)
}

extension DispatchSemaphore {
    /// 앱 코드의 동기 경계(포트 클로저) 안에서 시험이 풀어 줄 때까지 붙잡는다(`expectBlockingOffPool`)
    public func waitOffPool(sourceLocation: SourceLocation = #_sourceLocation) {
        expectBlockingOffPool(sourceLocation: sourceLocation)
        wait()
    }
}
