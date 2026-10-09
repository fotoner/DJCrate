import DJCApplication
import DJCDomain
import Foundation
import PortTestKit
import Testing

/// 반영 세션의 복원: 쓰기 전으로 복원(그 뒤 바뀐 것·충돌 확인 → 남길 초안 → 복원 → 되살리기)·시점 스냅샷 복원·iTunes 동기화 쓰기.
/// (옛 앱 시험 `ReflectionCoordinatorTests`의 복원 흐름, 옛 유스케이스 시험 `RekordboxRestoreTests`, 앱 시험 `WriteFollowUpTests`·
/// `TrackWritePathTests`가 실제 DB로 보던 되살리기·곡 넣기 되돌리기 판정)
@MainActor
@Suite("반영 세션: 복원")
struct ReflectionSessionRestoreTests {
    let h = ReflectionHarness()
    typealias H = ReflectionHarness

    /// 쓴 직후 카운터 1을 적은 백업(그 뒤 바뀌었는지 볼 수 있다)
    func backup(_ name: String = "b") -> RekordboxWriteBackup {
        H.backup(name, report: H.report(cues: [H.outcome("a", .written)], backup: "/backups/\(name)", dryRun: false))
    }

    // MARK: - 흐름

    @Test func rekordbox가_켜져_있으면_창_없이_알린다() async {
        h.running = true
        let outcome = await h.session.restore(backup())
        #expect(outcome.notice?.title == "rekordbox가 켜져 있어 복원하지 않았습니다" && outcome.notice?.text == "rekordbox를 완전히 종료한 뒤 다시 누르세요.")
        #expect(h.locks.isEmpty && h.gateCalls.value.restores.isEmpty)
    }

    @Test func 시점_복원_뒤의_옛_백업은_묻지_않고_이유만_알린다() async {
        h.pointRefusal = "시점 스냅샷으로 복원해서"
        let outcome = await h.session.restore(backup(), confirmed: true)
        #expect(outcome.notice?.title == "복원하지 않았습니다" && outcome.notice?.text == "시점 스냅샷으로 복원해서")
        #expect(h.prompts.isEmpty && h.locks.isEmpty && h.gateCalls.value.restores.isEmpty)
    }

    @Test func 되돌리기는_그_뒤_rekordbox가_바뀌었으면_경고하고_취소하면_복원하지_않는다() async {
        h.updateCount = 2
        h.answer = false
        #expect(await h.session.restore(backup()).name == "declined")
        #expect(h.prompts == [ReflectionPrompts.restoreConfirmation(backup(), changedSince: true)] && h.prompts.first?.critical == true)
        #expect(h.gateCalls.value.restores.isEmpty && h.locks == ["true", "false"])
        h.answer = true
        #expect(await h.session.restore(backup()).name == "restored")
        #expect(h.gateCalls.value.restores == [backup().url] && h.gateCalls.value.restoreTargets == [h.session.target])
    }

    @Test func 쓴_뒤_카운터가_없는_백업도_묻고_복원한다() async {
        // 복원 실패로 끝난 쓰기는 보고서를 남기지 않는다 → 그 뒤 바뀌었는지 모름(nil). 막지 않고 묻고 되돌린다.
        let old = H.backup("old")
        #expect(old.finalUpdateCount == nil)
        _ = await h.session.restore(old)
        #expect(h.prompts == [ReflectionPrompts.restoreConfirmation(old, changedSince: nil)] && !h.log.contains("snapshot"))
        #expect(h.gateCalls.value.restores == [old.url])
    }

    @Test func 명시한_사본으로_연_창은_그_뒤_바뀌었는지_모른다() async {
        h.location = H.location(explicitCopy: true)
        _ = await h.session.restore(backup())
        #expect(h.prompts == [ReflectionPrompts.restoreConfirmation(backup(), changedSince: nil)] && !h.log.contains("snapshot"))
    }

    @Test func 토스트의_복원_단추는_그_뒤_변경과_뒤_쓰기가_없으면_묻지_않는다() async {
        #expect(await h.session.restore(backup(), confirmed: true).name == "restored")
        #expect(h.prompts.isEmpty)
        // 그 뒤 쓴 백업이 있으면 함께 되돌리므로 다시 묻는다(#222)
        h.laterBackups = 1
        _ = await h.session.restore(backup(), confirmed: true)
        #expect(h.prompts == [ReflectionPrompts.restoreConfirmation(backup(), changedSince: false, later: 1)])
    }

    @Test func 쓴_뒤_새로_만든_초안이_있으면_고르게_하고_백업_초안을_고르면_모두_되살린다() async throws {
        h.backupDrafts.cues = [H.cue("a", at: 10)]
        h.memory.save(H.cue("a", at: 20))
        h.state.rows["a"] = H.row("a")
        h.choice = .alternate
        #expect(await h.session.restore(backup()).name == "restored")
        let prompt = try #require(h.prompts.first)
        #expect(prompt == ReflectionPrompts.restoreConfirmation(backup(), changedSince: false, conflicts: ["• 곡 a — 큐"], later: 0))
        // 백업 초안으로 바꾼다(남길 초안 없음)
        #expect(h.memory.cue("a") == H.cue("a", at: 10) && h.followUp == [])
        h.memory.save(H.cue("a", at: 30))
        h.choice = .cancel
        #expect(await h.session.restore(backup()).name == "declined")
    }

    @Test func 복원이_실패하면_되살리지_않고_실패로_알린다() async {
        h.backupDrafts.cues = [H.cue("a")]
        h.script.restoreError = FixtureFailure()
        let outcome = await h.session.restore(backup())
        guard case let .restoreFailed(failed, error) = outcome else { Issue.record("\(outcome.name)"); return }
        #expect(failed.url == backup().url && error is FixtureFailure)
        #expect(h.memory.cue("a") == nil && h.reloads.isEmpty && h.stages.last == .some(nil) && !h.locked)
    }

    // MARK: - 복원(단계)

    @Test func 복원은_지금_초안을_먼저_정하고_복원한_뒤_초안을_되살린다() async throws {
        h.backupDrafts.cues = [H.cue("a", at: 10)]
        h.memory.save(H.cue("a", at: 20))
        let saved = try await h.session.restoreBackup(backup(), to: .copy)
        #expect(saved == URL(filePath: "/copy/backups/before-restore") && h.gateCalls.value.restoreTargets.first?.database.path == "/copy/master.db")
        // 지금 초안(쓴 뒤 새로 만든 a)은 남기고 그 곡의 백업 초안은 되살리지 않는다(#175)
        #expect(h.memory.cue("a") == H.cue("a", at: 20) && h.followUp == [ReflectionSession.keptDraftsText(1)])
        #expect(h.stages.first == .some(WriteStage("rekordbox를 복원하는 중…")) && h.stages.last == .some(nil))
    }

    @Test func CLI는_초안을_되살리지_않고_관문만_부른다() async throws {
        // `djc rekordbox-restore`: 지금처럼 초안은 그대로다(사용자 결정 대기)
        h.options = .cli(attachesAnalysis: true, writesArtwork: true)
        h.backupDrafts.cues = [H.cue("a")]
        _ = try await h.session.restoreBackup(H.backup("x"), to: .copy)
        #expect(h.gateCalls.value.order == ["restore"] && h.memory.cue("a") == nil && h.reloads.isEmpty && h.changeNames == ["follow-up 0"])
    }

    @Test func 되살리기는_백업의_초안을_종류마다_되살리고_재생_목록_편집은_다시_읽은_뒤_쌓는다() async throws {
        let edit = ArtworkEdit(draft: ArtworkDraft(trackUUID: "w", change: .delete, base: ArtworkBase(imagePath: "")), image: nil)
        h.backupDrafts = RekordboxBackupDrafts(cues: [H.cue("a")], grids: [H.grid("g")], gains: ["n": -2], tags: [H.tag("t")], artworks: [edit],
                                               playlistEdits: [.rename(playlist: .id("9"), name: "세트")])
        let report = H.report(artworks: [H.outcome("v", .written)], backup: "/backups/b", dryRun: false)
        _ = try await h.session.restoreBackup(H.backup("b", report: report), to: h.session.target)
        #expect(h.memory.cue("a") == H.cue("a") && h.memory.grid("g") == H.grid("g") && h.memory.gain("n") == -2)
        #expect(try h.memory.store.artworkEdit("w") == edit && h.state.tagDrafts["t"] == H.tag("t"))
        #expect(h.changeNames.contains("artwork restored [\"w\"] touched [\"v\"]"))
        // 되살린 곡과 그림이 바뀐 곡을 다시 읽은 뒤 덱에 알리고, 재생 목록 편집은 다시 읽은 뒤 쌓는다
        #expect(h.reloads.first?.written == ["a", "g", "n", "t", "v", "w"] && h.reloads.first?.playlistEdits.count == 1)
        #expect(h.changeNames.suffix(3) == ["unlinked", "last backup -", "follow-up 0"])
    }

    @Test func 되살리기의_합치기는_남긴_합치기와_겹치지_않는_것만_되살린다() async throws {
        func merge(_ id: String, _ members: [String]) -> DuplicateMergeDraft {
            DuplicateMergeDraft(keeping: .init(contentID: id, trackUUID: id, title: "남김", duration: 1, offset: 0, cues: []),
                                removing: members.map { .init(contentID: $0, trackUUID: $0, title: "뺌", duration: 1, offset: 0, cues: []) }, base: "")
        }
        h.backupDrafts.merges = [merge("k1", ["r1"]), merge("k2", ["r2"])]
        h.state.mergeDrafts = [merge("k1", ["r1", "r9"]), merge("k3", ["r3"])]
        _ = try await h.session.restoreBackup(backup(), to: h.session.target)
        // 쓴 뒤 고친 k1은 지금 것을 남기고, k2는 되살리고, 겹치지 않는 k3는 그대로
        #expect(h.state.mergeDrafts.map(\.id) == ["k1", "k3", "k2"])
        #expect(h.followUp == [ReflectionSession.keptDraftsText(3)], "합치기는 묶인 곡 모두를 센다")
    }

    @Test func 앨범아트_초안을_되살리지_못하면_알린다() async throws {
        h.backupDrafts.artworks = [ArtworkEdit(draft: ArtworkDraft(trackUUID: "w", change: .delete, base: ArtworkBase(imagePath: "")), image: nil)]
        let session = h.session
        var ports = session.ports
        ports.drafts.saveArtwork = { _ in throw FixtureFailure() }
        _ = try await ReflectionSession(location: session.location, ports: ports, options: session.options).restoreBackup(backup(), to: .copy)
        #expect(h.followUp == [ReflectionSession.artworkRestoreFailureText(1)])
    }

    @Test func 복원한_뒤_다시_읽지_못하면_복원과_나눠_알린다() async throws {
        h.reloadSucceeds = false
        _ = try await h.session.restoreBackup(backup(), to: .copy)
        #expect(h.followUp == [ReflectionSession.reloadFailureText(restoring: true)])
    }

    // MARK: - 복원 충돌

    @Test func 충돌은_지금_초안이_백업과_다르고_고친_것이_있을_때만이다() {
        h.backupDrafts = RekordboxBackupDrafts(cues: [H.cue("same"), H.cue("diff", at: 1)], grids: [H.grid("g")], gains: ["n": -2, "m": -1],
                                               tags: [H.tag("t")])
        h.memory.save(H.cue("same"))
        h.memory.save(H.cue("diff", at: 2))
        h.memory.save(H.grid("g", bpm: 100))
        h.memory.save(gain: -5, "n")
        h.state.tagDrafts["t"] = H.tag("t", title: "다른 제목")
        h.state.rows["diff"] = H.row("diff")
        #expect(h.session.restoreConflictDetails(backup()) == ["• 곡 diff — 큐", "• g — 그리드", "• n — 게인", "• t — 태그"])
    }

    @Test func 충돌_곡_제목은_목록_보고서_백업의_추가_목록_순으로_찾는다() {
        h.backupDrafts.cues = ["r", "w", "s", "u"].map { H.cue($0, at: 1) }
        for uuid in ["r", "w", "s", "u"] { h.memory.save(H.cue(uuid, at: 2)) }
        h.state.rows["r"] = H.row("r")
        h.backupStaged = [StagedTrack(uuid: "s", path: "/music/s.mp3", title: "추가한 곡 s", duration: 1, addedOn: "")]
        let withReport = H.backup("b", report: H.report(cues: [H.outcome("w", .written)], dryRun: false))
        #expect(h.session.restoreConflictDetails(withReport) == ["• 곡 r — 큐", "• 곡 w — 큐", "• 추가한 곡 s — 큐", "• u — 큐"])
    }

    // MARK: - 곡 넣기 되돌리기

    /// a(큐 막혀 옮김), b(분석 못 붙여 그리드 옮김), k(키 막혀 옮김)를 넣은 백업
    func addBackup() -> RekordboxWriteBackup {
        var report = RekordboxTrackWriteReport(dryRun: false)
        var a = H.track("/music/a.mp3", uuid: "new-a"), k = H.track("/music/k.mp3", uuid: "new-k")
        a.cuesWritten = nil
        k.keyReason = "키 칸을 확인하지 않았습니다"
        report.added = [a, H.track("/music/b.mp3", uuid: "new-b"), k]
        report.backup = "/backups/add"
        return H.backup("add", tracks: report)
    }

    func stageBackup() {
        h.backupStaged = ["a", "b", "k"].map { H.staged($0) }
        // 넣을 때 백업에 남긴 추가한 곡의 초안(되돌리면 되살아난다)
        h.backupDrafts.cues = [H.cue("a")]
        h.backupDrafts.grids = [H.grid("b")]
    }

    @Test func 곡_넣기를_되돌리면_넣을_때_옮긴_사본만_지우고_곡을_추가_목록에_되돌린다() async throws {
        stageBackup()
        h.memory.save(AddedTrackDrafts.movedCueDraft(from: H.cue("a"), to: "new-a"))
        h.memory.save(AddedTrackDrafts.movedGridDraft(from: H.grid("b"), to: "new-b"))
        var key = TagDraft(trackUUID: "new-k", base: TagFields())
        key.fields.musicalKey = "8A"
        h.state.tagDrafts["new-k"] = key
        var stagedKey = TagDraft(trackUUID: "k", base: TagFields())
        stagedKey.fields.musicalKey = "8A"
        h.backupDrafts.tags = [stagedKey]
        _ = try await h.session.restoreBackup(addBackup(), to: .copy)
        #expect(h.memory.cue("new-a") == nil && h.memory.grid("new-b") == nil && h.state.tagDrafts["new-k"] == nil)
        #expect(h.state.staged.map(\.uuid) == ["a", "b", "k"])
        #expect(h.changeNames.contains("imports reset [\"id-/music/a.mp3\", \"id-/music/b.mp3\", \"id-/music/k.mp3\"]"))
        #expect(h.followUp == [])
    }

    @Test func 곡_넣기를_되돌리면_그_곡의_연결_기록과_재생_목록_초안_편집을_세션이_잊어_저장한다() async throws {
        stageBackup()
        let rekordbox = PlaylistLayout(rekordbox: [RekordboxPlaylist(id: "P", name: "목록", parentID: "root", seq: 1, isFolder: false,
                                                                    trackIDs: [])])
        var draft = PlaylistDraft()
        _ = try draft.append(.addTracks(playlist: PlaylistRef("P"), contentIDs: ["id-/music/a.mp3", "other"]), rekordbox: rekordbox)
        h.state.rekordboxPlaylists = rekordbox
        h.state.playlistDraft = draft
        var imports = PlaylistImports()
        imports.addFiles(["/music/a.mp3"], to: PlaylistRef("P"))
        var linked = draft
        _ = imports.reconcile(contentIDsByPath: ["/music/a.mp3": "id-/music/a.mp3"], draft: &linked, rekordbox: rekordbox)
        h.state.playlistImports = imports

        _ = try await h.session.restoreBackup(addBackup(), to: .copy)

        #expect(h.memory.store.playlistDraft().project(onto: rekordbox).layout.item("P")?.trackIDs == ["other"])
        #expect(h.importsSaved.last?.pendingCount == 1, "되돌린 곡은 다시 기다리는 연결이 된다")
    }

    @Test func 곡_넣기를_되돌려도_넣은_뒤_새_곡에_만든_초안은_지우지_않고_알린다() async throws {
        stageBackup()
        h.memory.save(H.cue("new-a", at: 99))
        h.state.tagDrafts["new-b"] = H.tag("new-b")
        _ = try await h.session.restoreBackup(addBackup(), to: .copy)
        #expect(h.memory.cue("new-a") == H.cue("new-a", at: 99) && h.state.tagDrafts["new-b"] != nil)
        #expect(h.followUp == [ReflectionSession.keptNewTrackDraftsText(2, kinds: [.cue, .tag])!])
    }

    @Test func 이미_추가_목록에_있는_곡은_다시_넣지_않는다() async throws {
        stageBackup()
        h.state.staged = [H.staged("a")]
        _ = try await h.session.restoreBackup(addBackup(), to: .copy)
        #expect(h.state.staged.map(\.uuid) == ["a", "b", "k"] && h.changeNames.contains("restaged [\"b\", \"k\"]"))
    }

    // MARK: - 시점 스냅샷

    @Test func 시점_복원은_쓰기_잠금_안에서_복원하고_다시_읽는다() async throws {
        let report = try await h.session.restorePointSnapshot(URL(filePath: "/s/2026-manual"), snapshots: URL(filePath: "/s"), autoDays: 7,
                                                              now: Date(timeIntervalSince1970: 0), changedTracks: ["u1"], to: .copy)
        #expect(report.restored.url == URL(filePath: "/s/2026-manual") && h.gateCalls.value.points == [URL(filePath: "/s/2026-manual")])
        #expect(h.locks == ["true", "false"] && h.reloads.map(\.written) == [["u1"]] && h.changeNames == ["backups changed"])
        #expect(h.stages.last == .some(nil))
    }

    @Test func 시점_복원이_실패해도_잠금을_푼다() async {
        h.script.pointError = FixtureFailure()
        await #expect(throws: FixtureFailure.self) {
            try await h.session.restorePointSnapshot(URL(filePath: "/s/x"), snapshots: URL(filePath: "/s"), autoDays: 7,
                                                     now: Date(timeIntervalSince1970: 0), changedTracks: [], to: .copy)
        }
        #expect(!h.locked && h.reloads.isEmpty && h.stages.last == .some(nil))
    }

    // MARK: - iTunes 동기화

    @Test func iTunes_동기화는_덱을_잠그지_않고_명시한_사본이면_그_사본에_아니면_라이브에_쓴다() async throws {
        let change = ITunesSyncWrite(base: Data(), source: [], selection: ITunesSyncSelection(selectedIDs: []))
        let live = try await h.session.syncITunes(change, opened: URL(filePath: "/snapshots/s.db"))
        #expect(live.target == URL(filePath: "/lib/master.db") && live.syncData == Data("sync".utf8))
        #expect(h.locks == ["true (덱 빼고)", "false (덱 빼고)"])
        h.location = H.location(explicitCopy: true)
        let copy = try await h.session.syncITunes(change, opened: URL(filePath: "/opened/master.db"))
        #expect(copy.target == URL(filePath: "/opened/master.db"))
        #expect(h.gateCalls.value.iTunesTargets.map(\.backups) == [URL(filePath: "/backups"), URL(filePath: "/backups")])
    }
}
