import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Testing

/// 반영 세션의 곡 넣기·빼기: 대상 → 사본 미리 보기 → 확인 → 쓰기 → 넣은·뺀 뒤 처리(초안 옮기기·추가 목록·백업 사본·다시 읽기).
/// (옛 앱 시험 `ReflectionCoordinatorTests`의 넣기·빼기 흐름, 옛 유스케이스 시험 `TrackCollectionWritingTests`,
/// 앱 시험 `TrackWritePathTests`가 실제 DB로 보던 넣은 뒤 처리 판정)
@MainActor
@Suite("반영 세션: 곡 넣기·빼기")
struct ReflectionSessionTrackTests {
    let h = ReflectionHarness()
    typealias H = ReflectionHarness

    /// 추가 목록에 든 곡(목록 행은 `djc-<uuid>`)
    func stage(_ uuids: String...) -> [TrackRow] {
        uuids.map { uuid in
            let track = H.staged(uuid)
            h.state.staged.append(track)
            return H.row(track.id, path: track.path)
        }
    }

    func path(_ uuid: String) -> String { "/music/\(uuid).mp3" }

    // MARK: - 넣기 흐름

    @Test func 추가한_곡만_넣고_rekordbox가_켜져_있으면_묻지도_않는다() async {
        let rows = stage("a")
        h.running = true
        #expect(await h.session.addTracks(rows: rows).notice?.title == "rekordbox가 켜져 있어 넣지 않았습니다")
        h.running = false
        let outcome = await h.session.addTracks(rows: [H.row("1")])
        #expect(outcome.notice?.title == "rekordbox에 넣을 곡이 없습니다" && outcome.notice?.text == "DJCrate에 추가한 곡만 rekordbox에 넣을 수 있습니다.")
        #expect(h.locks.isEmpty && h.gateCalls.value.order.isEmpty)
    }

    @Test func 넣을_수_있는_곡이_없으면_창_없이_결과로_알린다() async {
        let rows = stage("a")
        h.script.addPreview.added = [H.track(path("a"), written: false, reason: "이미 rekordbox 컬렉션에 있는 파일입니다")]
        #expect(await h.session.addTracks(rows: rows).name == "nothingAdded")
        #expect(h.prompts.isEmpty && h.gateCalls.value.order == ["add preview"] && h.locks == ["true", "false"])
    }

    @Test func 넣기_확인_창은_빠지는_것이_있을_때만_묻고_확인하면_넣는다() async throws {
        let rows = stage("a", "b", "c")
        h.memory.save(H.grid("a"))
        h.unsupported = [path("b"): "ALAC"]
        h.memory.save(H.grid("b"))
        h.script.addPreview.added = [H.track(path("a")), H.track(path("b")), H.track(path("c"), written: false, reason: "이미 있음")]
        let outcome = await h.session.addTracks(rows: rows)
        guard case let .added(_, preview, _) = outcome else { Issue.record("\(outcome.name)"); return }
        #expect(h.prompts == [ReflectionPrompts.addConfirmation(preview, writesArtwork: true, canBackUp: true)])
        #expect(h.gateCalls.value.adds.last?.plans.map(\.fileName) == ["a.mp3", "b.mp3"])
        // 분석은 그리드가 있고 지원하는 곡(a)만 붙인다
        #expect(h.gateCalls.value.adds.last?.analyses.keys.sorted() == [path("a")])
        // 막힘·빠짐이 없으면 묻지 않고 넣는다
        h.prompts = []
        let rowsD = stage("d")
        h.memory.save(H.grid("d"))
        h.script.addPreview.added = [H.track(path("d"))]
        _ = await h.session.addTracks(rows: rowsD)
        #expect(h.prompts.isEmpty && h.gateCalls.value.adds.last?.plans.map(\.fileName) == ["d.mp3"])
    }

    @Test func 넣기가_실패하면_실패로_알리고_넣은_뒤_처리를_하지_않는다() async {
        let rows = stage("a")
        h.script.addPreview.added = [H.track(path("a"))]
        h.script.addError = DJCError.writeRolledBack("검증 실패")
        let outcome = await h.session.addTracks(rows: rows)
        #expect(outcome.failure?.title == "rekordbox에 넣지 않았습니다" && h.locks == ["true", "false"])
        #expect(h.reloads.isEmpty && h.state.staged.count == 1)
    }

    // MARK: - 넣기 미리 보기

    @Test func 넣기_미리_보기는_곡마다_계획을_만들고_사본에서만_넣어_본다() async throws {
        let rows = stage("a", "b", "unreadable-c")
        h.memory.save(H.grid("a"))
        h.memory.save(H.cue("a"))
        var key = TagDraft(trackUUID: "a", base: TagFields())
        key.fields.musicalKey = "8A"
        key.fields.title = "고친 제목"
        h.state.tagDrafts["a"] = key
        let preview = try await h.session.previewAdd(rows: rows)
        // 사본을 뜨고 그 사본에 넣어 본다(분석 없이, 큐·키는 함께). 백업은 위치의 백업 폴더.
        #expect(h.log.contains("snapshot") && h.gateCalls.value.order == ["add preview"])
        #expect(h.gateCalls.value.addTargets == [RekordboxWriteTarget(database: URL(filePath: "/snapshots/copy.db"), shareRoot: nil,
                                                                      backups: URL(filePath: "/backups"))])
        let batch = try #require(h.gateCalls.value.adds.first)
        #expect(batch.analyses.isEmpty && batch.cues.keys.sorted() == [path("a")] && batch.keys == [path("a"): "8A"])
        // 태그 초안을 파일 태그 위에 얹는다
        #expect(batch.plans.first?.title == "고친 제목")
        #expect(preview.stagedUUIDs == [path("a"): "a", path("b"): "b"] && preview.withoutAnalysis == [path("b"): "그리드가 없음"])
        #expect(preview.unreadable.count == 1 && preview.unreadable.first?.hasPrefix("곡 unreadable-c: ") == true)
        #expect(!h.stages.isEmpty && !h.stages.contains(.none), "미리 보기는 진행 안내를 남긴 채 확인 창으로 간다")
    }

    @Test func 그리드를_추정하는_중이면_분석_없이_넣는다고_알린다() async throws {
        let rows = stage("a")
        h.state.estimatingGrids = true
        let preview = try await h.session.previewAdd(rows: rows)
        #expect(preview.withoutAnalysis == [path("a"): "그리드를 아직 추정하는 중"])
    }

    @Test func 명시한_사본으로_연_창은_사본을_뜨지_않는다() async {
        let rows = stage("a")
        h.location = H.location(explicitCopy: true)
        #expect(await refusal { try await h.session.previewAdd(rows: rows) } == ReflectionSession.snapshotRefusedMessage)
        #expect(await refusal { try await h.session.previewDelete(rows: [H.row("1")]) } == ReflectionSession.snapshotRefusedMessage)
        #expect(!h.log.contains("snapshot"))
    }

    @Test func 저장에_실패한_초안이_있으면_디스크의_옛_초안을_넣지_않는다() async {
        let rows = stage("a")
        h.saveFailures = [DraftSaveFailure(kind: .cue, trackUUID: "a", revision: 1, reason: "디스크")]
        await #expect(throws: DJCError.self) { try await h.session.previewAdd(rows: rows) }
        #expect(h.gateCalls.value.order.isEmpty)
    }

    // MARK: - 넣기와 넣은 뒤

    /// 미리 본 넣기: a(큐 씀·분석 붙임), b(큐 막힘·분석 못 붙임·키 막힘), c(넣지 않음)
    func addPreview() -> TrackAddPreview {
        var report = RekordboxTrackWriteReport(dryRun: true)
        var a = H.track(path("a"), uuid: "new-a"), b = H.track(path("b"), uuid: "new-b")
        a.cuesWritten = 1
        b.keyReason = "키 칸을 확인하지 않았습니다"
        b.keyBase = TagFields()
        report.added = [a, b, H.track(path("c"), written: false, reason: "이미 있음")]
        let plans = ["a", "b", "c"].map { uuid in
            TrackAddPlan(path: path(uuid), fileName: "\(uuid).mp3", title: uuid, comment: "", year: 0, trackNumber: 0, discNumber: 0, isrc: "",
                         lyricist: "", fileType: 1, fileSize: 1, fileID: uuid, length: 180, duration: 180, dateCreated: "", stockDate: "")
        }
        return TrackAddPreview(report: report, plans: plans, stagedUUIDs: [path("a"): "a", path("b"): "b", path("c"): "c"],
                               withoutAnalysis: [path("b"): "ALAC"], cues: [path("a"): H.cue("a").cues, path("b"): H.cue("b").cues],
                               keys: [path("b"): "8A"], unreadable: [])
    }

    @Test func 넣기는_받아들인_곡만_분석까지_붙여_넣는다() async throws {
        _ = stage("a", "b", "c")
        h.memory.save(H.grid("a"))
        h.script.add = addPreview().report
        _ = try await h.session.add(addPreview(), to: .copy)
        let batch = try #require(h.gateCalls.value.adds.first)
        #expect(batch.plans.map(\.fileName) == ["a.mp3", "b.mp3"] && batch.analyses.keys.sorted() == [path("a")])
        #expect(batch.cues.keys.sorted() == [path("a"), path("b")] && batch.keys == [path("b"): "8A"])
        #expect(h.gateCalls.value.addTargets.first?.database.path == "/copy/master.db" && h.gateCalls.value.dryRuns == [false])
        // 음량은 분석을 붙일 곡만, 쓰기 전에 잰다
        #expect(h.log.all.filter { $0.hasPrefix("loudness") } == ["loudness a.mp3"])
        #expect(h.stages.last == .some(nil))
    }

    @Test func 넣은_뒤_막힌_큐_못_붙인_그리드_막힌_키는_새_곡의_초안으로_옮긴다() async throws {
        _ = stage("a", "b", "c")
        h.memory.save(H.grid("a"))
        h.memory.save(H.grid("b"))
        h.memory.save(H.cue("a"))
        h.memory.save(H.cue("b"))
        h.script.add = addPreview().report
        _ = try await h.session.add(addPreview(), to: .copy)
        // b: 큐가 막혀 새 곡의 반영 대기로, 분석을 못 붙여 그리드도 새 곡으로(#197)
        #expect(h.memory.cue("new-b") == AddedTrackDrafts.movedCueDraft(from: H.cue("b"), to: "new-b"))
        #expect(h.memory.grid("new-b") == AddedTrackDrafts.movedGridDraft(from: H.grid("b"), to: "new-b"))
        // a: 큐를 썼고 분석을 붙였으니 옮기지 않는다
        #expect(h.memory.cue("new-a") == nil && h.memory.grid("new-a") == nil)
        // b의 키는 새 곡의 키 초안으로
        #expect(h.state.tagDrafts["new-b"]?.fields.musicalKey == "8A")
    }

    @Test func 넣은_곡은_추가_목록에서_빼고_백업에_추가_목록과_초안_사본을_남긴_뒤_옛_초안을_정리한다() async throws {
        _ = stage("a", "b", "c")
        h.memory.save(H.cue("a"))
        h.memory.save(H.grid("b"))
        h.state.tagDrafts["a"] = H.tag("a")
        var report = addPreview().report
        report.backup = "/backups/add-1"
        h.script.add = report
        _ = try await h.session.add(addPreview(), to: .copy)
        #expect(h.state.staged.map(\.uuid) == ["c"])
        #expect(h.log.contains("backup staged [\"a\", \"b\"]") && h.log.contains("backup cue a") && h.log.contains("backup grid b")
                && h.log.contains("backup tag a"))
        // 백업에 사본을 남긴 옛 UUID의 초안은 지운다(되돌리면 백업에서 되살아난다)
        #expect(h.memory.cue("a") == nil && h.memory.grid("b") == nil && h.state.tagDrafts["a"] == nil)
        #expect(h.changeNames.contains("show id-\(path("a"))") && h.changeNames.contains("last backup add-1") && h.followUp == [])
        #expect(h.reloads.count == 1)
    }

    @Test func 덱에_올린_추가한_곡을_넣으면_새_곡으로_바꿔_올린다() async throws {
        _ = stage("a", "b", "c")
        h.state.deckStagedUUID = "b"
        h.script.add = addPreview().report
        _ = try await h.session.add(addPreview(), to: .copy)
        #expect(h.changeNames.contains("deck id-\(path("b"))"))
    }

    @Test func 백업에_추가_목록이나_초안_사본을_못_남기면_경고하고_그_초안은_지우지_않는다() async throws {
        _ = stage("a", "b", "c")
        h.memory.save(H.cue("a"))
        h.failingBackupSaves = ["staged", "cue"]
        var report = addPreview().report
        report.backup = "/backups/add-1"
        h.script.add = report
        _ = try await h.session.add(addPreview(), to: .copy)
        #expect(h.followUp == [ReflectionSession.stagedBackupFailureText, ReflectionSession.stagedDraftsBackupFailureText(1)])
        #expect(h.memory.cue("a") != nil, "되돌릴 때 이어질 유일한 사본이라 남긴다")
    }

    @Test func CLI는_넣은_뒤_처리를_하지_않는다() async throws {
        h.options = .cli(attachesAnalysis: true, writesArtwork: true)
        _ = stage("a", "b", "c")
        h.script.add = addPreview().report
        _ = try await h.session.add(addPreview(), to: .copy)
        #expect(h.reloads.isEmpty && h.state.staged.count == 3)
    }

    @Test func 음원_계획으로_바로_넣고_빼는_단계는_관문만_부른다() throws {
        // `djc track-add`·`track-delete`: 추가 목록 없이 받은 계획·ContentID로 바로 쓴다
        let plan = addPreview().plans[0]
        _ = try h.session.addTracks(TrackAddBatch(plans: [plan]), to: .copy, dryRun: true)
        _ = try h.session.deleteTracks(["1"], from: .copy, dryRun: false)
        #expect(h.gateCalls.value.order == ["add preview", "delete"] && h.gateCalls.value.dryRuns == [true, false])
        #expect(h.locks.isEmpty && h.changes.isEmpty)
    }

    // MARK: - 빼기

    func deletePreview() -> RekordboxTrackWriteReport {
        var report = RekordboxTrackWriteReport(dryRun: true)
        report.deleted = [H.track("/x", uuid: nil), H.track("/y", written: false, reason: "동기화")]
        report.deleted[0].contentID = "1"
        return report
    }

    @Test func 빼기는_경고_창으로_늘_묻고_취소하면_빼지_않는다() async {
        h.script.deletePreview = deletePreview()
        h.answer = false
        #expect(await h.session.deleteTracks(rows: [H.row("1"), H.row("2")]).name == "declined")
        #expect(h.prompts.count == 1 && h.prompts.first?.critical == true && h.gateCalls.value.order == ["delete preview"])
        h.answer = true
        #expect(await h.session.deleteTracks(rows: [H.row("1"), H.row("2")]).name == "deleted")
        #expect(h.gateCalls.value.deletes.last == ["1"])
    }

    @Test func 빼기는_사본에서_미리_보고_뺄_수_있는_곡만_뺀_뒤_선택에서_빼고_다시_읽는다() async throws {
        h.script.deletePreview = deletePreview()
        var written = deletePreview()
        written.dryRun = false
        written.backup = "/backups/del-1"
        h.script.delete = written
        let preview = try await h.session.previewDelete(rows: [H.row("1"), H.row("2"), H.row("djc-3"), H.row("4", path: "spotify:4")])
        #expect(preview.contentIDs == ["1", "2"] && h.gateCalls.value.deleteTargets.first?.database.path == "/snapshots/copy.db")
        _ = try await h.session.delete(preview, from: h.session.target)
        #expect(h.gateCalls.value.deletes == [["1", "2"], ["1"]] && h.gateCalls.value.deleteTargets.last == h.session.target)
        #expect(h.changeNames == ["deselect [\"1\"]", "last backup del-1"] && h.reloads.count == 1)
    }

    @Test func 뺄_곡이_없거나_iTunes_목록이면_창_없이_알린다() async {
        #expect(await h.session.deleteTracks(rows: [H.row("djc-a")]).notice?.title == "rekordbox에서 뺄 곡이 없습니다")
        h.state.iTunesSelection = true
        #expect(await h.session.deleteTracks(rows: [H.row("1")]).notice?.title == "rekordbox에서 뺄 곡이 없습니다")
        #expect(await refusal { try await h.session.delete(TrackDeletePreview(report: deletePreview(), contentIDs: ["1"]), from: .copy) }
                == "iTunes 동기화 목록의 곡은 Music에서 빼세요.")
        #expect(h.gateCalls.value.order.isEmpty && h.locks.isEmpty)
    }

    @Test func 빼기가_모두_막히면_묻지_않고_결과로_알린다() async {
        var report = RekordboxTrackWriteReport(dryRun: true)
        report.deleted = [H.track("/x", written: false, reason: "동기화")]
        h.script.deletePreview = report
        #expect(await h.session.deleteTracks(rows: [H.row("1")]).name == "nothingDeleted")
        #expect(h.prompts.isEmpty && h.locks == ["true", "false"])
    }

    @Test func 빼기와_넣기가_실패하면_실패로_알린다() async {
        h.script.deletePreview = deletePreview()
        h.script.deleteError = FixtureFailure()
        #expect(await h.session.deleteTracks(rows: [H.row("1")]).failure?.title == "rekordbox에서 빼지 않았습니다")
        #expect(h.reloads.isEmpty && !h.locked)
    }
}
