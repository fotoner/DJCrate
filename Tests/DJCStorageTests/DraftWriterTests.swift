import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Synchronization
import Testing

/// 초안 저장 큐는 인스턴스마다 따로다. 조립 지점이 하나를 만들어 나눠 주고, 시험은 저장소마다 새로 만든다(#167 adv4 T5:
/// 전역 큐를 함께 쓰던 때 한 시험의 느린 저장이 다른 시험의 기다리기를 5초 넘게 막았다).
@Suite("초안 저장 큐 인스턴스")
struct DraftWriterTests {
    static func cueDraft(_ uuid: String) -> CueDraft {
        var draft = CueDraft(trackUUID: uuid)
        draft.place(EditableCue(kind: .hot(0), time: 1))
        return draft
    }

    @Test func 다른_인스턴스의_느린_저장을_기다리지_않는다() throws {
        let folder = try TemporaryFolder()
        let places = DraftLocations(home: folder.url)
        let slow = DraftWriter(), fast = DraftWriter()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); slow.flush() }
        slow.save(Self.cueDraft("a"), directory: places.cue, write: { _, _ in gate.wait() })
        let started = ContinuousClock.now
        fast.save(Self.cueDraft("b"), directory: places.cue)
        fast.flush()
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(CueDraftStore.load(trackUUID: "b", directory: places.cue) != nil)
        #expect(slow.unsavedUUIDs(in: places) == ["a"] && fast.unsavedUUIDs(in: places).isEmpty)
    }

    @Test func 저장_실패와_태그_실패는_그_인스턴스에만_남는다() throws {
        let folder = try TemporaryFolder()
        let places = DraftLocations(home: folder.url)
        let failing = DraftWriter(), other = DraftWriter()
        failing.save(Self.cueDraft("a"), directory: places.cue, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        // 태그 폴더 자리에 파일을 둬 태그 저장을 실패시킨다.
        try Data([0]).write(to: places.tags)
        var tag = TagDraft(trackUUID: "t", base: TagFields())
        tag.fields.comment = "코멘트"
        failing.save([tag], directory: places.tags)
        failing.flush()
        other.flush()
        #expect(failing.failures(in: places).map(\.trackUUID) == ["a"])
        #expect(failing.failedTagSaveUUIDs(in: places.tags) == ["t"])
        #expect(other.failures(in: places).isEmpty && other.failedTagSaveUUIDs(in: places.tags).isEmpty)
        #expect(other.saveRevision(in: places) == 0 && other.pendingCue(trackUUID: "a", directory: places.cue) == nil)
    }

    @Test func 한_인스턴스는_게인_파일_하나에_맡은_순서대로_쓴다() throws {
        let folder = try TemporaryFolder()
        let places = DraftLocations(home: folder.url)
        let writer = DraftWriter()
        for index in 0..<20 { writer.save(gain: Double(-index), trackUUID: "t\(index)", url: places.gain) }
        writer.removeGain(trackUUID: "t3", url: places.gain)
        writer.flush()
        let gains = try GainDraftStore.read(url: places.gain)
        #expect(gains.count == 19 && gains["t3"] == nil && gains["t19"] == -19)
    }

    @Test func 종류별_재시도는_기록된_입력을_완료와_함께_다시_저장한다() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-followup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = UUID().uuidString
        let grid = GridDraft(trackUUID: uuid, base: [], segments: [GridSegment(start: 1, bpm: 120, firstBeatNumber: 1)])
        let fail = Mutex(true)
        let writer = DraftWriter()
        writer.save(grid, directory: root, write: { draft, directory in
            if fail.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
            try GridDraftStore.save(draft, directory: directory)
        })
        writer.flush()
        let failure = try #require(writer.state(.grid, trackUUID: uuid, directory: root)?.failure)
        #expect(!writer.isResolved(failure, directory: root))
        fail.withLock { $0 = false }
        let completed = Mutex<DraftSaveFailure??>(nil)
        let started = writer.retry(.grid, trackUUID: uuid, directory: root, completion: { result in completed.withLock { $0 = .some(result) } })
        #expect(started)
        writer.flush()
        #expect(completed.withLock { $0 } == .some(nil))
        #expect(GridDraftStore.load(trackUUID: uuid, directory: root) == grid)
        #expect(writer.isResolved(failure, directory: root))
        // 이미 저장된 기록은 다시 저장하지 않는다.
        #expect(!writer.retry(.grid, trackUUID: uuid, directory: root))
    }
}
