import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 게인 초안의 base(R23, #405 컨실 2라운드 L): base는 값 저장이 성공한 판에만 묶고, ⌘S도 지금 값의 판에 묶인 base만 관문에 넘긴다
@MainActor
@Suite("게인 초안 base")
struct GainDraftBaseTests {
    typealias H = ReflectionHarness

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// 값 저장이 실패하면 base를 걸지 않는다(그때 보이는 옛 값의 판에 새 base가 묶이지 않게, S8)
    @Test func 값_저장이_실패하면_base를_걸지_않는다() {
        var store = MemoryDrafts().store
        let calls = Calls()
        store.saveGain = { _, uuid, completion in completion(DraftSaveFailure(kind: .gain, trackUUID: uuid, revision: 1, reason: "합성 실패")) }
        store.saveGainBase = { _, _ in calls.add() }
        store.saveGain(-1, base: -3, trackUUID: "n")
        #expect(calls.value == 0)
    }

    /// ⌘S는 지금 값의 판에 묶인 base만 넘긴다: 값만 다시 저장돼 base가 옛 판에 묶였으면 base 없는 초안처럼 쓴다
    @Test func 수동_저장은_값의_판에_묶인_base만_넘긴다() async {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.gainOutcomes = [H.outcome("n", .written)]
        h.state.rows["n"] = H.row("n")
        h.state.gainDraftUUIDs = ["n"]
        h.memory.save(gain: -1, base: -3, "n")
        h.memory.save(gain: -2, "n")
        _ = await h.session.write(rows: [H.row("n")])
        let preview = h.gateCalls.value.previews.first
        #expect(preview?.gains == ["n": -2])
        #expect(preview?.gainBases.isEmpty == true, "옛 판의 base를 넘기지 않는다")
    }

    @Test func 수동_저장은_판이_맞는_base를_넘긴다() async {
        let h = ReflectionHarness()
        h.script.reportsBatchOnly = true
        h.script.preview.gainOutcomes = [H.outcome("n", .written)]
        h.state.rows["n"] = H.row("n")
        h.state.gainDraftUUIDs = ["n"]
        h.memory.save(gain: -1, base: -3, "n")
        _ = await h.session.write(rows: [H.row("n")])
        #expect(h.gateCalls.value.previews.first?.gainBases == ["n": -3])
    }
}
