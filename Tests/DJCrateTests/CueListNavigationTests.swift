import DJCApplication
@testable import DJCrate
import DJCDomain
import Testing

@MainActor
@Suite("덱 — 큐 목록 이동")
struct CueListNavigationTests {
    @Test func Kind4는_활성_메모리_루프로_표시하고_편집_초안에서_제외한다() async throws {
        let active = Cue(id: "4", contentID: "1", kind: 4, inMsec: 10_000, name: "활성", colorTableIndex: nil,
                         outMsec: 12_000, beatLoopSize: 4 << 16 | 1)
        let invalid = Cue(id: "invalid", contentID: "1", kind: 4, inMsec: 30_000, name: "", colorTableIndex: nil)
        let h = try DeckHarness(cues: [active, invalid])
        try await h.loaded()
        let shown = h.deck.displayedCues.filter(CueListFilter.memory.includes)
        #expect(DrawState(h.deck).cues == shown && h.deck.readOnlyLoops == shown)
        #expect(shown.count == 1)
        let loop = try #require(shown.first)
        #expect(loop.kind == .memory && loop.time == 10 && loop.name == "활성")
        #expect(loop.loop == .init(end: 12, active: true, beats: 4))
        #expect(h.deck.draft?.cues.isEmpty == true && h.deck.draft?.hasChanges == false)
        h.deck.selectCueFromList(loop.id)
        #expect(h.deck.playhead == 10 && h.deck.selectedCueID == loop.id)
        #expect(h.deck.cue(loop.id) == nil && !h.deck.deleteSelectedCue())
        #expect(h.drafts.cue("track-1") == nil)
    }

    @Test func 이전과_다음_큐로_읽기_전용_활성_루프를_부른다() async throws {
        let cues = [Cue(id: "hot", contentID: "1", kind: 1, inMsec: 5_000, name: "", colorTableIndex: nil),
                    Cue(id: "loop", contentID: "1", kind: 4, inMsec: 10_000, name: "", colorTableIndex: nil, outMsec: 12_000),
                    Cue(id: "point", contentID: "1", kind: 0, inMsec: 15_000, name: "", colorTableIndex: nil)]
        let h = try DeckHarness(cues: cues)
        try await h.loaded()
        let active = try #require(h.deck.readOnlyLoops.first)
        for forward in [true, false] {
            h.deck.seek(forward ? 5 : 15)
            h.deck.jumpToCue(forward: forward)
            #expect(h.deck.selectedCueID == active.id && h.deck.playhead == 10 && h.deck.cuePoint == 10)
            #expect(h.deck.cue(active.id) == nil && !h.deck.isLooping)
        }
        #expect(h.drafts.cue("track-1") == nil)
    }

    @Test(arguments: [false, true], [0, 1])
    func 행을_누르면_재생_상태를_유지하고_그_큐를_고른다(playing: Bool, kind: Int) async throws {
        let cue = Cue(id: "cue", contentID: "1", kind: kind, inMsec: 27_877, name: "시험 큐", colorTableIndex: nil)
        let h = try DeckHarness(cues: [cue])
        try await h.loaded()
        let target = try #require(h.deck.draft?.cues.first)
        h.deck.seek(50)
        if playing { h.deck.togglePlay() }
        h.audio.log.removeAll()

        h.deck.selectCueFromList(target.id)

        #expect(h.deck.selectedCueID == target.id)
        #expect(h.deck.playhead == 27.877 && h.audio.position == 27.877)
        #expect(h.deck.isPlaying == playing && h.audio.isPlaying == playing)
        #expect(h.audio.log.contains("play 27.877") == playing)
        #expect(h.drafts.cue("track-1") == nil, "이동만으로 초안을 바꾸지 않는다")
    }

    @Test(arguments: [false, true], [false, true])
    func 루프_큐는_시작점으로만_이동한다(playing: Bool, active: Bool) async throws {
        let cue = Cue(id: "loop", contentID: "1", kind: 1, inMsec: 20_000, name: "루프", colorTableIndex: nil,
                      outMsec: 24_000, activeLoop: active ? 1 : 0, beatLoopSize: 8 << 16 | 1)
        let h = try DeckHarness(cues: [cue])
        try await h.loaded()
        let target = try #require(h.deck.draft?.cues.first)
        h.deck.seek(10)
        if playing { h.deck.togglePlay() }

        h.deck.selectCueFromList(target.id)
        if playing {
            h.audio.position = 20.2
            h.deck.tick()
        }

        #expect(h.deck.selectedCueID == target.id)
        #expect(h.deck.isPlaying == playing)
        #expect(!h.deck.isLooping && h.audio.loop == nil)
        #expect(h.deck.cue(target.id)?.loop == target.loop)
        #expect(h.deck.playhead == (playing ? 20.2 : 20))
    }

    @Test func 같은_시각의_반복_중인_루프도_목록에서_누르면_풀린다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(20.5)
        h.deck.toggleLoop()
        h.deck.pressHotCue(slot: 0)
        let target = try #require(h.deck.hotCue(slot: 0))
        #expect(h.deck.isLooping)

        h.deck.selectCueFromList(target.id)

        #expect(h.deck.playhead == 20.5 && h.deck.selectedCueID == target.id)
        #expect(!h.deck.isLooping && h.audio.loop == nil)
    }
}
