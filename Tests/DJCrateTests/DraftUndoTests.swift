import DJCApplication
@testable import DJCrate
import AppKit
import DJCAnalysis
import DJCDomain
import Foundation
import Testing

@Suite("초안 실행 취소") @MainActor
struct DraftUndoTests {
    func manager(_ deck: DeckModel) -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        deck.undoManager = manager
        return manager
    }

    @Test func 핫큐_찍기_지우기_옮기기를_정확히_복원한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = manager(h.deck)
        let before = h.deck.draft
        h.deck.pressHotCue(slot: 0)
        let placed = h.deck.draft
        #expect(undo.undoActionName == "핫큐 찍기")
        undo.undo()
        #expect(h.deck.draft == before)
        undo.redo()
        #expect(h.deck.draft == placed)
        let id = try #require(h.deck.hotCue(slot: 0)?.id)
        h.deck.move(id, to: 5)
        let moved = h.deck.draft
        undo.undo()
        #expect(h.deck.draft == placed)
        undo.redo()
        #expect(h.deck.draft == moved)
        h.deck.deleteHotCue(slot: 0)
        let deleted = h.deck.draft
        undo.undo()
        #expect(h.deck.draft == moved)
        undo.redo()
        #expect(h.deck.draft == deleted)
        // 고친 것이 없는 초안 저장은 지우기다(실제 저장소와 같다).
        #expect(deleted?.hasChanges == false && h.drafts.cue("track-1") == nil)
    }

    @Test func 큐_끌기는_한_단계이며_무변경은_등록하지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.pressHotCue(slot: 0)
        let undo = manager(h.deck), before = h.deck.draft
        let id = try #require(h.deck.hotCue(slot: 0)?.id)
        h.deck.move(id, to: 3, save: false)
        h.deck.move(id, to: 5, save: false)
        h.deck.commitDraft()
        let after = h.deck.draft
        undo.undo()
        #expect(h.deck.draft == before)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(h.deck.draft == after)
        undo.removeAllActions()
        h.deck.move(id, to: 5)
        h.deck.commitDraft()
        #expect(!undo.canUndo)
    }

    @Test func 그리드_끌기와_BPM은_큐와_루프를_함께_복원한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.pressHotCue(slot: 0)
        let id = try #require(h.deck.hotCue(slot: 0)?.id)
        h.deck.setLoop(id, beats: 4)
        let undo = manager(h.deck)
        let cues = h.deck.draft, grid = h.deck.gridDraft
        h.deck.beginGridDrag()
        h.deck.dragGrid(by: 0.1)
        h.deck.dragGrid(by: 0.2)
        h.deck.endGridDrag()
        let movedCues = h.deck.draft, movedGrid = h.deck.gridDraft
        undo.undo()
        #expect(h.deck.draft == cues && h.deck.gridDraft == grid)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(h.deck.draft == movedCues && h.deck.gridDraft == movedGrid)
        h.deck.setGridBPM(150)
        let bpmCues = h.deck.draft, bpmGrid = h.deck.gridDraft
        undo.undo()
        #expect(h.deck.draft == movedCues && h.deck.gridDraft == movedGrid)
        undo.redo()
        #expect(h.deck.draft == bpmCues && h.deck.gridDraft == bpmGrid)
        #expect(h.drafts.grid("track-1") == bpmGrid)
    }

    @Test func 게인과_초안_버리기도_복원한다() async throws {
        let h = try DeckHarness(autoGain: RekordboxAutoGain(gain: 1, peak: 0.9))
        try await h.loaded()
        let undo = manager(h.deck)
        h.deck.setTrackGain(-2)
        undo.undo()
        #expect(h.deck.gainDraft == nil && h.drafts.gain("track-1") == nil)
        undo.redo()
        #expect(h.deck.gainDraft == -2 && h.audio.gainDB == -2)
        h.deck.clearGainDraft()
        undo.undo()
        #expect(h.deck.gainDraft == -2)
        h.deck.pressHotCue(slot: 0)
        let cues = h.deck.draft
        h.deck.revertDraft()
        undo.undo()
        #expect(h.deck.draft == cues)
        h.deck.shiftGrid(ms: 100)
        let grid = h.deck.gridDraft
        h.deck.revertGrid()
        undo.undo()
        #expect(h.deck.gridDraft == grid)
    }

    @Test func 곡_전환과_쓰기_잠금은_덱_이력을_비운다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = manager(h.deck)
        h.deck.pressHotCue(slot: 0)
        h.deck.editsFrozen = true
        undo.undo()
        #expect(h.deck.hotCue(slot: 0) != nil)
        #expect(!undo.canUndo && !undo.canRedo)
        h.deck.editsFrozen = false
        h.deck.setGridBPM(140)
        h.deck.load(nil)
        #expect(!undo.canUndo && !undo.canRedo)
    }

    @Test func 태그_여러_칸과_덱은_같은_스택을_쓴다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = manager(h.deck)
        var saved: [TagDraft] = []
        let store = LibraryStore.test(saveTagDrafts: { saved = $0 })
        store.undoManager = undo
        let row = try #require(h.deck.row)
        store.rowsByUUID[row.track.uuid] = row
        h.deck.pressHotCue(slot: 0)
        store.tags.applyTagEdits([(row, .title, "새 제목"), (row, .artist, "새 아티스트")])
        let edited = store.tagDrafts
        #expect(undo.undoActionName == "태그 편집")
        undo.undo()
        #expect(store.tagDrafts.isEmpty && h.deck.hotCue(slot: 0) != nil)
        #expect(saved.first?.hasChanges == false)
        undo.undo()
        #expect(h.deck.hotCue(slot: 0) == nil)
        undo.redo()
        undo.redo()
        #expect(store.tagDrafts == edited)
        #expect(saved.first == edited[row.track.uuid])
        store.isWritingRekordbox = true
        store.tags.setTag(.title, "차단", rows: [row])
        undo.undo()
        #expect(store.tagDrafts == edited)
    }
    @Test func 기본_창_매니저에서도_편집마다_한_단계다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = UndoManager()
        h.deck.undoManager = undo
        h.deck.pressHotCue(slot: 0)
        h.deck.pressHotCue(slot: 1)
        undo.undo()
        #expect(h.deck.hotCue(slot: 0) != nil && h.deck.hotCue(slot: 1) == nil)
        undo.undo()
        #expect(h.deck.hotCue(slot: 0) == nil)
    }

    @Test func 루프_편집과_다시_읽기도_이력에_반영한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.pressHotCue(slot: 0)
        let undo = manager(h.deck)
        let id = try #require(h.deck.hotCue(slot: 0)?.id)
        h.deck.setLoop(id, beats: 4)
        h.deck.pressHotCue(slot: 0)
        let loop = h.deck.draft
        undo.undo()
        #expect(h.deck.hotCue(slot: 0)?.loop == nil && h.audio.loop == nil)
        undo.redo()
        #expect(h.deck.draft == loop)
        // 저장 뒤 다시 읽어도 ⌘Z 기록은 남는다(R12, #405: 예전에는 지웠다). 쓰지 않은 초안이 남았으니 지금처럼 편집 전 초안으로 되돌린다
        h.deck.refreshAfterWrite(h.deck.row)
        #expect(await waitForState(until: { !h.deck.isEditLocked }))
        #expect(undo.canUndo && h.deck.draft == loop)
        undo.undo()
        #expect(h.deck.hotCue(slot: 0)?.loop == nil && h.audio.loop == nil)
    }

    /// R12(#405, 컨실 S6): 그 곡을 쓰는 동안 누른 ⌘Z는 되돌리지 않고 누른 요청으로 두었다가, 잠금이 풀리면 누른 차례대로 실행한다
    @Test func 쓰는_동안_누른_실행_취소는_잠금이_풀리면_누른_차례대로_실행한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = manager(h.deck)
        h.deck.addMemoryCue(at: 10)
        h.deck.addMemoryCue(at: 20)
        let uuid = try #require(h.deck.row?.track.uuid)
        h.deck.lockedTracks = [uuid]
        undo.undo()
        undo.undo()
        #expect(h.deck.draft?.cues.count == 2, "쓰는 동안에는 되돌리지 않는다")
        h.deck.lockedTracks = []
        #expect(h.deck.draft?.cues.isEmpty == true, "풀리면 누른 두 요청을 차례로 실행한다")
        #expect(!undo.canUndo, "실행 취소 기록에 다시 올리지 않는다")
    }

    /// R12(#405): 분석 붙이기(분석 파일 없는 곡에 그리드를 처음 둔 편집)는 저장 뒤 되돌리지 않는다. 쓴 뒤 다시 읽어 그 곡에 rekordbox 그리드가
    /// 생기면 그 ⌘Z는 기록에서 빠져 메뉴가 꺼진다(무동작이 아니다)
    @Test func 분석을_붙인_그리드_편집은_저장_뒤_실행_취소가_꺼진다() async throws {
        let drafts = MemoryDrafts()
        let storage = DeckStorage.memory(drafts)
        let segment = GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)
        var assets = MemoryTrackAssets()
        let analysed = "/PIONEER/USBANLZ/after/ANLZ0000.DAT"
        assets.analysis[analysed] = .init(grid: .grid(GridDraft(trackUUID: "track-1", base: [segment], segments: [segment]).grid(duration: 181)))
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, reader: .memory(storage, assets), runsAnalysis: false)
        let undo = manager(deck)
        func track(_ analysis: String?) -> Track {
            Track(id: "1", uuid: "track-1", title: "시험 곡", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                  releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180, folderPath: "/tmp/silence.wav", comment: "",
                  importedOn: nil, analysisDataPath: analysis, imagePath: nil, isDeleted: false)
        }
        deck.load(TrackRow(track: track(nil), cues: [], playCount: 0))
        #expect(await waitForState(until: { deck.draft != nil }))
        // 분석 전 곡에 그리드를 처음 둔다(쓰면 분석 파일을 붙인다)
        let before = deck.draftSnapshot
        deck.gridDraft = GridDraft(trackUUID: "track-1", base: [], segments: [segment])
        deck.registerDraftUndo(from: before, name: "추정 그리드 적용")
        #expect(undo.canUndo)
        // 쓴 뒤 다시 읽음: rekordbox에 분석 파일과 그리드가 생겼다
        drafts.removeGrid("track-1")
        deck.refreshAfterWrite(TrackRow(track: track(analysed), cues: [], playCount: 0))
        #expect(await waitForState(until: { !deck.isEditLocked && deck.originalGrid != nil }))
        #expect(!undo.canUndo, "되돌릴 수 없는 단계는 기록에서 빠진다")
    }

    /// 쓴 뒤 큐를 하나로 정할 수 없으면(쓰기가 새 큐 ID를 돌려주지 않음) 그 ⌘Z는 꺼진다. 돌려주면 남는다
    @Test(arguments: [false, true])
    func 쓴_큐의_새_ID를_받지_못하면_실행_취소가_꺼진다(_ receivesIDs: Bool) async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = manager(h.deck)
        h.deck.addMemoryCue(at: 30)
        let added = try #require(h.deck.draft?.cues.first { $0.time == 30 })
        #expect(undo.canUndo)
        // 쓴 뒤: 초안은 지워지고 rekordbox에 새 ID의 큐가 있다
        h.drafts.save(CueDraft(trackUUID: "track-1"))
        let row = try #require(h.deck.row)
        let written = Cue(id: "N1", contentID: "1", kind: 0, inMsec: 30_000, name: "", colorTableIndex: nil)
        h.deck.refreshAfterWrite(TrackRow(track: row.track, cues: [written], playCount: 0), cueIDs: receivesIDs ? [added.id.uuidString: "N1"] : [:])
        #expect(await waitForState(until: { !h.deck.isEditLocked }))
        #expect(undo.canUndo == receivesIDs)
    }

    @Test func 쓰기_중에는_새로운_초안도_만들지_않는다() async throws {
        let h = try DeckHarness(autoGain: RekordboxAutoGain(gain: 1, peak: 0.9))
        try await h.loaded()
        let undo = manager(h.deck), before = h.deck.draftSnapshot
        h.deck.editsFrozen = true
        h.deck.pressHotCue(slot: 0)
        h.deck.setTrackGain(-3)
        h.deck.shiftGrid(ms: 100)
        h.deck.beginGridDrag()
        h.deck.dragGrid(by: 1)
        h.deck.endGridDrag()
        #expect(h.deck.draftSnapshot == before && !undo.canUndo)
    }

    @Test func 태그_중복_셀과_무변경은_한_번만_복원한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = manager(h.deck)
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        store.undoManager = undo
        let row = try #require(h.deck.row)
        store.rowsByUUID[row.track.uuid] = row
        store.tags.applyTagEdits([(row, .title, "첫 값"), (row, .title, "끝 값")])
        #expect(store.tags.tagCell(row, .title) == "끝 값")
        undo.undo()
        #expect(store.tagDrafts.isEmpty && !undo.canUndo)
        undo.redo()
        store.tags.setTag(.title, "끝 값", rows: [row])
        undo.undo()
        #expect(store.tagDrafts.isEmpty && !undo.canUndo)
    }

    @Test func 태그_표의_메뉴_액션은_셀을_수정하고_텍스트_포커스는_보호한다() async throws {
        _ = NSApplication.shared
        let h = try DeckHarness()
        try await h.loaded()
        let undo = manager(h.deck)
        let store = LibraryStore.test(saveTagDrafts: { _ in })
        store.undoManager = undo
        let row = try #require(h.deck.row)
        let coordinator = SheetCoordinator(store: store)
        coordinator.update(rows: [row, row], revision: 0)
        let table = SheetTableView()
        table.coordinator = coordinator
        coordinator.table = table
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(table)
        #expect(window.makeFirstResponder(table))
        coordinator.select(.init(row: 1, column: SheetColumn.titleIndex), extend: true)
        #expect(store.canFillDownTags)
        let delete = NSMenuItem(title: "지우기", action: #selector(SheetTableView.delete(_:)), keyEquivalent: "")
        #expect(table.validateUserInterfaceItem(delete))
        table.delete(nil)
        #expect(store.tags.tagCell(row, .title).isEmpty)
        undo.undo()
        #expect(store.tags.tagCell(row, .title) == row.track.title)
        let text = NSTextView()
        window.contentView?.addSubview(text)
        window.makeFirstResponder(text)
        #expect(!store.canFillDownTags)
        #expect(!KeyRoutingPolicy.accepts(6, in: .init(hasShortcutModifiers: true, focus: .textInput)))
        #expect(!KeyRoutingPolicy.accepts(6, in: .init(hasShortcutModifiers: true, focus: .sheet)))
        store.isWritingRekordbox = true
        #expect(!table.validateUserInterfaceItem(delete))
    }

    @Test func 추정_그리드는_없는_초안까지_복원하고_자동_분석은_이력을_남기지_않는다() async throws {
        let h = try DeckHarness(grid: nil)
        try await h.loaded()
        let undo = manager(h.deck)
        let beats = (0..<40).map { Double($0) * 0.5 }
        let suggestion: GridEstimator.Estimate = try #require(GridEstimator.estimate(beats: beats, bars: [0, 2, 4, 6], duration: 20))
        h.deck.gridSuggestion = suggestion
        h.deck.applyGridSuggestion()
        let grid = h.deck.gridDraft
        #expect(grid != nil)
        undo.undo()
        #expect(h.deck.gridDraft == nil && h.drafts.grid("track-1") == nil)
        undo.redo()
        #expect(h.deck.gridDraft == grid && h.drafts.grid("track-1") == grid)
        undo.removeAllActions()
        h.deck.gridSuggestion?.segments[0].start += 0.1
        h.deck.applyGridSuggestion(recordingUndo: false)
        #expect(h.deck.gridDraft != grid && !undo.canUndo)
    }

}
