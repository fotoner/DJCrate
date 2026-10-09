@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@MainActor
@Suite("선택한 종류만 복구", .serialized)
struct DraftRecovery168Tests {
    /// 초안 폴더는 합성 사본 폴더(`fixture.root`), 저장 큐는 `writer`(덱·시험이 같은 큐를 볼 때 준다)
    /// 태그 초안은 실제처럼 초안 폴더에 저장한다(복구 저장이 같은 저장 큐로 쓴다).
    func makeStore(_ fixture: RekordboxFixture, writer: DraftWriter = DraftWriter(), opensCopy: Bool = false) -> LibraryStore {
        LibraryStore.test(resultHistory: WriteResultHistory(url: nil), backupDirectory: fixture.backups,
                          playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                          draftHome: fixture.root, movesDamagedDrafts: false,
                          arguments: opensCopy ? ["test", "--db", fixture.database.path] : ["test"],
                          environment: opensCopy ? ["DJC_REKORDBOX_DIR": fixture.root.path] : [:], writer: writer)
    }
    func inputs(_ kind: DraftRecoveryKind, uuid: String) -> (RecoveryDraft, RecoveryDraft) {
        switch kind {
        case .tags:
            var base = TagFields(); base.title = "합성 원곡"
            var d = TagDraft(trackUUID: uuid, base: base); d.fields.comment = "내 편집"
            var c = base; c.title = "최신 제목"
            return (.tags(d), .tags(TagDraft(trackUUID: uuid, base: c)))
        case .cues:
            var d = CueDraft(trackUUID: uuid); let cue = EditableCue(sourceID: "cue", kind: .memory, time: 2)
            d.base = [cue]; d.cues = [cue]; d.cues[0].name = "내 편집"
            var c = d; c.base[0].time = 3; c.cues = c.base
            return (.cues(d), .cues(c))
        case .grid:
            let base = [GridSegment(start: 0.2, bpm: 120, firstBeatNumber: 1)]
            var d = GridDraft(trackUUID: uuid, base: base, segments: base); d.segments[0].firstBeatNumber = 3
            var c = base; c[0].bpm = 160
            return (.grid(d), .grid(GridDraft(trackUUID: uuid, base: c, segments: c)))
        }
    }
    /// 고르기(내 편집 유지·지금 값)별 결과는 아래 `실제_저장실패_복구저장_덱오류해소가_연결된다`(큐·그리드 × 두 고르기)와
    /// `RecoverySheetTests`가 본다. 회귀 시험이라 종류마다 한 번씩만 돈다.
    @Test(arguments: DraftRecoveryKind.allCases)
    func 가져오기는_입력을_보존하고_선택한_종류만_저장한다(kind: DraftRecoveryKind) async throws {
        let choice = DraftRecoveryChoice.keepEditing
        let fixture = try RekordboxFixture(), store = makeStore(fixture), row = ReflectionPresenterTests.row(UUID().uuidString)
        let (original, current) = inputs(kind, uuid: row.track.uuid)
        store.rowsByUUID[row.track.uuid] = row
        store.recoveryMemoryInput = { uuid, k in uuid == original.uuid && k == kind ? original : nil }
        if case let .tags(d) = original { store.tagDrafts[d.trackUUID] = d }
        let otherUUID = UUID().uuidString, other = inputs(.tags, uuid: otherUUID).0
        if case let .tags(d) = other { store.tagDrafts[otherUUID] = d }
        let review = try await store.prepareDraftRecovery(row: row, kind: kind, readCurrent: { _ in current })
        #expect(review.original == original && store.recoveryInput(uuid: original.uuid, kind: kind) == original)
        var saved: RecoveryDraft?
        try await store.applyDraftRecovery(review, choice: choice, readCurrent: { _ in current }, save: { saved = $0 })
        #expect(saved == (try original.resolved(onto: current, choice: choice)))
        #expect(store.tagDrafts[otherUUID].map(RecoveryDraft.tags) == other)
    }
    @Test(arguments: DraftRecoveryKind.allCases)
    func 읽기실패_저장실패_추가편집은_입력을_그대로_남긴다(kind: DraftRecoveryKind) async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture), row = ReflectionPresenterTests.row(UUID().uuidString)
        let (original, current) = inputs(kind, uuid: row.track.uuid)
        var memory = original
        store.rowsByUUID[row.track.uuid] = row
        store.recoveryMemoryInput = { _, _ in memory }
        if case let .tags(d) = original { store.tagDrafts[d.trackUUID] = d }
        await #expect(throws: CocoaError.self) { try await store.prepareDraftRecovery(row: row, kind: kind, readCurrent: { _ in throw CocoaError(.fileReadNoSuchFile) }) }
        #expect(store.recoveryInput(uuid: original.uuid, kind: kind) == original)
        let review = try await store.prepareDraftRecovery(row: row, kind: kind, readCurrent: { _ in current })
        await #expect(throws: CocoaError.self) { try await store.applyDraftRecovery(review, choice: .keepEditing, readCurrent: { _ in current }, save: { _ in throw CocoaError(.fileWriteNoPermission) }) }
        #expect(store.recoveryInput(uuid: original.uuid, kind: kind) == original)
        await #expect(throws: DJCError.self) {
            try await store.applyDraftRecovery(review, choice: .keepEditing, readCurrent: { _ in
                memory = current
                if case let .tags(d) = current { store.tagDrafts[d.trackUUID] = d }
                return current
            }, save: { _ in Issue.record("경합 뒤 저장했습니다") })
        }
        #expect(store.recoveryInput(uuid: original.uuid, kind: kind) == current)
    }
    @Test func 취소와_현재값_재변경_대상없어짐은_초안을_남긴다() async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture), row = ReflectionPresenterTests.row(UUID().uuidString)
        let (original, current) = inputs(.tags, uuid: row.track.uuid)
        if case let .tags(d) = original { store.tagDrafts[d.trackUUID] = d }
        store.rowsByUUID[row.track.uuid] = row
        let review = try await store.prepareDraftRecovery(row: row, kind: .tags, readCurrent: { _ in current })
        // 비교만 연 뒤 취소하면 apply를 부르지 않는다.
        #expect(store.tagDrafts[row.track.uuid].map(RecoveryDraft.tags) == original)
        await #expect(throws: DJCError.self) { try await store.applyDraftRecovery(review, choice: .keepEditing, readCurrent: { _ in original }, save: { _ in Issue.record("재변경 뒤 저장했습니다") }) }
        store.rowsByUUID[row.track.uuid] = nil
        await #expect(throws: DJCError.self) { try await store.applyDraftRecovery(review, choice: .useCurrent, readCurrent: { _ in current }, save: { _ in Issue.record("없는 곡을 저장했습니다") }) }
        #expect(store.tagDrafts[row.track.uuid].map(RecoveryDraft.tags) == original)
    }
    @Test(arguments: DraftRecoveryKind.allCases)
    func 실제_사본_현재값_복구_저장_재검사_쓰기_새읽기(kind: DraftRecoveryKind) async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture, opensCopy: true)
        var spec = TrackSpec(); spec.fileType = 11; spec.length = 60
        spec.folderPath = try AudioFixture.wav(seconds: 60, in: fixture.audio).path
        spec.analysisDataPath = "/PIONEER/USBANLZ/recovery/ANLZ0000.DAT"
        spec.cues = [CueSpec(id: "original", kind: 0, inMsec: 2000)]
        try fixture.add(spec)
        try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        let beats = AnlzBuilder.beats(bpm: 120, first: 200, count: 120)
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        await store.load(snapshot: fixture.database)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let original: RecoveryDraft
        switch kind {
        case .tags:
            var d = TagDraft(track: row.track); d.fields.comment = "내 코멘트"; original = .tags(d)
            store.tagDrafts[spec.uuid] = d
            try TagDraftStore.save(d, directory: fixture.root.appending(path: "tag-drafts"))
            try fixture.execute("UPDATE djmdContent SET Title = '최신 제목' WHERE ID = ?", [.text(spec.id)])
        case .cues:
            var d = CueDraft(trackUUID: spec.uuid, rekordboxCues: row.cues); d.cues[0].name = "내 큐"; original = .cues(d)
            try CueDraftStore.save(d, directory: fixture.root.appending(path: "cue-drafts"))
            var external = CueDraft(trackUUID: spec.uuid, rekordboxCues: row.cues); external.place(.init(kind: .memory, time: 8, name: "외부 추가"))
            let report = try RekordboxWriter.write(drafts: [external], to: fixture.database, dryRun: false, backups: fixture.backups, shareRoot: fixture.shareRoot)
            #expect(report.written.count == 1)
        case .grid:
            var d = GridDraft(trackUUID: spec.uuid, grid: try BeatGrid.load(anlz: fixture.analysisURL(for: spec))); d.shift(by: 0.01); original = .grid(d)
            try GridDraftStore.save(d, directory: fixture.root.appending(path: "grid-drafts"))
            let current = AnlzBuilder.beats(bpm: 160, first: 200, count: 160)
            try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: current), ext: AnlzBuilder.ext(beats: current))
        }
        func write(_ input: RecoveryDraft, dry: Bool) throws -> RekordboxWriter.Report {
            var cues: [CueDraft] = [], grids: [GridDraft] = [], tags: [TagDraft] = []
            switch input { case let .tags(d): tags = [d]; case let .cues(d): cues = [d]; case let .grid(d): grids = [d] }
            return try RekordboxWriter.write(drafts: cues, grids: grids, tags: tags, to: fixture.database, dryRun: dry,
                                            backups: fixture.backups, shareRoot: fixture.shareRoot)
        }
        let blocked = try write(original, dry: true)
        #expect(blocked.blocked.count + blocked.gridBlocked.count + blocked.tagBlocked.count == 1)
        let review = try await store.prepareDraftRecovery(row: row, kind: kind)
        try await store.applyDraftRecovery(review, choice: .keepEditing)
        let saved: RecoveryDraft
        switch kind {
        case .tags: saved = .tags(try #require(TagDraftStore.load(trackUUID: spec.uuid, directory: fixture.root.appending(path: "tag-drafts"))))
        case .cues: saved = .cues(try #require(CueDraftStore.load(trackUUID: spec.uuid, directory: fixture.root.appending(path: "cue-drafts"))))
        case .grid: saved = .grid(try #require(GridDraftStore.load(trackUUID: spec.uuid, directory: fixture.root.appending(path: "grid-drafts"))))
        }
        let preview = try write(saved, dry: true)
        #expect(preview.written.count + preview.gridWritten.count + preview.tagWritten.count == 1)
        let written = try write(saved, dry: false)
        #expect(written.written.count + written.gridWritten.count + written.tagWritten.count == 1)
        let fresh = try RekordboxLibrary.load(snapshot: fixture.database), track = try #require(fresh.tracks.first)
        switch kind {
        case .tags: #expect(track.title == "최신 제목" && track.comment == "내 코멘트")
        case .cues:
            #expect(fresh.cues.count == 2 && fresh.cues.contains { $0.name == "내 큐" } && fresh.cues.contains { $0.name == "외부 추가" })
        case .grid:
            let current = try BeatGrid.load(anlz: fixture.analysisURL(for: spec))
            #expect(current.beats.first?.time == 0.21 && current.beats.allSatisfy { $0.bpm == 160 })
        }
    }

    @Test(arguments: DraftRecoveryKind.allCases)
    func 실제_저장_실패의_pending도_기존_초안이어야_한다(kind: DraftRecoveryKind) async throws {
        let choice = DraftRecoveryChoice.keepEditing
        let writer = DraftWriter()
        let fixture = try RekordboxFixture(), store = makeStore(fixture, writer: writer), row = ReflectionPresenterTests.row(UUID().uuidString)
        let (original, current) = inputs(kind, uuid: row.track.uuid)
        store.rowsByUUID[row.track.uuid] = row
        let name: String
        switch kind { case .tags: name = "tag-drafts"; case .cues: name = "cue-drafts"; case .grid: name = "grid-drafts" }
        let directory = fixture.root.appending(path: name), archive = fixture.root.appending(path: name + "-original")
        switch original {
        case let .tags(d): store.tagDrafts[d.trackUUID] = d; try TagDraftStore.save(d, directory: directory)
        case let .cues(d): try CueDraftStore.save(d, directory: directory)
        case let .grid(d): try GridDraftStore.save(d, directory: directory)
        }
        let fileName = original.uuid + ".json"
        let originalBytes = try Data(contentsOf: directory.appending(path: fileName))
        try FileManager.default.moveItem(at: directory, to: archive)
        let sentinel = Data([0x16, 0x08]); try sentinel.write(to: directory)
        switch original {
        case .tags: break
        case let .cues(d): writer.save(d, directory: directory)
        case let .grid(d): writer.save(d, directory: directory)
        }
        writer.flush()
        // 덱이 보는 것: 같은 저장 큐의 저장 대기 입력, 없으면 디스크
        let deckDrafts = DraftStore.live(writer: writer, home: fixture.root)
        let review = try await store.prepareDraftRecovery(row: row, kind: kind, readCurrent: { _ in current })
        await #expect(throws: DJCError.self) { try await store.applyDraftRecovery(review, choice: choice, readCurrent: { _ in current }) }
        #expect(store.recoveryInput(uuid: original.uuid, kind: kind) == original)
        switch kind {
        case .tags: #expect(store.tagDrafts[original.uuid].map(RecoveryDraft.tags) == original)
        case .cues: #expect((deckDrafts.pendingCue(original.uuid) ?? deckDrafts.cueDraft(original.uuid)).map(RecoveryDraft.cues) == original)
        case .grid: #expect((deckDrafts.pendingGrid(original.uuid) ?? deckDrafts.gridDraft(original.uuid)).map(RecoveryDraft.grid) == original)
        }
        #expect(try Data(contentsOf: directory) == sentinel)
        #expect(try Data(contentsOf: archive.appending(path: fileName)) == originalBytes)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: archive, to: directory)
        // 입력과 현재값이 같으면 실패한 비교 화면에서 다시 저장할 수 있다.
        try await store.applyDraftRecovery(review, choice: choice, readCurrent: { _ in current })
        let expected = try original.resolved(onto: current, choice: choice)
        switch expected {
        case let .tags(d): #expect(TagDraftStore.load(trackUUID: d.trackUUID, directory: directory) == (d.hasChanges ? d : nil))
        case let .cues(d):
            #expect(CueDraftStore.load(trackUUID: d.trackUUID, directory: directory) == (d.hasChanges ? d : nil))
            #expect(writer.state(.cue, trackUUID: d.trackUUID, directory: directory)?.failure == nil)
        case let .grid(d):
            #expect(GridDraftStore.load(trackUUID: d.trackUUID, directory: directory) == (d.hasChanges ? d : nil))
            #expect(writer.state(.grid, trackUUID: d.trackUUID, directory: directory)?.failure == nil)
        }
    }

    @Test func 현재행_갱신은_목록_메타데이터를_보존한다() throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture)
        let basic = ReflectionPresenterTests.row(UUID().uuidString)
        var before = TrackRow(track: basic.track, cues: basic.cues, playCount: 4, tempoChanges: [120, 160])
        before.fileMissing = true; before.keyEstimated = true
        store.rowsByUUID[before.track.uuid] = before; store.rowsByID[before.id] = before
        store.updateRecoveryRow(basic)
        let after = try #require(store.rowsByUUID[before.track.uuid])
        #expect(after.tempoChanges == before.tempoChanges && after.fileMissing && after.keyEstimated)
    }
    @Test func 저장실패_초안은_외부읽기와_동기화뒤에도_복구목록에_남는다() async throws {
        let writer = DraftWriter()
        let fixture = try RekordboxFixture(), store = makeStore(fixture, writer: writer, opensCopy: true)
        var spec = TrackSpec(); spec.uuid = UUID().uuidString; try fixture.add(spec)
        let places = DraftLocations(home: fixture.root)
        let uuid = spec.uuid, cueDirectory = places.cue, gridDirectory = places.grid
        var cue = CueDraft(trackUUID: uuid); cue.place(.init(kind: .memory, time: 2, name: "실패 입력"))
        let base = [GridSegment(start: 0.2, bpm: 120, firstBeatNumber: 1)]
        let grid = GridDraft(trackUUID: uuid, base: base, segments: [.init(start: 0.3, bpm: 120, firstBeatNumber: 1)])
        writer.save(cue, directory: cueDirectory, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.save(grid, directory: gridDirectory, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        writer.flush()
        await store.load(snapshot: fixture.database)
        let row = try #require(store.rowsByUUID[uuid])
        #expect(store.recoveryKinds(for: row).contains(.cues) && store.recoveryKinds(for: row).contains(.grid))
        #expect(store.draftCueCounts[uuid] == CueCounts(cue))
        var reloaded: CueDraft?
        store.onCueDraftsReloaded = { reloaded = $0[uuid] }
        await store.refreshExternalDrafts()
        #expect(reloaded == cue)
        #expect(store.recoveryKinds(for: row).contains(.cues) && store.recoveryKinds(for: row).contains(.grid))
        #expect(store.recoveryInput(uuid: uuid, kind: .cues) == .cues(cue))
        #expect(store.recoveryInput(uuid: uuid, kind: .grid) == .grid(grid))
    }

    @Test func 덱의_복구성공은_선택종류_오류만_해소한다() async throws {
        let harness = try DeckHarness(); try await harness.loaded()
        let deck = harness.deck, uuid = try #require(deck.row?.track.uuid)
        let cueFailure = DraftSaveFailure(kind: .cue, trackUUID: uuid, revision: 1, reason: "시험 큐 오류")
        let gridFailure = DraftSaveFailure(kind: .grid, trackUUID: uuid, revision: 2, reason: "시험 그리드 오류")
        let other = DraftSaveFailure(kind: .cue, trackUUID: "other", revision: 3, reason: "다른 곡 오류")
        deck.draftSaveFailures = [cueFailure, gridFailure, other]
        let staleCompletion = deck.draftSaveCompletion(.cue, uuid: uuid)
        let gridBefore = deck.gridDraft
        let input = try #require(deck.draft)
        deck.applyDraftRecovery(.cues(input), currentRow: nil, currentGrid: nil)
        staleCompletion(cueFailure)
        await Task.yield()
        #expect(deck.currentDraftSaveFailures == [gridFailure])
        #expect(deck.draftSaveFailures.contains(other) && deck.gridDraft == gridBefore && deck.draft == input)
    }

    @Test(arguments: [false, true])
    func 복잡그리드_전체원본_경합과_이미반영된_대체를_구분한다(alreadyDesired: Bool) async throws {
        let fixture = try RekordboxFixture(), store = makeStore(fixture, opensCopy: true)
        var spec = TrackSpec(); spec.length = 60; spec.fileType = 11; spec.folderPath = try AudioFixture.wav(seconds: 60, in: fixture.audio).path; spec.analysisDataPath = "/PIONEER/USBANLZ/recovery/ANLZ0000.DAT"
        try fixture.add(spec); try fixture.execute("UPDATE djmdContent SET rb_data_status = 0 WHERE ID = ?", [.text(spec.id)])
        var beats = AnlzBuilder.beats(bpm: 120, first: 500, count: 120); beats[2].time += 3
        try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        let source = try BeatGrid.load(anlz: fixture.analysisURL(for: spec))
        let d = GridDraft(trackUUID: spec.uuid, base: GridDraft.segments(from: source), segments: [.init(start: 0.25, bpm: 128, firstBeatNumber: 1)])
        let original = try #require(d.approvingReplacement(of: source, duration: 60))
        try GridDraftStore.save(original, directory: fixture.root.appending(path: "grid-drafts"))
        await store.load(snapshot: fixture.database)
        let row = try #require(store.rowsByUUID[spec.uuid])
        let firstReview = try await store.prepareDraftRecovery(row: row, kind: .grid)
        if alreadyDesired {
            let written = try RekordboxWriter.write(drafts: [], grids: [original], to: fixture.database, dryRun: false, backups: fixture.backups, shareRoot: fixture.shareRoot)
            #expect(written.gridWritten.count == 1)
        } else {
            beats[2].time -= 1
            try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        }
        await #expect(throws: DJCError.self) { try await store.applyDraftRecovery(firstReview, choice: .keepEditing) }
        #expect(GridDraftStore.load(trackUUID: spec.uuid, directory: fixture.root.appending(path: "grid-drafts")) == original)
        let review = try await store.prepareDraftRecovery(row: row, kind: .grid)
        try await store.applyDraftRecovery(review, choice: .keepEditing)
        let saved = GridDraftStore.load(trackUUID: spec.uuid, directory: fixture.root.appending(path: "grid-drafts"))
        if alreadyDesired { #expect(saved == nil) }
        else {
            let current = try BeatGrid.load(anlz: fixture.analysisURL(for: spec)), recovered = try #require(saved)
            #expect(recovered.isVerifiedReplacement(of: current, duration: 60) && !recovered.isVerifiedReplacement(of: source, duration: 60))
            let report = try RekordboxWriter.write(drafts: [], grids: [recovered], to: fixture.database, dryRun: true, backups: fixture.backups, shareRoot: fixture.shareRoot)
            #expect(report.gridBlocked.isEmpty, "복구 뒤에도 그리드가 차단됨")
            #expect(report.gridWritten.count == 1)
        }
    }

    @Test func 슬롯재적용은_버릴_현재큐와_종류를_먼저_보여준다() throws {
        let old = EditableCue(sourceID: "old", kind: .memory, time: 2, name: "기준")
        var d = CueDraft(trackUUID: "synthetic"); d.base = [old]; d.cues = [old]; d.cues[0].kind = .hot(0)
        let occupying = EditableCue(sourceID: "new", kind: .hot(0), time: 4, name: "외부 슬롯 큐")
        var c = CueDraft(trackUUID: "synthetic"); c.base = [old, occupying]; c.cues = c.base
        let review = DraftRecoveryReview(original: .cues(d), current: .cues(c), title: "합성 곡", currentRow: nil, currentGrid: nil)
        let details = RecoverySummary.details(review)
        #expect(details.contains(String(ui: "내 편집 유지 때 없어질 현재 큐:")))
        #expect(details.contains { $0.contains("외부 슬롯 큐") })
        // 줄에는 어떤 종류의 차이인지와 내 편집을 유지하면 현재 큐가 없어진다는 경고가 보인다.
        #expect(RecoverySummary.summary(review).contains(DraftRecoveryKind.cues.label))
        #expect(RecoverySummary.notes(review) == [String(ui: "내 편집 유지를 고르면 rekordbox의 현재 큐 일부가 없어집니다. 자세히 보기에서 확인하세요.")])
        #expect(d.base == [old] && d.cues.count == 1)
    }

    @Test(arguments: [DraftRecoveryKind.cues, .grid], [DraftRecoveryChoice.keepEditing, .useCurrent])
    func 실제_저장실패_복구저장_덱오류해소가_연결된다(kind: DraftRecoveryKind, choice: DraftRecoveryChoice) async throws {
        let writer = DraftWriter()
        let fixture = try RekordboxFixture(), store = makeStore(fixture, writer: writer), row = ReflectionPresenterTests.row(UUID().uuidString)
        let (cueInput, cueCurrent) = inputs(.cues, uuid: row.track.uuid), (gridInput, gridCurrent) = inputs(.grid, uuid: row.track.uuid)
        let cue = try #require({ if case let .cues(d) = cueInput { return d }; return nil }())
        let grid = try #require({ if case let .grid(d) = gridInput { return d }; return nil }())
        let cues = fixture.root.appending(path: "cue-drafts"), grids = fixture.root.appending(path: "grid-drafts")
        try Data([1]).write(to: cues); try Data([2]).write(to: grids)
        writer.save(cue, directory: cues); writer.save(grid, directory: grids); writer.flush()
        // 덱은 저장소와 같은 저장 큐·초안 폴더를 본다(앱의 조립과 같다)
        let storage = DeckStorage.memory(.live(writer: writer, home: fixture.root),
                                         settings: SettingsStore(defaults: TestDefaults.make("deck"), persist: false))
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        deck.row = row; deck.draft = cue; deck.gridDraft = grid
        deck.draftSaveFailures = storage.testDraftStore.failures().filter { $0.trackUUID == row.track.uuid }
        #expect(deck.currentDraftSaveFailures.count == 2)
        store.rowsByUUID[row.track.uuid] = row
        store.recoveryMemoryInput = { deck.inputForDraftRecovery(uuid: $0, kind: $1) }
        store.onDraftRecovered = { deck.applyDraftRecovery($0, currentRow: $1, currentGrid: $2) }
        let current = kind == .cues ? cueCurrent : gridCurrent, original = kind == .cues ? cueInput : gridInput
        let review = try await store.prepareDraftRecovery(row: row, kind: kind, readCurrent: { _ in current })
        let directory = kind == .cues ? cues : grids
        try FileManager.default.removeItem(at: directory)
        try await store.applyDraftRecovery(review, choice: choice, readCurrent: { _ in current })
        #expect(deck.inputForDraftRecovery(uuid: row.track.uuid, kind: kind) == (try original.resolved(onto: current, choice: choice)))
        let remaining = deck.currentDraftSaveFailures
        #expect(remaining.count == 1 && remaining.first?.kind == (kind == .cues ? .grid : .cue))
        #expect(kind == .cues ? deck.gridDraft == grid : deck.draft == cue)
        // 다른 종류의 실패는 확인 뒤 합성 폴더에서만 정리한다.
        let other = kind == .cues ? grids : cues
        try FileManager.default.removeItem(at: other)
        writer.save(cue, directory: cues); writer.save(grid, directory: grids); writer.flush()
    }

}
