import DJCApplication
import Testing

private actor SnapshotPauseGate {
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        for waiter in pauseWaiters { waiter.resume() }
        pauseWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@MainActor
@Suite("스냅샷 갱신 대기")
struct SnapshotRequestQueueTests {
    @Test func 첫_요청의_취소는_뒤에_온_새_요청을_취소하지_않는다() async {
        let queue = SnapshotRequestQueue(), gate = SnapshotPauseGate()
        var newRequestWasCancelled: Bool?
        let first = Task { await queue.run(force: false, quiet: true) { _, _ in await gate.pause() } }
        await gate.waitUntilPaused()
        let second = Task {
            await queue.run(force: true, quiet: false) { _, _ in newRequestWasCancelled = Task.isCancelled }
        }
        while queue.waitingCount < 1 { await Task.yield() }
        first.cancel()
        await gate.release()
        await first.value
        await second.value
        #expect(newRequestWasCancelled == false)
    }

    @Test func 실행_전_취소한_대기_요청은_읽지_않는다() async {
        let queue = SnapshotRequestQueue(), gate = SnapshotPauseGate()
        var cancelledRequestRan = false
        let first = Task { await queue.run(force: false, quiet: true) { _, _ in await gate.pause() } }
        await gate.waitUntilPaused()
        let cancelled = Task {
            await queue.run(force: true, quiet: false) { _, _ in cancelledRequestRan = true }
        }
        while queue.waitingCount < 1 { await Task.yield() }
        cancelled.cancel()
        await gate.release()
        await first.value
        await cancelled.value
        #expect(!cancelledRequestRan)
    }

    @Test func 취소는_현재_요청의_Music_후속_작업에도_전달한다() async {
        let queue = SnapshotRequestQueue(), gate = SnapshotPauseGate()
        var published = false
        let request = Task {
            await queue.runWithFollowUp(force: false, quiet: true, refreshITunes: true) { _, _ in
                Task {
                    await gate.pause()
                    if !Task.isCancelled { published = true }
                }
            }
        }
        await gate.waitUntilPaused()
        request.cancel()
        await gate.release()
        await request.value
        #expect(!published)
    }

    @Test func 병합한_마지막_대기_호출이_취소돼도_남은_요청을_실행한다() async {
        let queue = SnapshotRequestQueue(), gate = SnapshotPauseGate()
        var completed: [String] = []
        let first = Task { await queue.run(force: false, quiet: true) { _, _ in await gate.pause() } }
        await gate.waitUntilPaused()
        let needed = Task {
            await queue.run(force: false, quiet: true) { force, quiet in
                #expect(!force && quiet)
                completed.append("남은 요청")
            }
        }
        while queue.waitingCount < 1 { await Task.yield() }
        let cancelled = Task {
            await queue.run(force: true, quiet: false) { _, _ in completed.append("취소한 요청") }
        }
        while queue.waitingCount < 2 { await Task.yield() }
        cancelled.cancel()
        await gate.release()
        await first.value
        await needed.value
        await cancelled.value
        #expect(completed == ["남은 요청"])
    }

    @Test func 병합한_Music은_한_호출의_취소로_다른_호출에서_빠지지_않는다() async {
        let queue = SnapshotRequestQueue(), copyGate = SnapshotPauseGate(), musicGate = SnapshotPauseGate()
        var published = false
        let first = Task { await queue.run(force: false, quiet: true) { _, _ in await copyGate.pause() } }
        await copyGate.waitUntilPaused()
        let needed = Task {
            await queue.runWithFollowUp(force: false, quiet: true, refreshITunes: true) { _, _ in nil }
        }
        while queue.waitingCount < 1 { await Task.yield() }
        let cancelled = Task {
            await queue.runWithFollowUp(force: true, quiet: false, refreshITunes: true) { _, _ in
                Task {
                    await musicGate.pause()
                    if !Task.isCancelled { published = true }
                }
            }
        }
        while queue.waitingCount < 2 { await Task.yield() }
        await copyGate.release()
        await musicGate.waitUntilPaused()
        cancelled.cancel()
        await musicGate.release()
        await first.value
        await needed.value
        await cancelled.value
        #expect(published)
    }

    @Test func 겹친_두번째_호출도_자신의_읽기가_끝나야_반환한다() async {
        let queue = SnapshotRequestQueue()
        let gate = SnapshotPauseGate()
        var completed: [String] = []
        let first = Task {
            await queue.run(force: false, quiet: true) { _, _ in
                await gate.pause()
                completed.append("첫 읽기")
            }
        }
        await gate.waitUntilPaused()

        let second = Task {
            await queue.run(force: true, quiet: false) { force, quiet in
                #expect(force && !quiet)
                completed.append("두번째 읽기")
            }
            completed.append("두번째 호출 반환")
        }
        for _ in 0..<100 where queue.waitingCount == 0 { await Task.yield() }
        #expect(queue.waitingCount == 1)
        #expect(completed.isEmpty)
        await gate.release()
        await first.value
        await second.value
        #expect(completed == ["첫 읽기", "두번째 읽기", "두번째 호출 반환"])
    }
    @Test func 명시적_초안_동기화는_자동_새로읽기와_합쳐_사라지지_않는다() async {
        let queue = SnapshotRequestQueue(), gate = SnapshotPauseGate()
        var completed: [String] = []
        let first = Task { await queue.run(force: false, quiet: true) { _, _ in await gate.pause() } }
        await gate.waitUntilPaused()
        let explicit = Task {
            await queue.runWithFollowUp(force: true, quiet: false, refreshITunes: false, synchronizingDrafts: true) { _, _ in
                completed.append("명시적 동기화")
                return nil
            }
        }
        while queue.waitingCount < 1 { await Task.yield() }
        let automatic = Task {
            await queue.runWithFollowUp(force: true, quiet: true, refreshITunes: false) { _, _ in
                completed.append("자동 새로 읽기")
                return nil
            }
        }
        while queue.waitingCount < 2 { await Task.yield() }
        await gate.release()
        await first.value
        await explicit.value
        await automatic.value
        #expect(completed == ["명시적 동기화", "자동 새로 읽기"])
    }

}
