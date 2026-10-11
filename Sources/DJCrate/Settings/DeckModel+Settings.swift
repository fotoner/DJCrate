import DJCDomain

extension DeckModel {
    /// 설정 창 "덱" 탭의 값을 기본으로 되돌린다(볼륨·확대·트림처럼 덱에서 바로 만지는 값은 그대로).
    func resetDeckSettings() {
        keyLock = SettingKeys.keyLock.defaultValue
        metronomeVolume = SettingKeys.metronomeVolume.defaultValue
        playQuantize = SettingKeys.playQuantize.defaultValue
        playQuantizeBeats = SettingKeys.playQuantizeBeats.defaultValue
        carryCues = SettingKeys.carryCues.defaultValue
        showSuggestions = SettingKeys.showSuggestions.defaultValue
        autoGain = SettingKeys.autoGain.defaultValue
        useRekordboxGain = SettingKeys.useRekordboxGain.defaultValue
        gainTarget = SettingKeys.gainTarget.defaultValue
        peakProtection = SettingKeys.peakProtection.defaultValue
    }
}
