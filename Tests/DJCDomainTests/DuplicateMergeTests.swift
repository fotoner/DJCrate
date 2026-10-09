import DJCDomain
import Foundation
import Testing

@Suite("중복 곡 합치기 규칙")
struct DuplicateMergeTests {
    func member(_ id: String, duration: Double = 30, offset: Double = 0, cues: [EditableCue] = []) -> DuplicateMergeDraft.Member {
        .init(contentID: id, trackUUID: id, title: id, duration: duration, offset: offset, cues: cues)
    }

    @Test func 인코더_지연만_보정하고_원본_큐_ID를_옮기지_않는다() throws {
        let source = EditableCue(sourceID: "old", kind: .memory, time: 1.05, name: "시작", loop: .init(end: 3.05, beats: 4))
        let draft = try DuplicateMerge.cues(keeping: member("a"), removing: [member("b", offset: 0.05, cues: [source])], newID: { UUID() })
        #expect(abs(draft.cues[0].time - 1) < 0.000001)
        #expect(abs(draft.cues[0].loop!.end - 3) < 0.000001)
        #expect(draft.cues[0].sourceID == nil && draft.cues[0].id != source.id)
    }

    @Test func 같은_큐만_합치고_핫큐_슬롯_충돌은_막는다() throws {
        let hot = EditableCue(kind: .hot(0), time: 1, name: "A")
        let memory = EditableCue(kind: .memory, time: 2)
        let target = member("a", cues: [hot, memory])
        let same = try DuplicateMerge.cues(keeping: target, removing: [member("b", cues: [hot, memory])], newID: { UUID() })
        #expect(same.cues.count == 2 && !same.hasChanges)
        #expect(throws: DuplicateMerge.Blocked.self) {
            try DuplicateMerge.cues(keeping: target, removing: [member("b", cues: [.init(kind: .hot(0), time: 3)])], newID: { UUID() })
        }
    }

    @Test func 길이차이_알수없는_시간축_범위밖_큐_활성루프_충돌을_막는다() throws {
        for bad in [member("b", duration: 30.021), member("b", offset: .nan),
                    member("b", cues: [.init(kind: .memory, time: 31)]),
                    member("b", offset: 0.1, cues: [.init(kind: .memory, time: 0)])] {
            #expect(throws: DuplicateMerge.Blocked.self) { try DuplicateMerge.cues(keeping: member("a"), removing: [bad], newID: { UUID() }) }
        }
        let target = member("a", cues: [.init(kind: .memory, time: 1, loop: .init(end: 2, active: true))])
        #expect(throws: DuplicateMerge.Blocked.self) {
            try DuplicateMerge.cues(keeping: target, removing: [member("b", cues: [.init(kind: .memory, time: 3, loop: .init(end: 4, active: true))])],
                                    newID: { UUID() })
        }
        #expect(throws: DuplicateMerge.Blocked.self) {
            try DuplicateMerge.cues(keeping: member("a"), removing: [member("b", cues: (0..<11).map { .init(kind: .memory, time: Double($0)) })],
                                    newID: { UUID() })
        }
    }

    @Test func 목록에_남길곡이_없으면_끝에_넣고_첫_삭제_자리로_옮긴다() throws {
        var layout = PlaylistLayout([(.init(id: "p", name: "목록", entries: ["x", "b", "y", "c", "z"].enumerated().map {
            .init(trackNo: $0.offset + 1, contentID: $0.element)
        }), 1)])
        let edits = try DuplicateMerge.playlists(keeping: "a", removing: ["b", "c"], in: layout)
        #expect(edits.count == 3)
        #expect(edits[1] == .addTracks(playlist: .id("p"), contentIDs: ["a"]))
        #expect(edits[2] == .moveTracks(playlist: .id("p"), entries: [.init(trackNo: 4, contentID: "a")], to: 2))
        for edit in edits { try layout.apply(edit) }
        #expect(layout.item("p")?.trackIDs == ["x", "a", "y", "z"])
    }

    @Test func 이미_있는_남길곡의_자리와_반복은_보존한다() throws {
        var layout = PlaylistLayout([(.init(id: "p", name: "목록", entries: ["b", "x", "a", "c", "a"].enumerated().map {
            .init(trackNo: $0.offset + 1, contentID: $0.element)
        }), 1)])
        for edit in try DuplicateMerge.playlists(keeping: "a", removing: ["b", "c"], in: layout) { try layout.apply(edit) }
        #expect(layout.item("p")?.trackIDs == ["x", "a", "a"])
    }
}
