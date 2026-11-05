import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Testing

/// 종료를 기다리는 중이면 쓴 뒤 다시 읽기를 건너뛰고 쓰기 결과를 먼저 남긴다(#305).
/// 다시 읽기는 반영 세션의 다시 읽기 포트(`LibraryReloader`) 한 곳에서 미룬다. 읽기만 남은 단계(`readsBack`)만 미루고,
/// 읽은 뒤에도 할 일이 남은 복원의 다시 읽기는 미루지 않는다.
@MainActor
@Suite("반영 세션: 종료 대기 중 다시 읽기 건너뛰기")
struct ReflectionSessionPostponeTests {
    let h = ReflectionHarness()
    typealias H = ReflectionHarness

    /// 알린 단계를 연속된 같은 단계를 하나로 줄여 본다
    var phases: [RekordboxWritePhase] {
        h.stages.compactMap { $0 }.map(\.phase).reduce(into: []) { result, phase in
            if result.last != phase { result.append(phase) }
        }
    }

    /// 앱이 지금 보고 있을 종료 판정: 잠금이 풀렸으면 쓰지 않고, 걸려 있으면 진행 안내의 단계(안내가 없는 틈은 쓰는 단계)다
    /// (`LibraryStore.rekordboxWritePhase`와 같은 규칙).
    var quitDecision: AppQuitDecision {
        let phase: RekordboxWritePhase = h.locked ? (h.stages.last.flatMap { $0 }?.phase ?? .writing) : .idle
        return AppQuitPolicy.decision(for: AppWriteActivity(rekordbox: phase, writingUsb: false))
    }

    func prepareWrite() {
        h.state.cueDraftUUIDs.insert("a")
        h.state.rows["a"] = H.row("a")
        h.memory.save(H.cue("a"))
        h.script.preview = H.report(cues: [H.outcome("a", .written)])
    }

    // MARK: - 쓰기

    @Test func 종료를_기다리는_중이면_쓴_뒤_다시_읽기_포트를_부르지_않고_미룬다() async {
        prepareWrite()
        h.postponesReload = true
        #expect(await h.session.write(rows: [H.row("a")]).name == "written")
        #expect(h.reloads.isEmpty && !h.log.contains("reload"), "미룬 읽기는 읽지 않는다")
        // 읽은 뒤 덱에 알릴 곡은 포트가 기억해 둔다(종료를 취소하면 이어서 읽을 때 알린다)
        #expect(h.postponed.map(\.written) == [["a"]] && h.postponed.map(\.playlistEdits.count) == [0])
        // 쓰기와 쓴 초안 정리는 그대로 끝났다
        #expect(h.gateCalls.value.writes.count == 1 && h.memory.cue("a") == nil)
        #expect(h.changeNames.contains("cleared cue [\"a\"] counts"))
        // 읽지 못한 것이 아니라 미룬 것이라 다시 읽기 실패 경고가 붙지 않는다
        #expect(h.followUp == [] && h.state.lastError == nil)
    }

    @Test func 종료를_기다리는_중이면_다시_읽는_단계를_알리지_않아_쓰기_결과를_남기기_전에_종료하지_않는다() async {
        prepareWrite()
        h.postponesReload = true
        // 단계가 바뀔 때마다 앱이 내릴 종료 판정을 모은다(결과를 알리기 전까지)
        var beforePublish: [AppQuitDecision] = []
        var published = false
        h.onStage = { [self] _ in if !published { beforePublish.append(quitDecision) } }
        h.onPublish = { [self] _ in
            published = true
            beforePublish.append(quitDecision)
        }
        _ = await h.session.write(rows: [H.row("a")])
        #expect(phases == [.cancellable, .writing], "다시 읽기 단계가 없다: \(phases)")
        // 다시 읽는 단계(`readingBack`)는 앱이 곧바로 종료해도 되는 단계라서, 미룬 길은 이 단계를 알리지 않는다.
        // 결과를 알리는(=활동 기록에 남기는) 순간까지 어느 판정도 곧바로 종료가 아니다
        #expect(!beforePublish.isEmpty && !beforePublish.contains(.terminateNow), "\(beforePublish)")
        #expect(beforePublish.last == .waitForRekordboxWrite)
        // 결과를 남긴 뒤에야 잠금이 풀려 종료를 허용한다
        #expect(h.published.map(\.name) == ["written"] && !h.locked && quitDecision == .terminateNow)
    }

    @Test func 종료를_기다리지_않으면_지금처럼_다시_읽고_다시_읽는_단계를_알린다() async {
        prepareWrite()
        var decisions: [AppQuitDecision] = []
        h.onStage = { [self] _ in decisions.append(quitDecision) }
        #expect(await h.session.write(rows: [H.row("a")]).name == "written")
        // 다시 읽는 단계에서는 종료를 바로 허용한다(#300). 미룬 길과 달라지는 자리다
        #expect(decisions.contains(.terminateNow))
        #expect(h.postponeAsks == 1, "다시 읽기 앞에서 미룰지 한 번 묻는다")
        #expect(h.reloads.map(\.written) == [["a"]] && h.postponed.isEmpty)
        #expect(phases == [.cancellable, .writing, .readingBack])
    }

    @Test func 다시_읽기를_미루면_읽기_실패_경고_대신_쓰기_결과만_남는다() async {
        prepareWrite()
        h.postponesReload = true
        // 읽었다면 실패했을 환경이어도 읽지 않았으니 이유가 없다
        h.reloadSucceeds = false
        h.reloadError = "rekordbox가 켜져 있어 읽지 못했습니다"
        _ = await h.session.write(rows: [H.row("a")])
        #expect(h.followUp == [] && !h.changeNames.contains { $0.hasPrefix("error ") })
    }

    // MARK: - 곡 넣기·빼기·시점 복원(읽기만 남은 단계)

    @Test func 넣기도_종료를_기다리는_중이면_읽지_않고_미룬다() async {
        let staged = H.staged("a")
        h.state.staged = [staged]
        h.memory.save(H.grid("a"))
        var written = RekordboxTrackWriteReport(dryRun: false)
        written.added = [H.track(staged.path, uuid: "new-a")]
        written.backup = "/backups/add-1"
        h.script.addPreview.added = [H.track(staged.path)]
        h.script.add = written
        h.postponesReload = true
        #expect(await h.session.addTracks(rows: [H.row(staged.id, path: staged.path)]).name == "added")
        #expect(h.reloads.isEmpty && h.postponed.count == 1)
        #expect(phases.last == .writing && !phases.contains(.readingBack), "\(phases)")
        // 읽기를 미뤄도 쓴 뒤 처리(추가 목록 정리·백업 사본)는 끝나 있다
        #expect(h.state.staged.isEmpty && h.log.contains("backup staged [\"a\"]"))
        #expect(h.changeNames.contains("last backup add-1"))
    }

    @Test func 빼기도_종료를_기다리는_중이면_읽지_않고_미룬다() async {
        var report = RekordboxTrackWriteReport(dryRun: true)
        report.deleted = [H.track("/x", uuid: nil)]
        report.deleted[0].contentID = "1"
        h.script.deletePreview = report
        h.postponesReload = true
        #expect(await h.session.deleteTracks(rows: [H.row("1")]).name == "deleted")
        #expect(h.reloads.isEmpty && h.postponed.count == 1)
        #expect(phases == [.cancellable, .writing])
    }

    @Test func 시점_복원도_종료를_기다리는_중이면_읽지_않고_미룬다() async throws {
        h.postponesReload = true
        _ = try await h.session.restorePointSnapshot(URL(filePath: "/s/2026-manual"), snapshots: URL(filePath: "/s"), autoDays: 7,
                                                     now: Date(timeIntervalSince1970: 0), changedTracks: ["u1"], to: .copy)
        #expect(h.reloads.isEmpty && h.postponed.map(\.written) == [["u1"]])
        #expect(phases == [.writing])
        #expect(h.changeNames.contains("backups changed"))
    }

    // MARK: - 복원(읽은 뒤에도 할 일이 남아서 미루지 않는다)

    @Test func 복원의_다시_읽기는_종료를_기다리는_중이어도_미루지_않는다() async {
        // 복원은 읽은 뒤 재생 목록 편집 쌓기와 추가 목록 되살리기가 남는다. 읽지 않고 종료하면 그 일을 잃는다.
        h.postponesReload = true
        _ = await h.session.restore(H.backup("x"))
        #expect(h.reloads.count == 1 && h.postponed.isEmpty)
        #expect(h.postponeAsks == 0, "읽기만 남은 단계가 아니면 미룰지 묻지도 않는다")
    }
}
