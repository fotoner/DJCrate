import Foundation
import Testing

/// 시험이 걸린 시간이 아니라 상태로 판정하게 하는 기다리기(#153·#154).
/// `condition`이 참이 되면 true를 돌려준다. 참이 될 수 없다고 이미 드러난 상태(`giveUp`, 예: 작업이 조건 없이 끝남)가 되면 기다리지 않고 false로 돌아온다.
/// `safetyNet`은 판정이 영영 오지 않는 잘못된 구현에서 시험이 멈춰 있지 않게 하는 안전망일 뿐이다. 통과하는 경로에서 만료되지 않게
/// (다른 `@MainActor` 시험이 메인 액터를 나눠 써서 시험 하나가 80~190초 밀린 부하 실험보다 길게) 넉넉히 잡는다.
@MainActor
func waitForState(safetyNet: Duration = .seconds(300), giveUp: () -> Bool = { false },
                  until condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + safetyNet
    while !condition() {
        if giveUp() || ContinuousClock.now >= deadline { return condition() }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// "일어나지 않음"을 볼 때 시간을 기다리지 않고, 메인 액터에 이미 쌓인 일(`Task {}`·이어 돌 계속)을 먼저 돌린 뒤 본다.
/// 시간 예약(`Task.sleep`·타이머)은 기다리지 않는다. 그런 경로가 있는 곳은 그 일이 남기는 신호를 `waitForState`로 기다린다.
@MainActor
func drainMainActor(rounds: Int = 20) async {
    for _ in 0..<rounds { await Task.yield() }
}

/// 지금 스레드가 Swift 동시성의 협력 스레드 풀인지. 풀은 코어 수만큼만 있어, 여기서 다른 일을 기다리며 막으면
/// 코어가 적은 기계(CI 러너)에서 풀이 바닥나 메인 액터 시험까지 돌아오지 못한다(dev CI가 30분에 잘렸다).
func isOnCooperativePool() -> Bool {
    String(cString: __dispatch_queue_get_label(nil)).hasSuffix(".cooperative")
}

/// 시험 훅이 시험이 풀어 줄 때까지 막기 직전에 부른다. 협력 스레드 풀에서 막으면 풀을 붙잡는 것이므로 실패로 기록한다
/// (앱 코드가 막는 일을 풀 밖에서 돌려야 한다).
func expectBlockingOffPool(sourceLocation: SourceLocation = #_sourceLocation) {
    guard isOnCooperativePool() else { return }
    FileHandle.standardError.write(Data("✘ 협력 풀에서 막음: \(sourceLocation)\n".utf8))
    Issue.record("협력 스레드 풀에서 막았습니다. 앱 코드가 이 동기 작업을 풀 밖(GCD)에서 돌려야 합니다", sourceLocation: sourceLocation)
}

extension DispatchSemaphore {
    /// 앱 코드의 동기 경계(포트 클로저) 안에서 시험이 풀어 줄 때까지 붙잡는다(`expectBlockingOffPool`)
    func waitOffPool(sourceLocation: SourceLocation = #_sourceLocation) {
        expectBlockingOffPool(sourceLocation: sourceLocation)
        wait()
    }
}
