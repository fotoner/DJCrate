@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 창 알림의 활동 기록(#296): 여러 건을 최근 것부터 남기고, 잇달아 같은 알림은 합치고, 파일로 보관한다.
@MainActor
@Suite("활동 기록")
struct ActivityLogTests {
    /// 시험마다 새 임시 폴더(사용자 데이터 폴더를 쓰지 않는다)
    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "djc-activity-log-\(UUID().uuidString)")
    }

    static func permissions(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    // MARK: - 저장소

    @Test func 여러_알림을_최근_것부터_남긴다() {
        let log = ActivityLog()
        log.record(AppToast.notice("첫 안내", "설명"))
        log.record(AppToast(title: "현재 rekordbox 내용을 불러왔습니다"))
        log.record(WriteResult(kind: .warning, title: "rekordbox에 썼습니다 · 큐 1곡", text: "• 곡 a — 큐 쓰기 완료"))
        #expect(log.entries.map(\.title) == ["rekordbox에 썼습니다 · 큐 1곡", "현재 rekordbox 내용을 불러왔습니다", "첫 안내"])
        #expect(log.entries.map(\.kind) == [.warning, .success, .warning])
        #expect(log.entries.last?.detail == "설명" && log.entries.last?.result == nil)
        // 쓰기 결과는 전체 내용을 자세한 내용으로 둔다
        #expect(log.latest?.detail == "• 곡 a — 큐 쓰기 완료" && log.latest?.result?.title == log.latest?.title)
    }

    @Test func 바로_앞과_같은_알림은_새_항목_대신_시각과_횟수를_고친다() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let log = ActivityLog(now: { clock })
        let first = log.record(AppToast.notice("rekordbox가 켜져 있어 쓰지 않았습니다", "rekordbox를 종료하세요"))
        clock = Date(timeIntervalSince1970: 2_000)
        let again = log.record(AppToast.notice("rekordbox가 켜져 있어 쓰지 않았습니다", "rekordbox를 종료하세요"))
        #expect(again == first && log.entries.count == 1)
        #expect(log.latest?.count == 2 && log.latest?.date == clock)
        // 종류나 내용이 다르면 따로 남긴다
        log.record(AppToast.notice("rekordbox가 켜져 있어 쓰지 않았습니다", "rekordbox를 종료하세요", kind: .success))
        log.record(AppToast.notice("rekordbox가 켜져 있어 쓰지 않았습니다", "다른 설명"))
        // 바로 앞 항목만 본다: 사이에 다른 알림이 있었으면 같은 알림도 새 항목이다
        log.record(AppToast.notice("rekordbox가 켜져 있어 쓰지 않았습니다", "rekordbox를 종료하세요"))
        #expect(log.entries.count == 4 && log.entries.map(\.count) == [1, 1, 1, 2])
    }

    @Test func 백업이_다른_쓰기_결과는_합치지_않는다() {
        let log = ActivityLog()
        let result = WriteResult(kind: .success, title: "rekordbox에 썼습니다 · 큐 1곡", text: "• 곡 a — 큐 쓰기 완료",
                                 backups: [URL(filePath: "/tmp/djc-synthetic-backup-1")])
        log.record(result)
        var next = result
        next.backups = [URL(filePath: "/tmp/djc-synthetic-backup-2")]
        log.record(next)
        #expect(log.entries.count == 2)
        // 백업까지 같으면(쓴 것이 없는 결과 등) 합친다
        let nothing = WriteResult(kind: .warning, title: "rekordbox에 쓴 것이 없습니다", text: "• 곡 b — 바꿀 것 없음")
        log.record(nothing)
        log.record(nothing)
        #expect(log.entries.count == 3 && log.latest?.count == 2)
    }

    @Test func 최근_200건까지만_남기고_오래된_것부터_지운다() {
        let log = ActivityLog()
        for index in 0..<205 { log.record(AppToast.notice("알림 \(index)", nil)) }
        #expect(log.entries.count == ActivityLog.limit && ActivityLog.limit == 200)
        #expect(log.entries.first?.title == "알림 204" && log.entries.last?.title == "알림 5")
    }

    /// 알림마다 파일 전체를 다시 쓰므로, 곡마다의 긴 결과가 200건 쌓여 파일이 한없이 커지지 않게 한다.
    @Test func 최근_20개보다_오래된_쓰기_결과는_문구의_앞부분만_남긴다() throws {
        let log = ActivityLog()
        let long = String(repeating: "• 곡 — 큐 쓰기 완료\n", count: 500)
        for index in 0..<(ActivityLog.fullResults + 3) {
            log.record(WriteResult(kind: .success, title: "rekordbox에 썼습니다 · \(index)", text: long,
                                   backups: [URL(filePath: "/tmp/djc-activity-backup-\(index)")]))
            log.record(AppToast(title: "현재 rekordbox 내용을 불러왔습니다 · \(index)"))
        }
        let results = log.entries.filter { $0.result != nil }
        #expect(results.count == ActivityLog.fullResults + 3)
        #expect(results.prefix(ActivityLog.fullResults).allSatisfy { $0.detail == long && $0.result?.text == long })
        for old in results.dropFirst(ActivityLog.fullResults) {
            for text in [old.detail, old.result?.text] {
                let text = try #require(text)
                #expect(text.count < long.count && text.hasPrefix(String(long.prefix(ActivityLog.trimmedLength))))
            }
            #expect(old.result?.backups.count == 1)
        }
    }

    @Test func 파일로_보관하고_다시_열면_그대로_읽는다() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "activity-log.json")
        let log = ActivityLog(url: url)
        log.record(AppToast.notice("USB에 쓰지 않았습니다", "USB를 다시 꽂으세요", isUsb: true))
        log.record(AppToast.notice("USB에 쓰지 않았습니다", "USB를 다시 꽂으세요", isUsb: true))
        log.record(WriteResult(kind: .success, title: "rekordbox를 쓰기 전으로 복원했습니다", text: "전체 내용",
                               backups: [URL(filePath: "/tmp/djc-synthetic-backup")]))
        #expect(log.storageError == nil)
        #expect(try Self.permissions(url) == 0o600)
        let reopened = ActivityLog(url: url)
        #expect(reopened.storageError == nil)
        #expect(reopened.entries == log.entries)
        #expect(reopened.entries.map(\.count) == [1, 2])
        #expect(reopened.latest?.result?.backups == [URL(filePath: "/tmp/djc-synthetic-backup")])
    }

    @Test func 옛_마지막_쓰기_결과_파일을_첫_항목으로_이어_받는다() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = folder.appending(path: "last-write-result.json"), url = folder.appending(path: "activity-log.json")
        let old = WriteResult(kind: .warning, title: "rekordbox에 썼습니다 · 그리드 1곡", text: "• 곡 a — 그리드 쓰기 완료",
                              shortfall: "큐 1곡은 쓰지 않았습니다", backups: [URL(filePath: "/tmp/djc-synthetic-backup")],
                              createdAt: Date(timeIntervalSince1970: 1_000))
        try JSONEncoder().encode(old).write(to: legacy)

        let log = ActivityLog(url: url, legacyResult: legacy)
        #expect(log.storageError == nil)
        #expect(log.entries.count == 1)
        #expect(log.latest?.result == old && log.latest?.title == old.title && log.latest?.kind == .warning)
        #expect(log.latest?.detail == old.text && log.latest?.date == old.createdAt)
        // 새 파일로 옮기고 옛 파일은 지운다(다시 열어도 두 번 이어 받지 않는다)
        #expect(try Self.permissions(url) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        log.record(AppToast.notice("다음 알림", nil))
        let reopened = ActivityLog(url: url, legacyResult: legacy)
        #expect(reopened.entries.map(\.title) == ["다음 알림", old.title])
    }

    @Test func 옛_결과를_새_파일에_옮기지_못했으면_다음에_보관할_때_옛_파일을_지운다() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = folder.appending(path: "last-write-result.json"), blocker = folder.appending(path: "home")
        let url = blocker.appending(path: "activity-log.json")
        let old = WriteResult(kind: .success, title: "rekordbox를 쓰기 전으로 복원했습니다", text: "전체 내용")
        try JSONEncoder().encode(old).write(to: legacy)
        // 기록 폴더 자리에 파일이 있어 처음에는 보관하지 못한다
        try Data().write(to: blocker)
        let log = ActivityLog(url: url, legacyResult: legacy)
        #expect(log.storageError != nil && log.latest?.result == old)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        try FileManager.default.removeItem(at: blocker)
        log.record(AppToast.notice("다음 알림", nil))
        #expect(log.storageError == nil)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(ActivityLog(url: url, legacyResult: legacy).entries.map(\.title) == ["다음 알림", old.title])
    }

    @Test func 읽지_못한_기록_파일은_덮지_않고_옆에_남긴_뒤_처음_알림과_창에_알린다() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "activity-log.json")
        try Data("{".utf8).write(to: url)
        let store = LibraryStore.test(activityLog: ActivityLog(url: url), feedback: AppFeedback(announce: { _ in }))
        let readError = try #require(store.activityLog.storageError)
        store.showToast(AppToast(title: "현재 rekordbox 내용을 불러왔습니다"))
        // 읽지 못한 파일은 지우지도 덮지도 않고 옆 이름으로 남긴다
        let kept = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "activity-log.json" }
        #expect(kept.count == 1)
        #expect(try kept.first.map { try Data(contentsOf: $0) } == Data("{".utf8))
        #expect(readError.contains(kept.first?.lastPathComponent ?? "-"))
        #expect(ActivityLog(url: url).entries.map(\.title) == ["현재 rekordbox 내용을 불러왔습니다"])
        // 처음 알림에 덧붙이고, 창에는 이번 실행 동안 계속 보인다
        #expect(store.toast?.kind == .warning && store.toast?.detail?.contains(readError) == true)
        #expect(store.activityLog.storageError == readError)
        store.showToast(AppToast(title: "다음 알림"))
        #expect(store.toast?.kind == .success && store.toast?.detail == nil)
    }

    @Test func 읽지_못한_옛_결과_파일은_지우지_않고_알린다() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "activity-log.json"), legacy = folder.appending(path: "last-write-result.json")
        try Data("{".utf8).write(to: legacy)
        let log = ActivityLog(url: url, legacyResult: legacy)
        #expect(log.storageError != nil && log.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    // MARK: - 창 알림과 잇기

    @Test func 창_알림을_띄우면_활동_기록에_남고_알림이_그_항목을_가리킨다() throws {
        let store = LibraryStore.test(activityLog: ActivityLog(), feedback: AppFeedback(announce: { _ in }))
        store.showToast(.notice("복원할 쓰기 기록이 없습니다", "백업이 정리됐습니다"))
        let entry = try #require(store.activityLog.latest)
        #expect(entry.title == "복원할 쓰기 기록이 없습니다" && entry.detail == "백업이 정리됐습니다" && entry.kind == .warning)
        #expect(store.toast?.activityID == entry.id)
        // 같은 안내가 다시 떠도 항목은 하나이고, 알림은 그 항목을 가리킨다
        store.dismissToast()
        store.showToast(.notice("복원할 쓰기 기록이 없습니다", "백업이 정리됐습니다"))
        #expect(store.activityLog.entries.count == 1 && store.toast?.activityID == entry.id)
        // 다른 알림 id로는 지금 알림을 닫지 않는다
        store.dismissToast(UUID())
        #expect(store.toast != nil)
        store.dismissToast(store.toast?.id)
        #expect(store.toast == nil)
    }

    @Test func 쓰기_결과는_결과와_함께_한_항목으로_남는다() throws {
        let store = LibraryStore.test(activityLog: ActivityLog(), feedback: AppFeedback(announce: { _ in }))
        var written = ReflectionPresenterTests.preview(cues: [ReflectionPresenterTests.outcome("a", .written)]).report
        written.backup = "/tmp/djc-synthetic-backup"
        ReflectionPresenter(store: store, prompter: ScriptedPrompter()).publish(.written(written, preview: written, followUp: []))
        let entry = try #require(store.activityLog.latest)
        #expect(store.activityLog.entries.count == 1)
        #expect(entry.result?.backups == [URL(filePath: "/tmp/djc-synthetic-backup")] && entry.detail == entry.result?.text)
        #expect(store.toast?.activityID == entry.id && store.toast?.title == entry.title && store.toast?.showsResult == true)
    }

    @Test func 기록을_보관하지_못하면_알림에도_알린다() throws {
        let folder = Self.folder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // 폴더 자리에는 파일을 쓸 수 없다
        let store = LibraryStore.test(activityLog: ActivityLog(url: folder), feedback: AppFeedback(announce: { _ in }))
        store.showToast(AppToast(title: "현재 rekordbox 내용을 불러왔습니다"))
        let error = try #require(store.activityLog.storageError)
        #expect(store.activityLog.latest?.title == "현재 rekordbox 내용을 불러왔습니다")
        #expect(store.toast?.kind == .warning && store.toast?.detail?.contains(error) == true)
    }

    // MARK: - 창

    @Test func 활동_기록_창은_고른_항목을_열고_주지_않으면_맨_위를_고른다() throws {
        let log = ActivityLog()
        let old = log.record(AppToast.notice("이전 안내", nil))
        let latest = log.record(WriteResult(kind: .success, title: "rekordbox에 썼습니다 · 큐 1곡", text: "전체 내용"))
        let picked = ActivityLogModel(log: log, selection: old)
        #expect(picked.selection == old && picked.selected?.title == "이전 안내")
        let top = ActivityLogModel(log: log)
        #expect(top.selection == latest && top.selected?.result?.text == "전체 내용")
        // 지워진(200건을 넘어 밀려난) 항목을 고르면 맨 위를 고른다
        #expect(ActivityLogModel(log: log, selection: UUID()).selection == latest)
        #expect(ActivityLogModel(log: ActivityLog()).selected == nil)
    }
}
