@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCAnalysis
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Synchronization
import Testing

@Suite("큐·그리드 저장 실패 복구", .serialized)
struct DraftSaveRecoveryTests {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-draft-save-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func cue(_ uuid: String, time: Double) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.place(EditableCue(kind: .memory, time: time))
        return draft
    }

    @Test func 큐_저장에_실패해도_다시_읽을_입력을_보존한다() throws {
        let writer = DraftWriter()
        let home = try directory(), locations = DraftLocations(home: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let uuid = UUID().uuidString
        let file = locations.cue.appending(path: "\(uuid).json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        var draft = CueDraft(trackUUID: uuid)
        draft.place(EditableCue(kind: .memory, time: 4))
        writer.save(draft, directory: locations.cue)
        writer.flush()
        #expect(CueDraftStore.load(trackUUID: uuid, directory: locations.cue) == nil)
        #expect(DraftStore.live(writer: writer, home: home).currentCue(uuid) == draft)
        try FileManager.default.removeItem(at: file)
        writer.retry(trackUUID: uuid, in: locations)
        writer.flush()
    }

    @Test func 그리드_저장에_실패해도_다시_읽을_입력을_보존한다() throws {
        let writer = DraftWriter()
        let home = try directory(), locations = DraftLocations(home: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let uuid = UUID().uuidString
        let file = locations.grid.appending(path: "\(uuid).json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let draft = GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 1, bpm: 120, firstBeatNumber: 1)])
        writer.save(draft, directory: locations.grid)
        writer.flush()
        #expect(GridDraftStore.load(trackUUID: uuid, directory: locations.grid) == nil)
        #expect(DraftStore.live(writer: writer, home: home).currentGrid(uuid) == draft)
        try FileManager.default.removeItem(at: file)
        writer.retry(trackUUID: uuid, in: locations)
        writer.flush()
    }

    @Test func 큐_실패와_추가_편집_뒤_최신값을_재시도하고_다른_UUID는_보존한다() throws {
        let writer = DraftWriter()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = UUID().uuidString, other = UUID().uuidString
        let saved = cue(uuid, time: 1)
        writer.save(saved, directory: root)
        writer.flush()
        let savedRevision = try #require(writer.state(.cue, trackUUID: uuid, directory: root)?.savedRevision)
        let fail = Mutex(true)
        let write: @Sendable (CueDraft, URL) throws -> Void = { draft, directory in
            if fail.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/private/example/sensitive"]) }
            try CueDraftStore.save(draft, directory: directory)
        }
        writer.save(cue(uuid, time: 2), directory: root, write: write)
        writer.save(cue(other, time: 5), directory: root, write: write)
        let latest = cue(uuid, time: 3)
        writer.save(latest, directory: root, write: write)
        writer.flush()
        let state = try #require(writer.state(.cue, trackUUID: uuid, directory: root))
        #expect(state.savedRevision == savedRevision && state.failure?.revision == state.revision)
        #expect(state.failure.map { !$0.reason.contains("sensitive") } == true)
        #expect(CueDraftStore.load(trackUUID: uuid, directory: root) == saved)
        #expect(writer.pendingCue(trackUUID: uuid, directory: root) == latest)
        fail.withLock { $0 = false }
        writer.retry(.cue, trackUUID: uuid, directory: root)
        writer.flush()
        #expect(CueDraftStore.load(trackUUID: uuid, directory: root) == latest)
        #expect(writer.pendingCue(trackUUID: uuid, directory: root) == nil)
        #expect(writer.state(.cue, trackUUID: uuid, directory: root)?.failure == nil)
        #expect(writer.state(.cue, trackUUID: other, directory: root)?.failure != nil)
    }

    @Test func 그리드_실패와_추가_편집_뒤_최신값을_재시도하고_flush한다() throws {
        let writer = DraftWriter()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = UUID().uuidString
        let saved = GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 1, bpm: 120, firstBeatNumber: 1)])
        writer.save(saved, directory: root)
        writer.flush()
        let savedRevision = writer.state(.grid, trackUUID: uuid, directory: root)?.savedRevision
        let fail = Mutex(true)
        let write: @Sendable (GridDraft, URL) throws -> Void = { draft, directory in
            if fail.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
            try GridDraftStore.save(draft, directory: directory)
        }
        var latest = saved
        latest.segments[0].bpm = 125
        writer.save(latest, directory: root, write: write)
        writer.flush()
        latest.segments[0].bpm = 130
        writer.save(latest, directory: root, write: write)
        writer.flush()
        #expect(writer.state(.grid, trackUUID: uuid, directory: root)?.savedRevision == savedRevision)
        #expect(GridDraftStore.load(trackUUID: uuid, directory: root) == saved)
        #expect(writer.pendingGrid(trackUUID: uuid, directory: root) == latest)
        #expect(writer.state(.grid, trackUUID: uuid, directory: root)?.failure?.reason.contains("빈 공간") == true)
        fail.withLock { $0 = false }
        writer.retry(.grid, trackUUID: uuid, directory: root)
        writer.flush()
        #expect(GridDraftStore.load(trackUUID: uuid, directory: root) == latest)
        let state = try #require(writer.state(.grid, trackUUID: uuid, directory: root))
        #expect(state.savedRevision == state.revision && state.failure == nil)
    }

    @Test func 재시도_중_추가_편집과_최신_실패를_옛_성공으로_지우지_않는다() throws {
        let writer = DraftWriter()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = UUID().uuidString
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let attempt = Mutex(0)
        let original = cue(uuid, time: 1), latest = cue(uuid, time: 3)
        writer.save(original, directory: root, write: { draft, directory in
            let number = attempt.withLock { $0 += 1; return $0 }
            if number == 1 { throw CocoaError(.fileWriteNoPermission) }
            started.signal()
            finish.waitOffPool()
            try CueDraftStore.save(draft, directory: directory)
        })
        writer.flush()
        writer.retry(.cue, trackUUID: uuid, directory: root)
        #expect(started.wait(timeout: .now() + 5) == .success)
        writer.save(latest, directory: root, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        finish.signal()
        writer.flush()
        let state = try #require(writer.state(.cue, trackUUID: uuid, directory: root))
        #expect(state.failure?.revision == state.revision && state.savedRevision != state.revision)
        #expect(CueDraftStore.load(trackUUID: uuid, directory: root) == original)
        #expect(writer.pendingCue(trackUUID: uuid, directory: root) == latest)
        writer.save(latest, directory: root)
        writer.flush()
        #expect(CueDraftStore.load(trackUUID: uuid, directory: root) == latest)
    }

    @Test @MainActor func 저장_실패가_있으면_디스크의_옛_초안을_실제_쓰기에_넘기지_않는다() async throws {
        let writer = DraftWriter()
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let home = fixture.root.appending(path: "drafts"), locations = DraftLocations(home: home)
        let old = cue(spec.uuid, time: 1), latest = cue(spec.uuid, time: 2)
        writer.save(old, directory: locations.cue)
        writer.flush()
        writer.save(latest, directory: locations.cue, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.flush()
        let failure = try #require(writer.failures(in: locations).first { $0.trackUUID == spec.uuid })
        defer {
            writer.save(CueDraft(trackUUID: spec.uuid), directory: locations.cue)
            writer.flush()
        }
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                                 draftHome: home, arguments: ["test", "--db", fixture.database.path], environment: [:], writer: writer)
        await store.load(snapshot: fixture.database)
        let row = try #require(store.rowsByUUID[spec.uuid])
        do {
            _ = try await store.session.previewWrite(rows: [row], playlists: false)
            Issue.record("저장 실패가 있는데 미리 보기가 통과했다")
        } catch { #expect(error.localizedDescription.contains(failure.message)) }
        do {
            _ = try await store.session.writeToRekordbox([old], to: fixture.database, shareRoot: fixture.shareRoot)
            Issue.record("저장 실패가 있는데 실제 쓰기가 통과했다")
        } catch { #expect(error.localizedDescription.contains(failure.message)) }
        #expect(try RekordboxLibrary.load(snapshot: fixture.database).cues.isEmpty)
        #expect(writer.pendingCue(trackUUID: spec.uuid, directory: locations.cue) == latest)
    }

    @Test func 그리드_초안_삭제_실패도_오류로_전달한다() throws {
        let root = try directory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let uuid = UUID().uuidString
        let saved = GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 1, bpm: 120, firstBeatNumber: 1)])
        try GridDraftStore.save(saved, directory: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let empty = GridDraft(trackUUID: uuid, base: [], segments: [])
        #expect(throws: (any Error).self) { try GridDraftStore.save(empty, directory: root) }
        #expect(GridDraftStore.load(trackUUID: uuid, directory: root) == saved)
    }

    @Test @MainActor func 덱에서_옛_완료는_최신_실패와_다른_UUID를_지우지_않는다() async throws {
        let callbacks = Mutex<[@Sendable (DraftSaveFailure?) -> Void]>([])
        var drafts = MemoryDrafts().store
        drafts.saveCue = { _, completion in callbacks.withLock { $0.append(completion) } }
        let storage = DeckStorage.memory(drafts)
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        let uuid = UUID().uuidString, other = UUID().uuidString
        deck.persist(cue(uuid, time: 1))
        deck.persist(cue(uuid, time: 2))
        deck.persist(cue(other, time: 3))
        let completions = callbacks.withLock { $0 }
        let newest = DraftSaveFailure(kind: .cue, trackUUID: uuid, revision: 2, reason: "합성 실패")
        let otherFailure = DraftSaveFailure(kind: .cue, trackUUID: other, revision: 3, reason: "다른 합성 실패")
        completions[1](newest)
        completions[2](otherFailure)
        for _ in 0..<100 where deck.draftSaveFailures.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        completions[0](nil)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(10))
        #expect(Set(deck.draftSaveFailures.map(\.trackUUID)) == [uuid, other])
        #expect(deck.draftSaveFailures.contains(newest))
    }

    @Test @MainActor func 큐_저장_실패_중_외부_재읽기로_입력을_버리지_않는다() async throws {
        var drafts = MemoryDrafts().store
        drafts.saveCue = { draft, completion in
            completion(DraftSaveFailure(kind: .cue, trackUUID: draft.trackUUID, revision: 1, reason: "합성 실패"))
        }
        let storage = DeckStorage.memory(drafts)
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        let row = ReflectionPresenterTests.row("failed-external")
        deck.row = row
        let latest = cue(row.track.uuid, time: 8)
        deck.draft = latest
        deck.persist(latest)
        for _ in 0..<100 where deck.draftSaveFailures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        deck.reloadExternalCueDraft(cue(row.track.uuid, time: 2))
        #expect(deck.draft == latest)
    }

    @Test func 실패한_초안_삭제는_디스크의_옛_입력으로_다시_읽지_않는다() throws {
        let writer = DraftWriter()
        let home = try directory(), cues = DraftLocations(home: home).cue
        defer { try? FileManager.default.removeItem(at: home) }
        let uuid = UUID().uuidString
        let saved = cue(uuid, time: 1)
        writer.save(saved, directory: cues)
        writer.flush()
        var reverted = saved
        reverted.revert()
        writer.save(reverted, directory: cues, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.flush()
        defer { writer.removeCue(trackUUID: uuid, directory: cues); writer.flush() }
        #expect(CueDraftStore.load(trackUUID: uuid, directory: cues) == saved)
        #expect(writer.pendingCue(trackUUID: uuid, directory: cues) == reverted)
        #expect(DraftStore.live(writer: writer, home: home).currentCue(uuid) == nil)
    }

    @Test @MainActor func 사본_쓰기가_성공한_뒤_초안_정리_실패는_별도로_알린다() async throws {
        let writer = DraftWriter()
        let fixture = try RekordboxFixture()
        let spec = TrackSpec()
        try fixture.add(spec)
        let home = fixture.root.appending(path: "drafts"), cues = DraftLocations(home: home).cue
        let draft = cue(spec.uuid, time: 4)
        writer.save(draft, directory: cues)
        writer.flush()
        // 초안 폴더 권한 대신 이 곡의 파일만 잠가 정리(삭제) 실패를 만든다.
        let file = cues.appending(path: "\(spec.uuid).json")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            writer.removeCue(trackUUID: spec.uuid, directory: cues)
            writer.flush()
        }
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                                 draftHome: home, arguments: ["test", "--db", fixture.database.path], environment: [:], writer: writer)
        await store.load(snapshot: fixture.database)
        let report = try await store.session.writeToRekordbox([draft], to: fixture.database, shareRoot: fixture.shareRoot)
        #expect(report.written.map(\.trackUUID) == [spec.uuid])
        #expect(try RekordboxLibrary.load(snapshot: fixture.database).cues.contains { $0.inMsec == 4000 })
        // 사본 쓰기의 백업은 저장소에 준 백업 폴더에 남는다(사용자 백업 폴더를 밀어내지 않는다).
        #expect(RekordboxWriter.backups(in: fixture.backups).contains { $0.isWrite })
        #expect(store.lastError?.contains("썼지만") == true)
        #expect(writer.pendingCue(trackUUID: spec.uuid, directory: cues)?.hasChanges == false)
        #expect(CueDraftStore.load(trackUUID: spec.uuid, directory: cues) == draft)
    }

    @Test @MainActor func 명시적_추정_대체는_원본_승인을_저장하고_버리면_막힘을_복원한다() async throws {
        let h = try DeckHarness(grid: nil)
        try await h.loaded()
        let beats = (0..<40).map { i in
            BeatGrid.Beat(number: i % 4 + 1, bpm: 120, time: 0.5 + Double(i) * 0.5 + (i == 10 ? 0.004 : 0))
        }
        let original = BeatGrid(beats: beats)
        let base = GridDraft(trackUUID: "track-1", grid: original)
        #expect(GridEditEligibility.reconstructionErrorMilliseconds(original: original, rebuilt: base.grid(duration: h.deck.duration + 1)) > 2)
        h.deck.originalGrid = original
        h.deck.gridDraft = base
        h.deck.gridEditBlockedReason = "합성 재생성 오차"
        // 대입 대상이 Optional이면 #require가 nil 검사를 건너뛰므로(경고) 지역 상수로 먼저 받는다.
        let estimate = try #require(GridEstimator.estimate(beats: (0..<40).map { 0.5 + Double($0) * 0.5 }, bars: [0.5, 2.5, 4.5], duration: 20))
        h.deck.gridSuggestion = estimate
        h.deck.gridSuggestion?.segments[0].bpm = 125
        h.deck.applyGridSuggestion()
        let approved = try #require(h.deck.gridDraft)
        #expect(approved.replacementSource != nil && approved.isVerifiedReplacement(of: original, duration: h.deck.duration))
        #expect(h.drafts.grid("track-1") == approved && h.deck.canEditGrid)
        h.deck.revertGrid()
        #expect(h.deck.gridDraft?.replacementSource == nil && h.deck.gridDraft?.hasChanges == false)
        #expect(h.deck.gridEditBlockedReason != nil && !h.deck.canEditGrid)
    }

    @Test func 실패한_큐와_그리드_삭제를_다시_읽으면_현재_원본을_사용한다() async throws {
        let writer = DraftWriter()
        let fixture = try RekordboxFixture()
        var spec = TrackSpec()
        spec.cues = [CueSpec(kind: 0, inMsec: 4000)]
        spec.analysisDataPath = "/PIONEER/USBANLZ/reload-\(UUID())/ANLZ0000.DAT"
        try fixture.add(spec)
        let beats = AnlzBuilder.beats(bpm: 120, first: 500, count: 80)
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        // 분석 파일은 합성 사본의 share에서 읽는다(DJC_REKORDBOX_DIR에 기대지 않는다).
        let library = try RekordboxLibrary.load(snapshot: fixture.database)
        let track = try #require(library.tracks.first)
        // 덱이 곡을 올릴 때와 같은 읽기(실제 초안 파일·합성 사본의 share)
        let home = fixture.root.appending(path: "drafts"), locations = DraftLocations(home: home)
        let loader = LoadDeckTrack(assets: .live(drafts: .live(writer: writer, home: home)), cache: MemoryAnalysisStore().store)
        let request = DeckTrackRequest(uuid: track.uuid, audioFile: nil, analysisPath: track.analysisDataPath,
                                       imagePath: nil, shareRoot: fixture.shareRoot, rekordboxCues: library.cues)
        let fresh = await loader.content(request, duration: 180)
        var editedCue = fresh.draft
        editedCue.place(EditableCue(kind: .memory, time: 8))
        var editedGrid = try #require(fresh.grid.gridDraft)
        editedGrid.shift(by: 0.1)
        writer.save(editedCue, directory: locations.cue)
        writer.save(editedGrid, directory: locations.grid)
        writer.flush()
        writer.save(fresh.draft, directory: locations.cue, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.save(try #require(fresh.grid.gridDraft), directory: locations.grid, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.flush()
        defer {
            writer.removeCue(trackUUID: spec.uuid, directory: locations.cue)
            writer.removeGrid(trackUUID: spec.uuid, directory: locations.grid)
            writer.flush()
        }
        let reloaded = await loader.content(request, duration: 180)
        #expect(CueDraftStore.load(trackUUID: spec.uuid, directory: locations.cue) == editedCue
            && GridDraftStore.load(trackUUID: spec.uuid, directory: locations.grid) == editedGrid)
        #expect(!reloaded.draft.hasChanges && reloaded.draft.cues.map(\.time) == [4])
        #expect(reloaded.draft.cues.map(\.sourceID) == fresh.draft.cues.map(\.sourceID))
        #expect(reloaded.grid.gridDraft == fresh.grid.gridDraft)
        #expect(reloaded.grid.originalGrid == fresh.grid.originalGrid && reloaded.grid.blockedReason == nil)
    }
}
