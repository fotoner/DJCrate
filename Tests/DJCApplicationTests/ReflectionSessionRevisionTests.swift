import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 쓰기 묶음의 판과 쓴 뒤 판 지정 정리(R22 호출부): ⌘S·자동 저장 모두 묶음에 초안마다 판과 앱 쓰기의 작업을 싣고,
/// 쓴 뒤에는 실제로 쓴 판만 지운다. 정리를 마치면 미정리 목록을 지우고, 마치지 못하면 남긴다.
@MainActor
@Suite("반영 세션: 판 지정 정리")
struct ReflectionSessionRevisionTests {
    let h = ReflectionHarness()

    func cue(_ uuid: String, at time: Double = 12, origin: DraftOrigin = .human) {
        h.state.rows[uuid] = ReflectionHarness.row(uuid)
        h.state.cueDraftUUIDs.insert(uuid)
        h.memory.save(ReflectionHarness.cue(uuid, at: time), origin: origin)
    }

    @Test func 앱_쓰기_묶음은_초안마다_판과_작업을_싣고_정리를_마치면_목록을_지운다() async throws {
        cue("a")
        h.script.preview = ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .written)])
        let stamp = try #require(h.memory.stamp(DraftKey(.cue, "a")))
        let outcome = await h.session.write(rows: [ReflectionHarness.row("a")])
        guard case .written = outcome else { Issue.record("썼다: \(outcome)"); return }
        let batch = try #require(h.gateCalls.value.writes.first)
        let entry = try #require(batch.revisions.tracks[DraftKey(.cue, "a")])
        let hash = try DraftContentHash(of: ReflectionHarness.cue("a"))
        #expect(entry.revision == stamp.revision && entry.contentHash == hash)
        let operation = try #require(batch.operation)
        #expect(operation.draftHome == URL(filePath: "/drafts"))
        #expect(h.memory.cue("a") == nil && h.gateCalls.value.removedCleanupLists == [operation.id])
    }

    @Test func CLI는_작업을_싣지_않는다() async throws {
        h.options = .cli(attachesAnalysis: false, writesArtwork: false)
        cue("a")
        h.script.preview = ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .written)])
        _ = try await h.session.writeDrafts(DraftWriteBatch(drafts: [ReflectionHarness.cue("a")]), to: h.session.target)
        #expect(h.gateCalls.value.writes.first?.operation == nil && h.gateCalls.value.removedCleanupLists.isEmpty)
    }

    @Test(arguments: [DraftOrigin.human, .cli])
    func 쓰는_동안_같은_곡에_새로_저장한_초안은_수동_저장_뒤에도_남는다(_ origin: DraftOrigin) async throws {
        cue("a")
        h.script.preview = ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .written)])
        h.previewHold.hold()
        let session = h.session
        let writing = Task { await session.write(rows: [ReflectionHarness.row("a")]) }
        for _ in 0..<2000 where !h.previewHold.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        h.memory.save(ReflectionHarness.cue("a", at: 40), origin: origin)
        h.previewHold.release()
        _ = await writing.value
        #expect(h.gateCalls.value.writes.count == 1)
        #expect(h.memory.cue("a")?.cues.first?.time == 40, "쓴 판이 아니라 지우지 않는다")
        #expect(!h.changeNames.contains("cleared cue [\"a\"] counts"), "화면 표시도 지우지 않는다")
    }

    @Test func 판이_같고_내용이_바깥에서_바뀐_초안은_지우지_않고_제안으로_남긴다() async throws {
        cue("a")
        h.script.preview = ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .written)])
        h.previewHold.hold()
        let session = h.session
        let writing = Task { await session.write(rows: [ReflectionHarness.row("a")]) }
        for _ in 0..<2000 where !h.previewHold.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        h.memory.editOutside(ReflectionHarness.cue("a", at: 50))
        h.previewHold.release()
        _ = await writing.value
        #expect(h.memory.cue("a")?.cues.first?.time == 50)
        #expect(h.session.ports.drafts.suggestion(DraftKey(.cue, "a")) != nil)
    }

    @Test func 재생_목록_정리를_마치지_못하면_미정리_목록을_남긴다() async throws {
        let layout = PlaylistLayout([(PlaylistLayout.Item(id: "B", name: "나"), 1)])
        var draft = PlaylistDraft()
        _ = try draft.append(.rename(playlist: .id("B"), name: "새 이름"), rekordbox: layout)
        try h.memory.store.savePlaylistDraft(draft)
        h.state.rekordboxPlaylists = layout
        h.state.playlistDraft = h.memory.store.playlistDraft()
        var report = ReflectionHarness.report()
        report.playlistOutcomes = [PlaylistOutcome(edit: draft.steps[0].edit, playlistID: "B", name: "새 이름", status: .written)]
        h.script.preview = report
        h.previewHold.hold()
        let session = h.session
        let writing = Task { await session.write(rows: [], playlists: true) }
        for _ in 0..<2000 where !h.previewHold.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        // 쓰는 동안 바깥에서 그 단계를 고쳤고 사본을 남기지 못한다
        var changed = PlaylistDraft()
        _ = try changed.append(.rename(playlist: .id("B"), name: "바깥 이름"), rekordbox: layout)
        changed.setStepIDs(h.memory.store.playlistDraft().stepIDs)
        h.memory.editPlaylistOutside(changed)
        h.memory.failPlaylistCopies()
        h.previewHold.release()
        _ = await writing.value
        #expect(h.gateCalls.value.writes.count == 1)
        #expect(h.gateCalls.value.removedCleanupLists.isEmpty, "목록이 남아 다음 쓰기 전 재시작 정리가 다시 한다")
        #expect(h.memory.store.playlistDraft().steps.count == 1)
    }

    @Test func 곡_넣기_묶음은_옛_UUID_초안의_판과_작업을_싣고_정리를_마치면_목록을_지운다() async throws {
        let track = ReflectionHarness.staged("s")
        h.state.staged = [track]
        h.memory.save(ReflectionHarness.cue("s"))
        h.memory.save(ReflectionHarness.grid("s"))
        h.script.addPreview.added = [ReflectionHarness.track(track.path)]
        let stamp = try #require(h.memory.stamp(DraftKey(.cue, "s")))
        let outcome = await h.session.addTracks(rows: [ReflectionHarness.row("djc-s", path: track.path)])
        guard case .added = outcome else { Issue.record("넣었다: \(outcome)"); return }
        let batch = try #require(h.gateCalls.value.adds.last)
        #expect(batch.stagedUUIDs == [track.path: "s"])
        #expect(batch.revisions.tracks[DraftKey(.cue, "s")]?.revision == stamp.revision && batch.revisions.tracks[DraftKey(.grid, "s")] != nil)
        let operation = try #require(batch.operation)
        #expect(h.gateCalls.value.removedCleanupLists == [operation.id])
    }

    @Test func 도장_없던_초안도_쓰는_동안_새_판을_받았으면_지우지_않는다() async throws {
        h.state.rows["a"] = ReflectionHarness.row("a")
        h.state.cueDraftUUIDs = ["a"]
        // 업데이트 전부터 있던 초안(도장 없음)
        h.memory.editOutside(ReflectionHarness.cue("a"))
        #expect(h.memory.stamp(DraftKey(.cue, "a")) == nil)
        h.script.preview = ReflectionHarness.report(cues: [ReflectionHarness.outcome("a", .written)])
        h.previewHold.hold()
        let session = h.session
        let writing = Task { await session.write(rows: [ReflectionHarness.row("a")]) }
        for _ in 0..<2000 where !h.previewHold.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        h.memory.save(ReflectionHarness.cue("a", at: 40), origin: .cli)
        h.previewHold.release()
        _ = await writing.value
        #expect(h.memory.cue("a")?.cues.first?.time == 40)
    }

    @Test func 곡을_넣는_동안_새로_저장한_초안은_옮기거나_지우지_않는다() async throws {
        let track = ReflectionHarness.staged("s")
        h.state.staged = [track]
        h.memory.save(ReflectionHarness.cue("s"))
        h.script.addPreview.added = [ReflectionHarness.track(track.path)]
        var addReport = RekordboxTrackWriteReport(dryRun: false)
        var outcome = ReflectionHarness.track(track.path, uuid: "new-s")
        outcome.cuesWritten = nil
        addReport.added = [outcome]
        addReport.backup = "/backups/add-1"
        h.script.add = addReport
        // 넣는 중에 CLI가 옛 UUID에 새 큐 판을 저장한다
        let later = ReflectionHarness.cue("s", at: 40)
        h.script.duringAdd = { [memory = h.memory] in memory.save(later, origin: .cli) }
        let result = await h.session.addTracks(rows: [ReflectionHarness.row("djc-s", path: track.path)])
        guard case .added = result else { Issue.record("넣었다: \(result)"); return }
        #expect(h.memory.cue("s")?.cues.first?.time == 40, "연결되지 않은 초안으로 남는다")
        #expect(h.memory.cue("new-s") == nil, "새 곡에 사람 편집으로 옮기지 않는다")
    }
}
