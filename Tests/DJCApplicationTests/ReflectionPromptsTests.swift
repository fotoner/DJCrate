import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 쓰기·넣기·빼기·복원 확인 창의 내용. 문장 대신 무엇을 보이는지(종류·곡 수·안내 코드)를 본다.
/// 문장 모양은 `문장_모양` 시험 하나가 원문으로 고정한다.
@Suite("반영 확인 창")
struct ReflectionPromptsTests {
    static func outcome(_ uuid: String, _ status: RekordboxWriteOutcome.Status, reason: String? = nil, added: Int = 1) -> RekordboxWriteOutcome {
        .init(trackUUID: uuid, title: "곡 \(uuid)", status: status, reason: reason, removed: 0, added: added)
    }

    static func report(cues: [RekordboxWriteOutcome] = [], grids: [RekordboxWriteOutcome] = [], analyses: [RekordboxWriteOutcome] = [],
                       gains: [RekordboxWriteOutcome] = [], tags: [RekordboxWriteOutcome] = [],
                       playlists: [PlaylistOutcome] = []) -> RekordboxWriteReport {
        var report = RekordboxWriteReport(outcomes: cues, backup: nil, dryRun: true, createdAt: "", finalUpdateCount: nil)
        report.gridOutcomes = grids.isEmpty ? nil : grids
        report.analysisOutcomes = analyses.isEmpty ? nil : analyses
        report.gainOutcomes = gains.isEmpty ? nil : gains
        report.tagOutcomes = tags.isEmpty ? nil : tags
        report.playlistOutcomes = playlists.isEmpty ? nil : playlists
        return report
    }

    static func track(_ path: String, written: Bool = true, reason: String? = nil) -> RekordboxTrackWriteOutcome {
        .init(path: path, contentID: written ? "id-\(path)" : nil, title: "곡 \(path)", written: written, reason: reason)
    }

    static func addPreview(_ outcomes: [RekordboxTrackWriteOutcome], without: [String: String] = [:], plans: [TrackAddPlan] = []) -> TrackAddPreview {
        var report = RekordboxTrackWriteReport(dryRun: true)
        report.added = outcomes
        return TrackAddPreview(report: report, plans: plans, stagedUUIDs: [:], withoutAnalysis: without, unreadable: [])
    }

    /// 넣기 계획(음원 없이 값만, 내장 그림이 있으면 `artwork`)
    static func plan(_ name: String, artwork: Data? = nil) -> TrackAddPlan {
        TrackAddPlan(path: "/music/\(name)", fileName: name, title: name, comment: "", year: 0, trackNumber: 0, discNumber: 0, isrc: "", lyricist: "",
                     fileType: 1, fileSize: 1, fileID: name, length: 1, duration: 1, dateCreated: "", stockDate: "", artwork: artwork)
    }

    static func backup(tracks: RekordboxTrackWriteReport? = nil) -> RekordboxWriteBackup {
        RekordboxWriteBackup(url: URL(filePath: "/tmp/b"), createdAt: Date(timeIntervalSince1970: 0), isWrite: true, report: nil, trackReport: tracks)
    }

    // MARK: 쓰기

    @Test func 쓰기_확인은_쓰는_종류별_곡_수와_쓰지_않는_줄만_보인다() {
        let playlist = PlaylistOutcome(edit: .delete(playlist: .id("9")), playlistID: nil, name: "스마트", status: .blocked, reason: "rekordbox에서 고치세요")
        let written = PlaylistOutcome(edit: .rename(playlist: .id("8"), name: "새"), playlistID: "8", name: "옛", status: .written, reason: nil)
        let report = Self.report(cues: [Self.outcome("a", .written, added: 2)],
                                 grids: [Self.outcome("a", .blocked, reason: "분석 전"), Self.outcome("g", .written)],
                                 analyses: [Self.outcome("n", .written), Self.outcome("b", .blocked, reason: "ALAC")],
                                 gains: [Self.outcome("d", .written)],
                                 tags: [Self.outcome("t", .written), Self.outcome("x", .blocked, reason: "칸")],
                                 playlists: [written, playlist])
        #expect(ReflectionPrompts.writeCounts(report) == [.part(.cue, 1), .part(.grid, 1), .part(.analysis, 1), .part(.gain, 1),
                                                         .part(.tag, 1), .playlists(1)])
        #expect(ReflectionPrompts.reasons(report) == ["• 곡 a: 분석 전", "• 곡 b: ALAC", "• 곡 x: 칸", PlaylistWriteText.reason(playlist)])
        let prompt = ReflectionPrompts.confirmation(report, exclusions: ["• 곡 z: 읽지 못함"])
        #expect(prompt.details == [ReflectionPrompts.skippedHeader(5)] + ReflectionPrompts.reasons(report) + ["• 곡 z: 읽지 못함"])
        #expect(prompt.confirm != nil && !prompt.destructive && !prompt.critical)
    }

    @Test func 합치기는_파괴적_확인이고_손실_안내를_붙인다() {
        var report = Self.report()
        report.mergeOutcomes = [Self.outcome("m", .written)]
        let prompt = ReflectionPrompts.confirmation(report)
        #expect(ReflectionPrompts.writeCounts(report) == [.part(.merge, 1)])
        #expect(prompt.destructive && prompt.details.contains(DuplicateMerge.lossNotice))
        #expect(!ReflectionPrompts.confirmation(report, canBackUp: false).details.isEmpty)
        #expect(ReflectionPrompts.confirmation(Self.report(cues: [Self.outcome("a", .written)]), canBackUp: false).details
                == [ReflectionPrompts.noBackupText])
    }

    @Test func 문장_모양() {
        let report = Self.report(cues: [Self.outcome("a", .written)], grids: [Self.outcome("b", .blocked, reason: "분석 전")])
        let prompt = ReflectionPrompts.confirmation(report)
        #expect(prompt.title == "큐 1곡을 rekordbox에 쓸까요?")
        #expect(prompt.text == "백업한 뒤 쓰고 다시 확인합니다. 끝날 때까지 rekordbox를 켜지 마세요.")
        #expect(prompt.details == ["쓰지 않는 것 1:", "• 곡 b: 분석 전"])
        #expect(ReflectionPrompts.summaryLine(["• 가", "• 나", "• 다"], prefix: "쓰지 않는 것") == "쓰지 않는 것 3: 가, 나 외 1건")
        // 넣기·빼기 확인도 쓰기와 같은 백업 안내로 끝난다
        var deleted = RekordboxTrackWriteReport(dryRun: true)
        deleted.deleted = [Self.track("a")]
        #expect(ReflectionPrompts.addConfirmation(Self.addPreview([Self.track("a")]), writesArtwork: true).text == prompt.text)
        #expect(ReflectionPrompts.deleteConfirmation(TrackDeletePreview(report: deleted, contentIDs: ["id-a"])).text.hasSuffix("\n" + prompt.text))
    }

    @Test func 쓰기_전_확인_정책() {
        let clean = Self.report(cues: [Self.outcome("a", .written)])
        #expect(WriteConfirmPolicy.reasons(clean, exclusions: [], canBackUp: true).isEmpty)
        #expect(WriteConfirmPolicy.reasons(Self.report(cues: [Self.outcome("a", .blocked, reason: "x")]), exclusions: [], canBackUp: true) == [.blocked])
        #expect(WriteConfirmPolicy.reasons(clean, exclusions: ["• 곡 x"], canBackUp: true) == [.excluded])
        var merged = clean
        merged.mergeOutcomes = [Self.outcome("m", .written)]
        #expect(WriteConfirmPolicy.reasons(merged, exclusions: [], canBackUp: true) == [.loss])
        #expect(WriteConfirmPolicy.reasons(clean, exclusions: [], canBackUp: false) == [.noBackup])
        let playlist = PlaylistOutcome(edit: .delete(playlist: .id("9")), playlistID: nil, name: "x", status: .blocked, reason: "y")
        #expect(WriteConfirmPolicy.reasons(Self.report(playlists: [playlist]), exclusions: [], canBackUp: true) == [.blocked])
    }

    @Test func 미리_보기에서_막힌_초안의_종류() {
        let playlist = PlaylistOutcome(edit: .delete(playlist: .id("9")), playlistID: nil, name: "x", status: .blocked, reason: "y")
        let report = Self.report(cues: [Self.outcome("a", .blocked)], grids: [Self.outcome("b", .blocked)], analyses: [Self.outcome("c", .blocked)],
                                 tags: [Self.outcome("a", .blocked), Self.outcome("d", .written)], playlists: [playlist])
        let blocked = BlockedDrafts(report: report)
        #expect(blocked.kinds == ["a": [.cues, .tags], "b": [.grid], "c": [.grid]])
        #expect(blocked.playlists)
        #expect(!BlockedDrafts(report: Self.report()).playlists)
    }

    // MARK: 넣기·빼기

    @Test func 넣기_확인은_빠지는_것이_있는_곡과_안내_코드만_보인다() {
        var a = Self.track("a"), b = Self.track("b"), k = Self.track("k")
        a.cuesWritten = 2
        b.cueReason = "메모리 큐가 11개가 됩니다"
        k.keyWritten = "8A"
        let preview = Self.addPreview([a, b, k, Self.track("c", written: false, reason: "이미 있음")], without: ["b": "ALAC", "k": "그리드 없음"])
        let shortfalls = ReflectionPrompts.addShortfallItems(preview, writesArtwork: true)
        #expect(shortfalls.tracks.map(\.title) == ["곡 b", "곡 k"], "다 들어가는 곡 a는 줄이 없다(#210)")
        #expect(shortfalls.tracks.first?.withoutAnalysis == "ALAC" && shortfalls.tracks.first?.cueReason == "메모리 큐가 11개가 됩니다")
        #expect(shortfalls.tracks.last?.key == "8A")
        #expect(shortfalls.notes == [.analyseLater(artwork: false), .bareKey])
        #expect(ReflectionPrompts.addReasons(preview) == ["• 곡 c: 이미 있음"])
        let prompt = ReflectionPrompts.addConfirmation(preview, writesArtwork: true)
        #expect(prompt.details == ReflectionPrompts.addShortfalls(preview, writesArtwork: true) + ["", ReflectionPrompts.notAddedHeader(1), "• 곡 c: 이미 있음"])
        #expect(WriteConfirmPolicy.addReasons(preview, writesArtwork: true, canBackUp: true) == [.blocked, .excluded])
        #expect(WriteConfirmPolicy.addReasons(Self.addPreview([Self.track("a")]), writesArtwork: true, canBackUp: true).isEmpty)
        #expect(WriteConfirmPolicy.addReasons(Self.addPreview([Self.track("a")]), writesArtwork: true, canBackUp: false) == [.noBackup])
        // 분석까지 넣어도 큐·키가 안 들어가면 묻는다
        var cue = Self.track("a"), key = Self.track("a")
        cue.cueReason = "메모리 큐가 11개가 됩니다"
        key.keyReason = "확인하지 않은 키"
        #expect(WriteConfirmPolicy.addReasons(Self.addPreview([cue]), writesArtwork: true, canBackUp: true) == [.excluded])
        #expect(WriteConfirmPolicy.addReasons(Self.addPreview([key]), writesArtwork: true, canBackUp: true) == [.excluded])
    }

    @Test func 넣기_확인은_앨범아트를_분석까지_붙이는_곡에만_넣고_닫혀_있으면_한_번_알린다() {
        let art = Self.plan("art.wav", artwork: Data([1])), later = Self.plan("later.wav", artwork: Data([1]))
        let preview = Self.addPreview([Self.track(art.path), Self.track(later.path)], without: [later.path: "그리드 없음"], plans: [art, later])
        let open = ReflectionPrompts.addShortfallItems(preview, writesArtwork: true)
        #expect(open.tracks.map(\.artwork) == [false] && open.notes == [.analyseLater(artwork: true)])
        let closed = ReflectionPrompts.addShortfallItems(preview, writesArtwork: false)
        #expect(closed.notes == [.analyseLater(artwork: true), .artworkClosed])
        var analysed = preview
        analysed.withoutAnalysis = [:]
        #expect(ReflectionPrompts.addShortfallItems(analysed, writesArtwork: true).tracks.isEmpty)
        #expect(WriteConfirmPolicy.addReasons(analysed, writesArtwork: false, canBackUp: true) == [.excluded])
    }

    @Test func 빼기_확인은_뺄_곡과_빼지_않는_곡을_경고로_보인다() {
        var report = RekordboxTrackWriteReport(dryRun: true)
        report.deleted = [Self.track("a"), Self.track("b", written: false, reason: "동기화 곡")]
        let prompt = ReflectionPrompts.deleteConfirmation(TrackDeletePreview(report: report, contentIDs: ["id-a", "id-b"]))
        #expect(prompt.critical && !prompt.destructive && prompt.confirm != nil)
        #expect(prompt.details == ["• 곡 a", "", ReflectionPrompts.notDeletedHeader(1), "• 곡 b: 동기화 곡"])
    }

    // MARK: 복원

    @Test func 복원_확인은_백업_종류와_그_뒤_변경을_코드로_고른다() {
        let writeBackup = Self.backup()
        #expect(ReflectionPrompts.restoreNotices(writeBackup, changedSince: false) == [.drafts])
        #expect(ReflectionPrompts.restoreNotices(writeBackup, changedSince: true, conflicts: 2, later: 3)
                == [.drafts, .laterBackups(3), .changed, .conflicts(2)])
        #expect(ReflectionPrompts.restoreNotices(writeBackup, changedSince: nil) == [.drafts, .unknownChanges])
        var tracks = RekordboxTrackWriteReport(dryRun: false)
        tracks.added = [Self.track("a"), Self.track("b")]
        tracks.deleted = [Self.track("c")]
        #expect(ReflectionPrompts.restoreNotices(Self.backup(tracks: tracks), changedSince: false) == [.tracks(added: 2, deleted: 1)])
    }

    @Test func 복원_확인의_단추와_경고() {
        let calm = ReflectionPrompts.restoreConfirmation(Self.backup(), changedSince: false)
        #expect(!calm.critical && !calm.destructive && calm.alternate == nil)
        let changed = ReflectionPrompts.restoreConfirmation(Self.backup(), changedSince: nil)
        #expect(changed.critical && changed.destructive)
        let conflicted = ReflectionPrompts.restoreConfirmation(Self.backup(), changedSince: false, conflicts: ["• 곡 a — 큐"])
        #expect(conflicted.alternate != nil && conflicted.confirm != calm.confirm)
        #expect(conflicted.details.suffix(1) == ["• 곡 a — 큐"])
        // 문장마다 번역하고 뒤 빈칸은 원래 모양 그대로 둔다.
        var tracks = RekordboxTrackWriteReport(dryRun: false)
        tracks.added = [Self.track("a")]
        #expect(ReflectionPrompts.restoreConfirmation(Self.backup(tracks: tracks), changedSince: false).text
            .contains("라이브러리 전체를 이 백업으로 복원합니다. 넣었던 1곡은 컬렉션에서 빠지고 DJCrate 추가 목록으로 돌아옵니다(분석·앨범아트 파일도 삭제). \n\n"))
    }

    @Test func 자동_복원까지_실패하면_터미널_명령을_안내하는_심각_경고() throws {
        let error = DJCError.restoreFailed(reason: "검증 실패", restoreError: "복원 실패", backup: "/tmp/b", database: nil)
        let prompt = try #require(ReflectionPrompts.restoreFailureAlert(error))
        #expect(prompt.critical && prompt.confirm == nil)
        #expect(prompt.text.contains(DJCError.restoreCommand(backup: "/tmp/b", database: nil)))
        #expect(!prompt.text.contains("검증 실패") && !prompt.text.contains("복원 실패"))
        #expect(ReflectionPrompts.restoreFailureAlert(DJCError.writeRolledBack("x")) == nil)
    }
}
