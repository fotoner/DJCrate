@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 창 아래 상태 줄과 활동 팝오버(#298): 읽지 않은 경고·실패 수, 앱을 다시 켜도 이어지는 읽음 기준, 알림의 [열기].
@MainActor
@Suite("상태 줄과 활동 팝오버")
struct StatusBarModelTests {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func settings() -> SettingsStore { SettingsStore(defaults: TestDefaults.make("status-bar")) }

    @Test func 읽음_기준보다_늦게_뜬_경고와_실패만_읽지_않은_수에_든다() {
        var clock = Self.start
        let log = ActivityLog(now: { clock })
        let model = StatusBarModel(log: log, settings: Self.settings())
        #expect(model.unreadCount == 0 && model.unreadKind == nil)
        log.record(AppToast(title: "현재 rekordbox 내용을 불러왔습니다"))
        #expect(model.unreadCount == 0)
        clock += 1
        log.record(AppToast.notice("rekordbox가 켜져 있어 쓰지 않았습니다", nil))
        #expect(model.unreadCount == 1 && model.unreadKind == .warning)
        clock += 1
        log.record(WriteResult(kind: .failure, title: "rekordbox에 쓰지 않았습니다", text: "• 곡 a — 실패"))
        // 점은 가장 무거운 종류의 색이다
        #expect(model.unreadCount == 2 && model.unreadKind == .failure)
    }

    @Test func 팝오버를_열면_그때까지의_알림을_읽음으로_보고_앱을_다시_켜도_이어진다() {
        var clock = Self.start
        let log = ActivityLog(now: { clock })
        let settings = Self.settings()
        let model = StatusBarModel(log: log, settings: settings)
        let warning = log.record(AppToast.notice("rekordbox가 켜져 있어 쓰지 않았습니다", nil))
        clock += 1
        model.togglePopover()
        #expect(model.isPresented && model.unreadCount == 0)
        // 연 동안은 열 때 읽지 않았던 줄에 점을 단다
        #expect(model.fresh == [warning])
        model.togglePopover()
        #expect(!model.isPresented && model.fresh.isEmpty)

        // 다시 켠 앱(같은 설정)도 읽은 알림을 읽지 않음으로 세지 않는다
        let reopened = StatusBarModel(log: log, settings: settings)
        #expect(reopened.unreadCount == 0 && reopened.seenThrough == model.seenThrough)
        // 같은 알림이 다시 뜨면(합친 항목의 시각이 늦어져) 다시 읽지 않음이 된다
        clock += 1
        log.record(AppToast.notice("rekordbox가 켜져 있어 쓰지 않았습니다", nil))
        #expect(log.entries.count == 1 && reopened.unreadCount == 1)
    }

    /// 항목 순서는 기록한 순서다. 시계가 거꾸로 가면 맨 앞 항목이 가장 늦은 시각이 아니다(리뷰 지적)
    @Test func 시계가_거꾸로_가도_팝오버를_열면_모든_알림을_읽음으로_본다() {
        var clock = Self.start + 100
        let log = ActivityLog(now: { clock })
        let model = StatusBarModel(log: log, settings: Self.settings())
        log.record(AppToast.notice("rekordbox가 켜져 있어 쓰지 않았습니다", nil))
        clock = Self.start + 10
        log.record(AppToast(title: "현재 rekordbox 내용을 불러왔습니다"))
        #expect(model.unreadCount == 1)
        model.togglePopover()
        model.togglePopover()
        #expect(model.unreadCount == 0)
    }

    @Test func 띄우지_못한_알림은_성공이어도_읽지_않은_수에_들고_파일에도_남는다() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-status-bar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "activity-log.json")
        var clock = Self.start
        let log = ActivityLog(url: url, now: { clock })
        let model = StatusBarModel(log: log, settings: Self.settings())
        let notice = AppToast.notice("USB에서 재생 기록 1개를 가져왔습니다", "합성 USB", kind: .success, isUsb: true)
        log.record(notice, shown: false)
        #expect(log.latest?.unshown == true && model.unreadCount == 1 && model.unreadKind == .success)
        #expect(ActivityLog(url: url).latest?.unshown == true)
        // 뒤에 같은 알림이 떠서 보였으면 띄우지 못한 알림이 아니다
        clock += 1
        log.record(notice)
        #expect(log.entries.count == 1 && log.latest?.unshown != true && model.unreadCount == 0)
    }

    @Test func 알림의_열기는_팝오버에서_그_항목을_펼치고_밀려난_항목은_활동_기록_창에서_고른다() {
        var clock = Self.start
        let log = ActivityLog(now: { clock })
        let model = StatusBarModel(log: log, settings: Self.settings())
        var opened: [ActivityEntry.ID?] = []
        model.showLog = { opened.append($0) }
        var ids: [ActivityEntry.ID] = []
        for index in 0..<12 {
            clock += 1
            ids.append(log.record(AppToast.notice("안내 \(index)", nil)))
        }
        #expect(model.recent.count == StatusBarModel.recentLimit && model.recent.first?.id == ids.last)
        model.open(ids[11])
        #expect(model.isPresented && model.expanded == ids[11] && opened.isEmpty)
        model.toggleExpanded(ids[11])
        #expect(model.expanded == nil)
        // 팝오버의 최근 10건 밖이면 팝오버를 닫고 활동 기록 창에서 그 항목을 고른다
        model.open(ids[0])
        #expect(!model.isPresented && opened == [ids[0]])
    }

    @Test func 모두_보기는_팝오버를_닫고_활동_기록_창을_연다() {
        let log = ActivityLog()
        let model = StatusBarModel(log: log, settings: Self.settings())
        var opened: [ActivityEntry.ID?] = []
        model.showLog = { opened.append($0) }
        let entry = log.record(AppToast.notice("안내", "설명"))
        model.open(entry)
        model.showAll()
        #expect(!model.isPresented && model.expanded == nil && opened == [nil])
        // 펼친 항목의 '활동 기록에서 보기…'는 그 항목을 고른다
        model.showAll(selecting: entry)
        #expect(opened == [nil, entry])
    }

    @Test func 결과_보기가_없는_경고와_실패_알림에만_열기를_붙인다() {
        #expect(AppToast.notice("rekordbox가 켜져 있어 쓰지 않았습니다", nil).opensActivity)
        #expect(AppToast(kind: .failure, title: "USB에 쓰지 못했습니다", isUsb: true).opensActivity)
        // 성공 알림과 결과 보기가 있는 쓰기 결과에는 붙이지 않는다
        #expect(!AppToast.notice("할 것이 없습니다", nil, kind: .success).opensActivity)
        #expect(!AppToast(kind: .warning, title: "일부 곡을 썼습니다").opensActivity)
        #expect(!AppToast(kind: .failure, title: "rekordbox에 쓰지 않았습니다").opensActivity)
    }

    @Test func 조립_지점이_상태_줄의_모두_보기를_주_창의_활동_기록에_잇는다() {
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil), saveTagDrafts: { _ in })
        let app = AppComposition(store: store, deck: DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false))
        #expect(app.statusBar.log === store.activityLog)
        let entry = store.activityLog.record(AppToast.notice("안내", nil))
        app.statusBar.showAll(selecting: entry)
        #expect(app.libraryWindow.activityLog?.selection == entry)
        #expect(SettingKeys.all.contains(SettingKeys.activitySeenThrough.name))
    }
}
