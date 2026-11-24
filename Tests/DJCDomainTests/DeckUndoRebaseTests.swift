@testable import DJCDomain
import Foundation
import Testing

/// 저장 뒤 ⌘Z(R12, #405): 덱 편집 한 번의 전후 스냅샷을 지금 rekordbox 값 위로 옮겨 역편집 초안을 만든다.
/// 편집을 아직 쓰지 않았으면(기준이 그대로) 지금처럼 편집 전 초안을 되살린다. 썼으면 지금 rekordbox 값을 base로, 편집 전 값을 목표로 한다.
/// 큐는 ID(정체성)로 찾는다: 쓴 뒤 다시 읽은 base의 큐는 쓰기가 돌려준 새 rekordbox ID를 달고 같은 ID를 이어 받는다.
@Suite("덱 저장 뒤 ⌘Z 역편집")
struct DeckUndoRebaseTests {
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    static func cue(_ n: Int, _ source: String?, _ kind: EditableCue.Kind = .memory, at time: Double, name: String = "",
                    loop: EditableCue.Loop? = nil, color: EditableCue.ColorMark? = nil) -> EditableCue {
        EditableCue(id: id(n), sourceID: source, kind: kind, time: time, name: name, loop: loop, color: color)
    }

    static func snapshot(base: [EditableCue], cues: [EditableCue], grid: GridDraft? = nil, gridBase: [GridSegment]? = nil,
                         gain: Double? = nil, gainBase: Double? = nil) -> DeckDraftSnapshot {
        DeckDraftSnapshot(cue: CueDraft(trackUUID: "t", base: base, cues: cues), grid: grid, gain: gain, gridBlockedReason: nil,
                          gridBase: gridBase, gainBase: gainBase)
    }

    @Test func 아직_쓰지_않은_편집은_편집_전_초안을_그대로_되살린다() throws {
        let base = [Self.cue(1, "10", at: 5)]
        let before = Self.snapshot(base: base, cues: base)
        var moved = base[0]; moved.time = 6
        let after = Self.snapshot(base: base, cues: [moved])
        let applied = try #require(before.rebased(from: after, onto: after))
        #expect(applied == before)
    }

    @Test func 쓴_뒤에는_지금_rekordbox_큐를_base로_옮긴_큐를_되돌린다() throws {
        // 편집: 큐 1(rekordbox 10)을 5초 → 6초. 쓰면 지우고 새로 넣어 rekordbox ID가 20이 된다
        let original = Self.cue(1, "10", at: 5), other = Self.cue(2, "11", .hot(0), at: 30)
        let before = Self.snapshot(base: [original, other], cues: [original, other])
        var moved = original; moved.time = 6
        let after = Self.snapshot(base: [original, other], cues: [moved, other])
        // 쓴 뒤 다시 읽음: 같은 큐 ID에 새 rekordbox ID
        var written = moved; written.sourceID = "20"
        let current = Self.snapshot(base: [written, other], cues: [written, other])
        let applied = try #require(before.rebased(from: after, onto: current))
        #expect(applied.cue.base == [written, other])
        #expect(applied.cue.changes == [.modified(from: written, to: Self.cue(1, "20", at: 5))])
    }

    @Test func 지운_큐는_rekordbox_ID_없이_새_큐로_되살리고_나머지_칸은_그대로다() throws {
        let color = EditableCue.ColorMark(color: 16711680, tableIndex: 3, memory: false)
        let deleted = Self.cue(1, "10", .hot(1), at: 12, name: "드롭", color: color), kept = Self.cue(2, "11", at: 30)
        let before = Self.snapshot(base: [deleted, kept], cues: [deleted, kept])
        let after = Self.snapshot(base: [deleted, kept], cues: [kept])
        let current = Self.snapshot(base: [kept], cues: [kept])
        let applied = try #require(before.rebased(from: after, onto: current))
        var restored = deleted; restored.sourceID = nil
        #expect(applied.cue.changes == [.added(restored)])
        #expect(applied.cue.cues.first { $0.id == deleted.id }?.color == color)
    }

    @Test func 편집이_더한_큐는_쓴_뒤_되돌리면_지운다() throws {
        let kept = Self.cue(2, "11", at: 30), added = Self.cue(3, nil, at: 40)
        let before = Self.snapshot(base: [kept], cues: [kept])
        let after = Self.snapshot(base: [kept], cues: [kept, added])
        var written = added; written.sourceID = "21"
        let current = Self.snapshot(base: [kept, written], cues: [kept, written])
        let applied = try #require(before.rebased(from: after, onto: current))
        #expect(applied.cue.changes == [.removed(written)])
    }

    /// 같은 시각에 메모리 큐와 메모리 루프가 있으면 시각·종류로는 가릴 수 없다: ID로 찾아 옮긴 하나만 되돌린다
    @Test func 같은_시각의_메모리_큐와_메모리_루프_가운데_옮긴_하나만_되돌린다() throws {
        let memory = Self.cue(1, "10", at: 8), loop = Self.cue(2, "11", at: 8, loop: EditableCue.Loop(end: 12, beats: 8))
        let before = Self.snapshot(base: [memory, loop], cues: [memory, loop])
        var movedLoop = loop; movedLoop.time = 9; movedLoop.loop?.end = 13
        let after = Self.snapshot(base: [memory, loop], cues: [memory, movedLoop])
        var written = movedLoop; written.sourceID = "21"
        let current = Self.snapshot(base: [memory, written], cues: [memory, written])
        let applied = try #require(before.rebased(from: after, onto: current))
        #expect(applied.cue.changes == [.modified(from: written, to: Self.cue(2, "21", at: 8, loop: EditableCue.Loop(end: 12, beats: 8)))])
        #expect(applied.cue.cues.first { $0.id == memory.id } == memory)
    }

    @Test func 쓴_큐를_지금_base에서_찾지_못하면_정할_수_없다() {
        let original = Self.cue(1, "10", at: 5)
        let before = Self.snapshot(base: [original], cues: [original])
        var moved = original; moved.time = 6
        let after = Self.snapshot(base: [original], cues: [moved])
        // 다시 읽은 base에 같은 ID가 없다(새 ID를 돌려받지 못함)
        let current = Self.snapshot(base: [Self.cue(9, "20", at: 6)], cues: [Self.cue(9, "20", at: 6)])
        #expect(before.rebased(from: after, onto: current) == nil)
    }

    @Test func 그리드와_따라_옮긴_큐를_함께_되돌린다() throws {
        let segment = GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1), shifted = GridSegment(start: 0.6, bpm: 120, firstBeatNumber: 1)
        let original = Self.cue(1, "10", at: 5)
        var carried = original; carried.time = 5.1
        let before = Self.snapshot(base: [original], cues: [original], gridBase: [segment])
        let after = Self.snapshot(base: [original], cues: [carried], grid: GridDraft(trackUUID: "t", base: [segment], segments: [shifted]),
                                  gridBase: [segment])
        var written = carried; written.sourceID = "20"
        let current = Self.snapshot(base: [written], cues: [written], gridBase: [shifted])
        let applied = try #require(before.rebased(from: after, onto: current))
        #expect(applied.grid == GridDraft(trackUUID: "t", base: [shifted], segments: [segment]))
        #expect(applied.cue.changes == [.modified(from: written, to: Self.cue(1, "20", at: 5))])
    }

    @Test func 게인은_편집_전_값을_지금_rekordbox_값_위의_초안으로_둔다() throws {
        let cues = [Self.cue(1, "10", at: 5)]
        // 편집 전: 초안 없음(rekordbox −6dB를 씀). 편집: −2dB. 쓴 뒤 rekordbox가 −2dB
        let before = Self.snapshot(base: cues, cues: cues, gain: nil, gainBase: -6)
        let after = Self.snapshot(base: cues, cues: cues, gain: -2, gainBase: -6)
        let current = Self.snapshot(base: cues, cues: cues, gain: nil, gainBase: -2)
        let applied = try #require(before.rebased(from: after, onto: current))
        #expect(applied.gain == -6 && applied.gainBase == -2)
        // 아직 쓰지 않았으면 지금처럼 초안을 지운다
        #expect(before.rebased(from: after, onto: after)?.gain == nil)
    }
    /// 쓴 뒤 다시 읽기가 늦어진 사이 rekordbox에서 더한 큐는 ⌘Z가 지우지 않는다(편집이 바꾼 큐만 되돌린다)
    @Test func 그_뒤_rekordbox에서_더한_큐는_되돌리지_않는다() throws {
        let original = Self.cue(1, "10", at: 5)
        let before = Self.snapshot(base: [original], cues: [original])
        var moved = original; moved.time = 6
        let after = Self.snapshot(base: [original], cues: [moved])
        var written = moved; written.sourceID = "20"
        let outside = Self.cue(7, "30", at: 50)
        let current = Self.snapshot(base: [written, outside], cues: [written, outside])
        let applied = try #require(before.rebased(from: after, onto: current))
        #expect(applied.cue.changes == [.modified(from: written, to: Self.cue(1, "20", at: 5))])
        #expect(applied.cue.cues.contains(outside))
    }

    /// 그리드를 건드리지 않은 편집(앞 편집과 함께 쓰였다)을 되돌려도 이미 쓴 그리드를 다시 저장 대기로 만들지 않는다
    @Test func 그리드를_건드리지_않은_편집은_지금_그리드를_그대로_둔다() throws {
        let segment = GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1), anchored = GridSegment(start: 10.25, bpm: 120, firstBeatNumber: 3)
        let reread = GridSegment(start: 0.25, bpm: 120, firstBeatNumber: 1)
        let original = Self.cue(1, "10", at: 5)
        let gridEdit = GridDraft(trackUUID: "t", base: [segment], segments: [anchored])
        // 앞 편집이 그리드를 고쳤고, 이 편집은 큐만 옮겼다
        let before = Self.snapshot(base: [original], cues: [original], grid: gridEdit, gridBase: [segment])
        var moved = original; moved.time = 6
        let after = Self.snapshot(base: [original], cues: [moved], grid: gridEdit, gridBase: [segment])
        var written = moved; written.sourceID = "20"
        // 다시 읽은 그리드는 첫 박에서 시작한다(구간 값은 같은 박을 다르게 적는다)
        let currentGrid = GridDraft(trackUUID: "t", base: [reread], segments: [reread])
        let current = Self.snapshot(base: [written], cues: [written], grid: currentGrid, gridBase: [reread])
        let applied = try #require(before.rebased(from: after, onto: current))
        #expect(applied.grid == currentGrid && applied.grid?.hasChanges == false)
        #expect(applied.cue.changes.count == 1)
    }
}
