import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 자동 저장 묶음의 검증(R4·R6·R14·R22): 묶음에 넣는 값은 도장의 판·출처·해시와 맞는 것만, 막힌 곡은 그 곡의 대상 초안을 모두 빼고,
/// 쓰이지 않은 재생 목록 단계는 확인 필요로 남기고, 재생 목록 단위의 행 수는 단계를 차례로 적용하며 실제로 갱신할 행으로 센다.
@MainActor
@Suite("자동 저장: 묶음 검증")
struct AutoReflectionBatchTests {
    static let layout = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가"), 1), (PlaylistLayout.Item(id: "B", name: "나"), 2)])

    // MARK: - S4

    @Test func 판은_같고_파일만_바뀐_초안은_자동으로_쓰지_않고_제안으로_남긴다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        // 저장 대기를 나눈 뒤 스냅샷을 기다리는 동안 바깥 편집기가 초안 파일만 바꿨다(판·출처는 그대로)
        w.onSnapshot = { [memory = w.h.memory] in memory.editOutside(ReflectionHarness.cue("a", at: 50)) }
        try await w.start()
        try await w.advance(12)
        #expect(w.writes.allSatisfy { batch in !batch.drafts.contains { $0.trackUUID == "a" } })
        #expect(w.h.memory.cue("a")?.cues.first?.time == 50)
        #expect(w.engine.conditions.leftovers.contains(.suggestion))
    }

    // MARK: - S7

    @Test func 한_종류가_막힌_곡은_통과한_종류도_쓰지_않고_확인_필요로_남긴다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a", "b")
        w.cue("a")
        w.cue("b")
        // a의 태그는 미리 보기에서 막힌다(큐는 통과)
        let tag = ReflectionHarness.tag("a")
        w.h.state.tagDrafts["a"] = tag
        w.h.memory.save(tag)
        w.h.script.preview.tagOutcomes = [ReflectionHarness.outcome("a", .blocked, reason: "기준 어긋남")]
        try await w.start()
        try await w.advance(12)
        let batch = try #require(w.writes.first)
        #expect(w.writes.count == 1 && batch.drafts.map(\.trackUUID) == ["b"] && batch.tags.isEmpty)
        #expect(w.h.memory.cue("a") != nil && w.engine.conditions.leftovers.contains(.needsConfirmation))
    }

    // MARK: - S13·G3·O1

    @Test(arguments: [RekordboxWriteOutcome.Status.blocked, .unchanged])
    func 재생_목록_단계가_하나도_쓰이지_않으면_새_편집_전까지_다시_미리_보지_않는다(_ status: RekordboxWriteOutcome.Status) async throws {
        let w = AutoReflectionWorld()
        var draft = PlaylistDraft()
        _ = try draft.append(.rename(playlist: .id("B"), name: "새 나"), rekordbox: Self.layout)
        try w.h.memory.store.savePlaylistDraft(draft)
        w.h.state.rekordboxPlaylists = Self.layout
        w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        w.h.script.preview.playlistOutcomes = [PlaylistOutcome(edit: draft.steps[0].edit, playlistID: "B", name: "새 나", status: status,
                                                               reason: status == .blocked ? "바뀜" : nil)]
        try await w.start()
        try await w.advance(12)
        #expect(w.previews.count == 1)
        try await w.advance(10)
        #expect(w.previews.count == 1 && w.writes.isEmpty)
        #expect(w.engine.conditions.leftovers.contains(.needsConfirmation))
    }

    // MARK: - S9

    @Test func 곡_빼기_뒤_번호를_다시_매기는_행까지_세어_K행을_넘는_단위는_자동으로_쓰지_않는다() async throws {
        let w = AutoReflectionWorld()
        // 94곡 목록에 54곡을 넣고 기존 54곡을 뺀다: 넣기 54 + 빼기 54 + 남은 94곡 번호 다시 매기기 = 202행(K=200)
        let old = (1...94).map { PlaylistEntry(trackNo: $0, contentID: "\($0)") }
        let layout = PlaylistLayout([(PlaylistLayout.Item(id: "A", name: "가", entries: old), 1)])
        for id in 1...148 { w.h.state.rows["\(id)"] = ReflectionHarness.row("\(id)") }
        var draft = PlaylistDraft()
        _ = try draft.append(.addTracks(playlist: .id("A"), contentIDs: (95...148).map { "\($0)" }), rekordbox: layout)
        _ = try draft.append(.removeTracks(playlist: .id("A"), entries: Array(old.prefix(54))), rekordbox: layout)
        try w.h.memory.store.savePlaylistDraft(draft)
        w.h.state.rekordboxPlaylists = layout
        w.h.state.playlistDraft = w.h.memory.store.playlistDraft()
        w.h.script.preview.playlistOutcomes = draft.steps.map { PlaylistOutcome(edit: $0.edit, playlistID: "A", name: "가", status: .written) }
        try await w.start()
        try await w.advance(60)
        #expect(w.writes.isEmpty && w.previews.isEmpty)
        #expect(w.engine.status == .leftover(count: 2))
    }

    // MARK: - S14

    @Test func 곡만_쓰는_자동_저장도_빈_단계로_얼려_재생_목록_편집을_받는다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        try await w.start()
        try await w.advance(10)
        #expect(w.writes.count == 1 && w.h.changeNames.contains("frozen 0 histories 0"))
    }

    // MARK: - O6

    @Test func 자동_저장은_쓰기_잠금을_기다리지_않고_못_잡으면_잠금_보류로_본다() async throws {
        let w = AutoReflectionWorld()
        w.writable("a")
        w.cue("a")
        // 판정 뒤 쓰기 입구가 잠금을 잡기 전에 다른 프로세스가 잡았다(관문이 기다리지 않고 알린다)
        w.h.script.writeError = RekordboxWriteGate.LockBusy()
        try await w.start()
        try await w.advance(13)
        #expect(!w.writes.isEmpty && w.writes.allSatisfy(\.isAutoSave))
        #expect(w.engine.conditions.holds.contains(.lockBusy))
        await w.engine.recordSaved()
        #expect(w.fakes.records.record.preBackupFailure == nil, "백업 전 실패로 세지 않는다")
    }
}
