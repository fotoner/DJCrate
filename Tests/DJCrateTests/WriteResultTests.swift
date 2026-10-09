@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

@MainActor
@Suite("쓰기 결과 보관")
struct WriteResultTests {
    typealias Fixture = ReflectionPresenterTests

    @Test(arguments: ["쓰기", "넣기", "빼기", "되돌리기"])
    func 결과는_토스트를_닫고_재시작해도_열린다(operation: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "last-write-result.json")
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: url), feedback: AppFeedback(announce: { _ in }))
        let presenter = ReflectionPresenter(store: store, prompter: ScriptedPrompter())
        let backupURL = URL(filePath: "/tmp/fixture-write-backup"), restoreSafetyBackup = URL(filePath: "/tmp/fixture-before-restore")
        var expected: [String]
        switch operation {
        case "쓰기":
            let preview = Fixture.preview(cues: [Fixture.outcome("written", .written), Fixture.outcome("blocked", .blocked, reason: "큐가 바뀜")],
                                          grids: [Fixture.outcome("grid", .blocked, reason: "분석 전")],
                                          analyses: [Fixture.outcome("analysis", .written), Fixture.outcome("analysis-blocked", .blocked, reason: "ALAC")])
            var written = preview.report
            written.outcomes.removeAll { $0.status != .written }
            written.gridOutcomes = nil
            written.analysisOutcomes?.removeAll { $0.status != .written }
            written.backup = backupURL.path
            presenter.publish(.written(written, preview: preview.report, followUp: []))
            expected = ["곡 written", "곡 blocked", "큐가 바뀜", "분석 전", "곡 analysis", "ALAC"]
        case "넣기":
            var add = Fixture.addPreview([Fixture.track("added"), Fixture.track("blocked", written: false, reason: "이미 있음")], without: ["added": "ALAC"])
            add.unreadable = ["읽지 못한 곡: 파일 없음"]
            var tracks = RekordboxTrackWriter.Report(dryRun: false)
            tracks.added = [Fixture.track("added")]
            tracks.backup = backupURL.path
            presenter.publish(.added(tracks, preview: add, followUp: []))
            expected = ["곡 added", "이미 있음", "ALAC", "파일 없음"]
        case "빼기":
            var tracks = RekordboxTrackWriter.Report(dryRun: false)
            tracks.deleted = [Fixture.track("deleted"), Fixture.track("blocked", written: false, reason: "연결된 표")]
            let preview = TrackDeletePreview(report: tracks, contentIDs: ["id-deleted", "id-blocked"])
            tracks.deleted.removeAll { !$0.written }
            tracks.backup = backupURL.path
            presenter.publish(.deleted(tracks, preview: preview))
            expected = ["곡 deleted", "연결된 표"]
        default:
            var tracks = RekordboxTrackWriter.Report(dryRun: false)
            tracks.deleted = [Fixture.track("deleted")]
            let backup = RekordboxWriter.Backup(url: backupURL, createdAt: .now, isWrite: true, report: nil, trackReport: tracks)
            presenter.publish(.restored(backup, saved: restoreSafetyBackup, fileWarning: nil, followUp: []))
            expected = ["쓰기 전 상태로 복원했습니다", "곡 deleted"]
        }
        store.toast = nil
        let result = try #require(WriteResultHistory(url: url).latest)
        for text in expected { #expect(result.text.contains(text)) }
        #expect(result.backups.contains(backupURL))
        #expect(result.kind == (operation == "되돌리기" ? .success : .warning))
        if operation == "되돌리기" { #expect(result.backups.contains(restoreSafetyBackup)) }
        // 경고 알림의 둘째 줄(무엇을 쓰지 않았는지)도 다시 열 때 그대로다(#147).
        let shortfall = ["쓰기": "큐 1곡 · 그리드 1곡 · 분석 1곡은 쓰지 않았습니다", "넣기": "2곡은 넣지 않았습니다", "빼기": "1곡은 빼지 않았습니다"]
        if let shortfall = shortfall[operation] { #expect(result.toast.detail?.hasPrefix(shortfall) == true) }
    }

    /// #147: 막힌 항목이 있으면 알림 둘째 줄에 무엇을 쓰지 않았는지와 할 일을 보인다.
    /// 막힘 이유는 할 일까지 적은 문장이라 이유가 하나면 그대로 보이고, 여럿이면 결과 보기로 안내한다.
    @Test func 막힌_항목이_있으면_무엇을_쓰지_않았는지와_할_일을_보인다() {
        let reason = "rekordbox 분석 파일이 없습니다. rekordbox에서 트랙 분석을 먼저 하세요"
        let set = Fixture.playlistOutcome(.create(key: "k", name: "세트", isFolder: false, parent: .root), "세트", .written)
        var predicted = Fixture.preview(cues: [Fixture.outcome("1", .written), Fixture.outcome("2", .written)],
                                        grids: [Fixture.outcome("3", .written), Fixture.outcome("4", .blocked, reason: reason)]).report
        predicted.playlistOutcomes = [set]
        var actual = predicted
        actual.gridOutcomes?.removeAll { $0.status != .written }
        let one = WriteResult.written(actual, preview: predicted)
        #expect(one.kind == .warning)
        #expect(one.title == "rekordbox에 썼습니다 · 큐 2곡 · 그리드 1곡 · 재생 목록 1건")
        #expect(one.toast.detail == "그리드 1곡은 쓰지 않았습니다 — " + reason)

        predicted.outcomes.append(Fixture.outcome("5", .blocked, reason: "초안을 만든 뒤 rekordbox에서 큐가 바뀌었습니다"))
        actual.playlistOutcomes = [set, Fixture.playlistOutcome(.create(key: "e", name: " ", isFolder: false, parent: .root), " ", .blocked,
                                                                reason: "이름을 적어 주세요")]
        let many = WriteResult.written(actual, preview: predicted)
        #expect(many.kind == .warning)
        #expect(many.toast.detail == "큐 1곡 · 그리드 1곡 · 재생 목록 1건은 쓰지 않았습니다 — 이유와 할 일은 ‘결과 보기’에서 확인하세요")
    }

    /// #147: 쓴 항목에 붙은 참고 사유(경로가 예상과 달라 분석 파일을 남김)만 있으면 성공으로 보이고, 사유는 결과에 남긴다.
    /// 곡 빼기·쓰기 전으로 복원도 같은 기준이다.
    @Test func 참고_사유만_붙으면_성공으로_보인다() throws {
        let note = RekordboxWriter.fileOwnershipWarning
        var merge = Fixture.preview(cues: []).report
        merge.mergeOutcomes = [Fixture.outcome("m", .written, reason: note)]
        let merged = WriteResult.written(merge, preview: merge)
        #expect(merged.kind == .success && merged.text.contains(note))
        #expect(merged.toast.detail == "전체 내용과 백업 위치는 ‘마지막 쓰기 결과…’에서 다시 볼 수 있습니다.")

        var tracks = RekordboxTrackWriter.Report(dryRun: false)
        tracks.deleted = [Fixture.track("d", reason: note)]
        let deleted = WriteResult.tracks(tracks, preview: tracks, adding: false)
        #expect(deleted.kind == .success && deleted.text.contains(note))

        let saved = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: saved) }
        try Data().write(to: saved.appending(path: "file-ownership-warning"))
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: merge)
        let restored = WriteResult.restored(backup, saved: saved, fileWarning: RekordboxWriter.fileWarning(in: saved))
        #expect(restored.kind == .success && restored.text.contains(note))
    }

    /// #147: 곡 넣기에서 넣지 않은 곡·분석 없이 넣은 곡·쓰지 않은 큐는 할 일이 남아 경고로 보이고 둘째 줄에 적는다.
    @Test func 곡_넣기_경고는_넣지_않은_것과_할_일을_보인다() {
        var report = RekordboxTrackWriter.Report(dryRun: false)
        report.added = [Fixture.track("a")]
        let unanalyzed = WriteResult.tracks(report, preview: report, adding: true, withoutAnalysis: ["a": "ALAC"])
        #expect(unanalyzed.kind == .warning && unanalyzed.title == "rekordbox에 1곡을 넣었습니다")
        #expect(unanalyzed.toast.detail == "1곡은 분석 없이 넣었습니다 — rekordbox에서 분석하세요")

        var preview = report
        preview.added.append(Fixture.track("b", written: false, reason: "이미 rekordbox 컬렉션에 있는 파일입니다"))
        let skipped = WriteResult.tracks(report, preview: preview, adding: true)
        #expect(skipped.kind == .warning)
        #expect(skipped.toast.detail == "1곡은 넣지 않았습니다 — 이미 rekordbox 컬렉션에 있는 파일입니다")

        report.added[0].cueReason = "큐가 바뀜"
        let all = WriteResult.tracks(report, preview: preview, adding: true, withoutAnalysis: ["a": "ALAC"])
        #expect(all.toast.detail == "1곡은 넣지 않았습니다 · 1곡은 분석 없이 넣었습니다 · 1곡의 큐는 쓰지 않았습니다 — 이유와 할 일은 ‘결과 보기’에서 확인하세요")
    }

    @Test func 태그_결과도_곡마다_남긴다() {
        var preview = Fixture.preview(cues: [], tags: [Fixture.tagOutcome("t", .written), Fixture.tagOutcome("x", .blocked, reason: "바뀜")])
        let predicted = preview.report
        preview.report.tagOutcomes = [Fixture.tagOutcome("t", .written)]
        let result = WriteResult.written(preview.report, preview: predicted)
        #expect(result.title == "rekordbox에 썼습니다 · 태그 1곡" && result.kind == .warning)
        #expect(result.text.contains("• 곡 t — 태그 쓰기 완료") && result.text.contains("• 곡 x — 태그 쓰지 않음: 바뀜"))
        let backup = RekordboxWriter.Backup(url: URL(filePath: "/tmp/b"), createdAt: .now, isWrite: true, report: preview.report)
        #expect(WriteResult.restored(backup, saved: URL(filePath: "/tmp/s")).text.contains("• 곡 t"))
    }

    @Test func 모두_막힌_결과도_전체_이유를_남긴다() {
        let store = LibraryStore.test(resultHistory: WriteResultHistory(), feedback: AppFeedback(announce: { _ in }))
        let preview = Fixture.preview(cues: (1...15).map { Fixture.outcome("\($0)", .blocked, reason: "이유 \($0)") })
        ReflectionPresenter(store: store, prompter: ScriptedPrompter()).publish(.nothingWritable(preview, targets: []))
        #expect(store.resultHistory.latest?.text.contains("이유 15") == true)
        #expect(store.resultHistory.latest?.kind == .warning)
    }

    @Test func 기록_저장이_실패해도_결과를_메모리에_보존하고_실패를_알린다() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = WriteResultHistory(url: folder)
        let result = WriteResult(kind: .success, title: "쓴 결과", text: "전체 내용")
        history.record(result)
        #expect(history.latest == result)
        #expect(history.storageError != nil)
    }

    @Test func 실제_쓰기_단계에는_취소를_전달하지_않는다() async {
        let store = LibraryStore.test(resultHistory: WriteResultHistory(), feedback: AppFeedback(announce: { _ in }))
        var suspended: CheckedContinuation<Void, Never>?
        var cancelled = false
        store.writeTask = Task {
            await withCheckedContinuation { suspended = $0 }
            cancelled = Task.isCancelled
        }
        while suspended == nil { await Task.yield() }
        store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        store.cancelWritePreparation()
        suspended?.resume()
        await store.writeTask?.value
        #expect(!cancelled)
    }

    @Test func 실패_결과도_토스트를_닫은_뒤_남는다() {
        let store = LibraryStore.test(resultHistory: WriteResultHistory(), feedback: AppFeedback(announce: { _ in }))
        ReflectionPresenter(store: store, prompter: ScriptedPrompter())
            .publish(.failed(title: "rekordbox에 쓰지 않았습니다", error: FixtureFailure(), exclusions: []))
        store.toast = nil
        #expect(store.resultHistory.latest?.kind == .failure)
        #expect(store.resultHistory.latest?.text == AppErrorMessage.message(for: FixtureFailure()))
    }

    @Test func 쓰기_결과에_재생_목록_편집마다_한_줄을_남긴다() {
        var report = RekordboxWriter.Report(outcomes: [], backup: "/tmp/b", dryRun: false, createdAt: "", finalUpdateCount: 1)
        report.playlistOutcomes = [
            ReflectionPresenterTests.playlistOutcome(.removeTracks(playlist: .id("1"), entries: [.init(trackNo: 1, contentID: "a")]), "목록", .written),
            ReflectionPresenterTests.playlistOutcome(.delete(playlist: .id("2")), "폴더", .blocked, reason: "rekordbox에서 지운 목록입니다"),
            ReflectionPresenterTests.playlistOutcome(.rename(playlist: .id("3"), name: "같음"), "같음", .unchanged),
        ]
        let result = WriteResult.written(report, preview: report)
        #expect(result.kind == .warning && result.title == "rekordbox에 썼습니다 · 재생 목록 1건")
        #expect(result.text.components(separatedBy: "\n") == [
            "• 목록 — 재생 목록 쓰기 완료: 1곡 빼기",
            "• 폴더 — 재생 목록 쓰지 않음(지우기): rekordbox에서 지운 목록입니다",
            "• 같음 — 재생 목록 변경 없음(이름 바꾸기)",
        ])
    }

    @Test func 알림은_주입한_한_함수로_제목과_설명을_보낸다() {
        var messages: [AppMessage] = []
        let feedback = AppFeedback(announce: { messages.append($0) }, isVoiceOverEnabled: { true })
        let store = LibraryStore.test(resultHistory: WriteResultHistory(), feedback: feedback)
        store.toast = AppToast(kind: .failure, title: "실패", detail: "이유 전체")
        store.stagingMessage = AppMessage(kind: .failure, text: "목록 저장 실패")
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        deck.feedback = feedback
        deck.showToast("덱 안내")
        #expect(messages.map(\.text) == ["실패\n이유 전체", "목록 저장 실패", "덱 안내"])
        #expect(messages.first?.kind == .failure)
        #expect(!AppToast(title: "성공").automaticallyDismisses(voiceOverEnabled: true))
        #expect(deck.toastTask == nil)
    }
}
