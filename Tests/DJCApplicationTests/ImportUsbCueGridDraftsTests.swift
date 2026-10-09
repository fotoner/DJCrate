import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// USB 큐·그리드를 이 라이브러리 초안으로 넣는 쪽(유스케이스 `ImportUsbCueGridDrafts`). 옛 `LibraryStore+UsbImport`가 화면 모델 안에서
/// 초안 파일 포트 구현(`UsbCueGridDraftFiles`)을 만들던 규칙을 앱 없이 본다: 걸린 저장을 먼저 끝내고, 저장 대기 입력·초안 파일·화면의 메모리 입력이
/// 있는 칸은 덮지 않는다.
@MainActor
@Suite("USB 큐·그리드 → 라이브러리 초안")
struct ImportUsbCueGridDraftsTests {
    typealias Plan = UsbCueGridImportSaveTests

    final class Counter: Sendable {
        private let value = Mutex(0)
        func add() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    static func importer(drafts: DraftStore, files: MemoryDraftFiles, flushed: Counter = Counter()) -> ImportUsbCueGridDrafts {
        var drafts = drafts
        drafts.flush = { flushed.add() }
        return ImportUsbCueGridDrafts(drafts: drafts, files: files.files, newKey: { "KEY" })
    }

    static func cue(_ uuid: String, slot: Int, at time: Double) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.cues = [EditableCue(kind: .hot(slot), time: time)]
        return draft
    }

    @Test func 걸린_저장을_끝낸_뒤_빈_칸만_곡별_파일로_쓴다() {
        let files = MemoryDraftFiles(), flushed = Counter()
        let plan = UsbCueGridImportPlan(rows: [Plan.row("a", title: "A"), Plan.row("b", title: "B")])

        let saved = Self.importer(drafts: MemoryDrafts().store, files: files, flushed: flushed).save(plan) { _, _ in false }

        #expect(flushed.count == 1)
        #expect(files.cue("a") != nil && files.grid("b") != nil)
        #expect(saved.cues.map { $0.trackUUID } == ["a", "b"] && saved.gridUUIDs == ["a", "b"])
    }

    @Test func 저장_대기_입력_초안_파일_메모리_입력이_있는_칸은_덮지_않는다() {
        let files = MemoryDraftFiles()
        files.put(GridDraft(trackUUID: "b", base: [], segments: [GridSegment(start: 0, bpm: 90, firstBeatNumber: 1)]))
        var drafts = MemoryDrafts().store
        let pending = Self.cue("c", slot: 1, at: 9)
        drafts.pendingCue = { $0 == "c" ? pending : nil }
        let plan = UsbCueGridImportPlan(rows: [Plan.row("a", title: "A"), Plan.row("b", title: "B"), Plan.row("c", title: "C")])

        let saved = Self.importer(drafts: drafts, files: files).save(plan) { uuid, part in uuid == "a" && part == .grid }

        #expect(saved.cues.map { $0.trackUUID } == ["a", "b"], "c는 저장 대기 큐 입력이 있다")
        #expect(saved.gridUUIDs == ["c"], "a는 화면의 메모리 입력, b는 그리드 초안 파일이 있다")
        #expect(files.grid("b")?.segments.first?.bpm == 90)
    }

    @Test func 덱에_넘길_큐_초안은_저장_대기_입력이_파일보다_먼저다() {
        let memory = MemoryDrafts()
        var disk = CueDraft(trackUUID: "a")
        disk.cues = [EditableCue(kind: .hot(0), time: 1)]
        memory.save(disk)
        var drafts = memory.store
        let pending = Self.cue("b", slot: 2, at: 3)
        drafts.pendingCue = { $0 == "b" ? pending : nil }

        let cues = Self.importer(drafts: drafts, files: MemoryDraftFiles()).cueDrafts(["a", "b", "none"])

        #expect(cues == ["a": disk, "b": pending])
    }

    @Test func USB_사본을_읽을_작업_폴더는_초안_폴더_아래_새_이름이다() {
        let folder = Self.importer(drafts: MemoryDrafts().store, files: MemoryDraftFiles()).scratchFolder(in: URL(filePath: "/home"))
        #expect(folder == URL(filePath: "/home/usb-snapshots/import-KEY"))
    }
}
