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
}
