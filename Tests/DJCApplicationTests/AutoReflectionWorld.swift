import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 자동 저장 엔진 시험의 세계: 반영 세션 하네스(메모리 초안·가짜 관문)와 엔진의 가짜 포트(손으로 넘기는 시계·실행 상태·파일 상태·잠금·기록).
/// 시계는 1초씩 넘기고 엔진이 판정을 마치고 쉴 때까지 기다린다(걸린 시간이 아니라 상태로 판정한다, TEST-30).
@MainActor
final class AutoReflectionWorld {
    let h = ReflectionHarness()
    let fakes: AutoReflectionFakes
    var appHolds: Set<ReflectionHold> = []
    var snapshot: AutoSnapshotGate = .satisfied
    /// 시점 스냅샷 포트를 부른 때마다 그때까지 관문이 쓴 횟수
    var snapshotCalls: [Int] = []
    /// 시점 스냅샷 포트를 부를 때 한다(준비하는 동안 바깥에서 생긴 일을 흉내 낸다)
    var onSnapshot: (@MainActor () -> Void)?
    var run: AutoReflectionRun = .live
    var timing = AutoReflectionTiming(editDelay: .seconds(3), quietDelay: .seconds(10), bulkDelay: .seconds(30), bulkTracks: 50, rowLimit: 200,
                                      successToasts: 5)
    private(set) var engine: AutoReflection!

    init(fakes: AutoReflectionFakes = AutoReflectionFakes()) {
        self.fakes = fakes
        h.script.reportsBatchOnly = true
        h.backupsMemory.condition = .ready
    }

    // MARK: - 재료

    /// 미리 보기·쓰기에서 쓸 수 있는 큐 초안의 곡(엔진을 만들기 전에 정한다: 가짜 관문은 만들 때의 결과를 든다)
    func writable(_ uuids: String..., status: RekordboxWriteOutcome.Status = .written) {
        for uuid in uuids { h.script.preview.outcomes.append(ReflectionHarness.outcome(uuid, status)) }
    }

    func writable(_ uuids: [String]) {
        for uuid in uuids { h.script.preview.outcomes.append(ReflectionHarness.outcome(uuid, .written)) }
    }

    /// 목록의 곡과 그 곡의 큐 초안(저장한 출처)
    func cue(_ uuid: String, at time: Double = 12, origin: DraftOrigin = .human, row: TrackRow? = nil) {
        h.state.rows[uuid] = row ?? ReflectionHarness.row(uuid)
        h.state.cueDraftUUIDs.insert(uuid)
        h.memory.save(ReflectionHarness.cue(uuid, at: time), origin: origin)
    }

    func start() async throws {
        // 시험이 끝나 세계가 사라진 뒤에도 엔진은 마지막 신호로 한 번 더 판정할 수 있다: 그때는 보류해 아무것도 하지 않는다
        let ports = fakes.ports(holds: { [weak self] in self?.appHolds ?? [.shuttingDown] }, pointSnapshot: { [weak self] in
            guard let self else { return .held(.shuttingDown) }
            snapshotCalls.append(h.gateCalls.value.writes.count)
            onSnapshot?()
            return snapshot
        })
        engine = AutoReflection(session: h.session, ports: ports, run: run, timing: timing)
        engine.start()
        try await settle()
    }

    /// 엔진이 판정을 마치고 시계로 쉬는 중일 때까지 기다린다
    func settle() async throws {
        for _ in 0..<4000 where !(engine.isParked && fakes.clock.sleeping == 1) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(engine.isParked && fakes.clock.sleeping == 1, "엔진이 쉬는 상태에 닿는다")
    }

    /// 시계를 1초씩 넘긴다(엔진은 1초마다 rekordbox·파일 상태를 지켜본다)
    func advance(_ seconds: Int) async throws {
        for _ in 0..<seconds {
            fakes.clock.advance(.seconds(1))
            try await settle()
        }
    }

    /// 편집 신호를 주고 엔진이 다시 판정할 때까지 기다린다
    func edited() async throws {
        engine.edited()
        try await settle()
    }

    /// 관문이 실제로 쓴 묶음(미리 보기 제외)
    var writes: [DraftWriteBatch] { h.gateCalls.value.writes }
    var previews: [DraftWriteBatch] { h.gateCalls.value.previews }
}
