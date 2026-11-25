import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// "이대로 둔다"(`RekordboxWriteGate.keepJournal`, R11)의 순서 계약. 대상에 중단 기록이 하나 남아 있고, `matching`은 그 기록을 판정했을 때의
/// 요청(작업 ID·master.db 크기·시각), `stale`은 작업 ID나 DB 도장이 다른 요청이다. `journalExists`는 기록 자체가 남았는지 본다
/// (실제 관문은 기록 파일, 가짜는 `ScriptedJournal.exists`). 쓰기 잠금을 잡는 `journal`로 보지 않는다: 넘긴 일 안에서도 부르기 때문이다.
/// - 요청이 다르면 `.changed`이고 넘긴 일(`apply`)을 부르지 않으며 기록이 남는다.
/// - 같아도 `apply`가 던지면 그 오류를 던지고 기록이 남는다.
/// - 같고 `apply`가 끝나면 그 뒤에 기록을 지우고 `.kept`다. 다시 부르면 `.nothing`이고 `apply`를 부르지 않는다.
/// 가짜(`RekordboxWriteGate.scripted`)는 DJCApplicationTests가, 실제 관문은 W1-A(#399)가 DJCAdaptersTests에서 같은 함수로 돌린다.
/// 동기 입구라 협력 풀 밖(메인 액터)에서 부른다.
@MainActor
public func journalKeepContract(_ gate: RekordboxWriteGate, target: RekordboxWriteTarget, matching: RekordboxJournalRequest,
                                stale: RekordboxJournalRequest, journalExists: @escaping @Sendable () throws -> Bool) throws {
    struct ApplyFailure: Error {}
    /// 넘긴 일을 부를 때마다 그때 기록이 남아 있었는지를 적는다
    final class Applied: Sendable {
        let calls = Mutex<[Bool]>([])
        var value: [Bool] { calls.withLock { $0 } }
    }
    let applied = Applied()
    let record: @Sendable () -> Void = { let exists = (try? journalExists()) == true; applied.calls.withLock { $0.append(exists) } }

    let changed = try gate.keepJournal(target, stale) { record() }
    let leftAfterChanged = try journalExists()
    #expect(changed == .changed)
    #expect(applied.value.isEmpty && leftAfterChanged, "요청이 다르면 넘긴 일을 하지 않고 기록을 남긴다")

    #expect(throws: ApplyFailure.self) {
        _ = try gate.keepJournal(target, matching) {
            record()
            throw ApplyFailure()
        }
    }
    let leftAfterFailure = try journalExists()
    #expect(applied.value == [true] && leftAfterFailure, "넘긴 일이 실패하면 기록을 남긴다")

    let kept = try gate.keepJournal(target, matching) { record() }
    let leftAfterKept = try journalExists()
    #expect(kept == .kept)
    #expect(applied.value == [true, true], "기록은 넘긴 일이 끝난 뒤에 지운다")
    #expect(!leftAfterKept)

    let nothing = try gate.keepJournal(target, matching) { record() }
    #expect(nothing == .nothing && applied.value.count == 2)
}

/// "이대로 둔다"를 겹쳐 부를 때의 계약(R11): 재확인·넘긴 일·기록 삭제가 한 쓰기 잠금 안에서 일어나, 같은 요청 둘이 겹쳐도
/// 넘긴 일은 한 번이고 하나는 `.kept`, 다른 하나는 기록이 사라진 뒤라 `.nothing`이다. 대상에 `request`와 맞는 중단 기록이 하나 남아 있어야 한다.
/// 첫 호출이 넘긴 일 안에서 멈춰 있는 동안 둘째 호출을 띄우고, 둘째가 쓰기 잠금 경합을 알린 뒤에 첫째를 풀어 준다.
/// 신호는 잠금 앞이 아니라 잠금 경합에서 와야 한다(잠금 앞 신호면 잠금이 빠져도 통과할 수 있다). 기다림마다 `timeout`을 두고,
/// 넘기면 첫째를 풀어 준 뒤 실패로 적는다. 한 호출이 막힌 동안 다른 호출도 실행되도록 각자 전용 스레드에서 부른다.
public func journalKeepOverlapContract(_ gate: RekordboxWriteGate, target: RekordboxWriteTarget, request: RekordboxJournalRequest,
                                       journalExists: @escaping @Sendable () throws -> Bool,
                                       secondContended: DispatchSemaphore,
                                       timeout: Duration = .seconds(30)) async throws {
    final class Applied: Sendable {
        let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
    }
    let applied = Applied()
    let inApply = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func keep(blocking: Bool) async -> Result<RekordboxJournalKeep, any Error> {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: Result {
                    try gate.keepJournal(target, request) {
                        applied.count.withLock { $0 += 1 }
                        guard blocking else { return }
                        inApply.signal()
                        release.wait()
                    }
                })
            }
        }
    }
    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    func signalled(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: semaphore.wait(timeout: .now() + seconds) == .success)
            }
        }
    }
    async let first = keep(blocking: true)
    guard await signalled(inApply) else {
        // 첫째가 넘긴 일 전에 끝났거나 던졌다: 결과를 그대로 보고한다
        release.signal()
        Issue.record("첫 호출이 넘긴 일에 들어가지 않았다: \(await first)")
        return
    }
    async let second = keep(blocking: false)
    guard await signalled(secondContended) else {
        release.signal()
        Issue.record("둘째 호출이 시간 안에 쓰기 잠금 경합에 닿지 않았다: \(await second)")
        _ = await first
        return
    }
    #expect(applied.value == 1, "둘째 호출은 첫째가 끝날 때까지 넘긴 일을 하지 않는다")
    release.signal()
    let results = [try await first.get(), try await second.get()]
    #expect(applied.value == 1, "같은 요청을 겹쳐 불러도 넘긴 일은 한 번이다")
    #expect(results.sorted { "\($0)" < "\($1)" } == [.kept, .nothing])
    #expect(!(try journalExists()))
}
