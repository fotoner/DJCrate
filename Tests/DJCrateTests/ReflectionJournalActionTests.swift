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
               store existing: LibraryStore? = nil) -> World {
        let folder = home ?? FileManager.default.temporaryDirectory.appending(path: "djc-journal-action-\(UUID().uuidString)")
        let store = existing ?? LibraryStore.test(activityLog: ActivityLog(), saveTagDrafts: { _ in }, draftHome: folder, movesDamagedDrafts: false,
                                                 takeLiveSnapshot: { _ in throw DJCError.snapshotNotFound })
        store.phase = .loaded
        let calls = Calls()
        let stamp = RekordboxFileStamp(size: 100, modifiedNanoseconds: 200)
        var journal = RekordboxWriteJournal(operationID: "op-1", kind: .counter, entry: .drafts, startCounter: 5)
        if let draft {
            journal.drafts = .init(home: folder.path, written: [WrittenDraft(key: draft.key, revision: draft.revision, contentHash: draft.hash)])
        }
        let finding = RekordboxJournalFinding(journal: journal, changedSince: changedSince, database: stamp)
        var gate = RekordboxWriteGate.restoringOnly
        gate.journal = { _, _ in calls.present ? .interrupted(finding) : .none }
        gate.restoreJournal = { _, request in try calls.restoreCalled(request).get() }
        gate.keepJournal = { _, request, apply in
            guard calls.present else { return .nothing }
            calls.keepCalled(request)
            try apply()
            calls.cleared()
            return .kept
        }
        let list = DraftCleanupList(operationID: "op-1", target: RekordboxWriteLockKey(device: 1, inode: 2), draftHome: folder.path, backupFolder: "b")
        gate.cleanupLists = { _, _ in [list] }
        gate.removeCleanupList = { list, _ in calls.removed(list.operationID) }
        let prompter = ScriptedPrompter()
        let coordinator = ReflectionCoordinator.test(store: store, prompter: prompter, gate: gate)
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
