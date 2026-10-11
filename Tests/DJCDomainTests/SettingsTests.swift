@testable import DJCDomain
import Foundation
import Testing

@Suite("설정 키·기본값")
struct SettingsTests {
    /// 설정 창을 만들기 전 코드에 흩어져 있던 이름·기본값(DeckModel·ContentView·Sidebar·DeckAudio).
    /// 이름이 같아야 쓰던 값이 그대로 읽히고, 기본값이 같아야 설정을 안 건드리면 아무것도 안 바뀐다.
    @Test func 옛_이름과_기본값을_그대로_쓴다() {
        let doubles: [(SettingKey<Double>, String, Double)] = [
            (SettingKeys.zoomSeconds, "deck.zoomSeconds", 16),
            (SettingKeys.volume, "deck.volume", 0.9),
            (SettingKeys.gainTarget, "deck.gainTarget", -10),
            (SettingKeys.gainTrim, "deck.gainTrim", 0),
            (SettingKeys.waveformHeight, "waveformHeight", 150),
            // 옛 코드 상수: DeckAudio.metronomeVolume, DeckAudio.idleSeconds
            (SettingKeys.metronomeVolume, "deck.metronomeVolume", 0.8),
            (SettingKeys.idleSeconds, "deck.idleSeconds", 20),
        ]
        for (key, name, value) in doubles {
            #expect(key.name == name)
            #expect(key.defaultValue == value, "\(name)")
        }
        let bools: [(SettingKey<Bool>, String, Bool)] = [
            (SettingKeys.quantize, "deck.quantize", true),
            (SettingKeys.carryCues, "deck.carryCues", true),
            (SettingKeys.showSuggestions, "deck.showSuggestions", true),
            (SettingKeys.keyLock, "deck.keyLock", true),
            (SettingKeys.autoGain, "deck.autoGain", true),
            (SettingKeys.peakProtection, "deck.peakProtection", true),
            (SettingKeys.useRekordboxGain, "deck.useRekordboxGain", true),
            (SettingKeys.sheetMode, "sheetMode", false),
            (SettingKeys.sidebarPlaylistsExpanded, "sidebar.playlistsExpanded", true),
            (SettingKeys.sidebarSummaryExpanded, "sidebar.summaryExpanded", true),
            (SettingKeys.sidebarHistoriesExpanded, "sidebar.historiesExpanded", false),
        ]
        for (key, name, value) in bools {
            #expect(key.name == name)
            #expect(key.defaultValue == value, "\(name)")
        }
        #expect(SettingKeys.dismissedGainSuggestions == "deck.dismissedGainSuggestions")
        #expect(SettingKeys.dismissedGridSuggestions == "deck.dismissedGridSuggestions")
        #expect(SettingKeys.deckShortcuts == "shortcuts.deck")
    }

    /// 현황·스냅샷 파일 이름은 늘 볼 필요가 없어 기본으로 숨기고 설정 › 일반에서 켠다(#120).
    @Test func 사이드바_현황은_기본으로_숨긴다() {
        #expect(SettingKeys.sidebarShowsStatus.name == "sidebar.showsStatus")
        #expect(SettingKeys.sidebarShowsStatus.defaultValue == false)
        #expect(SettingKeys.sidebarShowsStatus.value(from: nil) == false)
        #expect(SettingKeys.sidebarShowsStatus.value(from: true) == true)
        #expect(SettingKeys.all.contains(SettingKeys.sidebarShowsStatus.name))
    }

    /// 사이드바를 연 채·닫은 채 끈 그대로 다음에 뜬다(#119). 처음에는 열린 채로 시작한다.
    @Test func 사이드바_표시_상태를_저장한다() {
        #expect(SettingKeys.sidebarVisible.name == "sidebar.visible")
        #expect(SettingKeys.sidebarVisible.defaultValue == true)
        #expect(SettingKeys.all.contains(SettingKeys.sidebarVisible.name))
    }

    /// 곡 목록에서 스트리밍 곡을 빼는 설정은 기본으로 꺼져 있어(지금처럼 보인다) 설정을 안 건드리면 아무것도 안 바뀐다.
    @Test func 스트리밍_곡_숨기기는_기본으로_꺼져_있다() {
        #expect(SettingKeys.hideStreaming.name == "library.hideStreaming")
        #expect(SettingKeys.hideStreaming.defaultValue == false)
        #expect(SettingKeys.hideStreaming.value(from: nil) == false)
        #expect(SettingKeys.hideStreaming.value(from: "true") == false)
        #expect(SettingKeys.hideStreaming.value(from: true) == true)
        #expect(SettingKeys.all.contains(SettingKeys.hideStreaming.name))
    }

    /// 실험실 기능은 rekordbox와 결과를 견주기 전이라 기본으로 꺼 둔다(#68). 끄면 지금 dev와 같게 보인다.
    @Test func 실험실의_인텔리전트_재생_목록_보기는_기본으로_꺼져_있다() {
        #expect(SettingKeys.labSmartPlaylists.name == "lab.smartPlaylists")
        #expect(SettingKeys.labSmartPlaylists.defaultValue == false)
        #expect(SettingKeys.labSmartPlaylists.value(from: nil) == false)
        #expect(SettingKeys.labSmartPlaylists.value(from: "true") == false)
        #expect(SettingKeys.labSmartPlaylists.value(from: true) == true)
        #expect(SettingKeys.all.contains(SettingKeys.labSmartPlaylists.name))
    }

    @Test func 설정_이름은_겹치지_않는다() {
        let names = SettingKeys.all
        #expect(Set(names).count == names.count)
        #expect(names.contains("deck.quantize"))
        #expect(names.contains(SettingKeys.deckShortcuts))
    }

    @Test func 저장된_값이_없거나_형식이_다르면_기본값() {
        #expect(SettingKeys.quantize.value(from: nil) == true)
        #expect(SettingKeys.quantize.value(from: "false") == true)
        #expect(SettingKeys.quantize.value(from: false) == false)
        #expect(SettingKeys.quantize.value(from: NSNumber(value: false)) == false)
        #expect(SettingKeys.volume.value(from: nil) == 0.9)
        #expect(SettingKeys.volume.value(from: "0.5") == 0.9)
        #expect(SettingKeys.volume.value(from: Double.nan) == 0.9)
        #expect(SettingKeys.volume.value(from: Double.infinity) == 0.9)
        #expect(SettingKeys.volume.value(from: NSNumber(value: 0.4)) == 0.4)
    }

    @Test func 범위를_벗어난_값은_끝으로_자른다() {
        #expect(SettingKeys.volume.value(from: 1.5) == 1)
        #expect(SettingKeys.volume.value(from: -1.0) == 0)
        #expect(SettingKeys.zoomSeconds.value(from: 100.0) == 64)
        #expect(SettingKeys.zoomSeconds.value(from: 1.0) == 2)
        #expect(SettingKeys.gainTrim.value(from: 30.0) == 12)
        #expect(SettingKeys.gainTarget.value(from: -30.0) == -14)
        #expect(SettingKeys.metronomeVolume.value(from: 2.0) == 1)
        #expect(SettingKeys.idleSeconds.value(from: 0.0) == SettingKeys.idleSecondsChoices.first)
        #expect(SettingKeys.idleSeconds.value(from: 99_999.0) == SettingKeys.idleSecondsChoices.last)
        // 범위 안이면 그대로(예전처럼 저장값을 믿는다)
        #expect(SettingKeys.zoomSeconds.value(from: 23.5) == 23.5)
    }

    @Test func 고르는_값의_기본값은_목록_안에_있다() {
        #expect(SettingKeys.gainTargetChoices.contains(SettingKeys.gainTarget.defaultValue))
        #expect(SettingKeys.idleSecondsChoices.contains(SettingKeys.idleSeconds.defaultValue))
        #expect(SettingKeys.gainTargetChoices == [-14, -12, -11, -10, -9, -8])
    }
}
