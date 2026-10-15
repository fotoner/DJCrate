import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCTestKit
import Foundation
import Testing

@Suite("설정 저장소")
@MainActor
struct SettingsStoreTests {
    static func freshDefaults() -> UserDefaults { TestDefaults.make("settings") }

    /// 쓰기 뒤에도 이전 값을 돌려주는 저장소로 영속화 지연을 결정적으로 재현한다.
    private final class StaleDefaults: UserDefaults, @unchecked Sendable {
        private let suiteName = TestDefaults.suiteName("stale-settings")
        init() { super.init(suiteName: suiteName)! }
        deinit { removePersistentDomain(forName: suiteName) }
        override func object(forKey defaultName: String) -> Any? {
            if defaultName == SettingKeys.hideStreaming.name { return false }
            if defaultName == SettingKeys.waveformHeight.name { return 80.0 }
            return nil
        }
        override func set(_ value: Any?, forKey defaultName: String) {}
        override func removeObject(forKey defaultName: String) {}
    }

    @Test func 저장소가_이전_값을_돌려줘도_방금_쓴_설정을_읽는다() {
        let defaults = StaleDefaults()
        let store = SettingsStore(defaults: defaults, persist: true)
        #expect(!store.value(SettingKeys.hideStreaming))
        #expect(store.value(SettingKeys.waveformHeight) == 80)
        store.set(SettingKeys.hideStreaming, true)
        store.set(SettingKeys.waveformHeight, 199)
        #expect(store.value(SettingKeys.hideStreaming))
        #expect(store.value(SettingKeys.waveformHeight) == 199)
        store.set(SettingKeys.hideStreaming, false)
        #expect(!store.value(SettingKeys.hideStreaming))
        #expect(defaults.object(forKey: SettingKeys.hideStreaming.name) as? Bool == false)
        #expect(defaults.object(forKey: SettingKeys.waveformHeight.name) as? Double == 80)
        // 새 저장소는 영속 저장값에서 시작하며 이전 인스턴스의 캐시를 물려받지 않는다.
        #expect(!SettingsStore(defaults: defaults, persist: true).value(SettingKeys.hideStreaming))
    }

    @Test func 저장이_늦어도_재생_퀀타이즈의_새_값이_옛_설정보다_우선한다() {
        let store = SettingsStore(defaults: StaleDefaults(), persist: true)
        #expect(store.quantize)
        store.set(SettingKeys.playQuantize, false)
        #expect(!store.quantize)
    }

    @Test func 쓴_설정은_검증_규칙을_따르고_읽기만_한_설정은_외부_변경을_따른다() {
        let (name, defaults) = TestDefaults.suite("settings-external")
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, persist: true)
        #expect(store.value(SettingKeys.hideStreaming) == false)
        defaults.set(true, forKey: SettingKeys.hideStreaming.name)
        #expect(store.value(SettingKeys.hideStreaming))
        store.set(SettingKeys.volume, 2)
        #expect(store.value(SettingKeys.volume) == 1)
        store.set(SettingKeys.volume, .nan)
        #expect(store.value(SettingKeys.volume) == SettingKeys.volume.defaultValue)
    }

    @Test func 저장이_늦어도_단축키와_문자열_모음의_새_값을_읽는다() throws {
        let store = SettingsStore(defaults: StaleDefaults(), persist: true)
        var shortcuts = DeckShortcuts.standard
        try shortcuts.replace(8, with: 7, in: .cue)
        store.shortcuts = shortcuts
        #expect(store.shortcuts == shortcuts)
        store.shortcuts = .standard
        #expect(store.shortcuts == .standard)
        store.setStrings(SettingKeys.dismissedGainSuggestions, ["a"])
        #expect(store.strings(SettingKeys.dismissedGainSuggestions) == ["a"])
        store.setStrings(SettingKeys.dismissedGainSuggestions, [])
        #expect(store.strings(SettingKeys.dismissedGainSuggestions).isEmpty)
        let selftest = SettingsStore(defaults: StaleDefaults(), persist: false)
        selftest.set(SettingKeys.hideStreaming, true)
        #expect(!selftest.value(SettingKeys.hideStreaming))
        selftest.setStrings(SettingKeys.dismissedGainSuggestions, ["b"])
        #expect(selftest.strings(SettingKeys.dismissedGainSuggestions) == ["b"])
    }

    /// 시험 설정이 사용자 환경설정 폴더(~/Library/Preferences)에 plist를 남기지 않는다(adv4 T6: 10만 개 넘게 쌓였다).
    @Test func 시험_설정은_사용자_환경설정_폴더에_plist를_남기지_않는다() throws {
        let (name, defaults) = TestDefaults.suite("no-leak")
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, persist: true, sharedFile: nil)
        store.set(SettingKeys.cueListFilter, CueListFilter.memory.rawValue)
        store.setStrings("djc.test.strings", ["a"])
        #expect(store.defaults.synchronize())
        #expect(SettingsStore(defaults: TestDefaults.open(name), persist: true, sharedFile: nil).value(SettingKeys.cueListFilter) == "memory")
        let file = URL(filePath: NSHomeDirectory()).appending(path: "Library/Preferences")
            .appending(path: URL(filePath: name).lastPathComponent + ".plist")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// 덱 시험의 메모리 저장소는 설정을 저장하지 않는다(디스크·UserDefaults 표준 영역을 건드리지 않는다)
    @Test func 덱_메모리_저장소는_설정을_저장하지_않는다() {
        #expect(!DeckStorage.memory(MemoryDrafts()).settings.persist)
    }

    @Test func 큐_목록의_탭은_다시_켜도_기억하고_자가_테스트에서는_기본값이다() {
        let (name, defaults) = TestDefaults.suite("settings")
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, persist: true)
        store.set(SettingKeys.cueListFilter, CueListFilter.memory.rawValue)
        #expect(SettingsStore(defaults: defaults, persist: true).value(SettingKeys.cueListFilter) == "memory")
        #expect(SettingsStore(defaults: defaults, persist: false).value(SettingKeys.cueListFilter) == "all")
    }

    @Test func 설정을_안_건드린_덱은_예전_기본값으로_시작한다() {
        let audio = FakeDeckAudio()
        let deck = DeckModel.test(audio: audio, storage: .memory(MemoryDrafts()), runsAnalysis: false)
        #expect(deck.zoomSeconds == 16)
        #expect(deck.waveformColorMode == .threeBand)
        #expect(deck.quantize)
        #expect(deck.carryCues)
        #expect(deck.showSuggestions)
        #expect(!deck.showKeyBand)
        #expect(deck.volume == 0.9)
        #expect(deck.keyLock)
        #expect(deck.autoGain)
        #expect(deck.gainTarget == -10)
        #expect(deck.peakProtection)
        #expect(deck.gainTrim == 0)
        #expect(deck.useRekordboxGain)
        #expect(!deck.metronome)
        #expect(deck.metronomeVolume == 0.8)
        #expect(deck.idleSeconds == 20)
        #expect(deck.shortcuts == .standard)
        // 오디오 엔진도 예전 상수 그대로 받는다
        #expect(audio.volume == 0.9)
        #expect(audio.keyLock)
        #expect(audio.metronomeVolume == 0.8)
        #expect(audio.idleSeconds == 20)
    }

    @Test func 예전에_저장한_값을_같은_이름으로_읽는다() {
        let (name, defaults) = TestDefaults.suite("settings")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "deck.quantize")
        defaults.set(0.5, forKey: "deck.volume")
        defaults.set(-12.0, forKey: "deck.gainTarget")
        defaults.set(["a", "b"], forKey: "deck.dismissedGainSuggestions")
        let storage = DeckStorage.memory(MemoryDrafts(), settings: SettingsStore(defaults: defaults, persist: true))
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        #expect(!deck.quantize)
        #expect(deck.volume == 0.5)
        #expect(deck.gainTarget == -12)
        #expect(deck.dismissedGainSuggestions == ["a", "b"])
    }

    @Test func 바꾼_값은_다시_켜도_남는다() throws {
        let (name, defaults) = TestDefaults.suite("settings")
        defer { defaults.removePersistentDomain(forName: name) }
        let storage = DeckStorage.memory(MemoryDrafts(), settings: SettingsStore(defaults: defaults, persist: true))
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        deck.metronomeVolume = 0.3
        deck.idleSeconds = 60
        deck.carryCues = false
        deck.waveformColorMode = .rgb
        var shortcuts = deck.shortcuts
        try shortcuts.replace(8, with: 7, in: .cue)
        deck.shortcuts = shortcuts

        let audio = FakeDeckAudio()
        let again = DeckModel.test(audio: audio, storage: storage, runsAnalysis: false)
        #expect(again.metronomeVolume == 0.3)
        #expect(again.idleSeconds == 60)
        #expect(!again.carryCues)
        #expect(again.waveformColorMode == .rgb)
        #expect(again.shortcuts.keys(for: .cue) == [7])
        #expect(audio.metronomeVolume == 0.3)
        #expect(audio.idleSeconds == 60)
    }

    @Test func 설정_창_컨트롤이_같은_값을_다시_넣으면_저장하지_않는다() {
        // 저장해 두면 나중에 기본값이 바뀌어도 옛 기본값에 묶인다.
        let (name, defaults) = TestDefaults.suite("settings")
        defer { defaults.removePersistentDomain(forName: name) }
        let storage = DeckStorage.memory(MemoryDrafts(), settings: SettingsStore(defaults: defaults, persist: true))
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, runsAnalysis: false)
        deck.metronomeVolume = SettingKeys.metronomeVolume.defaultValue
        deck.idleSeconds = SettingKeys.idleSeconds.defaultValue
        #expect(defaults.object(forKey: SettingKeys.metronomeVolume.name) == nil)
        #expect(defaults.object(forKey: SettingKeys.idleSeconds.name) == nil)
    }

    @Test func 덱_설정을_기본값으로_되돌린다() throws {
        let storage = DeckStorage.memory(MemoryDrafts())
        let audio = FakeDeckAudio()
        let deck = DeckModel.test(audio: audio, storage: storage, runsAnalysis: false)
        deck.quantize = false
        deck.keyLock = false
        deck.metronomeVolume = 0.1
        deck.gainTarget = -14
        deck.volume = 0.5
        deck.resetDeckSettings()
        #expect(deck.quantize)
        #expect(deck.keyLock)
        #expect(deck.metronomeVolume == 0.8)
        #expect(deck.gainTarget == -10)
        #expect(deck.volume == 0.5, "덱에서 바로 만지는 볼륨은 그대로")
        #expect(audio.metronomeVolume == 0.8)
        #expect(audio.keyLock)
        #expect(storage.settings.value(SettingKeys.quantize))
    }

    @Test func 단축키는_바꾼_것만_저장하고_기본으로_돌리면_지운다() throws {
        let (name, defaults) = TestDefaults.suite("settings")
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults, persist: true)
        #expect(store.shortcuts == .standard)
        var shortcuts = DeckShortcuts.standard
        try shortcuts.replace(8, with: 7, in: .cue)
        store.shortcuts = shortcuts
        #expect(defaults.dictionary(forKey: SettingKeys.deckShortcuts) as? [String: [Int]] == ["cue": [7]])
        #expect(SettingsStore(defaults: defaults, persist: true).shortcuts == shortcuts)
        store.shortcuts = .standard
        #expect(defaults.object(forKey: SettingKeys.deckShortcuts) == nil)
    }

    @Test func 자가_테스트는_설정을_읽지도_쓰지도_않는다() throws {
        let (name, defaults) = TestDefaults.suite("settings")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "deck.quantize")
        defaults.set(["cue": [7]], forKey: SettingKeys.deckShortcuts)
        let store = SettingsStore(defaults: defaults, persist: false)
        #expect(store.value(SettingKeys.quantize))
        #expect(store.shortcuts == .standard)
        store.set(SettingKeys.volume, 0.1)
        store.shortcuts = DeckShortcuts(overrides: ["loop": [1]])
        #expect(defaults.object(forKey: "deck.volume") == nil)
        #expect(defaults.dictionary(forKey: SettingKeys.deckShortcuts) as? [String: [Int]] == ["cue": [7]])
    }
}
