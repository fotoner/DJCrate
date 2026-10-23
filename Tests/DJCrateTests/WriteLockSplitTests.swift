@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Synchronization
import Testing

/// #301: 쓰기 잠금을 용도별 값(`libraryBusy`·`editsFrozen`·`quitBlocked`)으로 나눴다. 지금은 셋이 원천 `isWritingRekordbox`와 같은 때
/// 켜지고 꺼져서 앱 동작이 그대로다. 실제 쓰기·복원 흐름의 쓰기 시작·미리 보기·확인 창·끝·실패·복원마다 그 사실을 묶는다.
/// 편집 잠금만 풀 때(1-4②) 이 시험의 기대를 그 값에 맞춰 바꾼다(그때까지 다른 값은 그대로여야 한다).
/// 실제 관문으로 합성 사본에 쓰고 되돌린다. 사용자 폴더는 쓰지 않아 `DJC_HOME`이 있을 때만 돈다.
@MainActor
@Suite("쓰기 잠금 용도별 값", .serialized, .enabled(if: LiveDraftHome.isIsolated))
struct WriteLockSplitTests {
    struct ProbeFailure: Error {}

    /// 한 순간의 잠금 값. `writing`은 원천(`isWritingRekordbox`)이다.
    struct Sample: Equatable, CustomStringConvertible {
        var writing: Bool
        var libraryBusy: Bool
        var editsFrozen: Bool
        var quitBlocked: Bool
        /// 종료·업데이트 판단이 지금 읽는 값(`writeActivity`, #300이 `quitBlocked`로 바꾼다)
        var quitActivity: Bool
        /// 덱 쪽 복사본(`onWriteLock`으로 받는다)
        var deckFrozen: Bool

        @MainActor init(_ store: LibraryStore, _ deck: DeckModel) {
            writing = store.isWritingRekordbox
            libraryBusy = store.libraryBusy
            editsFrozen = store.editsFrozen
            quitBlocked = store.quitBlocked
            quitActivity = store.writeActivity.writingRekordbox
            deckFrozen = deck.editsFrozen
        }

        /// 모든 값이 원천과 같은 때 켜지고 꺼진다
        var follows: Bool {
            libraryBusy == writing && editsFrozen == writing && quitBlocked == writing && quitActivity == writing && deckFrozen == writing
        }

        var description: String {
            "원천 \(writing) · libraryBusy \(libraryBusy) · editsFrozen \(editsFrozen) · quitBlocked \(quitBlocked) · 종료 판단 \(quitActivity) · 덱 \(deckFrozen)"
        }
    }

    /// 흐름 한가운데서 잠금 값을 잰다(재는 곳 이름과 값을 차례로 남긴다)
    @MainActor
    final class LockProbe {
        let store: LibraryStore
        let deck: DeckModel
        private(set) var samples: [(phase: String, sample: Sample)] = []

        init(store: LibraryStore, deck: DeckModel) {
            self.store = store
            self.deck = deck
        }

        func take(_ phase: String) { samples.append((phase, Sample(store, deck))) }
    }

    /// 관문 동기 입구(쓰기·복원)를 멈춰 두고 시험이 메인 액터에서 잠금 값을 잰 뒤 풀어 준다(세션은 협력 풀 밖 `BlockingWork`로 부른다).
    /// 닿지 않을 입구는 `open()`으로 준다: 닿아도 멈추지 않아 시험이 매달리지 않고 단계 기대에서 실패한다.
    final class GatePause: Sendable {
        private let entered = Mutex(false)
        private let resume = DispatchSemaphore(value: 0)
        static func open() -> GatePause {
            let pause = GatePause()
            pause.release()
            return pause
        }
        var hasEntered: Bool { entered.withLock { $0 } }
        func arrive() {
            entered.withLock { $0 = true }
            resume.wait()
        }
        func release() { resume.signal() }
    }

    /// 확인 창 대신 정해 둔 답을 주고, 창이 뜬 순간의 잠금 값을 잰다
    @MainActor
    final class ProbingPrompter: HeadlessReflectionPrompter {
        let probe: LockProbe
        var answer = true
        init(probe: LockProbe) { self.probe = probe }
        func show(_ prompt: ReflectionPrompt) -> Bool {
            probe.take("확인 창")
            return answer
        }
    }

    /// 실제 관문을 감싸 미리 보기·쓰기·복원 한가운데서 잠금 값을 재게 한다. `failAt`이면 그 단계에서 실패한다.
    static func probing(_ live: RekordboxWriteGate, probe: LockProbe, write: GatePause = .open(), restore: GatePause = .open(),
                        failAt: String? = nil) -> RekordboxWriteGate {
        var gate = live
        let livePreview = live.preview, liveWrite = live.write, liveRestore = live.restore
        gate.preview = { batch, inputs, target, copied in
            await probe.take("미리 보기")
            if failAt == "미리 보기" { throw ProbeFailure() }
            return try await livePreview(batch, inputs, target, copied)
        }
        gate.write = { batch, inputs, target, dryRun in
            if !dryRun {
                write.arrive()
                if failAt == "쓰기" { throw ProbeFailure() }
            }
            return try liveWrite(batch, inputs, target, dryRun)
        }
        gate.restore = { backup, target in
            restore.arrive()
            return try liveRestore(backup, target)
        }
        return gate
    }

    /// 합성 사본의 곡 하나에 큐 초안이 있는 저장소와 덱. 덱은 앱과 같은 연결(`AppComposition.connect`)로 잠금을 받는다.
    @MainActor
    struct Rig {
        let fixture: RekordboxFixture
        let store: LibraryStore
        let deck: DeckHarness
        let probe: LockProbe
        let track: TrackSpec
        let writer: DraftWriter

        var row: TrackRow { store.rowsByUUID[track.uuid]! }

        init(backups: URL? = nil) async throws {
            fixture = try RekordboxFixture()
            track = TrackSpec()
            try fixture.add(track)
            writer = DraftWriter()
            store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("lock-split"), persist: false),
                                            activityLog: ActivityLog(url: nil), feedback: AppFeedback(announce: { _ in }),
                                            backupDirectory: backups ?? fixture.backups,
                                            playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                            draftHome: fixture.root.appending(path: "drafts"),
                                            rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                                            arguments: ["test"], environment: [:],
                                            takeLiveSnapshot: { [database = fixture.database] _ in database }, writer: writer)
            await store.load(snapshot: fixture.database)
            var draft = CueDraft(trackUUID: track.uuid)
            draft.place(EditableCue(kind: .memory, time: 4))
            writer.save(draft, directory: store.draftLocations.cue)
            writer.flush()
            store.setDraftMark(.cue, trackUUID: track.uuid, exists: true)
            deck = try DeckHarness()
            try await deck.loaded()
            store.onWriteLock = { [weak deck = deck.deck] locked in deck?.editsFrozen = locked }
            probe = LockProbe(store: store, deck: deck.deck)
        }
    }

    static func expect(_ probe: LockProbe, _ expected: KeyValuePairs<String, Bool>, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(probe.samples.map(\.phase) == expected.map(\.key), "재는 곳: \(probe.samples.map(\.phase))", sourceLocation: sourceLocation)
        for ((phase, sample), (_, writing)) in zip(probe.samples, expected) {
            #expect(sample.writing == writing, "\(phase)에서 원천이 \(writing)이어야 한다: \(sample)", sourceLocation: sourceLocation)
            #expect(sample.follows, "\(phase)에서 세 값이 원천과 같아야 한다: \(sample)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - 쓰기·복원

    @Test func 쓰기와_복원은_처음부터_끝까지_세_값이_같이_켜지고_꺼진다() async throws {
        let rig = try await Rig()
        let write = GatePause(), restore = GatePause()
        let prompter = ProbingPrompter(probe: rig.probe)
        let coordinator = ReflectionCoordinator.test(store: rig.store, prompter: prompter,
                                                     gate: Self.probing(.live(), probe: rig.probe, write: write, restore: restore))
        rig.probe.take("시작 전")
        let writing = Task { await coordinator.write(rows: [rig.row]) }
        #expect(await waitForState(until: { write.hasEntered }), "관문 쓰기에 닿지 못함")
        rig.probe.take("쓰기 중")
        write.release()
        await writing.value
        rig.probe.take("쓰기 끝")
        #expect(rig.store.toast?.undoBackup != nil, "합성 사본에 써서 되돌릴 백업이 남아야 한다")

        let backups = rig.store.session.writeBackups()
        let backup = try #require(backups.first { $0.isWrite })
        let restoring = Task { await coordinator.restore(backup) }
        #expect(await waitForState(until: { restore.hasEntered }), "관문 복원에 닿지 못함")
        rig.probe.take("복원 중")
        restore.release()
        await restoring.value
        rig.probe.take("복원 끝")

        // 쓰기 흐름에는 확인 창이 없다(막힘·제외·손실이 없다). 복원은 늘 묻는다.
        Self.expect(rig.probe, ["시작 전": false, "미리 보기": true, "쓰기 중": true, "쓰기 끝": false,
                                "확인 창": true, "복원 중": true, "복원 끝": false])
    }

    @Test func 쓰기_전_확인_창이_뜨는_동안에도_잠겨_있고_거절하면_풀린다() async throws {
        // 쓰기 전 백업 폴더에 쓸 수 없으면 묻는다(noBackup). 거절하면 쓰지 않는다.
        let readOnly = FileManager.default.temporaryDirectory.appending(path: "djc-lock-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
            try? FileManager.default.removeItem(at: readOnly)
        }
        let rig = try await Rig(backups: readOnly.appending(path: "backups"))
        let prompter = ProbingPrompter(probe: rig.probe)
        prompter.answer = false
        let coordinator = ReflectionCoordinator.test(store: rig.store, prompter: prompter, gate: Self.probing(.live(), probe: rig.probe))
        rig.probe.take("시작 전")
        await coordinator.write(rows: [rig.row])
        rig.probe.take("거절 뒤")
        Self.expect(rig.probe, ["시작 전": false, "미리 보기": true, "확인 창": true, "거절 뒤": false])
        #expect(rig.store.toast?.undoBackup == nil, "거절했으니 쓰지 않았다")
    }

    // MARK: - 실패

    @Test func 미리_보기가_실패해도_잠금은_세_값_모두_풀린다() async throws {
        let rig = try await Rig()
        let coordinator = ReflectionCoordinator.test(store: rig.store, prompter: ProbingPrompter(probe: rig.probe),
                                                     gate: Self.probing(.live(), probe: rig.probe, failAt: "미리 보기"))
        rig.probe.take("시작 전")
        await coordinator.write(rows: [rig.row])
        rig.probe.take("실패 뒤")
        Self.expect(rig.probe, ["시작 전": false, "미리 보기": true, "실패 뒤": false])
        #expect(rig.store.toast?.kind == .failure)
    }

    @Test func 쓰기가_실패해도_잠금은_세_값_모두_풀린다() async throws {
        let rig = try await Rig()
        let write = GatePause()
        let coordinator = ReflectionCoordinator.test(store: rig.store, prompter: ProbingPrompter(probe: rig.probe),
                                                     gate: Self.probing(.live(), probe: rig.probe, write: write, failAt: "쓰기"))
        rig.probe.take("시작 전")
        let writing = Task { await coordinator.write(rows: [rig.row]) }
        #expect(await waitForState(until: { write.hasEntered }), "관문 쓰기에 닿지 못함")
        rig.probe.take("쓰기 중")
        write.release()
        await writing.value
        rig.probe.take("실패 뒤")
        Self.expect(rig.probe, ["시작 전": false, "미리 보기": true, "쓰기 중": true, "실패 뒤": false])
        #expect(rig.store.toast?.kind == .failure)
    }

    // MARK: - 덱을 잠그지 않는 잠금

    /// iTunes 동기화는 라이브러리만 잠그고 덱은 잠그지 않는다(덱 초안을 건드리지 않아 재생·실행 취소 이력이 그대로다).
    /// 덱 쪽 복사본만 다르고 저장소의 세 값은 같다.
    @Test func 덱을_잠그지_않는_잠금은_저장소의_세_값만_켠다() async throws {
        let rig = try await Rig()
        rig.store.setWriteLock(true, deck: false)
        let locked = Sample(rig.store, rig.deck.deck)
        rig.store.setWriteLock(false, deck: false)
        let unlocked = Sample(rig.store, rig.deck.deck)
        #expect(locked.writing && locked.libraryBusy && locked.editsFrozen && locked.quitBlocked && locked.quitActivity, "\(locked)")
        #expect(!locked.deckFrozen, "덱은 잠그지 않는다: \(locked)")
        #expect(unlocked.follows && !unlocked.writing, "\(unlocked)")
    }
}
