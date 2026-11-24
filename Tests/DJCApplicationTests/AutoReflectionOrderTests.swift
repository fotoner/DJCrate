import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 자동 저장 엔진의 판정 차례와 조건 모음(R1·R2·R7·R14·R16·R20): 쓰기 직전에 앱 보류 사유를 다시 보고, 대량 유예는 보류·켜짐이 없을 때만 세고,
/// 조건에는 지금 걸린 사유를 모두 모으고, 지켜보지 못한 틈은 조용함에 잇지 않고, 판정할 수 없는 재생 목록 초안의 판은 솎지 않는다.
@MainActor
@Suite("자동 저장: 판정 차례와 조건")
struct AutoReflectionOrderTests {
    static let layout = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가"), 1), (PlaylistLayout.Item(id: "B", name: "나"), 2)])
    static let finding = RekordboxJournalFinding(journal: RekordboxWriteJournal(operationID: "op", kind: .counter, entry: .drafts), changedSince: false,
                                                 database: nil)

    // MARK: - S6

    @Test(arguments: [ReflectionHold.linkServer, .usbBusy, .editing])
    func 준비하는_동안_새로_생긴_앱_보류_사유가_있으면_쓰지_않는다(_ reason: ReflectionHold) async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        // 시점 스냅샷을 확인하는 동안 LINK가 켜졌다·USB 시트가 열렸다·편집을 시작했다(초안 관찰은 이것으로 깨어나지 않는다)
        w.onSnapshot = { [weak w] in w?.appHolds = [reason] }
        try await w.start()
        try await w.advance(12)
        #expect(w.writes.isEmpty && w.previews.isEmpty)
        #expect(w.engine.conditions.holds.contains(reason))
        w.onSnapshot = nil
        w.appHolds = []
        try await w.advance(4)
        #expect(w.writes.count == 1)
    }

    // MARK: - G6

    @Test func 대량_유예는_rekordbox가_켜진_동안_세지_않는다() async throws {
        let w = AutoReflectionWorld()
        let uuids = (0..<50).map { String(format: "t%03d", $0) }
        w.writable(uuids)
        uuids.forEach { w.cue($0) }
        w.fakes.setRunState(.running)
        try await w.start()
        try await w.advance(40)
        #expect(w.engine.status == .rekordboxRunning(agentOnly: false))
        w.fakes.setRunState(.stopped)
        try await w.advance(12)
        guard case .grace = w.engine.status else { Issue.record("꺼진 뒤 유예를 처음부터 센다: \(w.engine.status)"); return }
        #expect(w.writes.isEmpty)
        try await w.advance(20)
        #expect(w.writes.count == 1)
    }

    @Test func 대량_유예_중_앱_보류가_생기면_유예를_처음부터_다시_센다() async throws {
        let w = AutoReflectionWorld()
        let uuids = (0..<50).map { String(format: "t%03d", $0) }
        w.writable(uuids)
        uuids.forEach { w.cue($0) }
        try await w.start()
        try await w.advance(20)
        guard case .grace = w.engine.status else { Issue.record("유예 중이다: \(w.engine.status)"); return }
        w.appHolds = [.usbBusy]
        try await w.advance(30)
        w.appHolds = []
        try await w.advance(5)
        #expect(w.writes.isEmpty, "보류 동안 유예가 다 지나지 않는다")
        guard case .grace = w.engine.status else { Issue.record("유예를 다시 센다: \(w.engine.status)"); return }
    }

    // MARK: - O2

    @Test func 조건에는_지금_걸린_사유를_모두_모으고_칩은_첫_사유를_보인다() async throws {
        let w = AutoReflectionWorld()
        w.h.script.journal = .interrupted(Self.finding)
        w.writable("a")
        w.cue("a")
        w.appHolds = [.usbBusy]
        w.fakes.setRunState(.running)
        try await w.start()
        try await w.advance(2)
        #expect(w.engine.status == .interrupted(recoveryFailed: false))
        #expect(w.engine.conditions.holds.isSuperset(of: [.interrupted(recoveryFailed: false), .usbBusy, .rekordboxRunning]))
    }

    @Test func 쓸_것이_없어도_멈춤과_앱_보류를_조건에_싣는다() async throws {
        let w = AutoReflectionWorld()
        w.fakes.records.failLoading()
        w.appHolds = [.linkServer]
        try await w.start()
        try await w.advance(2)
        #expect(w.engine.conditions.holds.isSuperset(of: [.stoppedAfterFailure, .linkServer]))
    }

    // MARK: - S15

    @Test func 자동으로_쓰는_동안_지켜보지_못한_틈이_길면_남은_묶음은_조용함을_처음부터_다시_센다() async throws {
        let w = AutoReflectionWorld()
        w.timing.rowLimit = 3
        w.writable("a", "b", "c", "d")
        ["a", "b", "c", "d"].forEach { w.cue($0) }
        try await w.start()
        try await w.advance(9)
        #expect(w.writes.isEmpty)
        w.h.previewHold.hold()
        w.fakes.clock.advance(.seconds(1))
        for _ in 0..<2000 where !w.h.previewHold.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        #expect(w.h.previewHold.isWaiting)
        // 쓰고 다시 읽는 5초 동안 rekordbox를 지켜보지 못했다(그 사이 켜졌다 꺼졌을 수 있다)
        w.fakes.clock.advance(.seconds(5))
        w.h.previewHold.release()
        try await w.settle()
        #expect(w.writes.count == 1)
        try await w.advance(5)
        #expect(w.writes.count == 1, "조용함을 처음부터 다시 센다")
        try await w.advance(6)
        #expect(w.writes.count == 2)
    }

    // MARK: - S10·O5

    @Test func 판정할_수_없는_재생_목록_초안은_남은_편집으로_보이고_그_판의_확인_필요를_풀지_않는다() async throws {
        let w = AutoReflectionWorld()
        var draft = PlaylistDraft()
        _ = try draft.append(.rename(playlist: .id("B"), name: "새 나"), rekordbox: Self.layout)
        try w.h.memory.store.savePlaylistDraft(draft)
        w.h.state.rekordboxPlaylists = Self.layout
        w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        w.h.script.preview.playlistOutcomes = [PlaylistOutcome(edit: draft.steps[0].edit, playlistID: "B", name: "새 나", status: .blocked,
                                                               reason: "바뀜")]
        try await w.start()
        try await w.advance(12)
        #expect(w.previews.count == 1)
        // 새 편집을 저장하지 못했다(메모리 ≠ 디스크): 판정할 수 없다
        w.h.state.playlistDraftUnsaved = true
        try await w.edited()
        #expect(w.engine.status == .leftover(count: 1))
        w.h.state.playlistDraftUnsaved = false
        try await w.edited()
        try await w.advance(15)
        #expect(w.previews.count == 1, "판이 그대로인 단계는 확인 필요로 남는다")
    }

    @Test func 화면의_재생_목록_초안이_비었어도_디스크에_초안이_있으면_판을_솎지_않는다() async throws {
        let w = AutoReflectionWorld()
        var draft = PlaylistDraft()
        _ = try draft.append(.rename(playlist: .id("B"), name: "새 나"), rekordbox: Self.layout)
        try w.h.memory.store.savePlaylistDraft(draft)
        w.h.state.rekordboxPlaylists = Self.layout
        w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        w.h.script.preview.playlistOutcomes = [PlaylistOutcome(edit: draft.steps[0].edit, playlistID: "B", name: "새 나", status: .blocked,
                                                               reason: "바뀜")]
        try await w.start()
        try await w.advance(12)
        #expect(w.previews.count == 1)
        // 화면 목록이 비었다(다시 켠 뒤 첫 읽기가 실패했다). 디스크에는 초안이 있다
        w.h.state.playlistDraft = PlaylistDraft()
        try await w.edited()
        #expect(w.engine.status == .leftover(count: 1))
        w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        try await w.edited()
        try await w.advance(15)
        #expect(w.previews.count == 1, "판이 그대로인 단계는 확인 필요로 남는다")
    }

    enum DiskUnknown: CaseIterable { case readFails, needsSync }

    @Test(arguments: DiskUnknown.allCases)
    func 디스크_재생_목록_초안을_읽지_못하면_화면_목록이_비어도_판을_솎지_않는다(_ unknown: DiskUnknown) async throws {
        let w = AutoReflectionWorld()
        var draft = PlaylistDraft()
        _ = try draft.append(.rename(playlist: .id("B"), name: "새 나"), rekordbox: Self.layout)
        try w.h.memory.store.savePlaylistDraft(draft)
        w.h.state.rekordboxPlaylists = Self.layout
        w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        w.h.script.preview.playlistOutcomes = [PlaylistOutcome(edit: draft.steps[0].edit, playlistID: "B", name: "새 나", status: .blocked,
                                                               reason: "바뀜")]
        try await w.start()
        try await w.advance(12)
        #expect(w.previews.count == 1)
        // 다시 켠 뒤 첫 읽기가 실패해 화면 목록이 비었고, 디스크 초안도 읽지 못한다(읽기 실패를 빈 초안으로 접는다)
        w.h.state.playlistDraft = PlaylistDraft()
        switch unknown {
        case .readFails: w.h.playlistReadFails.value = true
        case .needsSync:
            w.h.playlistReadFails.value = true
            w.h.state.playlistDraftNeedsSync = true
        }
        try await w.edited()
        w.h.playlistReadFails.value = false
        w.h.state.playlistDraftNeedsSync = false
        w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        try await w.edited()
        try await w.advance(15)
        #expect(w.previews.count == 1, "판이 그대로인 단계는 확인 필요로 남는다")
    }

    // MARK: - G7

    @Test func 일부만_쓴_수동_저장은_다른_곡의_취소를_풀지_않는다() async throws {
        let fakes = AutoReflectionFakes()
        let w = AutoReflectionWorld(fakes: fakes)
        let uuids = (0..<50).map { String(format: "t%03d", $0) }
        w.writable(uuids)
        uuids.forEach { w.cue($0) }
        try await w.start()
        try await w.advance(15)
        w.engine.cancelGrace()
        try await w.settle()
        _ = await w.engine.exclusive {
            ReflectionOutcome.written(ReflectionHarness.report(cues: [ReflectionHarness.outcome("t000", .written)]),
                                      preview: ReflectionHarness.report(), followUp: [])
        }
        await w.engine.recordSaved()
        #expect(fakes.records.record.cancelledRevisions.count == 50, "초안이 남은 판의 [취소]는 그대로다")
        try await w.advance(60)
        #expect(w.writes.isEmpty)
    }

    // MARK: - O7

    @Test func 백업_전_실패_보류는_다시_읽기만으로는_풀지_않고_사람_편집의_새_판에_다시_시도한다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        w.h.script.writeError = DJCError.writeRefused("백업 폴더에 쓰지 못했습니다")
        try await w.start()
        try await w.advance(12)
        #expect(w.writes.count == 2 && w.engine.status == .held(.preBackupFailure))
        // 다시 읽기(행만 바뀜)도 앱은 저장 대기 변경으로 알린다
        try await w.edited()
        try await w.advance(5)
        #expect(w.writes.count == 2)
        w.cue("a", at: 30)
        try await w.edited()
        try await w.advance(3)
        #expect(w.writes.count == 3)
    }
}

/// 영속 기록(R7·R8·R14): 멈춤·[취소]를 디스크에 남기지 못하면 이 실행은 자동 저장을 보류하고 다음 판정마다 다시 남겨 본다
@MainActor
@Suite("자동 저장: 영속 기록")
struct AutoReflectionRecordTests {
    @Test func 기록을_남기지_못하면_자동_저장을_보류하고_남길_수_있게_되면_이어_간다() async throws {
        let fakes = AutoReflectionFakes()
        let w = AutoReflectionWorld(fakes: fakes)
        let uuids = (0..<50).map { String(format: "t%03d", $0) }
        w.writable(uuids + ["z"])
        uuids.forEach { w.cue($0) }
        try await w.start()
        try await w.advance(15)
        // [취소]를 남기지 못한다(다시 켜면 [취소]가 풀려 같은 편집을 자동으로 쓸 수 있다)
        fakes.records.failSaving()
        w.engine.cancelGrace()
        try await w.settle()
        w.cue("z")
        try await w.edited()
        try await w.advance(15)
        #expect(w.writes.isEmpty && w.engine.conditions.holds.contains(.stoppedAfterFailure))
        fakes.records.failSaving(false)
        try await w.advance(2)
        await w.engine.recordSaved()
        #expect(fakes.records.record.cancelledRevisions.count == 50, "다음 판정에서 다시 남긴다")
        try await w.advance(5)
        #expect(w.writes.count == 1 && w.writes.first?.drafts.map(\.trackUUID) == ["z"])
    }
}

/// 2라운드: 조건·멈춤(O2·O3)
@MainActor
@Suite("자동 저장: 조건·멈춤 2")
struct AutoReflectionStopTests {
    @Test func 자동_저장하지_않는_실행도_rekordbox_켜짐을_조건에_싣는다() async throws {
        let w = AutoReflectionWorld()
        w.run = .off(.diagnostic)
        w.fakes.setRunState(.running)
        try await w.start()
        #expect(w.engine.conditions.holds.isSuperset(of: [.rekordboxRunning, .notAutoRun(.diagnostic)]))
        #expect(w.writes.isEmpty)
    }

    @Test func 수동_저장이_백업을_뜬_뒤_실패하면_오류_종류와_상관없이_멈춘다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        try await w.start()
        // ⌘S가 백업 뒤 준비 파일을 쓰지 못해 롤백했다(오류는 원래 오류 그대로 보이고 백업 뒤 표시만 실렸다)
        let failure = RekordboxWriteGate.AfterBackupFailure(CocoaError(.fileWriteNoPermission))
        _ = await w.engine.exclusive { ReflectionOutcome.failed(title: "실패", error: failure, exclusions: []) }
        try await w.settle()
        try await w.advance(20)
        #expect(w.writes.isEmpty && w.engine.status == .stopped(.stoppedAfterFailure))
    }
}
