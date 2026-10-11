import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCTestKit
import Foundation
import Testing

@Suite("Q 통합 설정")
@MainActor
struct DeckUnifiedQuantizeTests {
    @Test(arguments: [false, true])
    func 기존_등록_설정과_달라도_현재_Q를_유지하고_읽을_때_저장하지_않는다(q: Bool) {
        let name = TestDefaults.suiteName("unified-quantize")
        let defaults = TestDefaults.open(name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(q, forKey: SettingKeys.playQuantize.name)
        defaults.set(!q, forKey: SettingKeys.quantize.name)
        let storage = DeckStorage.memory(MemoryDrafts(), settings: SettingsStore(defaults: defaults, persist: true))

        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)

        #expect(deck.playQuantize == q)
        #expect(deck.quantize == q)
        #expect(defaults.bool(forKey: SettingKeys.quantize.name) == !q)
    }

    @Test(arguments: [false, true])
    func Q를_저장한_적이_없으면_기존_등록_설정을_유지한다(legacy: Bool) {
        let name = TestDefaults.suiteName("unified-quantize")
        let defaults = TestDefaults.open(name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(legacy, forKey: SettingKeys.quantize.name)
        let storage = DeckStorage.memory(MemoryDrafts(), settings: SettingsStore(defaults: defaults, persist: true))

        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)

        #expect(deck.playQuantize == legacy)
        #expect(deck.quantize == legacy)
        #expect(defaults.object(forKey: SettingKeys.playQuantize.name) == nil)
    }

    @Test func 저장값이_없거나_자가_테스트이면_기본값을_쓴다() {
        let name = TestDefaults.suiteName("unified-quantize")
        let defaults = TestDefaults.open(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let storage = DeckStorage.memory(MemoryDrafts(), settings: SettingsStore(defaults: defaults, persist: true))
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        #expect(deck.playQuantize && deck.quantize)
        #expect(defaults.object(forKey: SettingKeys.playQuantize.name) == nil)
        #expect(defaults.object(forKey: SettingKeys.quantize.name) == nil)

        defaults.set(false, forKey: SettingKeys.playQuantize.name)
        defaults.set(false, forKey: SettingKeys.quantize.name)
        let transient = DeckStorage.memory(MemoryDrafts(), settings: SettingsStore(defaults: defaults, persist: false))
        let selfTest = DeckModel.test(audio: FakeDeckAudio(), storage: transient, runsAnalysis: false)
        #expect(selfTest.playQuantize && selfTest.quantize)
    }

    @Test func Q와_등록_설정은_양방향으로_같이_바뀌고_재시작과_초기화에도_같다() {
        let name = TestDefaults.suiteName("unified-quantize")
        let defaults = TestDefaults.open(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let storage = DeckStorage.memory(MemoryDrafts(), settings: SettingsStore(defaults: defaults, persist: true))
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)

        deck.playQuantize = false
        #expect(!deck.quantize)
        #expect(!storage.settings.value(SettingKeys.quantize))
        deck.quantize = true
        #expect(deck.playQuantize)
        #expect(storage.settings.value(SettingKeys.playQuantize))
        deck.quantize = false

        let again = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        #expect(!again.playQuantize)
        #expect(!again.quantize)
        again.resetDeckSettings()
        #expect(again.playQuantize)
        #expect(again.quantize)
        #expect(storage.settings.value(SettingKeys.playQuantize))
        #expect(storage.settings.value(SettingKeys.quantize))
    }
}
