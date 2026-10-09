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
        h.deck.isWriteLocked = true
        undo.undo()
        #expect(h.deck.hotCue(slot: 0) != nil)
        #expect(!undo.canUndo && !undo.canRedo)
        h.deck.isWriteLocked = false
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
        store.applyTagEdits([(row, .title, "새 제목"), (row, .artist, "새 아티스트")])
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
        store.setTag(.title, "차단", rows: [row])
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
        h.deck.refreshAfterWrite(h.deck.row)
        #expect(!undo.canUndo && !undo.canRedo)
    }

    @Test func 쓰기_중에는_새로운_초안도_만들지_않는다() async throws {
        let h = try DeckHarness(autoGain: RekordboxAutoGain(gain: 1, peak: 0.9))
        try await h.loaded()
        let undo = manager(h.deck), before = h.deck.draftSnapshot
        h.deck.isWriteLocked = true
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
        store.applyTagEdits([(row, .title, "첫 값"), (row, .title, "끝 값")])
        #expect(store.tagCell(row, .title) == "끝 값")
        undo.undo()
        #expect(store.tagDrafts.isEmpty && !undo.canUndo)
        undo.redo()
        store.setTag(.title, "끝 값", rows: [row])
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
        coordinator.select(.init(row: 1, column: 1), extend: true)
        #expect(store.canFillDownTags)
        let delete = NSMenuItem(title: "지우기", action: #selector(SheetTableView.delete(_:)), keyEquivalent: "")
        #expect(table.validateUserInterfaceItem(delete))
        table.delete(nil)
        #expect(store.tagCell(row, .title).isEmpty)
        undo.undo()
        #expect(store.tagCell(row, .title) == row.track.title)
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
