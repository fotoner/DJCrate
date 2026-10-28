@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 창 아래 상태 줄의 rekordbox 쓰기 상태 칩(#324): 쓰기 대기·쓰는 중(1초 넘을 때만)·마지막 쓰기, 팝오버 단추, Dock 배지.
/// 팝오버 단추는 메뉴 막대와 같은 `LibraryMenuAction`을 같은 조건으로 부른다. 새 쓰기 경로는 없다.
@MainActor
@Suite("상태 줄 쓰기 상태")
struct ReflectionStatusModelTests {
    /// 모델이 기다리는 1초를 시험이 직접 풀어 준다(걸린 시간으로 판정하지 않는다, TEST-30)
    final class SleepGate: @unchecked Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        private let lock = NSLock()
        private var asked: [Duration] = []
        private var cancels = 0

        init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

        var requested: [Duration] { lock.withLock { asked } }
        /// 풀리기 전에 취소돼 끝난 기다림 수
        var cancelled: Int { lock.withLock { cancels } }

        var sleep: @Sendable (Duration) async throws -> Void {
            { [self] duration in
                lock.withLock { asked.append(duration) }
                var iterator = stream.makeAsyncIterator()
                _ = await iterator.next()
                if Task.isCancelled {
                    lock.withLock { cancels += 1 }
                    throw CancellationError()
                }
            }
        }

        func release() { continuation.yield() }
    }

    /// Dock 배지 가짜: 바뀐 글자만 기록한다
    @MainActor
    final class FakeDock {
        private(set) var labels: [String?] = []
        var badge: DockBadge { DockBadge { [self] in labels.append($0) } }
    }

    @MainActor
    struct Harness {
        let store: LibraryStore
        let window: LibraryWindowModel
        let gate = SleepGate()
        let dock = FakeDock()
        let model: ReflectionStatusModel
        let backupFolder: URL

        init(log: ActivityLog = ActivityLog(), windows: AppWindows? = nil) {
            let folder = FileManager.default.temporaryDirectory.appending(path: "djc-write-status-\(UUID().uuidString)")
            // 쓰기 대상도 임시 폴더로 둔다(라이브 DB 기본값을 쓰지 않는다, SAFE-7)
            store = LibraryStore.test(activityLog: log, saveTagDrafts: { _ in }, backupDirectory: folder.appending(path: "backups"),
                                      rekordboxDatabase: folder.appending(path: "master.db"))
            backupFolder = folder.appending(path: "backups")
            window = LibraryWindowModel(store: store)
            model = ReflectionStatusModel(store: store, window: window, windows: windows, reflection: store.reflection,
                                          dock: dock.badge, sleep: gate.sleep)
        }

        func addRows(_ uuids: String...) { for uuid in uuids { store.rowsByUUID[uuid] = PendingCountCacheTests.track(uuid) } }

        func addPlaylistEdit(_ name: String = "새 목록") throws {
            var draft = store.playlists.playlistDraft
            try draft.append(.create(key: name, name: name, isFolder: false, parent: PlaylistRef(PlaylistLayout.root)), rekordbox: PlaylistLayout())
            store.playlists.playlistDraft = draft
        }
    }

    // MARK: - 칩

    @Test func 쓰기_대기가_없으면_없음을_보이고_곡_초안이_쌓이면_곡_수를_보인다() {
        let h = Harness()
        h.model.refresh()
        #expect(h.model.chip == .clean && h.model.chip.title == "쓰기 대기 없음")

        h.addRows("a", "b")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0) && h.model.chip.title == "쓰기 대기 1건")
        h.store.setDraftMark(.gain, trackUUID: "b", exists: true)
        h.model.refresh()
        #expect(h.model.chip.title == "쓰기 대기 2건")

        h.store.setDraftMarks(cue: [], grid: [], gain: [])
        h.model.refresh()
        #expect(h.model.chip == .clean)
    }

    @Test func 재생_목록_편집만_있으면_편집_건수를_보이고_곡도_있으면_곡_수가_먼저다() throws {
        let h = Harness()
        try h.addPlaylistEdit("가")
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 0, playlistEdits: 1) && h.model.chip.title == "재생 목록 편집 1건")
        try h.addPlaylistEdit("나")
        h.model.refresh()
        #expect(h.model.chip.title == "재생 목록 편집 2건")

        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 2) && h.model.chip.title == "쓰기 대기 1건")
        #expect(h.model.extraLine == "재생 목록 편집 2건", "곡과 함께 있으면 팝오버가 편집 건수를 덧붙인다")
    }

    @Test func 칩의_곡_수는_사이드바_배지와_같은_정의다() {
        let h = Harness()
        h.addRows("a", "b", "c")
        h.store.rowsByUUID["s"] = PendingCountCacheTests.track("s", staged: true)
        h.store.setDraftMarks(cue: ["a", "s"], grid: ["b"])
        h.store.mergeDrafts = [PendingCountCacheTests.merge("c", "x")]
        h.model.refresh()
        // 추가한 곡 초안(s)과 읽지 못한 곡(x)은 세지 않는다
        #expect(h.store.pendingWriteCount == 3)
        #expect(h.model.chip == .pending(items: h.store.pendingWriteCount, playlistEdits: 0))
    }

    // MARK: - 쓰는 중(1초 넘을 때만)

    @Test func 쓰는_중은_1초를_넘긴_뒤에만_보이고_끝나면_사라진다() async throws {
        let h = Harness()
        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        h.model.refresh()
        #expect(ReflectionStatusModel.writingDelay == .seconds(1))

        h.store.isWritingRekordbox = true
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0), "쓰기 시작 직후에는 바꾸지 않는다")
        h.model.refresh()
        h.gate.release()
        #expect(await waitForState { h.model.chip == .writing })
        #expect(h.model.chip.title == "rekordbox에 쓰는 중…")
        #expect(h.gate.requested == [.seconds(1)], "기다림은 한 번만 건다")

        h.store.isWritingRekordbox = false
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0))
    }

    @Test func 쓰기가_1초_안에_끝나면_쓰는_중을_보이지_않는다() async {
        let h = Harness()
        h.store.isWritingRekordbox = true
        h.model.refresh()
        #expect(h.gate.cancelled == 0)
        h.store.isWritingRekordbox = false
        h.model.refresh()
        #expect(await waitForState { h.gate.cancelled == 1 }, "쓰기가 끝나면 기다리던 Task를 취소한다")
        h.gate.release()
        await drainMainActor()
        #expect(h.model.chip == .clean)
    }

    @Test func 미리_보기와_확인_창은_잠금만_걸렸을_뿐_아직_쓰지_않았으니_쓰는_중으로_보이지_않는다() async {
        let h = Harness()
        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        // 확인 창이 떠 있는 동안: 반영 세션이 잠금을 먼저 걸고 확인 창을 연다
        h.store.isWritingRekordbox = true
        h.store.isAwaitingConfirmation = true
        h.model.refresh()
        await drainMainActor()
        #expect(h.gate.requested.isEmpty, "쓰기 전에는 1초 기다림도 시작하지 않는다")
        h.store.isAwaitingConfirmation = false
        // 미리 보기(취소할 수 있는 단계)
        h.store.writeStage = WriteStage("바꿀 내용을 확인하는 중…", cancellable: true)
        h.model.refresh()
        await drainMainActor()
        #expect(h.gate.requested.isEmpty && h.model.chip == .pending(items: 1, playlistEdits: 0))
        // 실제 쓰기 단계가 되면 그때부터 1초를 센다
        h.store.writeStage = WriteStage("rekordbox에 쓰는 중…")
        h.model.refresh()
        h.gate.release()
        #expect(await waitForState { h.model.chip == .writing })
        #expect(h.gate.requested == [.seconds(1)])
        // 쓴 뒤 다시 읽는 단계도 쓰는 중이다. 끝나면 사라진다
        h.store.writeStage = .reloadingLibrary
        h.model.refresh()
        #expect(h.model.chip == .writing)
        h.store.writeStage = nil
        h.store.isWritingRekordbox = false
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 1, playlistEdits: 0))
    }

    // MARK: - 마지막 쓰기

    @Test func 마지막_쓰기는_활동_기록의_가장_최근_성공한_쓰기_결과다() {
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let log = ActivityLog(now: { clock })
        let h = Harness(log: log)
        h.model.refresh()
        #expect(h.model.lastWrite == nil && h.model.lastWriteText == nil, "기록이 없으면 보조 글을 숨긴다")

        let backup = URL(filePath: "/tmp/djc-backup-a")
        log.record(AppToast.notice("알림은 쓰기가 아니다", nil))
        log.record(WriteResult(kind: .failure, title: "rekordbox에 쓰지 않았습니다", text: "실패", backups: [backup]))
        log.record(WriteResult(kind: .success, title: "작업을 취소했습니다", text: "취소"))
        h.model.refresh()
        #expect(h.model.lastWrite == nil, "실패·취소·알림은 마지막 쓰기가 아니다")

        clock += 60
        log.record(WriteResult(kind: .success, title: "rekordbox에 썼습니다", text: "곡 1", backups: [backup]))
        let wroteAt = clock
        clock += 60
        log.record(WriteResult(kind: .failure, title: "rekordbox에 쓰지 않았습니다", text: "실패", backups: [backup]))
        h.model.refresh()
        #expect(h.model.lastWrite?.date == wroteAt)
    }

    @Test func 보조_글은_마지막_쓰기_시각과_백업_유무를_한_줄로_적는다() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let time = date.formatted(ReflectionLastWrite.timeFormat(includesDate: false))
        #expect(!time.contains("2026"), "오늘의 쓰기는 시각만 적는다")
        let withBackup = ReflectionLastWrite(date: date, hasBackup: true).text(now: date + 30)
        #expect(withBackup == "마지막 쓰기 \(time) · 백업 있음")
        #expect(ReflectionLastWrite(date: date, hasBackup: false).text(now: date + 30) == "마지막 쓰기 \(time)")
        // 다른 날의 쓰기는 날짜를 함께 적는다
        let older = ReflectionLastWrite(date: date, hasBackup: false).text(now: date + 3 * 86_400)
        #expect(older == "마지막 쓰기 \(date.formatted(ReflectionLastWrite.timeFormat(includesDate: true)))")
        #expect(older.contains(time) && older != "마지막 쓰기 \(time)")
    }

    @Test func 백업이_있는지는_저장소의_쓰기_백업_확인을_따른다() throws {
        let log = ActivityLog()
        let h = Harness(log: log)
        log.record(WriteResult(kind: .success, title: "rekordbox에 썼습니다", text: "곡 1", backups: [URL(filePath: "/tmp/djc-backup-b")]))
        h.model.refresh()
        #expect(h.store.hasWriteBackup == false && h.model.lastWrite?.hasBackup == false)

        // 쓰기 전 백업이 남으면(`-write`) 같은 쓰기 결과의 보조 글이 「백업 있음」이 된다
        let backup = h.backupFolder.appending(path: "2026-01-02-write")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data().write(to: backup.appending(path: "master.db"))
        defer { try? FileManager.default.removeItem(at: h.backupFolder.deletingLastPathComponent()) }
        h.store.refreshWriteBackups()
        h.model.refresh()
        #expect(h.store.hasWriteBackup && h.model.lastWrite?.hasBackup == true)
        #expect(h.model.lastWriteText?.hasSuffix("백업 있음") == true)
    }

    // MARK: - 팝오버

    @Test func 팝오버_단추는_메뉴_막대와_같은_명령을_같은_조건으로_보인다() {
        let h = Harness()
        #expect(h.model.items.map(\.action) == [.reflect, .pending, .activityLog, .restore])
        #expect(h.model.items.map(\.title) == ["rekordbox에 쓰기", "쓰기 대기 목록 보기", "활동 기록…", "쓰기 전으로 복원…"])
        #expect(h.model.items.first?.shortcutHint == "⇧⌘E" && h.model.items.dropFirst().allSatisfy { $0.shortcutHint == nil })

        func expectSameAsMenu(_ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
            for item in h.model.items {
                #expect(item.isEnabled == item.action.isEnabled(in: h.window), Comment(rawValue: "활성 — \(note) \(item.title)"), sourceLocation: sourceLocation)
                #expect(item.disabledReason == item.action.disabledReason(in: h.window), Comment(rawValue: "이유 — \(note) \(item.title)"), sourceLocation: sourceLocation)
            }
            #expect(h.model.canWrite == LibraryMenuAction.reflect.isEnabled(in: h.window), Comment(rawValue: "[쓰기] — \(note)"), sourceLocation: sourceLocation)
        }
        expectSameAsMenu("초안 없음")
        #expect(h.model.items.first?.isEnabled == false && h.model.canWrite == false)

        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        expectSameAsMenu("초안 있음")
        #expect(h.model.items.first?.isEnabled == true && h.model.canWrite)

        h.store.isWritingRekordbox = true
        expectSameAsMenu("쓰는 중")
        #expect(h.model.items.first?.isEnabled == false && !h.model.canWrite, "쓰는 동안은 메뉴처럼 막는다")
        h.store.isWritingRekordbox = false
        expectSameAsMenu("쓰기 끝")
    }

    @Test func 쓰기_대기_목록_보기와_활동_기록은_팝오버를_닫고_메뉴와_같이_연다() {
        let h = Harness()
        h.model.isPresented = true
        h.model.perform(.pending)
        #expect(!h.model.isPresented && h.store.sidebar == .pending)

        h.model.isPresented = true
        #expect(h.window.activityLog == nil)
        h.model.perform(.activityLog)
        #expect(!h.model.isPresented && h.window.activityLog != nil)
    }

    @Test func 막힌_쓰기_단추는_메뉴와_같은_이유를_알린다() throws {
        let h = Harness()
        // 쓸 초안이 없어 막혀 있어야 이 시험이 쓰기에 닿지 않는다
        let reason = try #require(LibraryMenuAction.reflect.disabledReason(in: h.window))
        h.model.perform(.reflect)
        #expect(h.store.toast?.title == reason, "초안이 없으면 메뉴와 같은 이유를 토스트로 알리고 아무것도 쓰지 않는다")
        #expect(h.store.isWritingRekordbox == false && h.store.writeTask == nil)

        // 쓸 수 있는 초안이 있으면 메뉴와 같은 입구(ReflectionCoordinator.startWrite)로 간다
        h.addRows("a")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        #expect(h.model.canWrite)
    }

    // MARK: - Dock 배지

    @Test func Dock_배지는_쓰기_대기_곡_수이고_0이면_없다() {
        let h = Harness()
        h.model.refresh()
        #expect(h.dock.labels.isEmpty, "처음부터 0이면 건드리지 않는다")

        h.addRows("a", "b", "c")
        h.store.setDraftMarks(cue: ["a", "b", "c"])
        h.model.refresh()
        #expect(h.dock.labels == ["3"])
        h.model.refresh()
        #expect(h.dock.labels == ["3"], "같은 수는 다시 보내지 않는다")

        h.store.setDraftMarks(cue: ["a"])
        h.model.refresh()
        #expect(h.dock.labels == ["3", "1"])
        h.store.setDraftMarks(cue: [])
        h.model.refresh()
        #expect(h.dock.labels == ["3", "1", nil])
        #expect(h.model.chip == .clean)
    }

    @Test func 재생_목록_편집만_있으면_사이드바_배지처럼_Dock_배지도_없다() throws {
        let h = Harness()
        try h.addPlaylistEdit()
        h.model.refresh()
        #expect(h.model.chip == .pending(items: 0, playlistEdits: 1))
        #expect(h.dock.labels.isEmpty && h.store.pendingWriteCount == 0)
    }

    // MARK: - 관찰

    @Test func 저장소가_바뀌면_모델이_관찰해_칩과_Dock_배지를_스스로_고친다() async {
        let h = Harness()
        h.model.start()
        h.addRows("a", "b")
        h.store.setDraftMark(.cue, trackUUID: "a", exists: true)
        #expect(await waitForState { h.model.chip == .pending(items: 1, playlistEdits: 0) })
        #expect(h.dock.labels == ["1"])

        h.store.setDraftMark(.grid, trackUUID: "b", exists: true)
        #expect(await waitForState { h.model.chip.title == "쓰기 대기 2건" })
        #expect(h.dock.labels == ["1", "2"])

        h.store.setDraftMarks(cue: [], grid: [])
        #expect(await waitForState { h.model.chip == .clean })
        #expect(h.dock.labels == ["1", "2", nil])
    }
}
