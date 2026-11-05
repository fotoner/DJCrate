import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Testing

/// 쓰는 중 앱 종료(#300): 반영 세션이 알리는 단계가 종료 판정의 단계(`RekordboxWritePhase`)로 맞게 바뀌는지 본다.
/// 끊어도 되는 단계는 "아직 아무것도 쓰지 않은 단계"와 "쓴 뒤 읽기만 하는 단계"뿐이다. 그 사이(백업·DB·분석 파일·초안 정리·복원)는 끝까지 기다린다.
@MainActor
@Suite("반영 세션: 쓰기 단계와 종료 판정")
struct WriteStagePhaseTests {
    let h = ReflectionHarness()
    typealias H = ReflectionHarness

    /// 알린 단계를 연속된 같은 단계를 하나로 줄여 본다
    var phases: [RekordboxWritePhase] {
        h.stages.compactMap { $0 }.map(\.phase).reduce(into: []) { result, phase in
            if result.last != phase { result.append(phase) }
        }
    }

    // MARK: - 단계 하나

    @Test func 취소할_수_있는_단계는_취소_단계이고_쓰는_단계는_끊지_않는다() {
        #expect(WriteStage("미리 보기", cancellable: true).phase == .cancellable)
        #expect(WriteStage("rekordbox에 쓰는 중…").phase == .writing)
        #expect(WriteStage.reloadingLibrary.phase == .readingBack)
        // 취소할 수 있으면 다시 읽기 표시가 있어도 취소 단계가 먼저다(아직 쓰지 않았다)
        #expect(WriteStage("읽기", cancellable: true, readsBack: true).phase == .cancellable)
    }

    // MARK: - 초안 쓰기

    @Test func 쓰기는_미리_보기_뒤_끊지_않는_쓰기를_거쳐_다시_읽기로_끝난다() async {
        h.state.cueDraftUUIDs.insert("a")
        h.state.rows["a"] = H.row("a")
        h.memory.save(H.cue("a"))
        h.script.preview = H.report(cues: [H.outcome("a", .written)])
        // 다시 읽기 단계에 들어선 순간에는 DB 쓰기가 끝났고 쓴 초안의 정리도 끝나 있어야 한다(종료 대기가 여기서 끝나므로)
        var atReadBack: (writes: Int, cueDraftLeft: Bool)?
        h.onStage = { [h] stage in
            guard stage?.phase == .readingBack, atReadBack == nil else { return }
            atReadBack = (h.gateCalls.value.writes.count, h.memory.cue("a") != nil)
        }
        #expect(await h.session.write(rows: [H.row("a")]).name == "written")
        #expect(phases == [.cancellable, .writing, .readingBack])
        #expect(atReadBack?.writes == 1 && atReadBack?.cueDraftLeft == false, "다시 읽기는 DB 쓰기와 초안 정리가 끝난 뒤에 시작한다")
    }

    /// 앱은 이 순간을 `confirming`으로 본다(확인 창을 띄우는 동안 표시를 켠다): 잠금은 걸려 있고 진행 안내는 거둔 뒤다. 아직 아무것도 쓰지 않았다.
    @Test func 확인_창이_뜨는_동안_잠금은_걸려_있고_진행_안내는_없으며_쓰기는_시작하지_않았다() async {
        h.state.cueDraftUUIDs.insert("a")
        h.state.rows["a"] = H.row("a")
        h.memory.save(H.cue("a"))
        h.script.preview = H.report(cues: [H.outcome("a", .written), H.outcome("b", .blocked, reason: "바뀜")])
        h.answer = false
        var seen: (locked: Bool, stage: Bool, writes: Int)?
        h.onPrompt = { [h] in seen = (h.locked, h.stages.last == .some(nil), h.gateCalls.value.writes.count) }
        #expect(await h.session.write(rows: [H.row("a")]).name == "declined")
        #expect(seen?.locked == true && seen?.stage == true && seen?.writes == 0)
    }

    // MARK: - 복원

    @Test func 복원은_다시_읽는_단계도_끊지_않는다() async {
        // 복원은 읽은 뒤에도 추가 목록 되살리기·재생 목록 편집 쌓기가 남아 있다
        _ = await h.session.restore(H.backup("x"))
        let texts = h.stages.compactMap { stage in stage?.text }
        #expect(phases == [.writing], "복원 단계에 취소·다시 읽기 단계가 없다: \(phases)")
        #expect(texts.contains("복원한 라이브러리를 읽는 중…"))
    }

    // MARK: - 빼기

    @Test func 빼기는_미리_보기_뒤_끊지_않는_쓰기를_거쳐_다시_읽기로_끝난다() async {
        var report = RekordboxTrackWriteReport(dryRun: true)
        report.deleted = [H.track("/x", uuid: nil)]
        report.deleted[0].contentID = "1"
        h.script.deletePreview = report
        #expect(await h.session.deleteTracks(rows: [H.row("1")]).name == "deleted")
        #expect(phases == [.cancellable, .writing, .readingBack])
    }

    // MARK: - 넣기

    @Test func 넣기는_음량을_재는_동안만_취소할_수_있고_쓰기는_끊지_않는다() async {
        let staged = H.staged("a")
        h.state.staged = [staged]
        h.memory.save(H.grid("a"))
        let path = staged.path
        // 넣은 곡은 새 UUID를 받고 백업이 남는다(넣은 뒤 처리: 추가 목록에서 빼기, 백업에 추가 목록과 초안 사본 남기기)
        var written = RekordboxTrackWriteReport(dryRun: false)
        written.added = [H.track(path, uuid: "new-a")]
        written.backup = "/backups/add-1"
        h.script.addPreview.added = [H.track(path)]
        h.script.add = written
        // 다시 읽기 단계에 들어선 순간에는 추가 목록 정리와 백업 사본 남기기가 끝나 있어야 한다(종료 대기가 여기서 끝나므로)
        var atReadBack: (stagedLeft: Bool, backedUp: Bool)?
        h.onStage = { [h] stage in
            guard stage?.phase == .readingBack, atReadBack == nil else { return }
            atReadBack = (!h.state.staged.isEmpty, h.log.contains("backup staged [\"a\"]"))
        }
        let outcome = await h.session.addTracks(rows: [H.row(staged.id, path: path)])
        #expect(outcome.name == "added")
        #expect(phases.first == .cancellable && phases.contains(.writing))
        #expect(phases.last == .readingBack, "넣은 곡을 읽는 단계는 초안 옮기기·백업 사본 남기기가 끝난 뒤다: \(phases)")
        #expect(atReadBack?.stagedLeft == false && atReadBack?.backedUp == true, "다시 읽기는 추가 목록 정리와 백업 사본 남기기가 끝난 뒤에 시작한다")
        // 쓰기 뒤에 취소 단계로 돌아가지 않는다
        if let firstWriting = phases.firstIndex(of: .writing) {
            #expect(!phases[firstWriting...].contains(.cancellable))
        }
    }

    // MARK: - 결과·실패 경고는 잠금이 걸린 채 알린다

    /// 쓰기·복원이 실패하면 결과(경고창)를 잠금이 풀리기 전에 알린다. 앱은 그 순간을 `acknowledging`으로 본다(경고창을 확인하기 전에는 끄지 않는다).
    @Test func 결과와_실패는_잠금이_걸린_채_알린다() async {
        var lockedAtPublish: [String: Bool] = [:]
        h.onPublish = { [h] outcome in lockedAtPublish[outcome.name] = h.locked }
        // 쓰기 성공
        h.state.cueDraftUUIDs.insert("a")
        h.state.rows["a"] = H.row("a")
        h.memory.save(H.cue("a"))
        h.script.preview = H.report(cues: [H.outcome("a", .written)])
        _ = await h.session.write(rows: [H.row("a")])
        // 쓰기 실패
        h.memory.save(H.cue("a"))
        h.script.writeError = FixtureFailure()
        _ = await h.session.write(rows: [H.row("a")])
        // 복원 실패(복원까지 실패해 사용자가 확인해야 하는 경고)
        h.script.restoreError = FixtureFailure()
        _ = await h.session.restore(H.backup("x"))
        #expect(lockedAtPublish["written"] == true)
        #expect(lockedAtPublish["failed"] == true)
        #expect(lockedAtPublish["restoreFailed"] == true)
        #expect(!h.locked)
    }

    // MARK: - 시점 스냅샷 복원

    @Test func 시점_복원은_복원이_끝난_뒤의_다시_읽기만_끊어도_된다() async throws {
        _ = try await h.session.restorePointSnapshot(URL(filePath: "/s/2026-manual"), snapshots: URL(filePath: "/s"), autoDays: 7,
                                                     now: Date(timeIntervalSince1970: 0), changedTracks: ["u1"], to: .copy)
        #expect(phases == [.writing, .readingBack])
    }
}
