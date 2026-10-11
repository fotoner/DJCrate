import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Testing

extension ReflectionOutcome {
    var name: String {
        switch self {
        case .busy: "busy"
        case .declined: "declined"
        case .notice: "notice"
        case .cancelled: "cancelled"
        case .written: "written"
        case .nothingWritable: "nothingWritable"
        case .added: "added"
        case .nothingAdded: "nothingAdded"
        case .deleted: "deleted"
        case .nothingDeleted: "nothingDeleted"
        case .restored: "restored"
        case .failed: "failed"
        case .restoreFailed: "restoreFailed"
        }
    }

    var notice: (title: String, text: String, lines: [String])? {
        if case let .notice(title, text, lines) = self { (title, text, lines) } else { nil }
    }

    var failure: (title: String, error: any Error, exclusions: [String])? {
        if case let .failed(title, error, exclusions) = self { (title, error, exclusions) } else { nil }
    }
}

/// 쓰기 거부(`DJCError.writeRefused`)의 이유. 다른 오류거나 던지지 않으면 nil
@MainActor
func refusal(_ body: () async throws -> some Any) async -> String? {
    do { _ = try await body() } catch let DJCError.writeRefused(reason) { return reason } catch {}
    return nil
}

/// 반영 세션의 쓰기: 대상 → 미리 보기 → 확인 정책 → 확인 → 쓰기 → 쓴 뒤 정리. 가짜 포트로 DB·앱 없이 본다.
/// (옛 앱 시험 `ReflectionCoordinatorTests`의 쓰기 흐름과 옛 유스케이스 시험 `DraftReflectionTests`, 앱 시험이 실제 DB로 보던 쓴 뒤 정리)
@MainActor
@Suite("반영 세션: 쓰기")
struct ReflectionSessionWriteTests {
    let h = ReflectionHarness()
    typealias H = ReflectionHarness

    /// 큐 초안이 있는 곡(표시·초안·목록 행)
    func pendingCue(_ uuids: String...) {
        for uuid in uuids {
            h.state.cueDraftUUIDs.insert(uuid)
            h.state.rows[uuid] = H.row(uuid)
            h.memory.save(H.cue(uuid))
        }
    }

    // MARK: - 흐름

    @Test func rekordbox가_켜져_있으면_미리_보지도_않는다() async {
        pendingCue("a")
        h.running = true
        let outcome = await h.session.write(rows: [H.row("a")])
        #expect(outcome.notice?.title == "rekordbox가 켜져 있어 쓰지 않았습니다" && outcome.notice?.text == ReflectionPrompts.quitRekordboxText)
        #expect(h.locks.isEmpty && h.gateCalls.value.order.isEmpty && h.published.map(\.name) == ["notice"])
    }

    @Test func 이미_쓰는_중이면_아무것도_하지_않는다() async {
        pendingCue("a")
        h.locked = true
        #expect(await h.session.write(rows: [H.row("a")]).name == "busy")
        #expect(h.published.isEmpty && h.gateCalls.value.order.isEmpty)
    }

    @Test func 쓸_초안이_없으면_창_없이_빠진_이유와_함께_알린다() async {
        h.state.rows["a"] = H.row("a")
        // 읽지 못해 옮겨 둔 큐 초안: 반영 대기 표시는 없지만 빠진 이유는 알린다
        h.state.unreadableDraftKinds["b"] = [.cue]
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b")])
        #expect(outcome.notice?.title == "쓸 초안이 없습니다")
        #expect(outcome.notice?.text == "고른 곡에 rekordbox와 다른 큐·그리드·게인·태그 초안이 없습니다.")
        #expect(outcome.notice?.lines.count == 2 && outcome.notice?.lines.last?.contains("곡 b") == true)
        #expect(h.locks.isEmpty && h.prompts.isEmpty)
    }

    @Test func 쓸_것이_없으면_창_없이_결과로_알리고_막힌_곡을_복구할_대상으로_넘긴다() async throws {
        pendingCue("a", "b")
        h.script.preview = H.report(cues: [H.outcome("a", .blocked, reason: "VBR MP3")])
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b"), H.row("c")])
        guard case let .nothingWritable(preview, targets) = outcome else { Issue.record("\(outcome.name)"); return }
        #expect(targets.map(\.id) == ["a", "b"] && preview.report.blocked.map(\.trackUUID) == ["a"])
        #expect(h.prompts.isEmpty && h.gateCalls.value.writes.isEmpty)
        #expect(h.locks == ["true", "false"] && h.stages.last == .some(nil) && h.published.map(\.name) == ["nothingWritable"])
    }

    @Test func 미리_보기는_막힌_초안의_빠진_이유를_함께_든다() async throws {
        pendingCue("a")
        // 표시는 있는데 초안 파일을 읽지 못한 곡
        h.state.gridDraftUUIDs.insert("b")
        h.state.rows["b"] = H.row("b")
        let preview = try await h.session.previewWrite(rows: [H.row("a"), H.row("b")], playlists: false)
        #expect(preview.exclusions == ["• 곡 b: " + WritePart.grid.blocked("초안을 불러오지 못했으니 초안 파일과 접근 권한을 확인한 뒤 다시 불러오세요")])
    }

    @Test func 취소하면_쓰지_않고_잠금을_푼다() async {
        pendingCue("a", "b")
        h.script.preview = H.report(cues: [H.outcome("a", .written), H.outcome("b", .blocked, reason: "바뀜")])
        h.answer = false
        #expect(await h.session.write(rows: [H.row("a"), H.row("b")]).name == "declined")
        #expect(h.prompts == [ReflectionPrompts.confirmation(h.script.preview)])
        #expect(h.gateCalls.value.writes.isEmpty && !h.locked && h.published.isEmpty)
    }

    @Test func 막힘_제외_손실이_없으면_묻지_않고_쓴다() async {
        pendingCue("a")
        h.script.preview = H.report(cues: [H.outcome("a", .written)])
        #expect(await h.session.write(rows: [H.row("a")]).name == "written")
        #expect(h.prompts.isEmpty && h.gateCalls.value.writes.count == 1)
        // 백업 폴더에 쓸 수 없으면 묻는다
        h.canBackUp = false
        pendingCue("a")
        _ = await h.session.write(rows: [H.row("a")])
        #expect(h.prompts == [ReflectionPrompts.confirmation(h.script.preview, canBackUp: false)])
    }

    @Test func 확인하면_쓸_수_있는_것만_쓴다() async throws {
        pendingCue("a", "b")
        h.memory.save(H.grid("a"))
        h.memory.save(H.grid("c"))
        h.memory.save(gain: -3, "d")
        for uuid in ["c", "d"] { h.state.rows[uuid] = H.row(uuid) }
        h.state.gridDraftUUIDs = ["a", "c"]
        h.state.gainDraftUUIDs = ["d"]
        h.script.preview = H.report(cues: [H.outcome("a", .written), H.outcome("b", .blocked, reason: "바뀜")],
                                    grids: [H.outcome("a", .written), H.outcome("c", .blocked, reason: "분석 전")],
                                    gains: [H.outcome("d", .written, added: -300)])
        let outcome = await h.session.write(rows: ["a", "b", "c", "d"].map { H.row($0) })
        let written = try #require(h.gateCalls.value.writes.first)
        #expect(written.drafts.map(\.trackUUID) == ["a"] && written.grids.map(\.trackUUID) == ["a"] && written.gains == ["d": -3])
        #expect(h.gateCalls.value.writeTargets == [h.session.target] && h.locks == ["true", "false"])
        guard case let .written(report, preview, _) = outcome else { Issue.record("\(outcome.name)"); return }
        #expect(report.dryRun == false && preview.dryRun == true)
    }

    // MARK: 재생 목록 초안(#39·#40)

    func playlistDraft() -> PlaylistDraft {
        var draft = PlaylistDraft()
        _ = try? draft.append(.create(key: "k", name: "세트", isFolder: false, parent: .root), rekordbox: PlaylistLayout())
        return draft
    }

    func playlistReport(_ outcomes: [PlaylistOutcome]) -> RekordboxWriteReport {
        var report = H.report()
        report.playlistOutcomes = outcomes
        return report
    }

    @Test func 곡_초안이_없어도_재생_목록_초안만_쓴다() async throws {
        let draft = playlistDraft()
        h.state.playlistDraft = draft
        h.script.preview = playlistReport([
            PlaylistOutcome(edit: .create(key: "k", name: "세트", isFolder: false, parent: .root), playlistID: "1", name: "세트", status: .written, reason: nil),
            PlaylistOutcome(edit: .addTracks(playlist: .id("9"), contentIDs: ["1"]), playlistID: nil, name: "옛 목록", status: .blocked,
                            reason: "초안을 만든 뒤 rekordbox에서 이 목록이 바뀌었으니 현재 목록을 비교해 다시 적용하거나 초안을 버리세요."),
        ])
        #expect(await h.session.write(rows: []).name == "written")
        #expect(h.gateCalls.value.previews.first?.playlists == draft)
        // 미리 본 보고서로 묻고(막힌 편집이 있다), 쓰기에는 초안 전체를 넘긴다(결과가 편집 순서와 같아야 쓴 편집만 뺄 수 있다)
        #expect(h.prompts == [ReflectionPrompts.confirmation(h.script.preview)])
        #expect(h.gateCalls.value.writes.first?.playlists == draft && h.gateCalls.value.writes.first?.drafts == [])
        // 쓰기 직전 재생 목록 초안 저장을 다시 확인한다
        #expect(h.log.contains("save playlist"))
    }

    @Test func 곡을_골라_쓸_때는_재생_목록_초안을_넣지_않는다() async {
        h.state.playlistDraft = playlistDraft()
        #expect(await h.session.write(rows: [H.row("a")], playlists: false).notice?.title == "쓸 초안이 없습니다")
        pendingCue("a")
        h.script.preview = H.report(cues: [H.outcome("a", .written)])
        _ = await h.session.write(rows: [H.row("a")], playlists: false)
        #expect(h.gateCalls.value.previews.first?.playlists == nil && h.gateCalls.value.writes.first?.playlists == nil)
    }

    @Test func 재생_목록_편집이_모두_막히면_쓰지_않는다() async {
        h.state.playlistDraft = playlistDraft()
        h.script.preview = playlistReport([PlaylistOutcome(edit: .rename(playlist: .id("9"), name: "x"), playlistID: nil, name: "스마트",
                                                           status: .blocked, reason: "합성 막힘 이유")])
        #expect(await h.session.write(rows: []).name == "nothingWritable")
        #expect(h.prompts.isEmpty && h.gateCalls.value.writes.isEmpty)
    }

    @Test func 태그만_쓸_수_있어도_묻고_막힌_곡의_태그는_넘기지_않는다() async throws {
        for uuid in ["t", "x"] {
            h.state.rows[uuid] = H.row(uuid)
            h.state.tagDrafts[uuid] = H.tag(uuid)
            h.memory.save(H.tag(uuid))
        }
        h.script.preview = H.report(tags: [H.outcome("t", .written), H.outcome("x", .blocked, reason: "rekordbox에서 곡 정보가 바뀌었습니다")])
        _ = await h.session.write(rows: ["t", "x"].map { H.row($0) })
        #expect(h.prompts == [ReflectionPrompts.confirmation(h.script.preview)])
        let written = try #require(h.gateCalls.value.writes.first)
        #expect(written.tags.map(\.trackUUID) == ["t"] && written.drafts.isEmpty && written.grids.isEmpty && written.gains.isEmpty)
    }

    @Test func 분석_전_곡은_그리드_초안으로_분석을_붙여_쓰고_쓸_때만_음량을_잰다() async throws {
        h.state.rows["n"] = H.row("n", analysis: nil)
        h.state.rows["h"] = H.row("h")
        h.state.gridDraftUUIDs = ["n", "h"]
        h.memory.save(H.grid("n"))
        h.memory.save(H.grid("h"))
        h.script.preview = H.report(analyses: [H.outcome("n", .written, added: 96),
                                               H.outcome("h", .blocked, reason: "rekordbox에서 트랙 분석을 먼저 한 뒤 쓰세요")])
        _ = await h.session.write(rows: ["n", "h"].map { H.row($0) })
        #expect(h.prompts == [ReflectionPrompts.confirmation(h.script.preview)])
        let written = try #require(h.gateCalls.value.writes.first)
        #expect(written.grids.map(\.trackUUID) == ["n"] && written.drafts.isEmpty)
        // 분석은 분석 파일이 없는 곡(n)만 붙인다. 미리 보기는 길이만, 쓸 때 음량까지 잰다.
        let input = try #require(h.gateCalls.value.writeInputs.first?["n"])
        #expect(h.gateCalls.value.writeInputs.first?.keys.sorted() == ["n"])
        #expect(input.duration == 180 && input.loudness == -9 && abs(input.peak - pow(10, -6.0 / 20)) < 1e-12 && input.artwork == Data([1]))
        #expect(h.log.all.filter { $0.hasPrefix("loudness") } == ["loudness n.mp3"])
    }

    @Test func 분석_붙이기가_닫혀_있으면_분석_입력을_재지_않는다() async throws {
        h.options = .app(attachesAnalysis: false, writesArtwork: false)
        h.state.rows["n"] = H.row("n", analysis: nil)
        h.state.gridDraftUUIDs = ["n"]
        h.memory.save(H.grid("n"))
        _ = try await h.session.writeDrafts(DraftWriteBatch(grids: [H.grid("n")]), to: h.session.target)
        #expect(h.gateCalls.value.writeInputs == [[:]] && !h.log.contains("tags"))
    }

    @Test func 음량을_재지_못하면_피크는_1이다() async throws {
        h.loudness = nil
        h.state.rows["n"] = H.row("n", analysis: nil)
        _ = try await h.session.writeDrafts(DraftWriteBatch(grids: [H.grid("n")]), to: h.session.target)
        #expect(h.gateCalls.value.writeInputs.first?["n"]?.peak == 1)
    }

    @Test func 미리_보기가_실패하면_막힌_초안을_합쳐_실패로_알린다() async throws {
        pendingCue("a")
        h.state.gridDraftUUIDs.insert("b")
        h.state.rows["b"] = H.row("b")
        h.script.previewError = FixtureFailure()
        let outcome = await h.session.write(rows: [H.row("a"), H.row("b")])
        #expect(outcome.failure?.title == "rekordbox에 쓰지 않았습니다" && outcome.failure?.error is FixtureFailure)
        #expect(outcome.failure?.exclusions.count == 1 && outcome.failure?.exclusions.first?.contains("곡 b") == true)
        #expect(h.stages.last == .some(nil) && !h.locked)
    }

    @Test func 쓰기가_실패해도_실패로_알리고_잠금을_푼다() async {
        pendingCue("a")
        h.script.preview = H.report(cues: [H.outcome("a", .written)])
        h.script.writeError = DJCError.writeRolledBack("무결성 검사 실패: x")
        let outcome = await h.session.write(rows: [H.row("a")])
        #expect(outcome.failure?.error is DJCError && h.locks == ["true", "false"] && h.stages.last == .some(nil))
        // 쓴 뒤 정리를 하지 않는다
        #expect(h.memory.cue("a") != nil && h.reloads.isEmpty)
    }

    @Test func 미리_보기를_취소하면_아무것도_쓰지_않았다고_알린다() async {
        pendingCue("a")
        let session = h.session
        let task = Task { await session.write(rows: [H.row("a")]) }
        task.cancel()
        #expect(await task.value.name == "cancelled")
        #expect(h.gateCalls.value.writes.isEmpty && !h.locked)
    }

    // MARK: - 미리 보기(단계)

    @Test func 미리_보기는_초안을_확인하고_묶은_뒤_사본에서만_써_본다() async throws {
        pendingCue("a")
        h.state.rows["n"] = H.row("n", analysis: nil)
        h.state.gridDraftUUIDs = ["n"]
        h.memory.save(H.grid("n"))
        h.memory.save(gain: -3, "g")
        h.state.rows["g"] = H.row("g")
        h.state.gainDraftUUIDs = ["g"]
        let preview = try await h.session.previewWrite(rows: ["a", "n", "g"].map { H.row($0) }, playlists: true)
        // 관문의 미리 보기는 위치의 rekordbox에서 사본을 떠서 쓴다(쓰기는 부르지 않는다)
        #expect(h.gateCalls.value.order == ["preview"] && h.gateCalls.value.previewSources == [h.session.target])
        #expect(preview.batch.drafts.map(\.trackUUID) == ["a"] && preview.batch.grids.map(\.trackUUID) == ["n"] && preview.batch.gains == ["g": -3])
        // 실패한 태그 저장을 다시 하고 읽지 못하는 파일을 옮긴 뒤 묶는다. 미리 보기는 길이만 잰다(음량은 쓸 때).
        let retry = try #require(h.log.first("retry tag saves")), preserve = try #require(h.log.first("preserve damaged"))
        #expect(retry < preserve && h.log.contains("tags n.mp3") && !h.log.contains("loudness") && h.log.contains("save playlist"))
        #expect(!h.stages.isEmpty && h.stages.compactMap { $0 }.allSatisfy(\.cancellable), "진행 안내는 모두 취소할 수 있다")
    }

    @Test func 미리_보기는_저장이_끝나지_않았거나_실패한_초안이_있으면_사본을_뜨지_않는다() async {
        pendingCue("a")
        h.unsaved = ["a"]
        await #expect(throws: DJCError.self) { try await h.session.previewWrite(rows: [H.row("a")], playlists: false) }
        h.unsaved = []
        h.saveFailures = [DraftSaveFailure(kind: .cue, trackUUID: "a", revision: 1, reason: "저장 실패")]
        await #expect(throws: DJCError.self) { try await h.session.previewWrite(rows: [H.row("a")], playlists: false) }
        h.saveFailures = []
        h.state.failedTagSaves = ["a"]
        #expect(await refusal { try await h.session.previewWrite(rows: [H.row("a")], playlists: false) } == DraftSaveFailure.tagSaveMessage)
        #expect(h.gateCalls.value.previews.isEmpty)
    }

    @Test func 미리_보기는_대상_곡의_초안_파일을_옮겼으면_쓰지_않는다() async {
        pendingCue("a")
        h.preserved = [DamagedDraftFile(name: "a.json", preserved: URL(filePath: "/drafts/damaged-drafts/a.json"), trackUUID: "a")]
        await #expect(throws: DJCError.self) { try await h.session.previewWrite(rows: [H.row("a")], playlists: false) }
        // 다른 곡의 파일만 옮겼으면 그대로 미리 본다
        h.preserved = [DamagedDraftFile(name: "z.json", preserved: URL(filePath: "/drafts/damaged-drafts/z.json"), trackUUID: "z")]
        _ = try? await h.session.previewWrite(rows: [H.row("a")], playlists: false)
        #expect(h.gateCalls.value.previews.count == 1)
    }

    @Test func 미리_보기는_게인_파일을_읽지_못하면_빈_값으로_넘기지_않는다() async {
        pendingCue("a")
        let session = h.session
        var ports = session.ports
        ports.drafts.gainDrafts = { throw FixtureFailure() }
        await #expect(throws: DJCError.self) {
            try await ReflectionSession(location: session.location, ports: ports, options: session.options)
                .previewWrite(rows: [H.row("a")], playlists: false)
        }
    }

    // MARK: - 쓰기(단계)와 쓴 뒤 정리

    @Test func 쓴_뒤_쓴_초안을_지우고_태그는_쓴_값을_새_기준으로_하고_다시_읽는다() async throws {
        h.memory.save(H.cue("a"))
        h.memory.save(H.grid("b"))
        h.memory.save(H.grid("n"))
        h.memory.save(gain: -3, "c")
        var tag = H.tag("t")
        tag.base.title = "옛 제목"
        h.state.tagDrafts["t"] = tag
        h.script.write = H.report(cues: [H.outcome("a", .written)], grids: [H.outcome("b", .written)], gains: [H.outcome("c", .written)],
                                  analyses: [H.outcome("n", .written)], tags: [H.outcome("t", .written)], backup: "/backups/w1", dryRun: false)
        let batch = DraftWriteBatch(drafts: [H.cue("a")], grids: [H.grid("b"), H.grid("n")], gains: ["c": -3], tags: [tag])
        let report = try await h.session.writeDrafts(batch, to: h.session.target)
        #expect(report.backup == "/backups/w1")
        #expect(h.memory.cue("a") == nil && h.memory.grid("b") == nil && h.memory.grid("n") == nil && h.memory.gain("c") == nil)
        // 태그 초안은 쓴 값이 기준이 되어 고친 것이 없는 초안이 된다(화면이 지운다)
        guard case let .tagDrafts(cleared) = try #require(h.changes.first { if case .tagDrafts = $0 { true } else { false } }) else { return }
        #expect(cleared.map(\.trackUUID) == ["t"] && cleared.first?.fields == tag.base && cleared.first?.hasChanges == false)
        #expect(h.changeNames.contains("cleared gain [\"c\"]") && h.changeNames.contains("cleared cue [\"a\"] counts")
                && h.changeNames.contains("cleared grid [\"b\", \"n\"]"))
        // 새 스냅샷을 읽은 뒤 덱에 알릴 곡: 쓴 곡 전부
        #expect(h.reloads.map(\.written) == [["a", "b", "c", "n", "t"]])
        #expect(h.changeNames.suffix(2) == ["last backup w1", "follow-up 0"] && h.followUp == [])
        #expect(h.stages.last == .some(nil), "끝나면 진행 안내를 거둔다")
    }

    @Test func 쓰기_직전에_초안과_재생_목록_저장을_다시_확인하고_음량을_잰다() async throws {
        h.state.rows["n"] = H.row("n", analysis: nil)
        var batch = DraftWriteBatch(grids: [H.grid("n")])
        batch.playlists = PlaylistDraft()
        _ = try await h.session.writeDrafts(batch, to: h.session.target)
        #expect(h.log.first("save playlist")! < h.log.first("loudness n.mp3")!)
        h.playlistSaves = false
        #expect(await refusal { try await h.session.writeDrafts(batch, to: h.session.target) } == ReflectionSession.playlistSaveFailureText)
        #expect(h.gateCalls.value.writes.count == 1)
    }

    @Test func 다시_읽기가_실패하면_쓰기와_나눠_경고하고_목록_위에_이유를_잇는다() async throws {
        h.reloadSucceeds = false
        h.reloadError = "rekordbox가 켜져 있어 읽지 못했습니다"
        h.script.write = H.report(cues: [H.outcome("a", .written)], backup: "/backups/w1", dryRun: false)
        _ = try await h.session.writeDrafts(DraftWriteBatch(drafts: [H.cue("a")]), to: h.session.target)
        #expect(h.followUp == [ReflectionSession.reloadFailureText(restoring: false)])
        #expect(h.changeNames.contains("error \(ReflectionSession.reloadFailureText(restoring: false)) rekordbox가 켜져 있어 읽지 못했습니다"))
    }

    @Test func 쓴_초안을_정리하지_못하면_그_경고를_남긴다() async throws {
        h.saveFailuresAfterWrite = [DraftSaveFailure(kind: .cue, trackUUID: "a", revision: 1, reason: "디스크가 가득 찼습니다")]
        h.script.write = H.report(cues: [H.outcome("a", .written)], backup: "/backups/w1", dryRun: false)
        _ = try await h.session.writeDrafts(DraftWriteBatch(drafts: [H.cue("a")]), to: h.session.target)
        #expect(h.followUp == ["rekordbox에는 썼지만 초안을 정리하지 못했습니다. 큐 초안을 저장하지 못했습니다. 디스크가 가득 찼습니다"])
    }

    @Test func 쓴_합치기_초안만_빼고_묶인_곡을_다시_읽은_뒤_알린다() async throws {
        func merge(_ id: String, members: [String]) -> DuplicateMergeDraft {
            DuplicateMergeDraft(keeping: .init(contentID: id, trackUUID: id, title: "남김", duration: 1, offset: 0, cues: []),
                                removing: members.map { .init(contentID: $0, trackUUID: $0, title: "뺌", duration: 1, offset: 0, cues: []) }, base: "")
        }
        h.state.mergeDrafts = [merge("m1", members: ["r1"]), merge("m2", members: ["r2"])]
        var report = H.report(backup: "/backups/w1", dryRun: false)
        report.mergeOutcomes = [H.outcome("m1", .written)]
        h.script.write = report
        _ = try await h.session.writeDrafts(DraftWriteBatch(merges: [h.state.mergeDrafts[0]]), to: h.session.target)
        #expect(h.state.mergeDrafts.map(\.id) == ["m2"])
        #expect(h.reloads.first?.written == ["m1", "r1"])
    }

    @Test func 재생_목록_초안을_정리하지_못하면_다음에_또_쓰지_않게_알린다() async throws {
        h.script.write = H.report(backup: "/backups/w1", dryRun: false)
        h.state.playlistDraftUnsaved = true
        var batch = DraftWriteBatch()
        batch.playlists = PlaylistDraft()
        _ = try await h.session.writeDrafts(batch, to: h.session.target)
        #expect(h.changeNames.contains("playlist written"))
        #expect(h.followUp == ["rekordbox에는 썼지만 재생 목록 초안을 정리하지 못했습니다. " + ReflectionSession.playlistSaveFailureText])
    }

    @Test func 쓴_앨범아트_초안을_지우고_화면이_그림을_새로_읽게_한다() async throws {
        let edit = ArtworkEdit(draft: ArtworkDraft(trackUUID: "w", change: .delete, base: ArtworkBase(imagePath: "")), image: nil)
        try h.memory.store.saveArtwork(edit)
        h.state.artworkDrafts["w"] = edit.draft
        h.script.write = H.report(artworks: [H.outcome("w", .written)], backup: "/backups/w1", dryRun: false)
        _ = try await h.session.writeDrafts(DraftWriteBatch(artworks: [edit]), to: h.session.target)
        #expect(try h.memory.store.artworkEdit("w") == nil && h.changeNames.contains("artwork cleared [\"w\"] failed 0"))
        #expect(h.reloads.first?.written == ["w"])
    }

    @Test func CLI는_쓴_초안을_지우지_않고_다시_읽지_않는다() async throws {
        // `djc cue-write`: 쓴 초안을 지우지 않는다(앱과 다름, 사용자 결정 대기)
        h.options = .cli(attachesAnalysis: true, writesArtwork: true)
        h.memory.save(H.cue("a"))
        h.script.write = H.report(cues: [H.outcome("a", .written)], backup: "/backups/w1", dryRun: true)
        let report = try await h.session.writeDrafts(DraftWriteBatch(drafts: [H.cue("a")]), to: .copy, dryRun: true)
        #expect(report.dryRun && h.gateCalls.value.dryRuns == [true] && h.gateCalls.value.writeTargets.first?.database.path == "/copy/master.db")
        #expect(h.memory.cue("a") != nil && h.reloads.isEmpty && h.changeNames == ["follow-up 0"])
    }

    @Test func 쓰기가_실패하면_쓴_뒤_처리를_하지_않는다() async {
        h.memory.save(H.cue("a"))
        h.script.writeError = FixtureFailure()
        await #expect(throws: FixtureFailure.self) { try await h.session.writeDrafts(DraftWriteBatch(drafts: [H.cue("a")]), to: h.session.target) }
        #expect(h.memory.cue("a") != nil && h.reloads.isEmpty)
    }

    // MARK: - 값

    @Test func 미리_본_것_가운데_쓸_수_있는_것만_쓴다() {
        var report = RekordboxWriteReport(outcomes: [H.outcome("a", .written), H.outcome("b", .blocked)],
                                          backup: nil, dryRun: true, createdAt: "", finalUpdateCount: nil)
        report.gridOutcomes = [H.outcome("c", .blocked)]
        report.analysisOutcomes = [H.outcome("n", .written)]
        report.gainOutcomes = [H.outcome("g", .written)]
        report.tagOutcomes = [H.outcome("t", .blocked)]
        report.mergeOutcomes = [H.outcome("m1", .written)]
        var all = DraftWriteBatch(drafts: ["a", "b"].map { CueDraft(trackUUID: $0) },
                                  grids: ["c", "n"].map { H.grid($0) }, gains: ["g": -1, "h": 2],
                                  tags: [TagDraft(trackUUID: "t", base: TagFields())], playlists: PlaylistDraft())
        all.merges = ["m1", "m2"].map { uuid in
            DuplicateMergeDraft(keeping: .init(contentID: uuid, trackUUID: uuid, title: "남김", duration: 1, offset: 0, cues: []), removing: [], base: "")
        }
        let writable = WritePreview(report: report, batch: all).writableBatch
        #expect(writable.drafts.map(\.trackUUID) == ["a"] && writable.grids.map(\.trackUUID) == ["n"] && writable.gains == ["g": -1])
        #expect(writable.tags.isEmpty && writable.playlists == nil, "쓰지 않는 재생 목록 초안은 넘기지 않는다")
        #expect(writable.merges.map(\.id) == ["m1"])
    }

    @Test func 분석_입력_계산은_곡_넣기와_같다() {
        let loudness = Loudness(integrated: -11, peak: -0.5, clippedRuns: 0)
        let add = RekordboxTrackAnalysis(segments: [], loudness: loudness)
        let attach = RekordboxAnalysisInput(duration: 10, loudness: loudness, artwork: nil)
        #expect(add.loudness == -11 && add.peak == attach.peak && attach.peak == pow(10, -0.5 / 20))
        #expect(RekordboxTrackAnalysis(segments: [], loudness: nil).peak == 1)
    }

    @Test func 쓰기_대상() {
        let copy = RekordboxWriteTarget.copy(database: URL(filePath: "/c/master.db"), shareRoot: nil)
        #expect(copy.backups == URL(filePath: "/c/backups") && copy.shareRoot == nil)
        #expect(h.session.target == RekordboxWriteTarget(database: URL(filePath: "/lib/master.db"), shareRoot: URL(filePath: "/lib/share"),
                                                         backups: URL(filePath: "/backups")))
    }

    // MARK: - 쓴 뒤 저장(합치기·재생 목록·연결 기록·태그는 세션이 저장하고 화면은 메모리만 맞춘다)

    static func merge(_ id: String, members: [String]) -> DuplicateMergeDraft {
        DuplicateMergeDraft(keeping: .init(contentID: id, trackUUID: id, title: "남김", duration: 1, offset: 0, cues: []),
                            removing: members.map { .init(contentID: $0, trackUUID: $0, title: "뺌", duration: 1, offset: 0, cues: []) }, base: "")
    }

    @Test func 쓴_뒤_남은_합치기_초안을_세션이_저장한다() async throws {
        h.state.mergeDrafts = [Self.merge("m1", members: ["r1"]), Self.merge("m2", members: ["r2"])]
        try h.memory.store.saveMergeDrafts(h.state.mergeDrafts)
        var report = H.report(backup: "/backups/w1", dryRun: false)
        report.mergeOutcomes = [H.outcome("m1", .written)]
        h.script.write = report
        _ = try await h.session.writeDrafts(DraftWriteBatch(merges: [h.state.mergeDrafts[0]]), to: h.session.target)
        #expect(h.memory.store.mergeDrafts().map(\.id) == ["m2"], "화면이 아니라 세션이 남은 합치기 초안을 저장한다")
        #expect(h.changeNames.contains("merges [\"m2\"]"))
    }

    @Test func 합치기_초안을_저장하지_못하면_화면에_실패를_넘긴다() async throws {
        h.failingMergeSave = true
        h.state.mergeDrafts = [Self.merge("m1", members: ["r1"])]
        var report = H.report(backup: "/backups/w1", dryRun: false)
        report.mergeOutcomes = [H.outcome("m1", .written)]
        h.script.write = report
        _ = try await h.session.writeDrafts(DraftWriteBatch(merges: [h.state.mergeDrafts[0]]), to: h.session.target)
        #expect(h.changeNames.contains("merges [] failed"))
    }

    @Test func 쓴_재생_목록_편집을_세션이_초안에서_빼_저장하고_새_목록_ID를_연결_기록에_이어_저장한다() async throws {
        let rekordbox = PlaylistLayout()
        var draft = PlaylistDraft()
        _ = try draft.append(.create(key: "k", name: "새 목록", isFolder: false, parent: .root), rekordbox: rekordbox)
        try h.memory.store.savePlaylistDraft(draft)
        h.state.playlistDraft = draft
        h.state.playlistImports.addFiles(["/m/a.mp3"], to: .new("k"))
        var report = H.report(backup: "/backups/w1", dryRun: false)
        report.playlistOutcomes = [PlaylistOutcome(edit: draft.steps[0].edit, playlistID: "900", name: "새 목록", status: .written)]
        h.script.write = report
        var batch = DraftWriteBatch()
        batch.playlists = draft
        _ = try await h.session.writeDrafts(batch, to: h.session.target)

        #expect(h.memory.store.playlistDraft().isEmpty, "쓴 편집을 뺀 초안을 세션이 저장한다")
        #expect(h.importsSaved.last?.requests.first?.target == PlaylistRef("900"), "새 목록 ID를 이은 연결 기록을 세션이 저장한다")
        let cleanup = h.changes.lazy.compactMap { if case let .playlistWritten(cleanup) = $0 { cleanup } else { nil } }.first
        #expect(cleanup?.ids == [PlaylistRef.new("k").layoutID: "900"] && cleanup?.draft?.isEmpty == true && cleanup?.imports?.stored == true)
    }

    @Test func 쓴_태그를_새_기준으로_한_초안을_세션이_저장한다() async throws {
        var tag = H.tag("t")
        tag.base.title = "옛 제목"
        h.memory.save(tag)
        h.state.tagDrafts["t"] = tag
        h.script.write = H.report(tags: [H.outcome("t", .written)], backup: "/backups/w1", dryRun: false)
        _ = try await h.session.writeDrafts(DraftWriteBatch(tags: [tag]), to: h.session.target)
        #expect(h.memory.tag("t") == nil, "고친 것이 없어진 태그 초안은 파일째 지운다")
        #expect(h.changeNames.contains("tags [\"t\"]"))
    }
}
