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

/// #301: 쓰기 잠금을 용도별 값(`libraryBusy`·`editsFrozen`·`quitBlocked`)으로 나눴다. 라이브러리 배타(`libraryBusy`)와 종료 판단(`quitBlocked`)은
/// 쓰는 동안 늘 원천 `isWritingRekordbox`와 같다. 편집 잠금은 쓰기 종류를 따른다(#401, R21):
/// 초안을 쓰면 곡 단위(쓰는 곡의 편집만 막고 덱은 재생을 이어 가며 창 덮개가 없다), 복원은 통째(편집 전체·덱 정지·덮개)다.
/// 실제 쓰기·복원 흐름의 쓰기 시작·미리 보기·확인 창·끝·실패·복원마다 그 사실을 묶는다.
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
        /// 곡 단위 잠금(`onLockedTracks`로 덱도 받는다)과 덱이 지금 곡의 편집을 막는지
        var lockedTracks: Set<String>
        var deckLockedTracks: Set<String>
        /// 덱이 재생 중인지(쓰기 잠금이 재생을 멈추지 않는다)
        var deckPlaying: Bool
        /// 쓰는 동안 창 전체를 덮는 진행 카드를 띄울 단계인지(`writeStage`가 있을 때)
        var overlay: Bool

        @MainActor init(_ store: LibraryStore, _ deck: DeckModel) {
            writing = store.isWritingRekordbox
            libraryBusy = store.libraryBusy
            editsFrozen = store.editsFrozen
            quitBlocked = store.quitBlocked
            quitActivity = store.writeActivity.writingRekordbox
            deckFrozen = deck.editsFrozen
            lockedTracks = store.lockedTracks
            deckLockedTracks = deck.lockedTracks
            deckPlaying = deck.isPlaying
            overlay = store.writeStage != nil && store.showsWriteOverlay
        }

        /// 잠금 종류별 기대. 라이브러리 배타·종료 판단은 늘 쓰는 중과 같다.
        enum Kind {
            /// 쓰는 중이 아니다
            case idle
            /// 초안을 쓴다(R21): 쓰는 곡의 편집만 막고 덱 재생·사이드바는 그대로, 덮개 없음
            case tracks(Set<String>)
            /// 복원·곡 넣기·빼기: 편집 전체와 덱을 막고 창 전체를 덮는다
            case whole
        }

        func matches(_ kind: Kind) -> Bool {
            let isWriting = libraryBusy == writing && quitBlocked == writing && quitActivity == writing
            switch kind {
            case .idle:
                return isWriting && !writing && !editsFrozen && !deckFrozen && lockedTracks.isEmpty && deckLockedTracks.isEmpty
            case let .tracks(uuids):
                return isWriting && writing && !editsFrozen && !deckFrozen && lockedTracks == uuids && deckLockedTracks == uuids && !overlay
            case .whole:
                return isWriting && writing && editsFrozen && deckFrozen && lockedTracks.isEmpty && deckLockedTracks.isEmpty
            }
        }

        var description: String {
            "원천 \(writing) · libraryBusy \(libraryBusy) · editsFrozen \(editsFrozen) · quitBlocked \(quitBlocked) · 종료 판단 \(quitActivity) · 덱 \(deckFrozen)"
                + " · 곡 잠금 \(lockedTracks.sorted()) · 덱 곡 잠금 \(deckLockedTracks.sorted()) · 덱 재생 \(deckPlaying) · 덮개 \(overlay)"
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
                if failAt == "저장" { throw ProbeFailure() }
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
            store.connectWriteLocks(to: deck.deck)
            // 덱이 재생 중이어도 초안 쓰기는 멈추지 않는다(R21). 복원은 멈춘다
            deck.deck.togglePlay()
            probe = LockProbe(store: store, deck: deck.deck)
        }
    }

    /// 재는 곳마다 기대하는 잠금 종류를 견준다(`Sample.Kind`)
    static func expect(_ probe: LockProbe, _ expected: KeyValuePairs<String, Sample.Kind>, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(probe.samples.map(\.phase) == expected.map(\.key), "재는 곳: \(probe.samples.map(\.phase))", sourceLocation: sourceLocation)
        for ((phase, sample), (_, kind)) in zip(probe.samples, expected) {
            #expect(sample.matches(kind), "\(phase)에서 \(kind)이어야 한다: \(sample)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - 쓰기·복원

    @Test func 쓰기와_복원은_처음부터_끝까지_잠금_종류에_맞게_켜지고_꺼진다() async throws {
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
        // 초안 쓰기는 곡 단위 잠금이다(쓰는 곡의 편집만 막고 덱 재생은 이어진다). 복원은 통째 잠금이다
        let tracks = Sample.Kind.tracks([rig.track.uuid])
        Self.expect(rig.probe, ["시작 전": .idle, "미리 보기": tracks, "쓰기 중": tracks, "쓰기 끝": .idle,
                                "확인 창": .whole, "복원 중": .whole, "복원 끝": .idle])
        // 초안을 쓰는 동안(미리 보기·쓰기 중) 덱은 재생을 멈추지 않았고, 복원하는 동안은 멈췄다
        let playing = rig.probe.samples.map { "\($0.phase)=\($0.sample.deckPlaying)" }
        #expect(playing == ["시작 전=true", "미리 보기=true", "쓰기 중=true", "쓰기 끝=true", "확인 창=false", "복원 중=false", "복원 끝=true"],
                "초안 쓰기는 재생을 멈추지 않고, 복원은 멈췄다 끝나면 이어 간다: \(playing)")
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
        Self.expect(rig.probe, ["시작 전": .idle, "미리 보기": .tracks([rig.track.uuid]), "확인 창": .tracks([rig.track.uuid]), "거절 뒤": .idle])
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
        Self.expect(rig.probe, ["시작 전": .idle, "미리 보기": .tracks([rig.track.uuid]), "실패 뒤": .idle])
        #expect(rig.store.toast?.kind == .failure)
    }

    @Test func 쓰기가_실패해도_잠금은_세_값_모두_풀린다() async throws {
        let rig = try await Rig()
        let write = GatePause()
        let coordinator = ReflectionCoordinator.test(store: rig.store, prompter: ProbingPrompter(probe: rig.probe),
                                                     gate: Self.probing(.live(), probe: rig.probe, write: write, failAt: "저장"))
        rig.probe.take("시작 전")
        let writing = Task { await coordinator.write(rows: [rig.row]) }
        #expect(await waitForState(until: { write.hasEntered }), "관문 쓰기에 닿지 못함")
        rig.probe.take("쓰기 중")
        write.release()
        await writing.value
        rig.probe.take("실패 뒤")
        Self.expect(rig.probe, ["시작 전": .idle, "미리 보기": .tracks([rig.track.uuid]), "쓰기 중": .tracks([rig.track.uuid]), "실패 뒤": .idle])
        #expect(rig.store.toast?.kind == .failure)
    }

    // MARK: - 덱을 잠그지 않는 잠금

    /// iTunes 동기화는 라이브러리만 잠그고 덱은 잠그지 않는다(덱 초안을 건드리지 않아 재생·실행 취소 이력이 그대로다).
    /// 덱 쪽 복사본만 다르고 저장소의 세 값은 같다(통째 편집 잠금이라 곡 잠금은 비어 있다).
    @Test func 덱을_잠그지_않는_잠금은_저장소의_세_값만_켠다() async throws {
        let rig = try await Rig()
        rig.store.setWriteLock(true, deck: false)
        let locked = Sample(rig.store, rig.deck.deck)
        rig.store.setWriteLock(false, deck: false)
        let unlocked = Sample(rig.store, rig.deck.deck)
        #expect(locked.writing && locked.libraryBusy && locked.editsFrozen && locked.quitBlocked && locked.quitActivity, "\(locked)")
        #expect(!locked.deckFrozen && locked.deckPlaying && locked.lockedTracks.isEmpty, "덱은 잠그지 않는다: \(locked)")
        #expect(unlocked.matches(.idle), "\(unlocked)")
    }
}
