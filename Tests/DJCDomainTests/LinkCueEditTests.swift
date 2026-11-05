@testable import DJCDomain
import Foundation
import Testing

/// LINK로 CDJ가 보낸 큐 저장·삭제(#280)를 큐 초안에 옮긴다. 시각은 rekordbox 시간축 ms다.
@Suite("LINK 큐 편집")
struct LinkCueEditTests {
    let rekordboxCues = [
        Cue(id: "1", contentID: "c", kind: 0, inMsec: 10_000, name: "", colorTableIndex: nil),
        Cue(id: "2", contentID: "c", kind: 1, inMsec: 20_000, name: "", colorTableIndex: nil),
    ]

    func edit(_ kind: Int, _ inMs: UInt32, out: UInt32? = nil, deleted: Bool = false, comment: String = "") -> LinkCueEdit {
        LinkCueEdit(contentID: "c", deleted: deleted, kind: kind, inMs: inMs, outMs: out, comment: comment)
    }

    @Test func MEMORY는_메모리_큐를_더하고_같은_자리면_그대로_둔다() {
        var draft = CueDraft(trackUUID: "t", rekordboxCues: rekordboxCues)
        #expect(draft.apply(edit(0, 30_000), newID: { UUID() }) == .applied)
        #expect(draft.cues.filter { $0.kind == .memory }.map(\.time) == [10, 30])
        #expect(draft.apply(edit(0, 30_010), newID: { UUID() }) == .unchanged)
        #expect(draft.memoryCount == 2)
    }

    @Test func 메모리_루프와_활성_루프를_받는다() throws {
        var draft = CueDraft(trackUUID: "t", rekordboxCues: [])
        #expect(draft.apply(edit(0, 1_000, out: 3_000), newID: { UUID() }) == .applied)
        #expect(draft.apply(edit(4, 5_000, out: 6_000), newID: { UUID() }) == .applied)
        let loop = try #require(draft.cues.first { $0.time == 1 }?.loop)
        #expect(loop.end == 3 && !loop.active)
        let active = try #require(draft.cues.first { $0.time == 5 })
        #expect(active.kind == .memory && active.loop?.end == 6 && active.loop?.active == true)
        // 활성 루프는 하나만: 새 활성 루프가 오면 앞 것은 꺼진다
        #expect(draft.apply(edit(4, 8_000, out: 9_000), newID: { UUID() }) == .applied)
        #expect(draft.cues.filter { $0.loop?.active == true }.map(\.time) == [8])
    }

    @Test func 핫큐는_그_칸을_바꾸고_rekordbox_큐_ID를_이어받는다() throws {
        var draft = CueDraft(trackUUID: "t", rekordboxCues: rekordboxCues)
        #expect(draft.apply(edit(1, 25_000), newID: { UUID() }) == .applied)
        let a = try #require(draft.hotCue(slot: 0))
        #expect(a.time == 25 && a.sourceID == "2")
        #expect(draft.cues.filter { $0.kind == .hot(0) }.count == 1)
        // D~H는 Kind 5~9
        #expect(draft.apply(edit(5, 40_000), newID: { UUID() }) == .applied)
        #expect(draft.hotCue(slot: 3)?.time == 40)
    }

    @Test func DELETE는_가까운_메모리_큐나_그_칸의_핫큐를_지운다() {
        var draft = CueDraft(trackUUID: "t", rekordboxCues: rekordboxCues)
        #expect(draft.apply(edit(0, 10_020, deleted: true), newID: { UUID() }) == .applied)
        #expect(draft.memoryCount == 0)
        #expect(draft.apply(edit(1, 20_000, deleted: true), newID: { UUID() }) == .applied)
        #expect(draft.hotCue(slot: 0) == nil)
        #expect(draft.apply(edit(0, 50_000, deleted: true), newID: { UUID() }) == .unchanged)
        #expect(draft.changes.count == 2)
    }

    @Test func 메모리_큐가_한도면_더하지_않고_알린다() {
        var draft = CueDraft(trackUUID: "t", rekordboxCues: [])
        for second in 0..<CueDraft.memoryLimit { _ = draft.apply(edit(0, UInt32(second) * 1_000), newID: { UUID() }) }
        #expect(draft.apply(edit(0, 60_000), newID: { UUID() }) == .memoryLimit)
        #expect(draft.memoryCount == CueDraft.memoryLimit)
    }

    @Test func 모르는_종류는_받지_않는다() {
        var draft = CueDraft(trackUUID: "t", rekordboxCues: [])
        #expect(draft.apply(edit(12, 1_000), newID: { UUID() }) == .unsupported)
        #expect(draft.cues.isEmpty)
    }

    @Test func 초안을_rekordbox_큐_모양으로_바꾸고_고치지_않은_큐는_색을_이어받는다() {
        let colored = [Cue(id: "1", contentID: "c", kind: 1, inMsec: 20_000, name: "", colorTableIndex: 3),
                       Cue(id: "2", contentID: "c", kind: 0, inMsec: 10_000, name: "", colorTableIndex: 1)]
        var draft = CueDraft(trackUUID: "t", rekordboxCues: colored)
        _ = draft.apply(edit(0, 10_000, deleted: true), newID: { UUID() })
        _ = draft.apply(edit(6, 40_000), newID: { UUID() })
        _ = draft.apply(edit(4, 50_000, out: 52_000), newID: { UUID() })
        let cues = draft.rekordboxShapedCues(contentID: "c", rekordboxCues: colored)
        #expect(cues.map(\.kind) == [1, 6, 0])
        #expect(cues.map(\.inMsec) == [20_000, 40_000, 50_000])
        #expect(cues[0].colorTableIndex == 3 && cues[1].colorTableIndex == nil)
        #expect(cues[2].outMsec == 52_000 && cues[2].activeLoop == 1)
    }
}
