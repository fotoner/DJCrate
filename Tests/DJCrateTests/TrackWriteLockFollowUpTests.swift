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

/// 쓰는 곡만 잠그기(#401) 리뷰 1라운드: 저장 뒤 덱·⌘Z·읽기 틈, 곡 없는 묶음, 취소 자리, 중복 후보.
/// 잠금은 세션과 같은 순서(곡 → 초안 쓰기 → 쓰는 중)로 쓰기 포트에 건다. 실제 관문 시험은 합성 사본에만 쓰므로 `DJC_HOME`이 있을 때만 돈다.
@MainActor
@Suite("쓰는 곡만 잠그기 — 리뷰 1라운드", .serialized)
struct TrackWriteLockFollowUpTests {
    // MARK: - 재료

    /// 쓰는 곡 하나(분석한 곡, 그림 없음)와 다른 곡 하나가 든 합성 사본, 그 저장소
    @MainActor
    struct Rig {
        let fixture: RekordboxFixture
        let store: LibraryStore
        let writing: TrackSpec
        let other: TrackSpec
        let writer = DraftWriter()

        var writingRow: TrackRow { store.rowsByUUID[writing.uuid]! }
        var otherRow: TrackRow { store.rowsByUUID[other.uuid]! }

        /// 켜면 쓴 뒤 다시 읽기(스냅샷 뜨기)가 실패한다
        let failingSnapshots = TestSwitch()

        init() async throws {
            fixture = try RekordboxFixture()
            var first = TrackSpec()
            first.analysisDataPath = "/PIONEER/USBANLZ/\(first.uuid.prefix(3))/\(first.uuid.dropFirst(3))/ANLZ0000.DAT"
            first.imagePath = ""
            writing = first
            try fixture.add(first)
            other = TrackSpec()
            try fixture.add(other)
            let writer = writer, failing = failingSnapshots
            store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("lock-round1"), persist: false),
                                      activityLog: ActivityLog(url: nil), feedback: AppFeedback(announce: { _ in }),
                                      backupDirectory: fixture.backups,
                                      playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                      draftHome: fixture.root.appending(path: "drafts"),
                                      rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot,
                                      arguments: ["test"], environment: [:],
                                      takeLiveSnapshot: { [database = fixture.database] _ in
                                          if failing.isOn { throw DJCError.writeRefused("합성 읽기 실패") }
                                          return database
                                      }, writer: writer)
            await store.load(snapshot: fixture.database)
        }

        /// 쓰는 곡에 큐 초안을 둔다
        func addCueDraft() {
            var draft = CueDraft(trackUUID: writing.uuid)
            draft.place(EditableCue(kind: .memory, time: 4))
            writer.save(draft, directory: store.draftLocations.cue)
            writer.flush()
            store.setDraftMark(.cue, trackUUID: writing.uuid, exists: true)
        }
    }

    /// 쓰기 관문의 쓰기에서 멈춰 둔다(시험이 그 사이에 화면 조작을 한 뒤 푼다)
    static func pausing(_ live: RekordboxWriteGate, at pause: WriteLockSplitTests.GatePause) -> RekordboxWriteGate {
        var gate = live
        let liveWrite = live.write
        gate.write = { batch, inputs, target, dryRun in
            if !dryRun { pause.arrive() }
            return try liveWrite(batch, inputs, target, dryRun)
        }
        return gate
    }

    // MARK: - S1 그림을 쓴 곡이 덱에서 재생 중이어도 곡을 다시 불러오지 않는다

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 재생_중인_곡의_앨범아트를_저장해도_덱은_소리를_다시_열지_않고_재생을_이어_간다() async throws {
        let rig = try await Rig()
        let store = rig.store
        let row = rig.writingRow
        ArtworkInspectorModel(store: store).setArtwork(ImageFixture.image(width: 64, height: 48), name: "표지.jpg", rows: [row])
        #expect(store.artworkDrafts[row.track.uuid] != nil)

        let h = try DeckHarness()
        h.deck.load(row)
        try await h.loaded()
        store.connectWriteLocks(to: h.deck)
        store.onLoadToDeck = { [weak deck = h.deck] in deck?.load($0) }
        store.setDeckTrack(row)
        h.deck.togglePlay()
        #expect(h.deck.isPlaying && h.audio.isPlaying && h.deck.row?.track.imagePath == "")
        let calls = h.audio.log

        _ = await store.session.write(rows: [row], playlists: false)
        let written = try #require(store.rowsByUUID[row.track.uuid])
        #expect(written.track.imagePath != "", "그림을 쓰면 rekordbox 곡 행의 그림 경로가 바뀐다")
        #expect(h.deck.row?.track.imagePath == written.track.imagePath, "덱은 새 값으로 맞췄다")
        #expect(h.deck.isPlaying && h.audio.isPlaying, "재생은 이어졌다")
        let added = h.audio.log.dropFirst(calls.count)
        #expect(!added.contains { $0 == "load" || $0 == "stop" || $0 == "pause" || $0.hasPrefix("play") },
                "소리를 다시 열거나 멈추거나 다시 재생하는 호출이 하나도 없다: \(Array(added))")
    }

    // MARK: - S2 쓰기 뒤 덱 갱신이 끝나기 전에는 그 곡의 편집을 풀지 않는다

    /// 덱의 읽기(큐 초안)를 붙잡아 두는 장치(메인 밖 읽기가 쓰기 잠금이 풀린 뒤에 도착하는 틈을 만든다)
    final class ReloadGate: Sendable {
        private let armed = Mutex(false)
        private let entered = Mutex(false)
        private let resume = DispatchSemaphore(value: 0)

        private let firstOnly = Mutex(false)

        func arm() { armed.withLock { $0 = true } }
        /// 처음 한 번만 붙잡는다(뒤 읽기는 바로 지나간다)
        func armFirstOnly() {
            firstOnly.withLock { $0 = true }
            armed.withLock { $0 = true }
        }
        var hasEntered: Bool { entered.withLock { $0 } }

        func pass() {
            guard armed.withLock({ $0 }) else { return }
            if firstOnly.withLock({ $0 }) { armed.withLock { $0 = false } }
            entered.withLock { $0 = true }
            resume.wait()
        }

        func open() {
            armed.withLock { $0 = false }
            resume.signal()
        }
    }

    static func track(cues: [Cue]) -> TrackRow {
        TrackRow(track: Track(id: "1", uuid: "track-1", title: "시험 곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                              composer: nil, releaseYear: nil, trackNumber: nil, key: "8B", bpm: 120, lengthSeconds: 180,
                              folderPath: "/tmp/djc-lock-round1/silence.wav", comment: "", importedOn: nil, analysisDataPath: nil,
                              imagePath: nil, isDeleted: false),
                 cues: cues, playCount: 0)
    }

    @Test func 저장한_곡의_새_초안을_덱에_적용하기_전에는_잠금이_풀려도_그_곡_편집을_막는다() async throws {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let audio = FakeDeckAudio()
        let drafts = MemoryDrafts()
        let storage = DeckStorage.memory(drafts)
        var reader = TrackAssetReader.memory(storage)
        let gate = ReloadGate()
        let baseCueDraft = reader.cueDraft
        reader.cueDraft = { uuid in
            gate.pass()
            return baseCueDraft(uuid)
        }
        let deck = DeckModel.test(audio: audio, storage: storage, reader: reader, runsAnalysis: false)
        store.connectWriteLocks(to: deck)
        deck.load(Self.track(cues: []))
        for _ in 0..<200 where deck.draft == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(deck.draft?.cues.isEmpty == true)

        // 쓰는 중: 곡을 잠그고, 저장 뒤 새 스냅샷(새 큐)을 읽어 덱에 알린다. 덱의 읽기는 아직 도착하지 않았다
        let lock = store.reflection.session.ports.lock
        lock.setTracks(["track-1"])
        lock.setDraftWriting(true)
        lock.set(true, false)
        let written = Cue(id: "N1", contentID: "1", kind: 1, inMsec: 8000, name: "", colorTableIndex: 0)
        let newRow = Self.track(cues: [written])
        store.rowsByUUID["track-1"] = newRow
        gate.arm()
        store.onRekordboxWritten?(["track-1"])
        #expect(await waitForState(until: { gate.hasEntered }), "덱의 새 값 읽기가 시작되지 않았다")

        // 세션이 곡 잠금을 푼다
        lock.set(false, false)
        lock.setDraftWriting(false)
        lock.setTracks([])
        #expect(store.lockedTracks.isEmpty && !store.isEditLocked("track-1"))
        #expect(deck.isEditLocked, "덱은 새 초안·기준값을 적용할 때까지 그 곡의 편집을 막는다")
        deck.addMemoryCue(at: 40.5)
        #expect(deck.draft?.cues.isEmpty == true, "쓰기 전 기준값의 초안에는 편집이 들어가지 않는다")

        // 늦은 읽기가 도착해 적용되면 그때 풀린다
        gate.open()
        #expect(await waitForState(until: { !deck.isEditLocked }), "덱의 갱신이 끝나도 잠금이 풀리지 않았다")
        #expect(deck.draft?.cues.count == 1 && deck.row == newRow, "쓴 뒤 값이 기준이다")
        deck.addMemoryCue(at: 40.5)
        #expect(deck.draft?.cues.count == 2, "해제 직후 편집은 새 기준 위에 쌓이고 늦은 읽기가 덮지 않는다")
        try await Task.sleep(for: .milliseconds(100))
        #expect(deck.draft?.cues.count == 2)
    }

    // MARK: - S2(2라운드) 저장은 됐는데 다시 읽기가 실패해도 다음 성공한 읽기까지 덱 편집을 막는다

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 저장은_됐는데_다시_읽기가_실패하면_다음_성공한_읽기까지_그_곡_덱_편집을_막는다() async throws {
        let rig = try await Rig()
        rig.addCueDraft()
        let store = rig.store
        let row = rig.writingRow
        let h = try DeckHarness()
        h.deck.load(row)
        try await h.loaded()
        store.connectWriteLocks(to: h.deck)
        store.onLoadToDeck = { [weak deck = h.deck] in deck?.load($0) }
        store.setDeckTrack(row)
        #expect(h.deck.draft?.cues.isEmpty == true)

        rig.failingSnapshots.set(true)
        let outcome = await store.session.write(rows: [row], playlists: false)
        guard case .written = outcome else { Issue.record("저장이 성공하지 못했다: \(outcome)"); return }
        #expect(!store.libraryBusy && store.lockedTracks.isEmpty, "쓰기 잠금은 풀렸다")
        #expect(store.writtenAwaitingReload == [row.track.uuid], "새 스냅샷을 받지 못해 알릴 곡이 남았다")
        #expect(h.deck.isEditLocked, "새 기준값을 받지 못한 곡은 덱 편집을 막는다")
        h.deck.addMemoryCue(at: 40.5)
        #expect(h.deck.draft?.cues.isEmpty == true, "쓰기 전 기준값의 초안에는 편집이 들어가지 않는다")

        // 다음 읽기가 성공하면 새 기준값을 적용하고 푼다
        rig.failingSnapshots.set(false)
        await store.takeSnapshot(quiet: true, refreshITunes: false)
        #expect(await waitForState(until: { !h.deck.isEditLocked }), "읽기가 성공해도 덱 편집이 풀리지 않았다")
        #expect(store.writtenAwaitingReload.isEmpty)
        #expect(h.deck.draft?.cues.count == 1 && h.deck.draft?.hasChanges == false, "쓴 큐가 rekordbox 값이 된 새 기준이다")
        h.deck.addMemoryCue(at: 40.5)
        #expect(h.deck.draft?.cues.count == 2)
    }

    // MARK: - S10 쓰는 도중 덱에 올린 곡의 최초 읽기가 저장 뒤 갱신보다 늦게 끝나도 옛 값을 적용하지 않는다

    @Test func 최초_불러오기가_저장_뒤_갱신보다_늦게_끝나도_옛_큐와_기준값을_적용하지_않는다() async throws {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let audio = FakeDeckAudio()
        let drafts = MemoryDrafts()
        let storage = DeckStorage.memory(drafts)
        var reader = TrackAssetReader.memory(storage)
        let gate = ReloadGate()
        let baseCueDraft = reader.cueDraft
        reader.cueDraft = { uuid in
            gate.pass()
            return baseCueDraft(uuid)
        }
        let deck = DeckModel.test(audio: audio, storage: storage, reader: reader, runsAnalysis: false)
        store.connectWriteLocks(to: deck)

        // 쓰는 도중 그 곡을 덱에 올린다. 최초 읽기(큐 초안)가 쓰기 전 곡 행으로 시작해 붙잡힌다
        let lock = store.reflection.session.ports.lock
        lock.setTracks(["track-1"])
        lock.setDraftWriting(true)
        lock.set(true, false)
        gate.armFirstOnly()
        deck.load(Self.track(cues: []))
        #expect(await waitForState(until: { gate.hasEntered }), "최초 읽기가 시작되지 않았다")

        // 쓰기가 끝나고 새 스냅샷의 곡 행으로 저장 뒤 갱신이 먼저 적용된다
        let written = Cue(id: "N1", contentID: "1", kind: 1, inMsec: 8000, name: "", colorTableIndex: 0)
        let newRow = Self.track(cues: [written])
        store.rowsByUUID["track-1"] = newRow
        store.onRekordboxWritten?(["track-1"])
        #expect(await waitForState(until: { deck.draft?.cues.count == 1 }), "저장 뒤 갱신이 적용되지 않았다")
        lock.set(false, false)
        lock.setDraftWriting(false)
        lock.setTracks([])
        #expect(await waitForState(until: { !deck.isEditLocked }))

        // 늦게 끝난 최초 읽기는 옛 곡 행의 큐·기준값이라 적용하지 않는다
        gate.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(deck.draft?.cues.count == 1 && deck.row == newRow, "덱의 큐·기준값은 저장 뒤 값이다")
        #expect(deck.canPlay, "이미 열린 음원은 그대로다")
        deck.addMemoryCue(at: 40.5)
        #expect(deck.draft?.cues.count == 2)
    }

    // MARK: - S3 재생 목록만 쓰는 묶음(세션)은 TrackWriteLockTests와 ReflectionSession 시험이 본다

    // MARK: - S4 저장 중 다른 곡의 ⌘Z는 저장 뒤에도 된다

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 저장_중_다른_곡의_태그_편집은_저장_뒤에도_되돌릴_수_있다() async throws {
        let rig = try await Rig()
        rig.addCueDraft()
        let store = rig.store
        let undo = UndoManager()
        store.undoManager = undo
        let other = rig.otherRow
        let pause = WriteLockSplitTests.GatePause()
        let coordinator = ReflectionCoordinator.test(store: store, gate: Self.pausing(.live(), at: pause))
        let writing = Task { await coordinator.write(rows: [rig.writingRow]) }
        #expect(await waitForState(until: { pause.hasEntered }), "관문 쓰기에 닿지 못함")
        #expect(store.lockedTracks == [rig.writing.uuid] && !store.isEditLocked(other.track.uuid))
        store.tags.setTag(.title, "저장 중에 고친 제목", rows: [other])
        #expect(store.tagDrafts[other.track.uuid]?.hasChanges == true && undo.canUndo)
        pause.release()
        await writing.value

        #expect(!store.libraryBusy && store.lockedTracks.isEmpty)
        #expect(undo.canUndo, "다른 곡의 ⌘Z 기록은 저장 뒤 읽기가 지우지 않는다")
        #expect(store.tagDrafts[other.track.uuid]?.hasChanges == true, "저장 뒤에도 편집은 남는다")
        undo.undo()
        #expect(store.tagDrafts[other.track.uuid]?.hasChanges != true, "⌘Z로 되돌려진다")
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 재생_목록만_저장하는_동안_고친_다른_곡_태그_되돌리기는_저장_뒤에도_된다() async throws {
        let rig = try await Rig()
        let store = rig.store
        let undo = UndoManager()
        store.undoManager = undo
        let other = rig.otherRow
        // 재생 목록·재생 기록만 쓰는 묶음: 곡이 없고 쓴 곡 집합도 비어 있다(초안 쓰기 표시만 있다)
        let lock = store.reflection.session.ports.lock
        lock.setTracks([])
        lock.setDraftWriting(true)
        lock.set(true, false)
        store.tags.setTag(.title, "저장 중에 고친 제목", rows: [other])
        #expect(store.tagDrafts[other.track.uuid]?.hasChanges == true && undo.canUndo)
        // 쓴 뒤 다시 읽기(세션이 쓰는 동안 부른다)
        let reloaded = await store.reloadAfterWrite(written: [], playlistEdits: [])
        #expect(reloaded)
        lock.set(false, false)
        lock.setDraftWriting(false)
        lock.setTracks([])
        #expect(undo.canUndo, "저장한 곡이 없어도 초안 쓰기 뒤 읽기는 다른 곡의 ⌘Z를 지우지 않는다")
        undo.undo()
        #expect(store.tagDrafts[other.track.uuid]?.hasChanges != true)
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 초안_쓰기가_아닌_다시_읽기는_되돌리기_기록을_통째로_지운다() async throws {
        let rig = try await Rig()
        let store = rig.store
        let undo = UndoManager()
        store.undoManager = undo
        store.tags.setTag(.title, "고친 제목", rows: [rig.otherRow])
        #expect(undo.canUndo)
        await store.takeSnapshot(quiet: true, refreshITunes: false)
        #expect(!undo.canUndo, "일반 읽기(동기화)는 옛 기준의 ⌘Z 기록을 지운다")
    }

    // MARK: - S5 잠긴 곡과 잠기지 않은 곡을 함께 고르면

    @Test func 잠긴_곡과_잠기지_않은_곡을_함께_고르면_잠기지_않은_곡만_편집_대상이다() {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let model = TagInspectorModel(store: store)
        let locked = TagInspectorModelTests.row("a"), open = TagInspectorModelTests.row("b")
        let lock = store.reflection.session.ports.lock
        lock.setTracks([locked.track.uuid])
        lock.setDraftWriting(true)
        lock.set(true, false)
        #expect(!model.isWriteLocked([locked, open]), "하나라도 잠기지 않았으면 인스펙터를 통째로 막지 않는다")
        #expect(model.writableRows([locked, open]).map(\.id) == [open.id])
        #expect(model.isWriteLocked([locked]) && model.writableRows([locked]).isEmpty)
        #expect(!model.isWriteLocked([]), "고른 곡이 없으면 막을 것이 없다")
        // 값 표시와 편집이 같은 대상 집합을 쓴다: 잠긴 곡의 값은 섞이지 않고, 편집은 잠기지 않은 곡에만 간다
        let targets = model.writableRows([locked, open])
        model.setText(.title, "새 제목", rows: targets)
        #expect(Set(store.tagDrafts.keys) == [open.track.uuid])
        #expect(model.field(.title, rows: targets) == TagInspectorModel.Field(value: "새 제목", mixed: false, edited: true))
        lock.set(false, false)
        lock.setDraftWriting(false)
        lock.setTracks([])
        #expect(model.writableRows([locked, open]).count == 2)
    }

    // MARK: - S9 입력을 시작할 때 대상 곡을 고정한다

    @Test func 입력을_시작할_때_대상을_고정해_잠금이_풀린_뒤_확정해도_처음_대상에만_들어간다() {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let model = TagInspectorModel(store: store)
        let a = TagInspectorModelTests.row("a"), b = TagInspectorModelTests.row("b")
        let lock = store.reflection.session.ports.lock
        lock.setTracks([a.track.uuid])
        lock.setDraftWriting(true)
        lock.set(true, false)
        // A·B를 골랐는데 A가 쓰는 곡이다: B의 제목을 입력하기 시작한다
        model.beginInput(.title, rows: [a, b])
        // 입력하는 사이 A의 쓰기가 끝나 잠금이 풀린다
        lock.set(false, false)
        lock.setDraftWriting(false)
        lock.setTracks([])
        // Return을 누르면 화면은 이제 둘 다 편집 대상으로 보지만, 입력을 시작할 때의 대상(B)에만 들어간다
        model.commitText(.title, "B만 바꾼 제목", rows: [a, b])
        #expect(Set(store.tagDrafts.keys) == [b.track.uuid], "입력 중에 풀린 A에는 들어가지 않는다")
        // 확정하면 고정은 풀린다: 다음 입력은 그때의 대상을 쓴다
        model.commitText(.title, "둘 다", rows: [a, b])
        #expect(Set(store.tagDrafts.keys) == [a.track.uuid, b.track.uuid])
    }

    @Test func 입력을_시작할_때_대상이던_곡이_확정_전에_잠기면_그_곡은_빠진다() {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let model = TagInspectorModel(store: store)
        let a = TagInspectorModelTests.row("a"), b = TagInspectorModelTests.row("b")
        model.beginInput(.title, rows: [a, b])
        let lock = store.reflection.session.ports.lock
        lock.setTracks([a.track.uuid])
        lock.setDraftWriting(true)
        lock.set(true, false)
        model.commitText(.title, "새 제목", rows: [a, b])
        #expect(Set(store.tagDrafts.keys) == [b.track.uuid], "확정할 때 아직 편집할 수 있는 곡에만 들어간다")
        lock.set(false, false)
        lock.setDraftWriting(false)
        lock.setTracks([])
    }

    // MARK: - S7 곡 단위 쓰기에는 덮개 대신 작은 진행·취소 자리가 있다

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 곡_단위_쓰기_중_취소_동작은_세션_쓰기를_취소하고_잠금을_푼다() async throws {
        let rig = try await Rig()
        rig.addCueDraft()
        let store = rig.store
        var gate = RekordboxWriteGate.live()
        gate.preview = { _, _, _, _ in
            try await Task.sleep(for: .seconds(120))
            throw CancellationError()
        }
        let coordinator = ReflectionCoordinator.test(store: store, gate: gate)
        coordinator.startWrite(rows: [rig.writingRow])
        #expect(await waitForState(until: { store.writeStage?.cancellable == true }), "미리 보기 단계에 닿지 못함")
        #expect(store.libraryBusy && store.lockedTracks == [rig.writing.uuid])
        #expect(!store.showsWriteOverlay, "곡 단위 쓰기는 창을 덮지 않는다")
        #expect(store.showsWriteProgressChip, "대신 작은 진행·취소 자리를 보인다")

        store.cancelWritePreparation()
        #expect(await waitForState(until: { store.writeTask == nil }), "취소가 세션 쓰기에 닿지 않았다")
        #expect(!store.libraryBusy && store.lockedTracks.isEmpty && store.writeStage == nil && !store.showsWriteProgressChip)
        #expect(!store.isEditLocked(rig.writing.uuid), "취소하면 곡 잠금도 풀린다")
    }

    @Test func 진행_취소_자리는_취소할_수_있는_단계에서만_곡_단위_쓰기_동안_보인다() {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let lock = store.reflection.session.ports.lock
        store.writeStage = WriteStage("바꿀 내용을 확인하는 중…", cancellable: true)
        #expect(!store.showsWriteProgressChip, "통째 잠금·쓰기 전에는 덮개가 맡는다")
        lock.setTracks(["uuid-a"])
        lock.setDraftWriting(true)
        lock.set(true, false)
        #expect(store.showsWriteProgressChip)
        store.writeStage = WriteStage("rekordbox에 저장하는 중…")
        #expect(!store.showsWriteProgressChip, "취소할 수 없는 단계는 상태 줄이 진행을 보인다")
        store.writeStage = nil
        lock.set(false, false)
        lock.setDraftWriting(false)
        lock.setTracks([])
    }

    // MARK: - S8 중복 후보 목록

    @Test func 곡_단위로_쓰는_동안에도_합치기_초안_버리기만_막고_나머지_후보_조작은_된다() throws {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let draft = DuplicateMergeDraft(keeping: .init(contentID: "m1", trackUUID: "m1", title: "남김", duration: 1, offset: 0, cues: []),
                                        removing: [.init(contentID: "r1", trackUUID: "r1", title: "뺌", duration: 1, offset: 0, cues: [])],
                                        base: "")
        try store.setMergeDrafts([draft])
        #expect(store.mergeDrafts.map(\.id) == [draft.id])
        let lock = store.reflection.session.ports.lock
        lock.setTracks(["uuid-a"])
        lock.setDraftWriting(true)
        lock.set(true, false)
        try store.discardMerge(draft.id)
        #expect(store.mergeDrafts.map(\.id) == [draft.id], "쓰는 동안 합치기 초안은 그대로다")
        #expect(!store.editsFrozen, "중복 후보 목록 전체를 막지 않는다")
        lock.set(false, false)
        lock.setDraftWriting(false)
        lock.setTracks([])
        try store.discardMerge(draft.id)
        #expect(store.mergeDrafts.isEmpty)
    }
}
