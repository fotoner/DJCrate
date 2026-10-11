import DJCDomain
import Foundation
import Testing

/// 편집 가능한 큐의 ID는 부르는 쪽이 준다(핵심부는 `UUID()`를 직접 부르지 않는다, #167). 받은 ID를 그대로 쓰는지와
/// 저장한 초안의 모양(JSON)이 그대로인지 본다.
@Suite("큐 ID 주입")
struct CueIDInjectionTests {
    /// 차례로 00…01, 00…02 … 를 주는 ID
    final class Sequence {
        private(set) var count = 0
        func next() -> UUID {
            count += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", count))!
        }
        static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    }

    static func cue(_ id: String, kind: Int, ms: Int, name: String = "") -> Cue {
        Cue(id: id, contentID: "1", kind: kind, inMsec: ms, name: name, colorTableIndex: nil)
    }

    @Test func rekordbox_큐로_만든_초안은_받은_ID를_base와_cues에_같게_붙인다() {
        let ids = Sequence()
        // Kind 4(의미 미확인)는 편집 대상이 아니라 ID를 받지 않는다
        let draft = CueDraft(trackUUID: "u", rekordboxCues: [Self.cue("b", kind: 1, ms: 2_000), Self.cue("x", kind: 4, ms: 500),
                                                             Self.cue("a", kind: 0, ms: 1_000)], newID: ids.next)
        #expect(draft.base.map(\.sourceID) == ["a", "b"])
        #expect(Set(draft.base.map(\.id)) == [Sequence.id(1), Sequence.id(2)])
        #expect(draft.cues == draft.base && !draft.hasChanges)
        #expect(ids.count == 2)
    }

    @Test func 자동_큐를_채울_때_받은_ID를_쓰고_없으면_묻지_않는다() {
        let ids = Sequence()
        let draft = CueDraft(trackUUID: "u")
        let filled = draft.includingAutoCues(from: [Self.cue("auto", kind: 0, ms: 350, name: "1.1Bars"), Self.cue("m", kind: 0, ms: 900)],
                                             newID: ids.next)
        #expect(filled.base.map(\.id) == [Sequence.id(1)] && filled.cues.map(\.id) == [Sequence.id(1)])
        #expect(!filled.hasChanges)
        _ = filled.includingAutoCues(from: [Self.cue("auto", kind: 0, ms: 350, name: "1.1Bars")], newID: ids.next)
        #expect(ids.count == 1, "이미 있는 자동 큐는 다시 만들지 않는다")
    }

    @Test func 빈_초안은_ID를_만들지_않는다() {
        let draft = CueDraft(trackUUID: "u")
        #expect(draft.trackUUID == "u" && draft.base.isEmpty && draft.cues.isEmpty)
    }

    @Test func 메모리_큐를_더할_때만_받은_ID를_쓴다() {
        let ids = Sequence()
        var draft = CueDraft(trackUUID: "u")
        guard case let .added(first) = draft.addMemory(at: 10, newID: ids.next) else { Issue.record("더하지 않았다"); return }
        #expect(first == Sequence.id(1) && draft.cues.map(\.id) == [Sequence.id(1)])
        // 같은 자리(±30ms)면 있는 큐를 돌려주고 ID를 만들지 않는다
        #expect(draft.addMemory(at: 10.02, newID: ids.next) == .existing(Sequence.id(1)))
        #expect(ids.count == 1)
    }

    @Test func 편집_조각으로_옮긴_큐는_받은_ID를_쓴다() throws {
        let edit = try TrackEdit(grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], sourceDuration: 100.5,
                                 bars: BarRange.list("1-16"))
        let source = EditableCue(id: Sequence.id(99), kind: .hot(0), time: 0.5)
        let ids = Sequence()
        let carried = edit.carry([source], newID: ids.next)
        #expect(carried.placed.map(\.id) == [Sequence.id(1)])
    }

    @Test func 저장한_초안의_모양은_그대로다() throws {
        // 옛 초안 파일 모양(ID·rekordbox ID·종류·시각·이름·루프)을 그대로 읽고, 다시 쓰면 같은 값이다
        let json = """
        {"trackUUID":"u","base":[{"id":"00000000-0000-0000-0000-000000000001","sourceID":"9","kind":{"hot":{"_0":2}},"time":1.5,"name":"A"}],
         "cues":[{"id":"00000000-0000-0000-0000-000000000001","sourceID":"9","kind":{"hot":{"_0":2}},"time":1.5,"name":"A"},
                 {"id":"00000000-0000-0000-0000-000000000002","kind":{"memory":{}},"time":3,"name":"","loop":{"end":5,"active":true,"beats":4}}]}
        """
        let draft = try JSONDecoder().decode(CueDraft.self, from: Data(json.utf8))
        #expect(draft.base.map(\.id) == [Sequence.id(1)] && draft.base[0].sourceID == "9" && draft.base[0].kind == .hot(2))
        #expect(draft.cues.map(\.id) == [Sequence.id(1), Sequence.id(2)] && draft.cues[1].loop == EditableCue.Loop(end: 5, active: true, beats: 4))
        #expect(try JSONDecoder().decode(CueDraft.self, from: JSONEncoder().encode(draft)) == draft)
    }
}
