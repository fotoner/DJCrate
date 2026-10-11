import DJCApplication
@testable import DJCrate
import DJCDomain
import Testing

@MainActor
@Suite("덱 — 큐 목록 이동")
struct CueListNavigationTests {
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
