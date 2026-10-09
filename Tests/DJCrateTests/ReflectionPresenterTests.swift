@testable import DJCrate
import DJCApplication
import AppKit
import DJCDomain
import DJCTestKit
import Foundation
@testable import RekordboxKit
import Testing

/// 반영의 화면 쪽: 결과 보이기(`ReflectionPresenter`: 토스트·결과 기록·심각 경고), 확인 창(`AlertPrompter`), 입구(`ReflectionCoordinator`).
/// 흐름의 판정(무엇을 언제 묻고 쓰는지)은 DJCApplicationTests의 반영 세션 시험이 가짜 포트로 본다.
@MainActor
@Suite("반영 결과 보이기")
struct ReflectionPresenterTests {
    let store = LibraryStore.test(resultHistory: WriteResultHistory(), feedback: AppFeedback(announce: { _ in }))
    let prompter = ScriptedPrompter()
    var presenter: ReflectionPresenter { ReflectionPresenter(store: store, prompter: prompter) }

    static func row(_ uuid: String) -> TrackRow {
        TrackRow(track: Track(id: uuid, uuid: uuid, title: "곡 \(uuid)", artist: nil, album: nil, albumArtist: nil, genre: nil,
                              composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180,
                              folderPath: "/x/\(uuid).mp3", comment: "", importedOn: nil, analysisDataPath: nil, imagePath: nil,
                              isDeleted: false),
                 cues: [], playCount: 0)
    }

    static func outcome(_ uuid: String, _ status: RekordboxWriter.Outcome.Status, reason: String? = nil, added: Int = 1) -> RekordboxWriter.Outcome {
        .init(trackUUID: uuid, title: "곡 \(uuid)", status: status, reason: reason, removed: 0, added: added)
    }

    static func preview(cues: [RekordboxWriter.Outcome], grids: [RekordboxWriter.Outcome] = [],
                        gains: [RekordboxWriter.Outcome] = [], analyses: [RekordboxWriter.Outcome] = [],
                        tags: [RekordboxWriter.Outcome] = []) -> WritePreview {
        var report = RekordboxWriter.Report(outcomes: cues, backup: nil, dryRun: true, createdAt: "", finalUpdateCount: nil)
        report.gridOutcomes = grids.isEmpty ? nil : grids
        report.gainOutcomes = gains.isEmpty ? nil : gains
        report.analysisOutcomes = analyses.isEmpty ? nil : analyses
        report.tagOutcomes = tags.isEmpty ? nil : tags
        return .init(report: report, batch: DraftWriteBatch(
            drafts: cues.map { CueDraft(trackUUID: $0.trackUUID) },
            grids: (grids + analyses).map { GridDraft(trackUUID: $0.trackUUID, base: [], segments: []) },
            gains: Dictionary(uniqueKeysWithValues: gains.map { ($0.trackUUID, -3.0) }),
            tags: tags.map { TagDraft(trackUUID: $0.trackUUID, base: TagFields()) }))
    }

    static func tagOutcome(_ uuid: String, _ status: RekordboxWriter.Outcome.Status, fields: [String] = ["title", "artist"],
                           reason: String? = nil) -> RekordboxWriter.Outcome {
        var outcome = outcome(uuid, status, reason: reason, added: fields.count)
        outcome.fields = status == .written ? fields : nil
        return outcome
    }

    /// 창을 띄우지 않고 닫을 때까지 남는 경고 안내 토스트로 알렸는지(#230). 안내는 쓰기 결과가 아니라 결과 보기를 달지 않는다.
    func expectNotice(_ title: String, detail: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(prompter.shown.isEmpty, sourceLocation: sourceLocation)
        #expect(store.toast?.title == title && store.toast?.kind == .warning, sourceLocation: sourceLocation)
        #expect(store.toast?.isNotice == true && store.toast?.showsResult == false && store.toast?.duration == .infinity,
                sourceLocation: sourceLocation)
        if let detail { #expect(store.toast?.detail?.contains(detail) == true, sourceLocation: sourceLocation) }
    }

    // MARK: - 안내

    @Test func 안내는_창_없이_닫을_때까지_남는_경고_토스트로_알리고_결과에_남기지_않는다() {
        presenter.publish(.notice(title: "rekordbox가 켜져 있어 쓰지 않았습니다", text: ReflectionPrompts.quitRekordboxText, lines: []))
        expectNotice("rekordbox가 켜져 있어 쓰지 않았습니다", detail: "rekordbox를 완전히 종료한 뒤 다시 누르세요")
        #expect(store.resultHistory.latest == nil)
        presenter.publish(.notice(title: "복원하지 않았습니다", text: "시점 스냅샷으로 복원해서", lines: []))
        #expect(store.toast?.title == "복원하지 않았습니다" && store.toast?.detail == "시점 스냅샷으로 복원해서")
    }

    @Test func 안내의_이유_줄은_앞_둘과_남은_수만_보인다() {
        let lines = ["• 곡 a: 초안을 만든 뒤 rekordbox에서 바뀌었습니다", "• 곡 b: 바꿀 것 없음", "• 곡 c: 바꿀 것 없음"]
        presenter.publish(.notice(title: "쓸 초안이 없습니다", text: "고른 곡에 rekordbox와 다른 큐·그리드·게인·태그 초안이 없습니다.", lines: lines))
        expectNotice("쓸 초안이 없습니다", detail: "곡 a: 초안을 만든 뒤 rekordbox에서 바뀌었습니다")
        #expect(store.toast?.detail?.contains("외 1건") == true && store.toast?.detail?.contains("곡 c") == false)
    }

    @Test func 이미_쓰는_중이거나_확인_창에서_취소하면_아무것도_알리지_않는다() {
        store.toast = AppToast(title: "이전")
        presenter.publish(.busy)
        presenter.publish(.declined)
        #expect(store.toast?.title == "이전" && store.resultHistory.latest == nil)
    }

    // MARK: - 쓰기 결과

    @Test func 쓴_결과는_토스트에서_되돌릴_백업을_달고_결과에_남긴다() throws {
        var written = Self.preview(cues: [Self.outcome("a", .written)], tags: [Self.tagOutcome("t", .written)]).report
        written.backup = "/tmp/djc-test-backup"
        presenter.publish(.written(written, preview: written, followUp: []))
        let toast = try #require(store.toast)
        #expect(toast.kind == .success && toast.title == store.resultHistory.latest?.title)
        #expect(toast.undoBackup == URL(filePath: "/tmp/djc-test-backup"))
    }

    @Test func 쓸_것이_제외뿐이면_제외한_이유를_결과_토스트에_남긴다() {
        var preview = Self.preview(cues: [])
        let reason = "곡 a: 합성 제외 이유"
        preview.exclusions = ["• " + reason]
        presenter.publish(.nothingWritable(preview, targets: [Self.row("a")]))
        // 결과 문장 모양은 WriteResultTests가 본다. 여기서는 제외 이유가 결과와 토스트에 이어지는지만 본다.
        #expect(prompter.shown.isEmpty && store.toast?.title == store.resultHistory.latest?.title)
        #expect(store.toast?.detail?.contains(reason) == true)
        #expect(store.resultHistory.latest?.text.contains("• " + reason) == true)
    }

    @Test func 모두_막히면_결과_토스트로_이유를_남긴다() {
        let preview = Self.preview(cues: [Self.outcome("a", .blocked, reason: "VBR MP3")])
        presenter.publish(.nothingWritable(preview, targets: [Self.row("a")]))
        #expect(prompter.shown.isEmpty)
        #expect(store.toast?.title == store.resultHistory.latest?.title && store.toast?.kind == .warning && store.toast?.showsResult == true)
        #expect(store.toast?.detail?.contains("VBR MP3") == true)
        #expect(store.resultHistory.latest?.text.contains("곡 a") == true)
    }

    @Test func 재생_목록_편집_일부가_막혔으면_경고_결과로_남긴다() {
        let preview = Self.playlistPreview([
            Self.playlistOutcome(.create(key: "k", name: "세트", isFolder: false, parent: .root), "세트", .written),
            Self.playlistOutcome(.addTracks(playlist: .id("9"), contentIDs: ["1", "2"]), "옛 목록", .blocked, reason: "목록이 바뀜"),
        ])
        // 관문은 쓴 편집과 막힌 편집을 한 보고서로 돌려준다(막힌 편집은 초안에 남는다)
        presenter.publish(.written(preview.report, preview: preview.report, followUp: []))
        #expect(store.toast?.title == store.resultHistory.latest?.title && store.resultHistory.latest?.kind == .warning)
    }

    @Test func 합치기만_쓴_결과는_합치기를_제목에_적는다() {
        var report = Self.preview(cues: []).report
        report.mergeOutcomes = [.init(trackUUID: "m", title: "남길 곡", status: .written, reason: nil, removed: 1, added: 0)]
        report.dryRun = false
        presenter.publish(.written(report, preview: report, followUp: []))
        #expect(store.toast?.kind == .success && store.toast?.title.contains("합치기") == true)
    }

    @Test func 뒤따른_경고는_쓰기_결과와_나눠_알린다() {
        let report = Self.preview(cues: [Self.outcome("u1", .written)]).report
        let note = ReflectionSession.reloadFailureText(restoring: false)
        presenter.publish(.written(report, preview: report, followUp: [note]))
        // 쓴 결과(제목)는 그대로 두고, 뒤따른 경고를 경고 토스트의 둘째 줄과 결과 전문에 나눠 적는다.
        #expect(store.toast?.kind == .warning && store.toast?.title.hasPrefix("rekordbox에 썼습니다") == true)
        #expect(store.toast?.detail == note)
        #expect(store.resultHistory.latest?.text.hasSuffix("• \(note)") == true)
    }

    @Test func 곡_넣기_뒤따른_경고도_넣기_결과와_나눠_알린다() {
        // #202: 넣기는 끝났지만 백업에 추가 목록을 남기지 못한 경고가 결과에 안 보였다(쓰기·복원 결과만 뒤따른 경고를 나눠 알렸다).
        let preview = Self.addPreview([Self.track("a")])
        let note = ReflectionSession.stagedBackupFailureText
        presenter.publish(.added(preview.report, preview: preview, followUp: [note]))
        #expect(store.toast?.kind == .warning && store.toast?.title.hasPrefix("rekordbox에 1곡을 넣었습니다") == true)
        #expect(store.resultHistory.latest?.text.hasSuffix("• \(note)") == true && store.resultHistory.latest?.kind == .warning)
    }

    @Test func 넣을_수_있는_곡이_없거나_뺄_곡이_모두_막히면_이유를_결과로_남긴다() {
        let reason = "합성 넣지 않는 이유"
        presenter.publish(.nothingAdded(Self.addPreview([Self.track("a", written: false, reason: reason)])))
        #expect(store.toast?.title == store.resultHistory.latest?.title && store.toast?.kind == .warning)
        #expect(store.toast?.detail?.contains(reason) == true)
        var report = RekordboxTrackWriter.Report(dryRun: true)
        report.deleted = [Self.track("a", written: false, reason: RekordboxTrackWriter.syncedTrackReason)]
        presenter.publish(.nothingDeleted(.init(report: report, contentIDs: ["id-a"])))
        #expect(store.toast?.detail?.contains(RekordboxTrackWriter.syncedTrackReason) == true)
        #expect(store.resultHistory.latest?.text.contains("• 곡 a — 빼지 않음: " + RekordboxTrackWriter.syncedTrackReason) == true)
    }

    /// 모두 막히면 창을 띄우지 않고(#230) 결과 기록(결과 보기)에 100곡의 이유를 모두 남긴다.
    @Test func 모두_막힌_경우도_전체_이유를_결과_보기에_남긴다() {
        presenter.publish(.nothingWritable(Self.preview(cues: (1...100).map { Self.outcome("blocked-\($0)", .blocked, reason: "막힌 이유") }), targets: []))
        var lines = store.resultHistory.latest?.text.components(separatedBy: "\n") ?? []
        #expect(lines == (1...100).map { "• 곡 blocked-\($0) — 큐 쓰지 않음: 막힌 이유" })
        let tracks = (1...100).map { Self.track("blocked-\($0)", written: false, reason: "막힌 이유") }
        presenter.publish(.nothingAdded(Self.addPreview(tracks)))
        lines = store.resultHistory.latest?.text.components(separatedBy: "\n") ?? []
        #expect(lines == (1...100).map { "• 곡 blocked-\($0) — 넣지 않음: 막힌 이유" })
        var deleted = RekordboxTrackWriter.Report(dryRun: true)
        deleted.deleted = tracks
        presenter.publish(.nothingDeleted(.init(report: deleted, contentIDs: [])))
        lines = store.resultHistory.latest?.text.components(separatedBy: "\n") ?? []
        #expect(lines == (1...100).map { "• 곡 blocked-\($0) — 빼지 않음: 막힌 이유" })
        #expect(prompter.shown.isEmpty && store.toast?.kind == .warning)
    }

    @Test func 미리_보기를_취소하면_아무것도_쓰지_않았다고_알린다() {
        presenter.publish(.cancelled)
        #expect(store.toast?.title.contains("취소") == true && store.toast?.detail?.contains("아무것도 쓰지 않았습니다") == true)
        #expect(store.resultHistory.latest?.text == "rekordbox에 아무것도 쓰지 않았습니다.")
    }

    // MARK: - 실패

    @Test func 미리_보기가_실패하면_실패_토스트() {
        presenter.publish(.failed(title: "rekordbox에 쓰지 않았습니다", error: FixtureFailure(), exclusions: []))
        #expect(store.toast?.kind == .failure && store.toast?.detail == AppErrorMessage.message(for: FixtureFailure()))
        #expect(store.resultHistory.latest?.kind == .failure && store.resultHistory.latest?.text == AppErrorMessage.message(for: FixtureFailure()))
    }

    @Test func 쓰기_거부_토스트는_제목을_되풀이하지_않고_할_일을_안내한다() {
        presenter.publish(.failed(title: "rekordbox에 쓰지 않았습니다", error: DJCError.writeRefused("지원하지 않는 버전입니다"), exclusions: []))
        let detail = store.toast?.detail ?? ""
        #expect(detail == AppErrorMessage.message(for: DJCError.writeRefused("지원하지 않는 버전입니다")))
        #expect(store.toast?.title.isEmpty == false && !detail.contains(store.toast?.title ?? "-"))
        #expect(store.resultHistory.latest?.text == detail)
    }

    @Test func 쓰기_오류와_제외한_초안을_한_실패_토스트로_알린다() {
        let excluded = "곡 b: 합성 제외 이유"
        presenter.publish(.failed(title: "rekordbox에 쓰지 않았습니다", error: FixtureFailure(), exclusions: ["• " + excluded]))
        #expect(prompter.shown.isEmpty)
        #expect(store.toast?.kind == .failure && store.toast?.title == store.resultHistory.latest?.title)
        #expect(store.toast?.detail?.hasPrefix(AppErrorMessage.message(for: FixtureFailure())) == true)
        #expect(store.toast?.detail?.contains(excluded) == true)
        #expect(store.resultHistory.latest?.text.contains("• " + excluded) == true)
    }

    @Test func 파일_오류_토스트는_NSError_원문을_숨긴다() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                            userInfo: [NSLocalizedDescriptionKey: "Error Domain=NSCocoaErrorDomain SQL 원문"])
        presenter.publish(.failed(title: "rekordbox에 쓰지 않았습니다", error: error, exclusions: []))
        #expect(store.toast?.detail == AppErrorMessage.message(for: error) && store.toast?.detail?.contains("SQL 원문") == false)
    }

    @Test func 자동_복원까지_실패하면_토스트가_아니라_닫아야_하는_심각_경고로_알린다() throws {
        store.toast = AppToast(title: "이전 성공")
        let backup = "/tmp/rekordbox-backups/2026-09-26T120000-write"
        let error = DJCError.restoreFailed(reason: "무결성 검사 실패: x", restoreError: "master.db: 권한 없음", backup: backup, database: nil)
        for title in ["rekordbox에 쓰지 않았습니다", "rekordbox에 넣지 않았습니다", "rekordbox에서 빼지 않았습니다"] {
            presenter.publish(.failed(title: title, error: error, exclusions: []))
        }
        #expect(store.toast == nil, "사라지는 토스트로 알리지 않는다")
        let alerts = prompter.shown.filter { $0.confirm == nil }
        #expect(alerts.count == 3 && alerts.allSatisfy(\.critical))
        // 반영·넣기·빼기 모두 같은 경고(원문을 숨기고 복원 명령을 안내하는 문장은 ReflectionPromptsTests)
        let expected = try #require(ReflectionPrompts.restoreFailureAlert(error))
        #expect(alerts.allSatisfy { $0.title == expected.title && $0.text == expected.text })
        #expect(store.resultHistory.latest?.kind == .failure)
        #expect(store.resultHistory.latest?.text == alerts.last?.text)
        #expect(store.resultHistory.latest?.backups == [URL(filePath: backup)])
    }

    @Test func 백업으로_되돌렸으면_실패_토스트로_알린다() {
        let error = DJCError.writeRolledBack("무결성 검사 실패: x")
        presenter.publish(.failed(title: "rekordbox에서 빼지 않았습니다", error: error, exclusions: []))
        #expect(prompter.shown.isEmpty, "경고 창은 띄우지 않는다")
        // 문장(원문 숨김·할 일)은 AppErrorMessageTests
        #expect(store.toast?.kind == .failure && store.toast?.title == store.resultHistory.latest?.title)
        #expect(store.toast?.detail == AppErrorMessage.message(for: error))
    }

    @Test func 실패와_경고_토스트는_시간이_지나도_닫히지_않는다() {
        #expect(AppToast(kind: .failure, title: "실패").duration == .infinity)
        #expect(AppToast(kind: .warning, title: "경고").duration == .infinity)
        #expect(AppToast(title: "성공").duration.isFinite)
    }

    @Test func 되돌리기_실패는_원문_대신_할_일을_심각_경고로_보여_준다() {
        store.toast = AppToast(title: "이전")
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/test-backup"), createdAt: .now, isWrite: true, report: nil)
        presenter.publish(.restoreFailed(backup, error: FixtureFailure()))
        #expect(store.toast == nil)
        #expect(prompter.shown.last?.critical == true && prompter.shown.last?.confirm == nil)
        #expect(prompter.shown.last?.text.contains("rekordbox를 켜지 말고") == true)
        #expect(prompter.shown.last?.text.contains("다시 복원하세요") == true)
        #expect(prompter.shown.last?.text.contains("미리 보기 실패") == false)
        #expect(store.resultHistory.latest?.kind == .failure)
        #expect(store.resultHistory.latest?.backups == [backup.url])
    }

    // MARK: - 입구

    @Test func 토스트의_복원_단추는_백업을_찾지_못하면_알린다() {
        ReflectionCoordinator.test(store: store, prompter: prompter).startRestore(backupURL: URL(filePath: "/tmp/djc-없는-백업"))
        #expect(store.toast?.title == "백업을 찾지 못했습니다" && store.writeTask == nil)
    }

    @Test func 메뉴의_복원은_쓰기_백업이_없으면_알린다() {
        ReflectionCoordinator.test(store: store, prompter: prompter).startRestoreLatest()
        #expect(store.toast?.title == "복원할 쓰기 기록이 없습니다" && store.writeTask == nil)
    }

    // MARK: - 확인 창

    static func playlistOutcome(_ edit: PlaylistEdit, _ name: String, _ status: RekordboxWriter.Outcome.Status,
                                reason: String? = nil) -> PlaylistOutcome {
        PlaylistOutcome(edit: edit, playlistID: status == .written ? "1" : nil, name: name, status: status, reason: reason)
    }

    static func playlistPreview(_ outcomes: [PlaylistOutcome]) -> WritePreview {
        var preview = Self.preview(cues: [])
        preview.report.playlistOutcomes = outcomes
        var draft = PlaylistDraft()
        _ = try? draft.append(.create(key: "k", name: "세트", isFolder: false, parent: .root), rekordbox: PlaylistLayout())
        preview.batch.playlists = draft
        return preview
    }

    static func track(_ path: String, written: Bool = true, reason: String? = nil) -> RekordboxTrackWriter.Outcome {
        .init(path: path, contentID: written ? "id-\(path)" : nil, title: "곡 \(path)", written: written, reason: reason)
    }

    static func addPreview(_ outcomes: [RekordboxTrackWriter.Outcome], without: [String: String] = [:]) -> TrackAddPreview {
        var report = RekordboxTrackWriter.Report(dryRun: true)
        report.added = outcomes
        return .init(report: report, plans: [], stagedUUIDs: [:], withoutAnalysis: without, unreadable: [])
    }

    @Test(arguments: [true, nil] as [Bool?])
    func 변경됐거나_확인하지_못한_되돌리기는_파괴적_경고이고_Return으로_실행하지_않는다(changed: Bool?) throws {
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        let prompt = ReflectionPrompts.restoreConfirmation(backup, changedSince: changed)
        #expect(prompt.critical && prompt.destructive)

        _ = NSApplication.shared
        let alert = AlertPrompter().makeAlert(prompt)
        alert.layout()
        #expect(alert.alertStyle == .critical)
        #expect(alert.buttons.first?.hasDestructiveAction == true)
        #expect(alert.buttons.allSatisfy { $0.keyEquivalent != "\r" })
        #expect(alert.window.defaultButtonCell == nil)
        #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
    }

    @Test func 변경이_없는_되돌리기는_Return으로_확인할_수_있다() {
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: nil)
        let prompt = ReflectionPrompts.restoreConfirmation(backup, changedSince: false)
        #expect(!prompt.critical && !prompt.destructive)
        _ = NSApplication.shared
        let alert = AlertPrompter().makeAlert(prompt)
        alert.layout()
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.buttons.first?.hasDestructiveAction == false)
        #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
    }

    @Test func 쓰기_넣기_빼기_확인_창은_Return_기본_버튼을_유지하고_Esc로_취소할_수_있다() {
        var deleted = RekordboxTrackWriter.Report(dryRun: true)
        deleted.deleted = [Self.track("a")]
        let prompts = [
            ReflectionPrompts.confirmation(Self.preview(cues: [Self.outcome("a", .written)]).report),
            ReflectionPrompts.addConfirmation(Self.addPreview([Self.track("a")]), writesArtwork: true),
            ReflectionPrompts.deleteConfirmation(.init(report: deleted, contentIDs: ["id-a"])),
        ]
        _ = NSApplication.shared
        for prompt in prompts {
            #expect(!prompt.destructive)
            let alert = AlertPrompter().makeAlert(prompt)
            alert.layout()
            #expect(alert.buttons.map(\.title) == [prompt.confirm, "취소"])
            #expect(alert.buttons.first?.keyEquivalent == "\r")
            #expect(alert.buttons.first?.hasDestructiveAction == false)
            #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
        }
    }

    @Test func 정보_알림은_한국어_확인_버튼을_직접_만든다() {
        _ = NSApplication.shared
        let alert = AlertPrompter().makeAlert(ReflectionPrompt(title: "알림", text: "안내"))
        #expect(alert.buttons.map(\.title) == ["확인"])
    }

    @Test func 자동_복원_실패_경고는_심각_경고와_한국어_확인_버튼을_유지한다() throws {
        let prompt = try #require(ReflectionPrompts.restoreFailureAlert(
            DJCError.restoreFailed(reason: "검증 실패", restoreError: "복원 실패", backup: "/tmp/b", database: nil)))
        _ = NSApplication.shared
        let alert = AlertPrompter().makeAlert(prompt)
        #expect(alert.alertStyle == .critical && !prompt.destructive)
        #expect(alert.buttons.map(\.title) == ["확인"])
        #expect(alert.buttons.first?.keyEquivalent == "\r")
    }
}
