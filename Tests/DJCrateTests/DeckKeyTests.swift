@testable import DJCrate
import DJCAnalysis
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// 덱 조성 표시(#124): 조표 흐름은 장·단을 가리지 않으므로 rekordbox 키가 없을 때 장·단을 크로마로 정한다.
@MainActor
@Suite("덱 — 조성")
struct DeckKeyTests {
    static func chroma(_ chords: [ChordFixture.Chord]) -> KeyAnalyzer.Chroma {
        let samples = ChordFixture.samples(chords, seconds: 40, sampleRate: 22_050)
        return samples.withUnsafeBufferPointer { KeyAnalyzer.chroma(channels: [$0], sampleRate: 22_050) }
    }
    /// 같은 합성 음원의 크로마는 시험마다 다시 계산하지 않는다(디버그 빌드에서 하나에 약 0.4초).
    static let aMinor = chroma(ChordFixture.aMinor)
    static let dMajor = chroma(ChordFixture.dMajor)

    @Test func rekordbox_키가_없으면_단조_곡은_단조_이름으로() async throws {
        let h = try DeckHarness(key: nil)
        try await h.loaded()
        h.deck.keyChroma = Self.aMinor
        h.deck.refreshKeySegments()
        #expect(h.deck.key(at: 10) == "8A")
    }

    @Test func rekordbox_키가_없으면_장조_곡은_장조_이름으로() async throws {
        let h = try DeckHarness(key: nil)
        try await h.loaded()
        h.deck.keyChroma = Self.dMajor
        h.deck.refreshKeySegments()
        #expect(h.deck.key(at: 10) == "10B")
    }

    @Test func rekordbox_키가_있으면_장단은_rekordbox를_따른다() async throws {
        let h = try DeckHarness(key: "8B")
        try await h.loaded()
        h.deck.keyChroma = Self.aMinor
        h.deck.refreshKeySegments()
        #expect(h.deck.key(at: 10) == "8B")
    }
}
