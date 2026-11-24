@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 성공한 자동 저장은 활동 기록에만 남고 처음 몇 번만 「N곡을 저장했습니다 · [되돌리기]」 토스트를 보인다(#404, R15).
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
        let settings: SettingsStore
        let presenter: ReflectionPresenter

        init(settings: SettingsStore = SettingsStore(defaults: TestDefaults.make("auto-toast-\(UUID().uuidString)"))) {
            self.settings = settings
            store = LibraryStore.test(settings: settings, activityLog: ActivityLog(), feedback: AppFeedback(announce: { _ in }))
            presenter = ReflectionPresenter(store: store, prompter: ScriptedPrompter())
        }

        func publish(_ report: RekordboxWriteReport, followUp: [String] = []) {
            store.dismissToast()
            presenter.publish(.autoWritten(report, followUp: followUp))
        }
    }

    @Test func 처음_다섯_번은_곡_수와_되돌리기가_있는_토스트를_보인다() {
        let s = Setup()
        s.publish(Self.report(tracks: ["a", "b", "c"]))
        #expect(s.store.toast?.title == "3곡을 저장했습니다" && s.store.toast?.kind == .success)
        #expect(s.store.toast?.undoBackup == URL(filePath: "/backups/auto-1"), "[되돌리기]는 이번 쓰기 직전 백업으로 간다")
        #expect(s.store.toast?.detail == nil)
        #expect(s.store.activityLog.latest?.result != nil, "토스트는 활동 기록에도 남는다")
        // 같은 곡의 큐와 태그는 한 곡이다
        s.publish(Self.report(tracks: ["a"], tags: ["a", "b"]))
        #expect(s.store.toast?.title == "2곡을 저장했습니다")
    }

    @Test func 여섯_번째부터는_토스트_없이_활동_기록에만_남는다() {
        let s = Setup()
        for index in 1...5 {
            s.publish(Self.report(tracks: ["t\(index)"]))
            #expect(s.store.toast != nil, "\(index)번째")
        }
        let before = s.store.activityLog.entries.count
        s.publish(Self.report(tracks: ["t6"]))
        #expect(s.store.toast == nil, "조용한 성공")
        #expect(s.store.activityLog.entries.count == before + 1 && s.store.activityLog.latest?.result != nil)
    }

    @Test func 보인_횟수는_설정에_남아_다시_켜도_이어진다() {
        let s = Setup()
        for index in 1...3 { s.publish(Self.report(tracks: ["t\(index)"])) }
        // 같은 설정을 쓰는 새 저장소(다시 켠 앱)
        let again = Setup(settings: s.settings)
        again.publish(Self.report(tracks: ["x"]))
        again.publish(Self.report(tracks: ["y"]))
        #expect(again.store.toast != nil, "5번째까지는 보인다")
        again.publish(Self.report(tracks: ["z"]))
        #expect(again.store.toast == nil, "6번째는 조용하다")
    }

    @Test func 뒤처리_경고가_있으면_횟수와_상관없이_경고로_알린다() {
        let s = Setup()
        for index in 1...5 { s.publish(Self.report(tracks: ["t\(index)"])) }
        s.publish(Self.report(tracks: ["w"]), followUp: ["초안을 정리하지 못했습니다"])
        #expect(s.store.toast?.kind == .warning && s.store.toast?.detail?.contains("초안을 정리하지 못했습니다") == true)
    }

    @Test func 곡이_없고_재생_목록_편집만_썼으면_저장_결과_제목을_쓴다() {
        let s = Setup()
        s.publish(Self.report(tracks: [], playlists: 2))
        #expect(s.store.toast?.title.hasPrefix("rekordbox에 저장했습니다") == true)
    }

    // MARK: - S10: 떠 있는 알림을 덮지 않는다

    @Test(arguments: [AppToast.Kind.warning, .failure])
    func 떠_있는_경고_실패_알림은_덮지_않고_그_성공은_횟수에_세지_않는다(_ kind: AppToast.Kind) {
        let s = Setup()
        s.store.showToast(AppToast(kind: kind, title: "지금 읽어야 하는 알림"))
        let shownBefore = s.store.toast?.id
        s.presenter.publish(.autoWritten(Self.report(tracks: ["a"]), followUp: []))
        #expect(s.store.toast?.id == shownBefore, "떠 있는 \(kind) 알림이 그대로다")
        #expect(s.store.activityLog.latest?.result != nil, "성공은 활동 기록에 남는다")
        #expect(s.settings.value(SettingKeys.writeToastsShown) == 0, "보이지 않은 성공은 센 횟수에 넣지 않는다")
        // 알림을 닫은 뒤에는 처음 다섯 번이 그대로 남아 있다
        for index in 1...5 {
            s.publish(Self.report(tracks: ["t\(index)"]))
            #expect(s.store.toast != nil, "\(index)번째")
        }
        s.publish(Self.report(tracks: ["t6"]))
        #expect(s.store.toast == nil)
    }

    @Test func 단추가_있는_알림도_덮지_않는다() {
        let s = Setup()
        s.publish(Self.report(tracks: ["a"]))
        let first = s.store.toast
        #expect(first?.undoBackup != nil, "첫 성공 토스트에는 [되돌리기]가 있다")
        // 사용자가 아직 누를 수 있는 [되돌리기]를 두 번째 자동 저장이 지우지 않는다
        s.presenter.publish(.autoWritten(Self.report(tracks: ["b"], backup: "/backups/auto-2"), followUp: []))
        #expect(s.store.toast?.id == first?.id)
        #expect(s.settings.value(SettingKeys.writeToastsShown) == 1)
    }

    @Test func 곧_사라지는_성공_알림은_덮는다() {
        let s = Setup()
        s.store.showToast(AppToast(kind: .success, title: "다른 성공"))
        s.presenter.publish(.autoWritten(Self.report(tracks: ["a"]), followUp: []))
        #expect(s.store.toast?.title == "1곡을 저장했습니다")
        #expect(s.settings.value(SettingKeys.writeToastsShown) == 1)
    }
}
