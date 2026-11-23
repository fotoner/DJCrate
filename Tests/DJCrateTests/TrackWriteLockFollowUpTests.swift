@testable import DJCrate
import CoreGraphics
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
        /// 쓰는 곡도 `other`도 아닌 곡(바깥 CLI가 초안을 바꾸는 곡으로 쓴다)
        let third: TrackSpec
        let writer = DraftWriter()

        var writingRow: TrackRow { store.rowsByUUID[writing.uuid]! }
        var otherRow: TrackRow { store.rowsByUUID[other.uuid]! }
        var thirdRow: TrackRow { store.rowsByUUID[third.uuid]! }

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
            third = TrackSpec()
            try fixture.add(third)
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

    // MARK: - S13 최초 불러오기가 저장 뒤 갱신과 겹쳐도 파형·분석은 이어 간다

    /// 첫 호출만 붙잡는 비동기 문(읽기 도중 다른 갱신이 끼어드는 틈을 만든다)
    final class AsyncGate: Sendable {
        private struct State {
            var isOpen = false
            var entered = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }
        private let state = Mutex(State())
        private let calls = Mutex(0)

        var hasEntered: Bool { state.withLock { $0.entered } }

        /// 첫 호출은 열릴 때까지 기다리고, 뒤 호출은 바로 지나간다
        func passFirstCall() async {
            guard calls.withLock({ $0 += 1; return $0 }) == 1 else { return }
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    state.entered = true
                    if state.isOpen { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.isOpen = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    static func tinyArtwork() throws -> DeckArtwork {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return DeckArtwork(image: try #require(context.makeImage()))
    }

    @Test func 최초_불러오기_중_저장_뒤_갱신이_그림을_먼저_채워도_파형과_분석은_이어_간다() async throws {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let audio = FakeDeckAudio()
        let drafts = MemoryDrafts()
        let storage = DeckStorage.memory(drafts)
        var reader = TrackAssetReader.memory(storage)
        let artwork = try Self.tinyArtwork()
        let gate = AsyncGate()
        reader.embeddedArtwork = { _ in
            await gate.passFirstCall()
            return artwork
        }
        let waveforms = Mutex(0)
        let analyzer = TrackAnalyzer(
            waveform: { _, _ in waveforms.withLock { $0 += 1 }; return Waveform(rate: 1, duration: 0, low: [], mid: [], high: []) },
            sections: { _, _ in throw CocoaError(.fileNoSuchFile) },
            estimateGrid: { _, _ in nil }, sectionEnergies: { _ in [] }, memoryCueSuggestions: { _, _ in [] },
            keyWindows: { _, _ in [] }, keySegments: { _, _, _, _ in ([], nil) }, isMinor: { _, _, _ in false })
        let deck = DeckModel.test(audio: audio, storage: storage, reader: reader,
                                  analysis: AnalyzeDeckTrack(analyzer: analyzer, cache: MemoryAnalysisStore().store), runsAnalysis: true)
        store.connectWriteLocks(to: deck)

        // 쓰는 도중 덱에 올린다: 최초 불러오기가 음원 내장 그림을 읽다가 멈춘다
        deck.load(Self.track(cues: []))
        #expect(await waitForState(until: { gate.hasEntered }), "최초 불러오기가 그림 읽기에 닿지 않았다")
        #expect(deck.canPlay && deck.artwork == nil)

        // 저장 뒤 갱신이 먼저 끝나 그림을 채운다
        let newRow = Self.track(cues: [Cue(id: "N1", contentID: "1", kind: 1, inMsec: 8000, name: "", colorTableIndex: 0)])
        store.rowsByUUID["track-1"] = newRow
        store.onRekordboxWritten?(["track-1"])
        #expect(await waitForState(until: { deck.artwork != nil && !deck.isEditLocked }), "저장 뒤 갱신이 끝나지 않았다")

        // 늦게 풀린 최초 불러오기는 그림 적용만 건너뛰고 파형·분석을 이어 간다
        gate.open()
        await deck.loadTask?.value
        #expect(waveforms.withLock { $0 } == 1, "곡은 그대로인데 파형·분석이 시작되지 않았다")
        #expect(deck.draft?.cues.count == 1 && deck.row == newRow, "덱의 큐·기준값은 저장 뒤 값이다")
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

    /// S11: 저장 직후 읽기가 실패해도 "초안 쓰기 뒤 읽기 대기"는 읽기가 성공할 때까지 남는다(쓰기 잠금·초안 쓰기 표시는 이미 꺼졌다)
    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 저장_직후_읽기가_실패해도_다음_성공한_읽기가_다른_곡_되돌리기를_지우지_않는다() async throws {
        let rig = try await Rig()
        rig.addCueDraft()
        let store = rig.store
        let undo = UndoManager()
        store.undoManager = undo
        let other = rig.otherRow
        let pause = WriteLockSplitTests.GatePause()
        let coordinator = ReflectionCoordinator.test(store: store, gate: Self.pausing(.live(), at: pause))
        rig.failingSnapshots.set(true)
        let writing = Task { await coordinator.write(rows: [rig.writingRow]) }
        #expect(await waitForState(until: { pause.hasEntered }), "관문 쓰기에 닿지 못함")
        store.tags.setTag(.title, "저장 중에 고친 제목", rows: [other])
        #expect(undo.canUndo)
        pause.release()
        await writing.value
        #expect(!store.libraryBusy && !store.isDraftWrite && store.writtenAwaitingReload == [rig.writing.uuid], "저장은 됐고 읽기는 실패했다")
        #expect(undo.canUndo, "실패한 읽기는 기록을 지우지 않는다")

        // 창을 다시 활성화해 자동 읽기가 성공한다
        rig.failingSnapshots.set(false)
        await store.takeSnapshot(quiet: true, refreshITunes: false)
        #expect(store.writtenAwaitingReload.isEmpty)
        #expect(undo.canUndo, "저장 뒤 첫 성공한 읽기도 다른 곡의 ⌘Z 기록을 지우지 않는다")
        undo.undo()
        #expect(store.tagDrafts[other.track.uuid]?.hasChanges != true, "⌘Z로 되돌려진다")
        // 그 읽기로 대기는 끝났다: 다음 일반 읽기는 기록을 지운다
        store.tags.setTag(.title, "또 고친 제목", rows: [other])
        #expect(undo.canUndo)
        await store.takeSnapshot(quiet: true, refreshITunes: false)
        #expect(!undo.canUndo)
    }

    /// S15: 읽기 실패 사이 바깥(CLI)이 다른 곡의 태그 초안을 바꾸면, 다음 읽기가 그 초안을 받아들이므로 그 곡의 옛 ⌘Z는 무효가 된다
    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 읽기_실패_사이_바깥이_바꾼_곡의_되돌리기만_무효가_되고_나머지는_남는다() async throws {
        let rig = try await Rig()
        rig.addCueDraft()
        let store = rig.store
        let undo = UndoManager()
        store.undoManager = undo
        let unchanged = rig.otherRow, changedOutside = rig.thirdRow
        let pause = WriteLockSplitTests.GatePause()
        let coordinator = ReflectionCoordinator.test(store: store, gate: Self.pausing(.live(), at: pause))
        rig.failingSnapshots.set(true)
        let writing = Task { await coordinator.write(rows: [rig.writingRow]) }
        #expect(await waitForState(until: { pause.hasEntered }), "관문 쓰기에 닿지 못함")
        // 저장 중에 두 곡의 태그를 고친다: ⌘Z 단계가 둘이다(먼저 고친 곡이 아래)
        store.tags.setTag(.title, "그대로 둘 곡의 제목", rows: [unchanged])
        store.tags.setTag(.title, "내가 고친 제목", rows: [changedOutside])
        pause.release()
        await writing.value
        #expect(!store.libraryBusy && store.writtenAwaitingReload == [rig.writing.uuid], "저장은 됐고 읽기는 실패했다")

        // 그 사이 바깥(CLI)이 `changedOutside`의 태그 초안을 다른 값으로 저장한다
        var outside = TagDraft(trackUUID: changedOutside.track.uuid, base: changedOutside.tagFields)
        outside.fields.title = "CLI가 저장한 제목"
        store.testDrafts.saveTags([outside])
        store.testDrafts.flush()
        rig.failingSnapshots.set(false)
        await store.takeSnapshot(quiet: true, refreshITunes: false)
        #expect(store.tagDrafts[changedOutside.track.uuid]?.fields.title == "CLI가 저장한 제목", "다음 읽기가 CLI 초안을 받아들였다")

        // 가장 나중 단계(바깥이 바꾼 곡): 옛 값으로 CLI 초안을 덮지 않는다
        undo.undo()
        #expect(store.tagDrafts[changedOutside.track.uuid]?.fields.title == "CLI가 저장한 제목", "⌘Z가 새 CLI 초안을 이전 값으로 덮으면 안 된다")
        // 그 앞 단계(변하지 않은 곡): 그대로 되돌려진다
        #expect(undo.canUndo, "변하지 않은 곡의 ⌘Z는 남는다")
        undo.undo()
        #expect(store.tagDrafts[unchanged.track.uuid]?.hasChanges != true)
    }

    /// S16: 두 곡을 한 번에 고친 단계에서 다음 읽기가 한 곡의 CLI 초안만 받아들이면, 그 곡만 빼고 나머지 곡은 ⌘Z로 되돌린다
    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 두_곡을_한_번에_고친_단계에서_바깥이_바꾼_곡만_빼고_되돌린다() async throws {
        let rig = try await Rig()
        rig.addCueDraft()
        let store = rig.store
        let undo = UndoManager()
        store.undoManager = undo
        let unchanged = rig.otherRow, changedOutside = rig.thirdRow
        let pause = WriteLockSplitTests.GatePause()
        let coordinator = ReflectionCoordinator.test(store: store, gate: Self.pausing(.live(), at: pause))
        rig.failingSnapshots.set(true)
        let writing = Task { await coordinator.write(rows: [rig.writingRow]) }
        #expect(await waitForState(until: { pause.hasEntered }), "관문 쓰기에 닿지 못함")
        // 저장 중에 두 곡의 태그를 한 번에 고친다: ⌘Z 단계 하나
        store.tags.applyTagEdits([(row: unchanged, key: .title, value: "한 번에 고친 제목"),
                                  (row: changedOutside, key: .title, value: "한 번에 고친 제목")])
        pause.release()
        await writing.value

        var outside = TagDraft(trackUUID: changedOutside.track.uuid, base: changedOutside.tagFields)
        outside.fields.title = "CLI가 저장한 제목"
        store.testDrafts.saveTags([outside])
        store.testDrafts.flush()
        rig.failingSnapshots.set(false)
        await store.takeSnapshot(quiet: true, refreshITunes: false)
        #expect(store.tagDrafts[changedOutside.track.uuid]?.fields.title == "CLI가 저장한 제목")

        #expect(undo.canUndo)
        undo.undo()
        #expect(store.tagDrafts[unchanged.track.uuid]?.hasChanges != true, "초안이 그대로인 곡은 되돌려진다")
        #expect(store.tagDrafts[changedOutside.track.uuid]?.fields.title == "CLI가 저장한 제목", "바깥이 바꾼 곡은 덮지 않는다")
        // ⇧⌘Z는 실제로 되돌린 곡만 다시 한다
        #expect(undo.canRedo)
        undo.redo()
        #expect(store.tagDrafts[unchanged.track.uuid]?.fields.title == "한 번에 고친 제목")
        #expect(store.tagDrafts[changedOutside.track.uuid]?.fields.title == "CLI가 저장한 제목")
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 재생_목록만_저장한_뒤_읽기가_실패해도_다음_성공한_읽기가_되돌리기를_지우지_않는다() async throws {
        let rig = try await Rig()
        let store = rig.store
        let undo = UndoManager()
        store.undoManager = undo
        let other = rig.otherRow
        let lock = store.reflection.session.ports.lock
        lock.setTracks([])
        lock.setDraftWriting(true)
        lock.set(true, false)
        store.tags.setTag(.title, "저장 중에 고친 제목", rows: [other])
        rig.failingSnapshots.set(true)
        let reloaded = await store.reloadAfterWrite(written: [], playlistEdits: [])
        #expect(!reloaded, "읽기가 실패했다")
        lock.set(false, false)
        lock.setDraftWriting(false)
        lock.setTracks([])
        rig.failingSnapshots.set(false)
        await store.takeSnapshot(quiet: true, refreshITunes: false)
        #expect(undo.canUndo, "재생 목록·기록만 저장한 뒤 첫 성공한 읽기도 다른 곡의 ⌘Z를 남긴다")
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

    /// S12: 입력을 시작할 때는 곡 UUID만 고정한다. 읽기가 그 곡 행을 갱신한 뒤 확정하면 최신 행의 기준으로 초안을 만든다
    @Test func 입력을_시작한_뒤_읽기가_곡_행을_갱신하면_확정할_때_최신_행의_기준으로_초안을_만든다() {
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        let model = TagInspectorModel(store: store)
        let old = TagInspectorModelTests.row("b", title: "옛 제목")
        store.rowsByUUID[old.track.uuid] = old
        model.beginInput(.title, rows: [old])
        // 입력하는 사이 읽기가 rekordbox의 새 제목을 가져온다
        let fresh = TagInspectorModelTests.row("b", title: "rekordbox 새 제목")
        store.rowsByUUID[fresh.track.uuid] = fresh
        model.commitText(.title, "내 제목", rows: [old])
        let draft = store.tagDrafts[old.track.uuid]
        #expect(draft?.fields[.title] == "내 제목")
        #expect(draft?.base[.title] == "rekordbox 새 제목", "초안의 기준은 확정할 때의 최신 행이다")
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
