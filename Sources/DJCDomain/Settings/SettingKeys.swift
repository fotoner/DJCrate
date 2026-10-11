/// 앱 설정 목록(이름·기본값·범위). 이름은 설정 창 전부터 쓰던 UserDefaults 키 그대로라 쓰던 값이 이어진다.
public enum SettingKeys {
    public static let commentPreset = SettingKey("library.commentPreset", CommentPreset.none.rawValue) {
        CommentPreset(rawValue: $0)?.rawValue
    }

    // MARK: 덱

    public static let waveformColorMode = SettingKey("waveform.colorMode", WaveformColorMode.threeBand.rawValue) {
        WaveformColorMode(rawValue: $0)?.rawValue
    }

    /// 파형 확대(화면에 보이는 초)
    public static let zoomSeconds = SettingKey<Double>("deck.zoomSeconds", 16, in: 2...64)
    public static let quantize = SettingKey("deck.quantize", true)
    /// Q 하나로 큐·루프 등록 스냅과 재생 중 핫큐 점프 퀀타이즈를 함께 켠다.
    public static let playQuantize = SettingKey("deck.playQuantize", true)
    /// 이전 박 간격 저장값의 호환용. 재생 경계는 다음 한 박이며 이 값은 사용하지 않는다.
    public static let playQuantizeBeats = SettingKey<Double>("deck.playQuantizeBeats", PlayQuantize.defaultBeats) {
        PlayQuantize.choices.contains($0) ? $0 : nil
    }
    /// 그리드를 고칠 때 큐도 같은 박을 따라 옮긴다.
    public static let carryCues = SettingKey("deck.carryCues", true)
    /// 메모리 큐 제안 표시
    public static let showSuggestions = SettingKey("deck.showSuggestions", true)
    public static let volume = SettingKey<Double>("deck.volume", 0.9, in: 0...1)
    public static let keyLock = SettingKey("deck.keyLock", true)
    public static let metronomeVolume = SettingKey<Double>("deck.metronomeVolume", 0.8, in: 0...1)
    /// 재생을 멈춘 뒤 오디오 엔진을 끄기까지(초). 짧으면 CPU를 덜 쓰고, 길면 멈춘 뒤 바로 다시 소리가 난다.
    public static let idleSeconds = SettingKey<Double>("deck.idleSeconds", 20, in: 5...300)
    public static let idleSecondsChoices: [Double] = [5, 10, 20, 30, 60, 120, 300]

    // MARK: 게인

    public static let autoGain = SettingKey("deck.autoGain", true)
    /// 오토게인 목표(LUFS)
    public static let gainTarget = SettingKey<Double>("deck.gainTarget", -10, in: -14...(-8))
    public static let gainTargetChoices: [Double] = [-14, -12, -11, -10, -9, -8]
    public static let peakProtection = SettingKey("deck.peakProtection", true)
    /// 수동 트림(dB)
    public static let gainTrim = SettingKey<Double>("deck.gainTrim", 0, in: -12...12)
    public static let useRekordboxGain = SettingKey("deck.useRekordboxGain", true)

    // MARK: 화면 상태(창에서 바로 바꾸는 값)

    public static let cueListFilter = SettingKey("deck.cueListFilter", CueListFilter.all.rawValue) {
        CueListFilter(rawValue: $0)?.rawValue
    }
    public static let waveformHeight = SettingKey<Double>("waveformHeight", 150, in: nil)
    public static let sheetMode = SettingKey("sheetMode", false)
    public static let showTagEditor = SettingKey("showTagEditor", false)
    public static let sidebarPlaylistsExpanded = SettingKey("sidebar.playlistsExpanded", true)
    public static let sidebarSummaryExpanded = SettingKey("sidebar.summaryExpanded", true)
    /// 재생 기록은 날짜마다 한 줄이라 길어서 접어 두고 시작한다.
    public static let sidebarHistoriesExpanded = SettingKey("sidebar.historiesExpanded", false)
    /// 사이드바 현황·스냅샷 파일 이름. 늘 볼 필요가 없어 숨겨 두고 설정 › 일반에서 켠다.
    public static let sidebarShowsStatus = SettingKey("sidebar.showsStatus", false)
    /// 주 창 사이드바를 연 채 두었는지. 저절로 접은 것도 저장해 다음 실행을 같은 모양으로 시작한다(#119).
    public static let sidebarVisible = SettingKey("sidebar.visible", true)

    /// 앱 안 글자 배율(보기 › 글자 크게·작게). 단계 밖의 값은 가장 가까운 단계로 읽는다.
    public static let textScale = SettingKey<Double>("view.textScale", 1) { value in
        value.isFinite ? TextScale.nearest(value) : nil
    }

    // MARK: 목록·표

    public static let commentClassColumnHidden = SettingKey("library.commentClassColumnHidden", false)
    /// 곡 목록·곡 수에서 스트리밍 곡을 뺀다. 보이는 것만 바꾸고 라이브러리·초안·rekordbox에 쓰는 내용은 그대로다(`StreamingVisibility`).
    public static let hideStreaming = SettingKey("library.hideStreaming", false)

    // MARK: 저장 공간

    /// 자동 시점 스냅샷(#228)을 남겨 둘 일수(#223 결정: 기본 7일, 설정에서 일수만). 수동·고정·복원 직전 스냅샷은 이 값과 상관없다.
    public static let pointSnapshotAutoDays = SettingKey<Double>("storage.pointSnapshotAutoDays", 7, in: 1...90)
    /// rekordbox가 꺼져 있고 라이브러리가 바뀌었으면 하루 한 번 자동 시점 스냅샷을 남긴다(#228). 기본은 켬
    public static let pointSnapshotAuto = SettingKey("storage.pointSnapshotAuto", true)

    // MARK: 실험실

    /// 실험실: 사이드바에서 인텔리전트 재생 목록의 조건을 DJCrate가 계산해 읽기 전용으로 보인다(#68). rekordbox가 보여 주는 곡과 아직 견주지 않아
    /// 기본은 끔이고, 끄면 설정이 없던 때와 똑같이 보인다. 앞으로 다른 실험 기능도 `lab.` 이름으로 이 구역에 둔다.
    public static let labSmartPlaylists = SettingKey("lab.smartPlaylists", false)

    /// 곡 UUID 모음: 무시한 게인·그리드·키 제안
    public static let dismissedGainSuggestions = "deck.dismissedGainSuggestions"
    public static let dismissedGridSuggestions = "deck.dismissedGridSuggestions"
    public static let dismissedKeySuggestions = "library.dismissedKeySuggestions"
    /// 덱 단축키 중 바꾼 동작만(`DeckShortcuts.overrides`)
    public static let deckShortcuts = "shortcuts.deck"

    /// 모든 이름(겹치지 않는지 확인용)
    public static var all: [String] {
        [zoomSeconds.name, volume.name, metronomeVolume.name, idleSeconds.name, gainTarget.name, gainTrim.name,
         waveformHeight.name, textScale.name, playQuantizeBeats.name, pointSnapshotAutoDays.name]
            + [quantize, playQuantize, carryCues, showSuggestions, keyLock, autoGain, peakProtection, useRekordboxGain,
               sheetMode, showTagEditor, sidebarPlaylistsExpanded, sidebarSummaryExpanded, sidebarHistoriesExpanded, sidebarShowsStatus,
               sidebarVisible, commentClassColumnHidden, hideStreaming, labSmartPlaylists, pointSnapshotAuto].map(\.name)
            + [dismissedGainSuggestions, dismissedGridSuggestions, dismissedKeySuggestions, deckShortcuts, waveformColorMode.name, commentPreset.name, cueListFilter.name]
    }
}
