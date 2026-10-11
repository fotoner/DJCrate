import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Testing

/// 되돌릴 수 있는 rekordbox 쓰기는 묻지 않고 바로 쓴다(#210, #209 조사 1의 B칸). 막힘·제외·손실(합치기)이 있거나 쓰기 전 백업을 만들 수
/// 없을 때만 묻고, 창에는 그 이유만 보인다. 판정 자체(`WriteConfirmPolicy`)는 `ReflectionPromptsTests`가 보고, 여기서는 세션이 판정대로 묻는지 본다.
/// (옛 앱 시험 `WriteConfirmPolicyTests`·`DuplicateMergeAppTests`·`ReflectionPromptLayoutTests`·`WriteResultTests`·`WriteFollowUpTests`의 흐름 부분)
@MainActor
@Suite("반영 세션: 확인 정책과 취소")
struct ReflectionSessionConfirmTests {
    let h = ReflectionHarness()
    typealias H = ReflectionHarness

    func pendingCue(_ uuids: String...) {
        for uuid in uuids {
            h.state.cueDraftUUIDs.insert(uuid)
            h.state.rows[uuid] = H.row(uuid)
            h.memory.save(H.cue(uuid))
        }
    }

    // MARK: 쓰기

    @Test func 막힘이_없으면_묻지_않고_쓰고_결과에_되돌릴_백업을_남긴다() async throws {
        pendingCue("a")
        h.state.tagDrafts["t"] = H.tag("t")
        h.state.rows["t"] = H.row("t")
        h.memory.save(H.tag("t"))
        h.script.preview = H.report(cues: [H.outcome("a", .written)], tags: [H.outcome("t", .written)])
        h.script.write = H.report(cues: [H.outcome("a", .written)], tags: [H.outcome("t", .written)], backup: "/tmp/djc-test-backup", dryRun: false)
        let outcome = await h.session.write(rows: ["a", "t"].map { H.row($0) })
        #expect(h.prompts.isEmpty && h.locks == ["true", "false"])
        let written = try #require(h.gateCalls.value.writes.first)
        #expect(written.drafts.map(\.trackUUID) == ["a"] && written.tags.map(\.trackUUID) == ["t"])
        guard case let .written(report, _, _) = outcome else { Issue.record("\(outcome.name)"); return }
        #expect(report.backup == "/tmp/djc-test-backup")
    }

    @Test func 막히면_쓰는_것은_빼고_막힌_이유만_보이는_창으로_묻는다() async throws {
        pendingCue("a", "b")
        h.script.preview = H.report(cues: [H.outcome("a", .written), H.outcome("b", .blocked, reason: "rekordbox에서 바뀜")])
        h.answer = false
        _ = await h.session.write(rows: ["a", "b"].map { H.row($0) })
        #expect(h.prompts == [ReflectionPrompts.confirmation(h.script.preview)] && h.gateCalls.value.writes.isEmpty)
    }

    @Test func 백업을_만들_수_없으면_묻는다() async throws {
        pendingCue("a")
        h.script.preview = H.report(cues: [H.outcome("a", .written)])
        h.canBackUp = false
        h.answer = false
        _ = await h.session.write(rows: [H.row("a")])
        let prompt = try #require(h.prompts.first)
        #expect(prompt.details.contains(ReflectionPrompts.noBackupText) && h.gateCalls.value.writes.isEmpty)
    }

    @Test func 합치기만_있어도_잃는_것을_묻고_확인하면_한_번_쓴다() async throws {
        let merge = DuplicateMergeDraft(keeping: .init(contentID: "a", trackUUID: "a", title: "남길 곡", duration: 1, offset: 0, cues: []),
                                        removing: [.init(contentID: "b", trackUUID: "b", title: "뺄 곡", duration: 1, offset: 0, cues: [])], base: "")
        h.state.mergeDrafts = [merge]
        h.state.rows["a"] = H.row("a")
        var report = H.report()
        report.mergeOutcomes = [RekordboxWriteOutcome(trackUUID: merge.id, title: "남길 곡", status: .written, reason: nil, removed: 1, added: 0)]
        h.script.preview = report
        _ = await h.session.write(rows: [H.row("a")])
        let prompt = try #require(h.prompts.first)
        #expect(prompt.destructive && (prompt.text + prompt.details.joined()).contains("재생 기록"))
        #expect(h.gateCalls.value.writes.map(\.merges) == [[merge]])
    }

    @Test func 그리드와_게인_각_100곡은_막힘이_없으면_묻지_않고_모두_쓴다() async throws {
        for index in 1...100 {
            h.memory.save(H.grid("grid-\(index)"))
            h.memory.save(gain: -2.5, "gain-\(index)")
            h.state.gridDraftUUIDs.insert("grid-\(index)")
            h.state.gainDraftUUIDs.insert("gain-\(index)")
        }
        let rows = (1...100).flatMap { [H.row("grid-\($0)"), H.row("gain-\($0)")] }
        h.script.preview = H.report(grids: (1...100).map { H.outcome("grid-\($0)", .written, added: 64) },
                                    gains: (1...100).map { H.outcome("gain-\($0)", .written, added: -250) })
        _ = await h.session.write(rows: rows)
        let written = try #require(h.gateCalls.value.writes.first)
        #expect(h.prompts.isEmpty && written.grids.count == 100 && written.gains.count == 100 && h.locks == ["true", "false"])
    }

    // MARK: 넣기

    func stage(_ uuids: String...) -> [TrackRow] {
        uuids.map { uuid in
            let track = H.staged(uuid)
            h.state.staged.append(track)
            h.memory.save(H.grid(uuid))
            return H.row(track.id, path: track.path)
        }
    }

    @Test func 분석까지_넣는_곡만이면_묻지_않고_넣는다() async {
        let rows = stage("a", "b")
        h.script.addPreview.added = [H.track("/music/a.mp3"), H.track("/music/b.mp3")]
        _ = await h.session.addTracks(rows: rows)
        #expect(h.prompts.isEmpty && h.gateCalls.value.adds.last?.plans.map(\.fileName) == ["a.mp3", "b.mp3"] && h.locks == ["true", "false"])
    }

    @Test func 넣을_때_빠지는_것이_있으면_묻는다() async throws {
        let rows = stage("a", "b")
        h.unsupported = ["/music/b.mp3": "ALAC"]
        var b = H.track("/music/b.mp3")
        b.cueReason = "메모리 큐가 11개가 됩니다"
        h.script.addPreview.added = [H.track("/music/a.mp3"), b]
        h.answer = false
        #expect(await h.session.addTracks(rows: rows).name == "declined")
        #expect(h.prompts.count == 1 && h.gateCalls.value.order == ["add preview"])
    }

    // MARK: 빼기

    @Test func 빼기_확인_창은_동기화_곡을_이유와_함께_빼지_않는_곡으로_보여_준다() async throws {
        // 동기화 상태 곡은 쓰기 쪽이 곡마다 막고 이유를 돌려준다(#196). 확인 창은 빼지 않는 곡과 그 이유를 보여 주고, 뺄 곡만 뺀다.
        var report = RekordboxTrackWriteReport(dryRun: true)
        report.deleted = [H.track("a"), H.track("b", written: false, reason: "동기화 곡"), H.track("c", written: false, reason: "동기화 고아")]
        h.script.deletePreview = report
        _ = await h.session.deleteTracks(rows: ["1", "2", "3"].map { H.row($0) })
        let lines = try #require(h.prompts.first).details
        #expect(lines.contains("• 곡 b: 동기화 곡") && lines.contains("• 곡 c: 동기화 고아"))
        #expect(h.gateCalls.value.deletes.last == ["id-a"])
    }

    // MARK: 복원

    @Test func 토스트에서_누른_복원은_그_뒤_변경과_초안_충돌이_없으면_묻지_않고_지금_초안을_남긴다() async {
        h.backupDrafts.cues = [H.cue("a", at: 1)]
        h.memory.save(H.cue("a", at: 1))
        let backup = H.backup("b", report: H.report(dryRun: false))
        _ = await h.session.restore(backup, confirmed: true)
        #expect(h.prompts.isEmpty && h.gateCalls.value.restores == [backup.url])
        // 메뉴에서 고른 복원(어느 백업인지 아직 보지 않음)은 묻는다
        _ = await h.session.restore(backup)
        #expect(h.prompts.count == 1)
    }

    @Test(arguments: [2, nil] as [Int?])
    func 토스트에서_누른_복원도_그_뒤_rekordbox가_바뀌었거나_모르면_묻는다(count: Int?) async {
        // 카운터가 다르면 바뀜, 카운터를 남기지 않은 백업이면 모름
        h.updateCount = count ?? 1
        let backup = count == nil ? H.backup("old") : H.backup("b", report: H.report(dryRun: false))
        h.answer = false
        _ = await h.session.restore(backup, confirmed: true)
        #expect(h.prompts.first?.critical == true && h.gateCalls.value.restores.isEmpty)
    }

    @Test func 토스트에서_누른_복원도_뒤_백업이_있으면_묻는다() async {
        h.laterBackups = 1
        h.answer = false
        _ = await h.session.restore(H.backup("b", report: H.report(dryRun: false)), confirmed: true)
        #expect(h.prompts.count == 1 && h.gateCalls.value.restores.isEmpty)
    }

    @Test func 초안_충돌이_있으면_지금_초안과_백업_초안을_고르게_한다() async throws {
        let backup = H.backup("b", report: H.report(dryRun: false))
        for (choice, kept) in [(ReflectionChoice.confirm, true), (.alternate, false), (.cancel, nil)] {
            let h = ReflectionHarness()
            h.backupDrafts.cues = [H.cue("a", at: 1)]
            h.memory.save(H.cue("a", at: 2))
            h.choice = choice
            _ = await h.session.restore(backup, confirmed: true)
            let prompt = try #require(h.prompts.first)
            #expect(prompt.alternate == "복원하고 백업 초안으로 바꾸기" && prompt.confirm == "복원하고 지금 초안 남기기")
            #expect(prompt.details.contains("• a — 큐"))
            // 지금 초안을 남기면(확인) 그 곡의 백업 초안은 되살리지 않는다
            switch kept {
            case true?: #expect(h.memory.cue("a") == H.cue("a", at: 2))
            case false?: #expect(h.memory.cue("a") == H.cue("a", at: 1))
            case nil: #expect(h.gateCalls.value.restores.isEmpty)
            }
        }
    }

    // MARK: 취소

    @Test func 미리_보기_도중_취소하면_확인창과_실제_쓰기를_건너뛴다() async {
        pendingCue("a")
        h.script.preview = H.report(cues: [H.outcome("a", .written)])
        h.previewHold.hold()
        let session = h.session
        let task = Task { await session.write(rows: [H.row("a")]) }
        while !h.previewHold.isWaiting { await Task.yield() }
        // 미리 보기 단계는 취소할 수 있다
        #expect(h.stages.last??.cancellable == true)
        task.cancel()
        h.previewHold.release()
        #expect(await task.value.name == "cancelled")
        #expect(h.prompts.isEmpty && h.gateCalls.value.writes.isEmpty && !h.locked && h.stages.last == .some(nil))
    }

    @Test(arguments: ["넣기", "빼기"])
    func 미리_보기_전에_취소하면_아무것도_쓰지_않는다(operation: String) async {
        let rows = stage("a")
        h.script.addPreview.added = [H.track("/music/a.mp3")]
        var deleted = RekordboxTrackWriteReport(dryRun: true)
        deleted.deleted = [H.track("x")]
        h.script.deletePreview = deleted
        let session = h.session
        let task = Task { operation == "넣기" ? await session.addTracks(rows: rows) : await session.deleteTracks(rows: [H.row("1")]) }
        task.cancel()
        #expect(await task.value.name == "cancelled")
        #expect(h.prompts.isEmpty && h.gateCalls.value.order.isEmpty && !h.locked)
    }
}
