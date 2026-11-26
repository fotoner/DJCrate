@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 성공한 자동 저장은 토스트 없이 활동 기록에만 남는다(#404 R15를 고쳤다: 처음 다섯 번 보이던 「N곡을 저장했습니다」도 없앴다).
/// 마지막 저장 시각과 저장 대기 수는 상태 줄이 보인다. 뒤처리에 남은 경고만 알린다.
@MainActor
@Suite("자동 저장 조용한 성공")
struct ReflectionAutoWriteToastTests {
    static func report(tracks: [String], tags: [String] = [], playlists: Int = 0, backup: String? = "/backups/auto-1") -> RekordboxWriteReport {
        func outcome(_ uuid: String) -> RekordboxWriteOutcome {
            RekordboxWriteOutcome(trackUUID: uuid, title: "곡 \(uuid)", status: .written, removed: 0, added: 1)
        }
        var report = RekordboxWriteReport(outcomes: tracks.map(outcome), backup: backup, dryRun: false, createdAt: "", finalUpdateCount: 1)
        report.tagOutcomes = tags.map(outcome)
        if playlists > 0 {
            report.playlistOutcomes = (0..<playlists).map { index in
                PlaylistOutcome(edit: .rename(playlist: .id("P\(index)"), name: "이름 \(index)"), playlistID: "P\(index)", name: "이름 \(index)", status: .written)
            }
        }
        return report
    }

    @MainActor
    struct Setup {
        let store: LibraryStore
        let presenter: ReflectionPresenter

        init() {
            store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("auto-toast-\(UUID().uuidString)")),
                                      activityLog: ActivityLog(), feedback: AppFeedback(announce: { _ in }))
            presenter = ReflectionPresenter(store: store, prompter: ScriptedPrompter())
        }

        func publish(_ report: RekordboxWriteReport, followUp: [String] = []) {
            presenter.publish(.autoWritten(report, followUp: followUp))
        }
    }

    @Test func 처음부터_토스트_없이_활동_기록에만_남는다() {
        let s = Setup()
        for index in 1...6 {
            s.publish(Self.report(tracks: ["t\(index)"]))
            #expect(s.store.toast == nil, "\(index)번째")
            #expect(s.store.activityLog.latest?.result?.kind == .success)
            #expect(s.store.activityLog.latest?.result?.backups == [URL(filePath: "/backups/auto-1")])
            #expect(s.store.activityLog.latest?.needsAttention == false, "읽지 않은 알림 수에 세지 않는다")
        }
        #expect(s.store.activityLog.entries.count == 6)
    }

    @Test func 재생_목록_편집만_쓴_결과도_활동_기록에_저장_결과_제목으로_남는다() {
        let s = Setup()
        s.publish(Self.report(tracks: [], playlists: 2))
        #expect(s.store.toast == nil)
        #expect(s.store.activityLog.latest?.title.hasPrefix("rekordbox에 저장했습니다") == true)
    }

    @Test(arguments: [AppToast.Kind.success, .warning, .failure])
    func 떠_있는_알림은_건드리지_않는다(_ kind: AppToast.Kind) {
        let s = Setup()
        s.store.showToast(AppToast(kind: kind, title: "먼저 뜬 알림"))
        let shown = s.store.toast?.id
        s.publish(Self.report(tracks: ["a"]))
        #expect(s.store.toast?.id == shown)
        #expect(s.store.activityLog.latest?.result != nil, "성공은 활동 기록에 남는다")
    }

    // MARK: - 뒤처리 경고는 늘 알린다(S13)

    @Test func 뒤처리_경고가_있으면_경고로_알리고_되돌릴_백업을_단다() {
        let s = Setup()
        s.publish(Self.report(tracks: ["w"]), followUp: ["초안을 정리하지 못했습니다"])
        #expect(s.store.toast?.kind == .warning && s.store.toast?.detail?.contains("초안을 정리하지 못했습니다") == true)
        #expect(s.store.toast?.undoBackup == URL(filePath: "/backups/auto-1"))
    }

    @Test(arguments: [AppToast.Kind.warning, .failure])
    func 뒤처리_경고는_떠_있는_경고_실패_알림이_있어도_늘_보인다(_ kind: AppToast.Kind) {
        let s = Setup()
        s.store.showToast(AppToast(kind: kind, title: "먼저 뜬 알림"))
        s.publish(Self.report(tracks: ["a"]), followUp: ["초안을 정리하지 못했습니다"])
        #expect(s.store.toast?.kind == .warning && s.store.toast?.detail?.contains("초안을 정리하지 못했습니다") == true,
                "\(String(describing: s.store.toast?.title))")
    }

    @Test func 뒤처리_경고는_단추가_있는_알림이_떠_있어도_보인다() {
        let s = Setup()
        var undo = AppToast(kind: .success, title: "되돌릴 수 있는 알림")
        undo.undoBackup = URL(filePath: "/backups/manual")
        s.store.showToast(undo)
        s.publish(Self.report(tracks: ["b"], backup: "/backups/auto-2"), followUp: ["초안을 정리하지 못했습니다"])
        #expect(s.store.toast?.kind == .warning && s.store.toast?.undoBackup == URL(filePath: "/backups/auto-2"))
    }
}
