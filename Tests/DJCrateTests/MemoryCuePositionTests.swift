import DJCApplication
@testable import DJCrate
import DJCDomain
import Testing

@MainActor
@Suite("메모리 큐 — CUE 위치 저장")
struct MemoryCuePositionTests {
    enum Entry: CaseIterable { case button, keyboard, menu }

    func add(_ entry: Entry, to deck: DeckModel) {
        switch entry {
        case .button:
            deck.addMemoryCue()
        case .keyboard:
            let router = KeyRouter()
            router.deck = deck
            #expect(router.handleKeyDown(46, focus: .deck))
        case .menu:
            DeckMenuCommand.action(.memoryCue).perform(on: deck)
        }
    }

    @Test(arguments: Entry.allCases, [false, true])
    func 이동하거나_재생해도_CUE의_정확한_위치를_저장한다(entry: Entry, playing: Bool) async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.quantize = false
        h.deck.seek(10.6)
        h.deck.cueDown()
        h.deck.cueUp()
        #expect(h.deck.cuePoint == 10.6)
        // CUE를 정한 뒤 등록 퀀타이즈를 켜도 이미 정한 CUE를 다른 박으로 옮기지 않는다.
        h.deck.quantize = true
        h.deck.seek(31.3)
        if playing { h.deck.togglePlay() }
        add(entry, to: h.deck)
        let cue = try #require(h.deck.draft?.cues.first { $0.kind == .memory })
        #expect(cue.time == 10.6)
        #expect(h.deck.playhead == 31.3)
        #expect(h.deck.isPlaying == playing)
        #expect(h.drafts.cue("track-1")?.cues.first?.time == 10.6)
    }

    @Test func CUE를_정하지_않았으면_기본_CUE인_0초에_저장한다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        #expect(h.deck.cuePoint == 0)
        h.deck.seek(20)
        add(.button, to: h.deck)
        #expect(h.deck.draft?.cues.first { $0.kind == .memory }?.time == 0)
    }

    @Test func CUE_위치에_이미_메모리_큐가_있으면_그것을_고른다() async throws {
        let existing = Cue(id: "memory", contentID: "1", kind: 0, inMsec: 10_600, name: "", colorTableIndex: nil)
        let h = try DeckHarness(cues: [existing])
        try await h.loaded()
        #expect(h.deck.cuePoint == 10.6)
        h.deck.seek(20)
        add(.keyboard, to: h.deck)
        let cue = try #require(h.deck.draft?.cues.first { $0.kind == .memory })
        #expect(h.deck.memoryCueCount == 1)
        #expect(h.deck.selectedCueID == cue.id)
    }

    @Test(arguments: Entry.allCases)
    func 즉석_루프는_CUE와_달라도_그_루프를_저장한다(entry: Entry) async throws {
        let h = try DeckHarness()
        try await h.loaded()
        h.deck.seek(20.5)
        h.deck.toggleLoop()
        add(entry, to: h.deck)
        let cue = try #require(h.deck.draft?.cues.first { $0.kind == .memory })
        #expect(h.deck.cuePoint == 0)
        #expect(cue.time == 20.5)
        #expect(cue.loop == EditableCue.Loop(end: 22.5, active: false, beats: 4))
        #expect(h.deck.instantLoop == nil && h.deck.engagedLoopID == cue.id)
        #expect(h.deck.isLooping && h.audio.loop == 20.5...22.5)
    }

    @Test func 바꾼_메모리_큐_키도_CUE에_저장하고_Shift는_재생_위치에서_지운다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        try h.deck.shortcuts.replace(46, with: 7, in: .memoryCue)
        let router = KeyRouter()
        router.deck = h.deck
        h.deck.seek(20.5)
        h.deck.addMemoryCue(at: 20.5)
        #expect(!router.handleKeyDown(46, focus: .deck))
        #expect(router.handleKeyDown(7, focus: .deck))
        #expect(h.deck.draft?.cues.contains { $0.kind == .memory && $0.time == 0 } == true)
        #expect(router.handleKeyDown(7, shift: true, focus: .deck))
        #expect(h.deck.memoryCueCount == 1)
        #expect(h.deck.draft?.cues.first?.time == 0)
        #expect(h.deck.playhead == 20.5)
    }

    @Test func 입력_중에는_M과_바꾼_메모리_큐_키를_가로채지_않는다() throws {
        var shortcuts = DeckShortcuts.standard
        #expect(!KeyRoutingPolicy.accepts(46, in: .init(focus: .textInput), shortcuts: shortcuts))
        try shortcuts.replace(46, with: 7, in: .memoryCue)
        #expect(!KeyRoutingPolicy.accepts(7, in: .init(focus: .textInput), shortcuts: shortcuts))
    }

    @Test func M의_반복_입력은_메모리_큐를_추가하지_않는다() async throws {
        let h = try DeckHarness()
        try await h.loaded()
        let router = KeyRouter()
        router.deck = h.deck
        #expect(router.handleKeyDown(46, isRepeat: true, focus: .deck))
        #expect(h.deck.memoryCueCount == 0)
    }
}
