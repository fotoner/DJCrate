import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Testing

/// 반영 세션의 USB 재생 기록 쓰기(#43): 쓰기 대기 기록만 있어도 쓰고, 막힌 기록은 확인 창에 이유를 보이고, 미리 보기에서 쓸 수 있던 기록만 넘기고,
/// 쓴(또는 최신 사본에 이미 있던) 기록을 화면에 알린다. 가짜 포트로 DB·앱 없이 본다
/// (옛 앱 시험 `UsbHistoryWriteTests`의 `FakeReflectionHost` 흐름 시험. 결과 문장은 앱 시험 `UsbHistoryWriteTests.resultLines`가 본다)
@MainActor
@Suite("반영 세션: USB 재생 기록 쓰기")
struct ReflectionSessionHistoryTests {
    let h = ReflectionHarness()
    typealias H = ReflectionHarness
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func history(_ key: String) -> HistoryImport {
        HistoryImport(id: ArchivedHistory.idPrefix + key, name: "HISTORY \(key)", dateCreated: now, contentIDs: ["1", "2"])
    }

    static func outcome(_ key: String, _ status: RekordboxHistoryOutcome.Status, reason: String? = nil) -> RekordboxHistoryOutcome {
        RekordboxHistoryOutcome(id: ArchivedHistory.idPrefix + key, name: "HISTORY \(key)",
                                historyID: status == .blocked ? nil : "rb-\(key)", status: status, reason: reason,
                                entries: status == .written ? 2 : 0, skipped: 0)
    }

    static func report(_ outcomes: [RekordboxHistoryOutcome], cues: [RekordboxWriteOutcome] = []) -> RekordboxWriteReport {
        var report = H.report(cues: cues)
        report.historyOutcomes = outcomes
        return report
    }

    func pendingCue(_ uuid: String) {
        h.state.cueDraftUUIDs.insert(uuid)
        h.state.rows[uuid] = H.row(uuid)
        h.memory.save(H.cue(uuid))
    }

    @Test func 곡_초안이_없어도_쓰기_대기_재생_기록만_묻지_않고_쓰고_쓴_기록을_화면에_알린다() async {
        h.state.pendingHistories = [Self.history("a")]
        h.script.preview = Self.report([Self.outcome("a", .written)])
        #expect(await h.session.write(rows: []).name == "written")
        #expect(h.gateCalls.value.previews.first?.histories.map(\.id) == [ArchivedHistory.idPrefix + "a"])
        #expect(h.prompts.isEmpty)
        #expect(h.gateCalls.value.writes.first?.histories.map(\.id) == [ArchivedHistory.idPrefix + "a"])
        #expect(h.gateCalls.value.writes.first?.drafts == [])
        // 다시 읽기 전에 쓴 기록 ID를 남긴다(다시 읽지 못해도 같은 기록을 또 쓰지 않게)
        #expect(h.recordedHistories == [[Self.outcome("a", .written)]])
        #expect(h.log.first("record histories")! < h.log.first("reload")!)
        #expect(h.locks == ["true", "false"])
    }

    @Test func 막힌_재생_기록이_있으면_확인_창에_이유를_보이고_쓸_수_있는_것만_쓴다() async throws {
        pendingCue("x")
        h.state.pendingHistories = [Self.history("b")]
        h.script.preview = Self.report([Self.outcome("b", .blocked, reason: "재생 기록 쓰기를 아직 열지 않았습니다")],
                                       cues: [H.outcome("x", .written)])
        #expect(await h.session.write(rows: [H.row("x")]).name == "written")
        let prompt = try #require(h.prompts.first)
        #expect(prompt.title == "큐 1곡을 rekordbox에 쓸까요?")
        #expect(prompt.details == ["쓰지 않는 것 1:", "• HISTORY b: 재생 기록 쓰기를 아직 열지 않았습니다"])
        #expect(h.gateCalls.value.writes.first?.drafts.map(\.trackUUID) == ["x"] && h.gateCalls.value.writes.first?.histories == [])
        // 함께 쓸 수 있으면 제목에 함께 센다
        let both = Self.report([Self.outcome("a", .written), Self.outcome("b", .blocked, reason: "이유")], cues: [H.outcome("x", .written)])
        #expect(ReflectionPrompts.confirmation(both).title == "큐 1곡 · 재생 기록 1건을 rekordbox에 쓸까요?")
    }

    @Test func 재생_기록이_모두_막히면_창_없이_쓰지_않는다() async {
        h.state.pendingHistories = [Self.history("b")]
        h.script.preview = Self.report([Self.outcome("b", .blocked, reason: "닫힘")])
        #expect(await h.session.write(rows: []).name == "nothingWritable")
        #expect(h.prompts.isEmpty && h.gateCalls.value.writes.isEmpty && h.recordedHistories.isEmpty)
    }

    @Test func 곡을_골라_쓰는_메뉴는_재생_기록을_넣지_않는다() async {
        h.state.pendingHistories = [Self.history("a")]
        #expect(await h.session.write(rows: [H.row("a")], playlists: false).notice?.title == "쓸 초안이 없습니다")
        #expect(h.gateCalls.value.previews.isEmpty)
        pendingCue("x")
        h.script.preview = H.report(cues: [H.outcome("x", .written)])
        _ = await h.session.write(rows: [H.row("x")], playlists: false)
        #expect(h.gateCalls.value.previews.first?.histories == [] && h.gateCalls.value.writes.first?.histories == [])
    }

    @Test func 최신_사본에_이미_있는_기록은_미리_보기에서_연결만_알리고_넘기지_않는다() async throws {
        h.state.pendingHistories = [Self.history("a"), Self.history("b")]
        h.script.preview = Self.report([Self.outcome("a", .unchanged), Self.outcome("b", .written)])
        h.historyMarkWarning = "합성 저장 실패"
        let preview = try await h.session.previewWrite(rows: [], playlists: true)
        #expect(h.recordedHistories == [[Self.outcome("a", .unchanged)]])
        #expect(h.changeNames.contains("history mark failed 합성 저장 실패"))
        #expect(preview.writableBatch.histories.map(\.id) == [ArchivedHistory.idPrefix + "b"])
        #expect(preview.hasWritable)
    }

    @Test func 쓴_표시를_저장하지_못하면_쓴_뒤_경고에_남긴다() async {
        h.state.pendingHistories = [Self.history("a")]
        h.script.preview = Self.report([Self.outcome("a", .written)])
        h.historyMarkWarning = "합성 표시 경고"
        #expect(await h.session.write(rows: []).name == "written")
        #expect(h.followUp == ["합성 표시 경고"])
    }
}
