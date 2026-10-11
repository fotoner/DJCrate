import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 덱의 큐·그리드·게인 초안 저장(유스케이스 `SaveDeckDrafts`): 덱 화면 모델은 초안 저장소를 들지 않고 이 유스케이스만 부른다.
@Suite("덱 초안 저장")
struct SaveDeckDraftsTests {
    @Test func 큐_그리드_게인을_저장소에_쓰고_지금_그리드를_읽는다() {
        let memory = MemoryDrafts()
        let drafts = SaveDeckDrafts(drafts: memory.store)
        var cue = CueDraft(trackUUID: "a")
        cue.place(EditableCue(id: UUID(), kind: .memory, time: 1))
        drafts.saveCue(cue) { _ in }
        let grid = GridDraft(trackUUID: "a", base: [], segments: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)])
        drafts.saveGrid(grid) { _ in }
        drafts.saveGain(-3, trackUUID: "a") { _ in }

        #expect(memory.cue("a") == cue)
        #expect(drafts.currentGrid("a") == grid)
        #expect(memory.gain("a") == -3)
        drafts.removeGrid("a") { _ in }
        #expect(drafts.currentGrid("a") == nil)
    }

    @Test func 지금_실패는_덱이_받은_실패를_앞에_두고_해소된_것을_빼고_저장소_실패를_종류별로_더한다() {
        var store = MemoryDrafts().store
        let resolved = DraftSaveFailure(kind: .grid, trackUUID: "a", revision: 1, reason: "해소됨")
        let reported = DraftSaveFailure(kind: .cue, trackUUID: "a", revision: 2, reason: "덱이 받음")
        let knownCue = DraftSaveFailure(kind: .cue, trackUUID: "a", revision: 1, reason: "저장소의 옛 큐 실패")
        let knownGain = DraftSaveFailure(kind: .gain, trackUUID: "a", revision: 1, reason: "저장소의 게인 실패")
        let otherTrack = DraftSaveFailure(kind: .gain, trackUUID: "b", revision: 1, reason: "다른 곡")
        store.isResolved = { $0 == resolved }
        store.failures = { [knownCue, knownGain, otherTrack] }
        let drafts = SaveDeckDrafts(drafts: store)

        #expect(drafts.currentFailures("a", reported: [resolved, reported, otherTrack]) == [reported, knownGain])
    }

    @Test func 다시_저장은_저장소의_마지막_입력으로_한다() {
        var store = MemoryDrafts().store
        let retried = Mutex<[String]>([])
        store.retry = { kind, uuid, completion in
            retried.withLock { $0.append("\(kind):\(uuid)") }
            completion(nil)
            return true
        }
        let drafts = SaveDeckDrafts(drafts: store)
        drafts.retry(.grid, trackUUID: "a") { _ in }
        #expect(retried.withLock { $0 } == ["grid:a"])
    }

    @Test func 새_큐_ID는_저장소가_준다() {
        var store = MemoryDrafts().store
        let id = UUID()
        store.newCueID = { id }
        #expect(SaveDeckDrafts(drafts: store).newCueID() == id)
    }
}
