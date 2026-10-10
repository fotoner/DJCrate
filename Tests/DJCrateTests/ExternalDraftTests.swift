import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

@Suite("외부 초안 다시 읽기")
@MainActor
struct ExternalDraftTests {
    @Test func 저장하지_않은_드래그는_외부_초안이_덮지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = UndoManager()
        h.deck.undoManager = undo
        let initial = try #require(h.deck.draft)
        h.deck.mutate(save: false) { $0.place(EditableCue(kind: .hot(3), time: 35)) }
        h.deck.reloadExternalCueDraft(initial)
        #expect(h.deck.hotCue(slot: 3)?.time == 35)
        #expect(h.deck.hasUncommittedCueEdits && h.deck.pendingDraftUndo != nil)
        h.deck.commitDraft()
        undo.undo()
        #expect(h.deck.draft == initial && !h.deck.hasUncommittedCueEdits)
    }

    @Test(arguments: [false, true], [false, true])
    func 외부_태그_변경은_태그_이력만_비운다(undoFirst: Bool, delete: Bool) async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = UndoManager()
        h.deck.undoManager = undo
        var saved: [TagDraft] = []
        let home = h.root.appending(path: "home")
        let store = LibraryStore.test(saveTagDrafts: { saved += $0 }, draftHome: home, movesDamagedDrafts: false)
        store.undoManager = undo
        store.phase = .loaded
        let row = try #require(h.deck.row)
        store.rowsByUUID[row.track.uuid] = row
        let directory = home.appending(path: "tag-drafts")
        h.deck.pressHotCue(slot: 0)
        store.tags.setTag(.title, "첫 제목", rows: [row])
        store.tags.setTag(.title, "둘째 제목", rows: [row])
        if undoFirst { undo.undo() }
        var external = try #require(store.tagDrafts[row.track.uuid])
        try TagDraftStore.save(external, directory: directory)
        await store.refreshExternalDrafts()
        #expect(undo.undoActionName == "태그 편집" && undo.canRedo == undoFirst)
        let savedCount = saved.count

        if delete {
            try TagDraftStore.remove(trackUUID: row.track.uuid, directory: directory)
        } else {
            external.fields.title = "외부에서 고친 제목"
            try TagDraftStore.save(external, directory: directory)
        }
        await store.refreshExternalDrafts()
        let expected: TagDraft? = delete ? nil : external
        #expect(store.tagDrafts[row.track.uuid] == expected)
        #expect(undo.canUndo && !undo.canRedo)
        undo.undo()
        #expect(h.deck.hotCue(slot: 0) == nil && !undo.canUndo)
        #expect(store.tagDrafts[row.track.uuid] == expected)
        undo.redo()
        #expect(h.deck.hotCue(slot: 0) != nil)
        #expect(store.tagDrafts[row.track.uuid] == expected && saved.count == savedCount)
    }

    @Test(arguments: [false, true], [false, true])
    func 외부_큐_변경은_덱_이력만_비운다(undoFirst: Bool, delete: Bool) async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let undo = UndoManager()
        h.deck.undoManager = undo
        let home = h.root.appending(path: "home")
        let store = LibraryStore.test(saveTagDrafts: { _ in }, draftHome: home, movesDamagedDrafts: false)
        store.undoManager = undo
        store.phase = .loaded
        let row = try #require(h.deck.row)
        store.rowsByUUID[row.track.uuid] = row
        store.onCueDraftsReloaded = { drafts in h.deck.reloadExternalCueDraft(drafts[row.track.uuid]) }
        let directory = home.appending(path: "cue-drafts")
        store.tags.setTag(.title, "앱에서 고친 제목", rows: [row])
        let tag = try #require(store.tagDrafts[row.track.uuid])
        try TagDraftStore.save(tag, directory: home.appending(path: "tag-drafts"))
        h.deck.pressHotCue(slot: 0)
        h.deck.pressHotCue(slot: 1)
        if undoFirst { undo.undo() }
        var external = try #require(h.deck.draft)
        try CueDraftStore.save(external, directory: directory)
        await store.refreshExternalDrafts()
        #expect(undo.undoActionName == "핫큐 찍기" && undo.canRedo == undoFirst)
        let persisted = h.drafts.cue(row.track.uuid)

        if delete {
            try CueDraftStore.remove(trackUUID: row.track.uuid, directory: directory)
        } else {
            external.place(EditableCue(kind: .hot(3), time: 30))
            try CueDraftStore.save(external, directory: directory)
        }
        await store.refreshExternalDrafts()
        let expected = delete ? CueDraft(trackUUID: row.track.uuid, rekordboxCues: row.cues, newID: { UUID() }) : external
        #expect(h.deck.draft == expected)
        #expect(undo.canUndo && !undo.canRedo)
        undo.undo()
        #expect(store.tagDrafts.isEmpty && !undo.canUndo)
        #expect(h.deck.draft == expected)
        undo.redo()
        #expect(store.tagDrafts[row.track.uuid] == tag)
        #expect(h.deck.draft == expected && h.drafts.cue(row.track.uuid) == persisted)
    }

    /// #145: 자동 큐를 빼고 만든 옛 초안 파일도 곡 목록 수·미리 보기·덱에 자동 큐를 채워 보인다(덱과 목록이 같은 수).
    @Test func 옛_초안_파일에는_곡의_자동_큐를_채운다() async throws {
        let auto = Cue(id: "auto", contentID: "1", kind: 0, inMsec: 350, name: "1.1Bars", colorTableIndex: 0, color: 255)
        let h = try DeckHarness(cues: [auto])
        try await h.loaded()
        let row = try #require(h.deck.row)
        let home = h.root.appending(path: "home")
        let store = LibraryStore.test(draftHome: home, movesDamagedDrafts: false)
        store.phase = .loaded
        store.rowsByUUID[row.track.uuid] = row
        store.onCueDraftsReloaded = { drafts in h.deck.reloadExternalCueDraft(drafts[row.track.uuid]) }
        var old = CueDraft(trackUUID: row.track.uuid)
        old.place(EditableCue(kind: .memory, time: 20))
        try CueDraftStore.save(old, directory: home.appending(path: "cue-drafts"))
        await store.refreshExternalDrafts()
        #expect(store.draftCueCounts[row.track.uuid].map { row.memoryCueLabel(draft: $0) } == .count(2))
        #expect(store.draftPreviewCues[row.track.uuid]?.count == 2)
        #expect(h.deck.draft?.cues.count == 2 && h.deck.draft?.cues.first?.isAutoGenerated == true)
        #expect(h.deck.draft?.changes.count == 1)
    }

    @Test func 파일_생성_수정_삭제가_목록과_덱에_반영된다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let folder = try TemporaryFolder(), home = folder.url.appending(path: "home")
        let row = try #require(h.deck.row)
        let store = LibraryStore.test(draftHome: home, movesDamagedDrafts: false)
        store.phase = .loaded
        store.rowsByUUID[row.track.uuid] = row
        store.onCueDraftsReloaded = { drafts in h.deck.reloadExternalCueDraft(drafts[row.track.uuid]) }
        await store.refreshExternalDrafts()
        h.deck.seek(20)
        let original = try #require(h.deck.draft)
        var draft = original
        draft.place(EditableCue(kind: .hot(3), time: 30))
        let cueDirectory = home.appending(path: "cue-drafts")
        try CueDraftStore.save(draft, directory: cueDirectory)
        var tag = TagDraft(track: row.track)
        tag.fields.title = "외부 제목"
        try TagDraftStore.save(tag, directory: home.appending(path: "tag-drafts"))
        await store.refreshExternalDrafts()
        #expect(store.pendingUUIDs.contains(row.track.uuid))
        #expect(store.tagDrafts[row.track.uuid]?.fields.title == "외부 제목")
        #expect(h.deck.hotCue(slot: 3)?.time == 30 && h.deck.playhead == 20)
        draft.place(EditableCue(kind: .hot(3), time: 40))
        try CueDraftStore.save(draft, directory: cueDirectory)
        await store.refreshExternalDrafts()
        #expect(h.deck.hotCue(slot: 3)?.time == 40)
        try CueDraftStore.remove(trackUUID: row.track.uuid, directory: cueDirectory)
        try TagDraftStore.remove(trackUUID: row.track.uuid, directory: home.appending(path: "tag-drafts"))
        await store.refreshExternalDrafts()
        #expect(store.pendingUUIDs.isEmpty && store.tagDrafts.isEmpty)
        #expect(h.deck.draft?.hasChanges == false && h.deck.playhead == 20)
    }

    /// #72: rekordbox XML 가져오기가 만든 그리드 초안을 덱이 받는다. 덱 초안이 바뀌지 않았을 때만 받는다.
    @Test func 바꾸지_않은_덱_그리드는_가져온_초안으로_바꾸고_이어_편집한다() async throws {
        let base = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]
        let h = try DeckHarness(grid: base, gridBase: base)
        try await h.loaded()
        #expect(h.deck.gridDraft?.hasChanges == false)
        let imported = GridDraft(trackUUID: "track-1", base: base, segments: [GridSegment(start: 0.5, bpm: 125, firstBeatNumber: 1)])
        #expect(h.deck.adoptImportedGridDraft(imported))
        #expect(h.deck.gridDraft == imported)
        #expect(await waitForState { h.drafts.grid("track-1") == imported }, "덱이 자기 저장 경로로 저장한다")
        // 이어지는 덱 편집은 가져온 초안 위에 쌓인다
        h.deck.shiftGrid(ms: 10)
        #expect(h.deck.gridDraft?.segments.first?.bpm == 125)
        // 되돌리면 원래 rekordbox 그리드로 간다(가져온 초안이 덱 화면에 보였으므로)
        h.deck.revertGrid()
        #expect(h.deck.gridDraft?.segments == base)
    }

    @Test func 덱에서_고친_그리드는_가져온_초안으로_덮지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let before = h.deck.gridDraft
        #expect(before?.hasChanges == true)
        let imported = GridDraft(trackUUID: "track-1", base: [], segments: [GridSegment(start: 0.5, bpm: 125, firstBeatNumber: 1)])
        #expect(!h.deck.adoptImportedGridDraft(imported))
        #expect(h.deck.gridDraft == before)
        let other = GridDraft(trackUUID: "다른 곡", base: [], segments: [GridSegment(start: 0.5, bpm: 125, firstBeatNumber: 1)])
        #expect(!h.deck.adoptImportedGridDraft(other))
    }
}
