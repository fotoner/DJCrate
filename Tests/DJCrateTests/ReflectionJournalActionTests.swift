@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
@testable import RekordboxKit
import Synchronization
import Testing

/// 중단 알림(#404, R11): 상태 줄의 [기록으로 복원…]·[이대로 두기…]가 쓰기 관문의 `restoreJournal`·`keepJournal`로 가고,
/// 복원 확인 창이 "백업 뒤 rekordbox에서 바뀜" 경고를 띄우며, 끝나면 엔진이 복원 뒤 멈춤(R8)·기록 다시 판정으로 이어진다.
/// 판정·복원·이대로 두기 자체는 W1-A의 관문 시험이 본다. 여기는 앱의 연결(차례·확인 창·알림·엔진 신호)을 본다.
@MainActor
@Suite("중단 알림 복원·이대로 두기")
struct ReflectionJournalActionTests {
    static let warning = "⚠︎ 이 백업 뒤에 rekordbox에서도 라이브러리가 바뀌었습니다(큐·재생 목록·곡 추가 등). 복원하면 그 변경도 함께 사라집니다."

    /// 가짜 관문이 본 일
    final class Calls: @unchecked Sendable {
        private let state = Mutex<(present: Bool, restores: [RekordboxJournalRequest], keeps: [RekordboxJournalRequest], removed: [String],
                                   restoreResult: RekordboxJournalRestore, restoreError: (any Error)?, keepApplyError: Bool)>(
            (true, [], [], [], .restored(backup: URL(filePath: "/backups/before-restore")), nil, false))
        var present: Bool { state.withLock { $0.present } }
        var restores: [RekordboxJournalRequest] { state.withLock { $0.restores } }
        var keeps: [RekordboxJournalRequest] { state.withLock { $0.keeps } }
        var removed: [String] { state.withLock { $0.removed } }
        func set(_ edit: (inout (present: Bool, restores: [RekordboxJournalRequest], keeps: [RekordboxJournalRequest], removed: [String],
                                 restoreResult: RekordboxJournalRestore, restoreError: (any Error)?, keepApplyError: Bool)) -> Void) {
            state.withLock { edit(&$0) }
        }
        func restoreCalled(_ request: RekordboxJournalRequest) -> Result<RekordboxJournalRestore, any Error> {
            state.withLock { state in
                state.restores.append(request)
                if let error = state.restoreError { return .failure(error) }
                if case .restored = state.restoreResult { state.present = false }
                if case .alreadyRestored = state.restoreResult { state.present = false }
                return .success(state.restoreResult)
            }
        }
        func keepCalled(_ request: RekordboxJournalRequest) { state.withLock { $0.keeps.append(request) } }
        func removed(_ id: String) { state.withLock { $0.removed.append(id) } }
        func cleared() { state.withLock { $0.present = false } }
        /// 관문을 부르는 동안 앱의 쓰기 상태(`libraryBusy`)와 USB 쓰기 상태를 본 값
        private let busySeen = Mutex<[Bool]>([])
        var busyDuringGate: [Bool] { busySeen.withLock { $0 } }
        func sawBusy(_ busy: Bool) { busySeen.withLock { $0.append(busy) } }
    }

    /// 확인 창이 답한 직후 일을 하는 프롬프터(확인 창이 떠 있는 동안 USB 쓰기가 시작된 경우를 흉내 낸다)
    @MainActor
    final class AfterAnswerPrompter: HeadlessReflectionPrompter {
        var afterAnswer: () -> Void = {}
        var shown: [ReflectionPrompt] = []
        func show(_ prompt: ReflectionPrompt) -> Bool {
            shown.append(prompt)
            afterAnswer()
            return true
        }
    }

    struct World {
        let store: LibraryStore
        let coordinator: ReflectionCoordinator
        let prompter: ScriptedPrompter
        let calls: Calls
        let finding: RekordboxJournalFinding
        let home: URL
    }

    func world(changedSince: Bool = false, draft: (key: DraftKey, revision: DraftRevision, hash: DraftContentHash)? = nil, home: URL? = nil,
               journalHome: URL? = nil, entry: RekordboxWriteJournal.Entry = .drafts, store existing: LibraryStore? = nil,
               prompter customPrompter: (any ReflectionPrompter)? = nil) -> World {
        let folder = home ?? FileManager.default.temporaryDirectory.appending(path: "djc-journal-action-\(UUID().uuidString)")
        let store = existing ?? LibraryStore.test(activityLog: ActivityLog(), saveTagDrafts: { _ in }, draftHome: folder, movesDamagedDrafts: false,
                                                 takeLiveSnapshot: { _ in throw DJCError.snapshotNotFound })
        store.phase = .loaded
        let calls = Calls()
        let stamp = RekordboxFileStamp(size: 100, modifiedNanoseconds: 200)
        var journal = RekordboxWriteJournal(operationID: "op-1", kind: .counter, entry: entry, startCounter: 5)
        if let draft {
            journal.drafts = .init(home: (journalHome ?? folder).path, written: [WrittenDraft(key: draft.key, revision: draft.revision, contentHash: draft.hash)])
        }
        let finding = RekordboxJournalFinding(journal: journal, changedSince: changedSince, database: stamp)
        var gate = RekordboxWriteGate.restoringOnly
        gate.journal = { _, _ in calls.present ? .interrupted(finding) : .none }
        nonisolated(unsafe) let observed = store
        let busyNow: @Sendable () -> Bool = { DispatchQueue.main.sync { MainActor.assumeIsolated { observed.libraryBusy } } }
        gate.restoreJournal = { _, request in
            calls.sawBusy(busyNow())
            return try calls.restoreCalled(request).get()
        }
        gate.keepJournal = { _, request, apply in
            guard calls.present else { return .nothing }
            calls.sawBusy(busyNow())
            calls.keepCalled(request)
            try apply()
            calls.cleared()
            return .kept
        }
        let list = DraftCleanupList(operationID: "op-1", target: RekordboxWriteLockKey(device: 1, inode: 2), draftHome: folder.path, backupFolder: "b")
        gate.cleanupLists = { _, _ in [list] }
        gate.removeCleanupList = { list, _ in calls.removed(list.operationID) }
        let prompter = ScriptedPrompter()
        let coordinator = ReflectionCoordinator.test(store: store, prompter: customPrompter ?? prompter, gate: gate)
        return World(store: store, coordinator: coordinator, prompter: prompter, calls: calls, finding: finding, home: folder)
    }

    // MARK: - 기록으로 복원

    @Test func 기록으로_복원은_확인한_뒤_관문의_요청으로_복원하고_결과를_알린다() async {
        let w = world()
        await w.coordinator.restoreJournal()
        #expect(w.prompter.shown.count == 1 && w.prompter.shown.first?.confirm == String(ui: "기록으로 복원"))
        #expect(w.prompter.shown.first?.text.contains(Self.warning) == false, "바뀐 것이 없으면 경고가 없다")
        #expect(w.calls.restores == [w.finding.request], "판정이 찾은 요청 그대로(작업 ID·그때 본 master.db)")
        #expect(w.store.toast?.title == "기록으로 복원했습니다" && w.store.toast?.kind == .success)
    }

    @Test func 백업_뒤_rekordbox가_라이브러리를_바꿨으면_복원_확인_창이_경고를_띄운다() async {
        let w = world(changedSince: true)
        await w.coordinator.restoreJournal()
        let prompt = w.prompter.shown.first
        #expect(prompt?.text.contains(Self.warning) == true)
        #expect(prompt?.critical == true && prompt?.destructive == true, "되돌릴 수 없는 손실이 있을 수 있어 파괴적 경고로 띄운다")
    }

    @Test func 확인에서_취소하면_아무것도_하지_않는다() async {
        let w = world()
        w.prompter.answer = false
        await w.coordinator.restoreJournal()
        #expect(w.calls.restores.isEmpty && w.store.toast == nil)
    }

    @Test func 복원_뒤_다시_읽어_이미_복원된_기록은_완료로_알린다() async {
        let w = world()
        w.calls.set { $0.restoreResult = .alreadyRestored }
        await w.coordinator.restoreJournal()
        #expect(w.store.toast?.title == "기록으로 복원했습니다")
    }

    @Test func 복원_사이에_기록이나_라이브러리가_바뀌었으면_다시_확인하게_안내한다() async {
        let w = world()
        w.calls.set { $0.restoreResult = .changed }
        await w.coordinator.restoreJournal()
        #expect(w.store.toast?.title == "그 사이 라이브러리가 바뀌어 처리하지 않았습니다" && w.store.toast?.kind == .warning)
    }

    @Test func 복원할_기록이_이미_없으면_알리고_끝낸다() async {
        let w = world()
        w.calls.cleared()
        await w.coordinator.restoreJournal()
        #expect(w.calls.restores.isEmpty && w.prompter.shown.isEmpty, "기록이 없으면 묻지 않는다")
    }

    @Test func 복원이_실패하면_이유를_알리고_기록은_그대로_남긴다() async {
        let w = world()
        w.calls.set { $0.restoreError = DJCError.writeRefused("시험 거절") }
        await w.coordinator.restoreJournal()
        #expect(w.store.toast?.kind == .failure && w.calls.present, "기록이 남아 있어 다시 고를 수 있다")
        #expect(w.store.toast?.title == "기록으로 복원하지 못했습니다")
    }

    // MARK: - 이대로 두기

    @Test func 이대로_두기는_확인한_뒤_미정리_목록을_지우고_기록에_적힌_판만_제안으로_바꾼다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-journal-keep-\(UUID().uuidString)")
        let store = LibraryStore.test(activityLog: ActivityLog(), saveTagDrafts: { _ in }, draftHome: home, movesDamagedDrafts: false,
                                      takeLiveSnapshot: { _ in throw DJCError.snapshotNotFound })
        var cue = CueDraft(trackUUID: "t1")
        cue.place(EditableCue(id: UUID(), kind: .hot(0), time: 1))
        // 앱의 편집 포트는 사람 편집이다(시험 저장소의 기본 출처는 모름이라 사람 포트로 저장한다)
        let human = store.testDrafts.with(origin: .human)
        human.saveCue(cue)
        human.flush()
        let key = DraftKey(.cue, "t1")
        let stamp = try #require(store.testDrafts.stamp(key))
        #expect(stamp.isHumanOnly && store.testDrafts.suggestion(key) == nil, "사람이 고친 큐라 자동 저장 대상이다")
        let w = world(draft: (key, stamp.revision, stamp.contentHash), home: home, store: store)
        await w.coordinator.keepJournal()
        #expect(w.prompter.shown.count == 1 && w.prompter.shown.first?.confirm == String(ui: "이대로 두기"))
        #expect(w.calls.keeps == [w.finding.request])
        #expect(w.calls.removed == ["op-1"], "그 쓰기의 미정리 목록을 먼저 지운다")
        #expect(store.testDrafts.suggestion(key) != nil, "쓴 판의 초안은 지우지 않고 제안으로 남는다")
        #expect(store.toast?.title == "이대로 두었습니다" && store.toast?.kind == .success)
    }

    @Test func 이대로_두기에서_취소하면_아무것도_바꾸지_않는다() async {
        let w = world()
        w.prompter.answer = false
        await w.coordinator.keepJournal()
        #expect(w.calls.keeps.isEmpty && w.calls.removed.isEmpty && w.calls.present)
    }

    @Test func 이대로_두기_사이에_기록이_바뀌었으면_다시_확인하게_안내한다() async {
        let w = world()
        w.calls.cleared()
        await w.coordinator.keepJournal()
        #expect(w.calls.keeps.isEmpty, "판정이 기록을 찾지 못하면 묻지도 않는다")
    }

    // MARK: - S1: 다른 데이터 폴더의 기록

    @Test func 이대로_두기는_기록에_적힌_초안_저장소가_이_앱의_것이_아니면_기록을_지우지_않고_알린다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-journal-home-a-\(UUID().uuidString)")
        let other = FileManager.default.temporaryDirectory.appending(path: "djc-journal-home-b-\(UUID().uuidString)")
        let store = LibraryStore.test(activityLog: ActivityLog(), saveTagDrafts: { _ in }, draftHome: home, movesDamagedDrafts: false,
                                      takeLiveSnapshot: { _ in throw DJCError.snapshotNotFound })
        var cue = CueDraft(trackUUID: "t1")
        cue.place(EditableCue(id: UUID(), kind: .hot(0), time: 1))
        let human = store.testDrafts.with(origin: .human)
        human.saveCue(cue)
        human.flush()
        let key = DraftKey(.cue, "t1")
        let stamp = try #require(store.testDrafts.stamp(key))
        // 기록은 다른 데이터 폴더(홈 B)의 앱이 남겼다
        let w = world(draft: (key, stamp.revision, stamp.contentHash), home: home, journalHome: other, store: store)
        await w.coordinator.keepJournal()
        #expect(w.calls.keeps.isEmpty && w.calls.removed.isEmpty && w.calls.present, "기록·미정리 목록을 건드리지 않는다")
        #expect(store.testDrafts.suggestion(key) == nil, "초안도 제안으로 바꾸지 않는다")
        #expect(w.store.toast?.kind == .warning && w.store.toast?.title.contains("다른 데이터 폴더") == true, "\(String(describing: w.store.toast?.title))")
        #expect(w.prompter.shown.isEmpty, "처리할 수 없는 기록은 묻지 않는다")
    }

    // MARK: - S7: 앱 쓰기 상태와 USB 배타

    @Test func 기록으로_복원은_관문을_부르는_동안_라이브러리_쓰기_상태를_유지하고_끝나면_푼다() async {
        let w = world()
        await w.coordinator.restoreJournal()
        #expect(w.calls.restores.count == 1)
        #expect(w.calls.busyDuringGate == [true], "복원하는 동안 USB 동기화 같은 다른 일이 겹치지 않게 쓰기 상태다: \(w.calls.busyDuringGate)")
        #expect(!w.store.libraryBusy, "끝나면 푼다")
    }

    @Test func 이대로_두기도_관문을_부르는_동안_라이브러리_쓰기_상태를_유지한다() async {
        let w = world()
        await w.coordinator.keepJournal()
        #expect(w.calls.keeps.count == 1)
        #expect(w.calls.busyDuringGate == [true], "\(w.calls.busyDuringGate)")
        #expect(!w.store.libraryBusy)
    }

    @Test func USB에_쓰는_중이면_복원을_시작하지_않고_이유를_알린다() async {
        let w = world()
        w.coordinator.isWritingUsb = { true }
        await w.coordinator.restoreJournal()
        #expect(w.calls.restores.isEmpty && w.calls.present)
        #expect(w.store.toast?.title == "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 시도하세요")
    }

    @Test func 확인하는_사이_USB_쓰기가_시작되면_관문을_부르기_직전에_막는다() async {
        let prompter = AfterAnswerPrompter()
        let w = world(prompter: prompter)
        nonisolated(unsafe) var usb = false
        w.coordinator.isWritingUsb = { usb }
        prompter.afterAnswer = { usb = true }
        await w.coordinator.restoreJournal()
        #expect(prompter.shown.count == 1, "확인은 받았다")
        #expect(w.calls.restores.isEmpty && w.calls.present, "그 사이 시작된 USB 쓰기를 호출 직전에 다시 본다")
        #expect(w.store.toast?.title == "USB에 쓰는 중입니다. 쓰기가 끝난 뒤 다시 시도하세요")
        #expect(!w.store.libraryBusy)
    }

    @Test func 다른_저장이_도는_중이면_기록_복원은_시작하지_않는다() async {
        let w = world()
        w.store.isWritingRekordbox = true
        await w.coordinator.restoreJournal()
        #expect(w.calls.restores.isEmpty && w.prompter.shown.isEmpty)
        #expect(w.store.toast?.title == "rekordbox 저장이 끝난 뒤 다시 시도하세요")
        w.store.isWritingRekordbox = false
    }

    // MARK: - S9: 기록 종류에 맞는 복원 목표

    @Test(arguments: [
        (RekordboxWriteJournal.Entry.drafts, "쓰다가 끊긴 저장을 이 기록으로 쓰기 전 상태로 되돌립니다."),
        (.trackAdd, "쓰다가 끊긴 저장을 이 기록으로 쓰기 전 상태로 되돌립니다."),
        (.trackDelete, "쓰다가 끊긴 저장을 이 기록으로 쓰기 전 상태로 되돌립니다."),
        (.restore, "끊긴 복원을 이 기록의 같은 백업으로 다시 끝냅니다."),
        (.pointRestore, "끊긴 복원을 처음 고른 복원 시점으로 다시 끝냅니다."),
        (.iTunesSync, "끊긴 iTunes 동기화가 바꾼 동기화 파일만 쓰기 전 상태로 되돌립니다."),
    ])
    func 복원_확인_창은_기록_종류에_맞는_실제_목표를_말한다(_ entry: RekordboxWriteJournal.Entry, _ expected: String) async {
        let w = world(entry: entry)
        await w.coordinator.restoreJournal()
        #expect(w.prompter.shown.first?.text.hasPrefix(expected) == true, "\(entry): \(String(describing: w.prompter.shown.first?.text))")
    }

    // MARK: - 엔진의 차례와 신호

    /// 엔진이 있으면 복원도 엔진의 차례를 받고(`exclusive`), 끝나면 엔진이 복원 뒤 멈춤(R8)으로 간다. "이대로 두기"는 기록을 다시 판정한다
    @Test func 엔진이_있으면_복원은_엔진의_차례로_하고_복원_뒤_자동_저장이_멈춘다() async throws {
        let w = world()
        let home = try TemporaryFolder(prefix: "djc-journal-engine")
        let feed = w.coordinator.autoFeed
        let ports = AutoReflectionPorts(clock: .live, runState: { .stopped },
                                        quietStamps: { _ in LibraryQuietStamps(walSize: nil, shmExists: false, database: nil, playlistsXML: nil) },
                                        writeLock: .live(RekordboxWriteLocks(folder: home.url.appending(path: "locks"))),
                                        records: .live(home: home.url), pointSnapshot: { .satisfied }, appHolds: { [] },
                                        publish: { feed.update($0, $1) })
        let engine = AutoReflection(session: w.coordinator.session, ports: ports, run: .live)
        w.coordinator.engine = engine
        engine.start()
        #expect(await waitForState { feed.status == .interrupted(recoveryFailed: false) }, "시작 판정이 중단을 찾는다")
        await w.coordinator.restoreJournal()
        #expect(w.calls.restores.count == 1)
        #expect(await waitForState { feed.status == .stopped(.stoppedAfterRestore) }, "복원 뒤 자동 저장이 멈춘다(R8)")
        engine.stop()
        withExtendedLifetime((w, home)) {}
    }

    @Test func 엔진이_있으면_이대로_두기_뒤_기록을_다시_판정해_중단_안내가_사라진다() async throws {
        let w = world()
        let home = try TemporaryFolder(prefix: "djc-journal-keep-engine")
        let feed = w.coordinator.autoFeed
        let ports = AutoReflectionPorts(clock: .live, runState: { .stopped },
                                        quietStamps: { _ in LibraryQuietStamps(walSize: nil, shmExists: false, database: nil, playlistsXML: nil) },
                                        writeLock: .live(RekordboxWriteLocks(folder: home.url.appending(path: "locks"))),
                                        records: .live(home: home.url), pointSnapshot: { .satisfied }, appHolds: { [] },
                                        publish: { feed.update($0, $1) })
        let engine = AutoReflection(session: w.coordinator.session, ports: ports, run: .live)
        w.coordinator.engine = engine
        engine.start()
        #expect(await waitForState { feed.status == .interrupted(recoveryFailed: false) })
        await w.coordinator.keepJournal()
        #expect(await waitForState { feed.status == .saved && !feed.conditions.holds.contains { $0.kind == .interrupted } })
        engine.stop()
        withExtendedLifetime((w, home)) {}
    }
}
