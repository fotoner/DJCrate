import DJCApplication
@testable import DJCrate
import DJCDomain
import Foundation
import Testing

/// LINK와 덱(#278): CDJ가 덱의 곡을 새로 실으면 덱에서 내리고, CDJ가 재생 중인 곡은 덱에 올리지 않는다.
@MainActor
@Suite("덱 — LINK CDJ 곡")
struct DeckLinkLockTests {
    private func deck() -> DeckModel {
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        deck.feedback = AppFeedback(announce: { _ in }, isVoiceOverEnabled: { true })
        return deck
    }

    private func row(_ id: String) -> TrackRow {
        TrackRow(track: Track(id: id, uuid: "u\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil,
                              composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 60,
                              folderPath: "/Users/dj/Music/\(id).mp3", comment: "", importedOn: nil, analysisDataPath: nil,
                              imagePath: nil, isDeleted: false),
                 cues: [], playCount: 0)
    }

    @Test func CDJ가_덱의_곡을_새로_실으면_덱에서_내린다() {
        let deck = deck()
        deck.load(row("10"))
        #expect(!deck.applyCDJTracks(loaded: ["20"]))
        #expect(deck.applyCDJTracks(loaded: ["20", "10"]))
        #expect(deck.toast != nil)
    }

    @Test func CDJ에_실려_있는_곡은_멈춰_있어도_덱에_올리지_않고_CDJ가_다른_곡을_실으면_올린다() {
        // 2026-10-16 실기: CDJ에서 멈춰 둔 곡이 더블클릭으로 덱에 올라갔다
        let deck = deck()
        _ = deck.applyCDJTracks(loaded: ["10"])
        #expect(deck.cdjRefusal(row("10")) != nil)
        #expect(deck.refusesForCDJ(row("10")))
        deck.toast = nil
        deck.load(row("10"))
        #expect(deck.row == nil)
        // 덱도 막으면서 까닭을 알린다
        #expect(deck.toast != nil)
        deck.load(row("20"))
        #expect(deck.row?.track.id == "20")
        _ = deck.applyCDJTracks(loaded: ["30"])
        #expect(!deck.refusesForCDJ(row("10")))
        deck.load(row("10"))
        #expect(deck.row?.track.id == "10")
    }
}
