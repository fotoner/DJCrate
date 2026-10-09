import DJCApplication
import DJCDomain
import AppKit
import Observation
import Foundation

/// 위쪽 덱: 선택한 곡의 파형·그리드·분석·재생·큐/그리드 초안.
@MainActor
@Observable
final class DeckModel {
    enum DraftKind { case cue, grid, gain }

    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet { if oldValue !== undoManager { oldValue?.removeAllActions(withTarget: self) } }
    }
    @ObservationIgnored var pendingDraftUndo: DeckDraftSnapshot?

    var row: TrackRow?
    var waveform: Waveform? { didSet { refreshColorWaveform() } }
    var colorWaveform: ColorWaveformRaster?
    @ObservationIgnored var colorWaveformTask: Task<Void, Never>?
    var waveformColorMode = WaveformColorMode.threeBand {
        didSet {
            guard waveformColorMode != oldValue else { return }
            storage.settings.set(SettingKeys.waveformColorMode, waveformColorMode.rawValue)
            refreshColorWaveform()
        }
    }
    var waveformError: String?
    var audioSourceState: AudioSourceState = .none
    var analysis: PartAnalysis?
    var analysisError: String?
    /// rekordbox 분석 파일 상태(분석 전·파형 없음). 곡을 불러올 때 읽기 포트가 쓰기 대상 share에서 함께 읽는다(덱 머리 경고).
    var analysisState: RekordboxAnalysisState?
    /// 섹션(MU) 분석이 끝나기를 기다리는 중(섹션 칸에 로딩 막대)
    var isAnalyzingSections = false
    var artwork: NSImage?
    var draft: CueDraft?
    var hasUncommittedCueEdits = false
    var draftSaveFailures: [DraftSaveFailure] = []
    @ObservationIgnored var draftSaveRevisions: [String: UInt64] = [:]
    var selectedCueID: EditableCue.ID?
    var playhead: Double = 0 {
        didSet { updateDisplayTime() }
    }
    var isPlaying = false {
        didSet { if !isPlaying, displayTime != playhead { displayTime = playhead } }
    }
    var zoomSeconds: Double = 16 { didSet { storage.settings.set(SettingKeys.zoomSeconds, zoomSeconds) } }
    /// CDJ식 메인 CUE 지점. 곡을 불러오면 첫 메모리 큐(없으면 0초)에 놓인다. 초안·rekordbox에는 쓰지 않는다.
    var cuePoint: Double = 0
    /// CUE를 누르고 있는 동안의 미리 듣기.
    var isCuePreviewing = false
    var placeAtFirstMemoryCue = false
    /// 큐·루프 등록도 Q와 같은 상태를 읽는다. 기존 편집 호출부는 이 이름을 유지한다.
    var quantize: Bool {
        get { playQuantize }
        set { playQuantize = newValue }
    }
    /// Q 하나로 큐·루프 등록 스냅과 재생 중 핫큐 점프 퀀타이즈를 함께 켠다.
    var playQuantize = true {
        didSet {
            storage.settings.set(SettingKeys.playQuantize, playQuantize)
            storage.settings.set(SettingKeys.quantize, playQuantize)
        }
    }
    /// 이전 박 간격 저장값의 호환용. 재생 경계는 이 값과 관계없이 다음 한 박이다.
    var playQuantizeBeats = PlayQuantize.defaultBeats {
        didSet { storage.settings.set(SettingKeys.playQuantizeBeats, playQuantizeBeats) }
    }
    /// 오디오가 샘플 단위로 예약하지 못한 점프(곡을 메모리에 풀기 전). 화면 틱이 경계를 지나면 넘긴다.
    var pendingJump: PendingJump?
    /// 오디오가 경계에서 넘길 점프. 화면 틱이 넘어간 순간을 알아본다(건너뛴 구간을 지나간 것으로 보지 않게).
    @ObservationIgnored var scheduledJump: PlayQuantize.Jump?
    /// 경계 전에 일시정지하면 아직 도착하지 않은 루프 상태도 함께 취소한다.
    @ObservationIgnored var scheduledJumpSourceLoop: (instant: InstantLoop?, cueID: EditableCue.ID?)?
    /// 그리드를 고칠 때 큐(핫큐·메모리 큐·루프)도 같은 박을 따라 옮긴다.
    var carryCues = true { didSet { storage.settings.set(SettingKeys.carryCues, carryCues) } }
    var showSuggestions = true {
        didSet { storage.settings.set(SettingKeys.showSuggestions, showSuggestions); refreshSuggestions() }
    }

    // 재생 설정
    var volume: Double = 0.9 {
        didSet {
            audio.volume = Float(volume)
            guard volume != oldValue else { return }
            storage.settings.set(SettingKeys.volume, volume)
        }
    }
    @ObservationIgnored private var lastVolumePreviewTime: Double = 0
    /// 슬라이더를 끄는 동안에는 소리에만 바로 반영하고 저장은 손을 놓을 때 한다.
    func previewVolume(_ value: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVolumePreviewTime >= 1.0 / 30 else { return }
        lastVolumePreviewTime = now
        audio.volume = Float(value)
    }
    var metronome = false { didSet { audio.metronome = metronome } }
    /// 메트로놈 소리 크기(0~1). 설정 창 컨트롤이 같은 값을 다시 넣을 때는 저장하지 않는다.
    var metronomeVolume = SettingKeys.metronomeVolume.defaultValue {
        didSet {
            guard metronomeVolume != oldValue else { return }
            audio.metronomeVolume = Float(metronomeVolume)
            storage.settings.set(SettingKeys.metronomeVolume, metronomeVolume)
        }
    }
    /// 재생을 멈춘 뒤 오디오 엔진을 끄기까지(초)
    var idleSeconds = SettingKeys.idleSeconds.defaultValue {
        didSet {
            guard idleSeconds != oldValue else { return }
            audio.idleSeconds = idleSeconds
            storage.settings.set(SettingKeys.idleSeconds, idleSeconds)
        }
    }
    /// 덱 단축키(키 위치 → 동작). 설정 창에서 바꾸고 KeyRouter가 읽는다.
    var shortcuts = DeckShortcuts.standard { didSet { storage.settings.shortcuts = shortcuts } }
    /// 재생 속도(%). rekordbox 템포 슬라이더와 같은 의미.
    var tempoPercent: Double = 0 { didSet { audio.rate = 1 + tempoPercent / 100 } }
    var keyLock = true { didSet { audio.keyLock = keyLock; storage.settings.set(SettingKeys.keyLock, keyLock) } }

    // MARK: 상태(역할별 파일에서 쓰는 저장값)

    /// 곡마다 통합 음량을 목표에 맞춘다.
    var autoGain = true { didSet { storage.settings.set(SettingKeys.autoGain, autoGain); applyGain() } }

    /// 오토게인 목표(LUFS)
    var gainTarget: Double = -10 { didSet { storage.settings.set(SettingKeys.gainTarget, gainTarget); applyGain() } }

    /// 피크가 0dBFS를 넘지 않을 만큼만 올린다.
    var peakProtection = true {
        didSet { storage.settings.set(SettingKeys.peakProtection, peakProtection); applyGain() }
    }

    /// 수동 트림(dB). 오토게인 위에 더한다.
    var gainTrim: Double = 0 { didSet { storage.settings.set(SettingKeys.gainTrim, gainTrim); applyGain() } }

    /// 지금 곡의 음량(메모리 디코딩 뒤 측정, 다음부터는 캐시)
    var loudness: Loudness?

    /// rekordbox 오토게인을 그대로 쓴다(없으면 DJCrate 측정으로 계산).
    var useRekordboxGain = true {
        didSet { storage.settings.set(SettingKeys.useRekordboxGain, useRekordboxGain); applyGain() }
    }

    /// 이 곡의 오토게인 초안(dB). rekordbox에 반영하면 rekordbox 오토게인이 이 값이 된다.
    var gainDraft: Double?

    var dismissedGainSuggestions: Set<String> = [] {
        didSet { storage.settings.setStrings(SettingKeys.dismissedGainSuggestions, dismissedGainSuggestions) }
    }

    /// 곡 안의 조표 구간(rekordbox 시간축). 주 조표는 rekordbox 키에 맞춘다.
    var keySegments: [KeySegment] = []

    /// 장·단(A/B)은 rekordbox 키를 따른다(없으면 크로마로 정한다).
    var keyMinor = false

    @ObservationIgnored var keyChroma: KeyChroma?

    /// 키가 빈 rekordbox 곡에서 덱이 구한 주 조성. 덱 제안 줄의 키 제안이 곡 UUID로 맞춰 본 뒤 쓴다.
    var keyEstimate: KeyEstimate?

    /// 레벨 미터 다시 그리기 신호(재생 틱에 맞춰 초당 30번). 미터가 따로 타이머를 돌리면 창 갱신이 그만큼 더 생긴다.
    var meterFrame = 0

    @ObservationIgnored var meterStamp: Double = 0

    /// 지금 반복 중인 루프(큐 ID)
    var engagedLoopID: EditableCue.ID?

    var instantLoop: InstantLoop?

    /// 즉석 루프 길이(박). ½ · ×2로 바꾼다.
    var loopSize: Double = 4

    /// 무시 표시가 바뀌면 화면을 다시 그리게 한다.
    var dismissedRevision = 0

    var toast: AppMessage?
    @ObservationIgnored var feedback = AppFeedback()

    /// Flip 기록 중(덱의 Flip 버튼 불빛). 기록 내용은 재생이 끝날 때마다 바뀌어 관찰하지 않는다(`flipRecording`).
    var isFlipRecording = false
    /// 넣지 않은 Flip 결과 창이 열려 있다(새로 기록하면 그 결과를 버린다: 메뉴·단추가 확인 창을 연다).
    var hasPendingFlipResult = false
    @ObservationIgnored var flipRecording: FlipRecording?
    /// 기록을 마치고 결과 창을 열려고 음원 파일 확인을 기다리는 기록(그동안 곡을 바꾸면 버릴지 묻는다)
    @ObservationIgnored var awaitingFlipResult: FlipRecording?
    /// 결과 창을 기다리는 기록의 차례. 기다리는 중 기록을 버리면 올라가 진행 중인 열기가 조용히 끝난다.
    @ObservationIgnored var flipResultTurn = 0
    /// 기록을 버릴지 묻는 창이 떠 있는 동안만 nil이 아니다. 그동안 음원 확인을 마친 결과 창 열기가 여기서 답을 기다린다.
    @ObservationIgnored var flipDecisionWaiters: [CheckedContinuation<Void, Never>]?
    /// 되돌릴 수 없는 일(Flip 기록 버리기) 전에 묻는 창. 시험은 정해 둔 답을 준다.
    @ObservationIgnored var prompter: any ReflectionPrompter = AlertPrompter()

    @ObservationIgnored var toastTask: Task<Void, Never>?

    // 그리드
    var originalGrid: BeatGrid?
    var gridDraft: GridDraft?
    /// 화면·스냅·메트로놈이 쓰는 그리드. 편집하지 않았으면 rekordbox 원본 그대로다.
    var grid: BeatGrid? { didSet { if grid?.downbeats != oldValue?.downbeats { refreshKeySegments() } } }
    var gridEditing = false
    /// rekordbox에 쓰는 동안 큐 편집을 막는다(쓰는 초안과 덱 초안이 어긋나지 않게).
    /// rekordbox에 쓰는 동안: 재생을 잠시 멈추고(끝나면 이어서) 편집을 막는다.
    var isWriteLocked = false {
        didSet {
            guard isWriteLocked != oldValue else { return }
            if isWriteLocked {
                clearDraftUndo()
                resumeAfterWrite = isPlaying
                if isPlaying { togglePlay() }
            } else if resumeAfterWrite {
                resumeAfterWrite = false
                if canPlay, !isPlaying { togglePlay() }
            }
        }
    }
    var resumeAfterWrite = false
    var softReloadTask: Task<Void, Never>?
    /// 편집 전 재생성 오차가 크면(다이내믹 그리드 등) 그리드 편집을 막는다.
    var gridEditBlockedReason: String?
    var gridSourceNotice: String?
    /// rekordbox 비트 그리드가 있는 곡인지(없으면 추정 그리드를 권한다)
    var hasRekordboxGrid = false
    /// rekordbox 시간축 − 음원(AVFoundation) 시간축(초). 덱은 rekordbox 시간축을 쓰고,
    /// 음원 재생·파형·MU 분석만 이만큼 밀어 맞춘다(압축 음원의 인코더 지연을 rekordbox처럼 남긴다).
    var timelineOffset: Double = 0
    /// DJCrate가 추정한 그리드(DJCrate 시간축)
    var gridSuggestion: GridEstimate?
    /// 덱 제안 줄의 그리드 제안(현재 그리드와 사실상 같으면 nil)
    var gridSuggestionItem: DeckSuggestion?
    /// 그리드가 없는 곡에서 파형 위에 미리 보여 줄 추정 박(적용 전)
    var suggestedGrid: BeatGrid?
    var suggestionTask: Task<Void, Never>?
    /// 추가한 곡의 그리드가 바뀌면 목록 BPM을 맞춘다.
    var onStagedGridChange: ((String, Double?) -> Void)?
    /// 큐 초안이 바뀔 때(목록의 핫큐·메모리 숫자용)
    var onCueDraftChange: ((CueDraft) -> Void)?
    /// 재분석이 이 곡의 분석 캐시를 지울 때(곡 UUID). 캐시에서 읽는 키 추정의 "무시"도 풀어야 하는 목록 쪽이 받는다.
    var onReanalyze: ((String) -> Void)?
    var tapBPM: Double?
    var taps: [Double] = []
    var gridDragBase: GridDraft?
    /// 그리드를 끄는 동안 핫큐의 출발 위치(끄는 동안 오차가 쌓이지 않게 늘 여기서 옮긴다)
    var cueDragBase: [EditableCue]?
    var lastClickReset: Double = 0

    /// 초안 존재 여부가 바뀌면 알린다(목록의 편집 표시용). 디스크를 다시 읽지 않도록 상태를 함께 넘긴다.
    var onDraftChange: ((String, DraftKind, Bool) -> Void)?

    /// 곡 길이와 재생 가능 여부는 관찰되는 저장값이다(오디오 엔진 값은 관찰되지 않는다).
    var duration: Double = 0
    var canPlay = false
    var currentTime: Double { playhead }
    /// 글자·전체 파형용 재생 위치. 재생 중에는 초당 15번만 바뀐다(멈춰 있을 땐 바로 따라간다).
    var displayTime: Double = 0
    @ObservationIgnored var displayTimeStamp: Double = 0

    func updateDisplayTime() {
        guard displayTime != playhead else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // 재생 중이 아니거나(탐색·끌기) 크게 뛰면 바로, 재생 중에는 1/15초마다
        if !isPlaying || now - displayTimeStamp >= 1.0 / 15 || abs(playhead - displayTime) > 0.5 {
            displayTime = playhead
            displayTimeStamp = now
        }
    }
    var rate: Double { 1 + tempoPercent / 100 }

    /// 플레이헤드가 있는 템포 구간의 BPM. 바뀔 때만 갱신되는 저장값이다.
    var gridBPM: Double?

    /// 메모리 큐 제안과 섹션 에너지는 분석·큐·그리드가 바뀔 때만 다시 계산한다.
    var suggestions: [Double] = []
    var sectionEnergies: [SectionEnergy] = []

    let audio: any DeckAudioEngine
    let storage: DeckStorage
    /// 곡을 올릴 때 메인 스레드 밖에서 읽는 일(초안·그리드·그림·캐시)
    let loader: LoadDeckTrack
    /// 음원을 연 뒤의 분석(파형·음악 분석·그리드 추정·조성 흐름·메모리 큐 제안)과 디코딩이 잰 값 기억
    let analyzer: AnalyzeDeckTrack
    /// 분석 파일·그림을 찾을 rekordbox share 뿌리. 앱은 쓰기 대상(`LibraryStore.rekordboxShareRoot`)과 맞춘다(nil이면 기본 rekordbox 폴더).
    @ObservationIgnored var shareRoot: () -> URL? = { nil }
    /// 곡을 바꿀 때마다 오른다. 백그라운드 읽기는 시작할 때의 값과 같을 때만 적용한다.
    @ObservationIgnored var loadGeneration = 0
    /// 곡을 올린 뒤 파형·음악 분석·그리드 추정을 돌릴지(시험에서는 끈다: 캐시 폴더에 쓰지 않게)
    let runsAnalysis: Bool
    @ObservationIgnored lazy var ticker = DisplayTicker { [weak self] in self?.tick() }
    var loadTask: Task<Void, Never>?
    var waveformTask: Task<Waveform, Error>?
    var resumeAfterScrub = false
    /// 확대 파형을 끄는 동안의 기준점(놓으면 nil). 끄는 도중 핫큐로 옮기면 기준도 옮긴다(#133).
    @ObservationIgnored var scrubAnchor: ScrubAnchor?
    var seekRestartTask: Task<Void, Never>?

    /// 앱은 조립 지점(`AppComposition.live`)이 실제 오디오·저장소·읽기·분석을 준다.
    /// - Parameters:
    ///   - assets: 곡을 올릴 때 읽는 것(음원·분석 파일·그림·`storage`의 초안)
    ///   - analysis: 분석과 분석 캐시(불러올 때 크로마·음량 캐시도 여기서 읽는다)
    init(audio: any DeckAudioEngine, storage: DeckStorage, assets: TrackAssetReader, analysis: AnalyzeDeckTrack,
         runsAnalysis: Bool = true) {
        self.audio = audio
        self.storage = storage
        loader = LoadDeckTrack(assets: assets, cache: analysis.cache)
        analyzer = analysis
        self.runsAnalysis = runsAnalysis
        // 설정은 저장소에서 읽는다.
        let settings = storage.settings
        zoomSeconds = settings.value(SettingKeys.zoomSeconds)
        waveformColorMode = WaveformColorMode(rawValue: settings.value(SettingKeys.waveformColorMode)) ?? .threeBand
        // 관찰 프로퍼티의 setter를 거치지 않아 초기화 때 기존 두 저장값을 덮어쓰지 않는다.
        _playQuantize = settings.quantize
        playQuantizeBeats = settings.value(SettingKeys.playQuantizeBeats)
        carryCues = settings.value(SettingKeys.carryCues)
        showSuggestions = settings.value(SettingKeys.showSuggestions)
        volume = settings.value(SettingKeys.volume)
        keyLock = settings.value(SettingKeys.keyLock)
        metronomeVolume = settings.value(SettingKeys.metronomeVolume)
        idleSeconds = settings.value(SettingKeys.idleSeconds)
        shortcuts = settings.shortcuts
        autoGain = settings.value(SettingKeys.autoGain)
        gainTarget = settings.value(SettingKeys.gainTarget)
        peakProtection = settings.value(SettingKeys.peakProtection)
        gainTrim = settings.value(SettingKeys.gainTrim)
        useRekordboxGain = settings.value(SettingKeys.useRekordboxGain)
        dismissedGainSuggestions = settings.strings(SettingKeys.dismissedGainSuggestions)
        audio.volume = Float(volume)
        audio.keyLock = keyLock
        audio.metronomeVolume = Float(metronomeVolume)
        audio.idleSeconds = idleSeconds
        audio.onChroma = { [weak self] chroma in
            guard let self, let row = self.row, !row.track.isStreaming else { return }
            self.analyzer.remember(chroma: chroma, key: row.track.uuid, file: URL(filePath: row.track.folderPath))
            self.keyChroma = chroma
            self.refreshKeySegments()
        }
        audio.onLoudness = { [weak self] measured in
            guard let self, let row = self.row, !row.track.isStreaming else { return }
            self.analyzer.remember(loudness: measured, file: URL(filePath: row.track.folderPath))
            self.loudness = measured
            self.applyGain()
        }
        audio.onRecovered = { [weak self] in
            guard let self else { return }
            self.isPlaying = true
            self.ticker.start()
        }
        audio.onInterrupted = { [weak self] position in
            guard let self else { return }
            self.ticker.stop()
            self.isPlaying = false
            self.playhead = position
            // 이어 재생하지 못하고 멈췄다. 다음 재생은 새로 시작한 재생이다(Flip 기록에 점프로 남지 않는다).
            self.flipRecording?.breakLink()
        }
    }

    func setZoom(_ seconds: Double) {
        zoomSeconds = min(max(seconds, 2), 64)
    }

    func zoom(by factor: Double) {
        setZoom(zoomSeconds * factor)
    }

    func refreshGrid() {
        if let gridDraft, gridDraft.hasChanges {
            grid = gridDraft.grid(duration: max(duration, Double(row?.track.lengthSeconds ?? 0)))
        } else {
            grid = originalGrid
        }
        updateGridBPM()
        refreshSuggestions()
    }

    func refreshSuggestions() {
        guard showSuggestions, let analysis, let draft else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        suggestions = analyzer.memoryCueSuggestions(analysis, existing: draft.cues.map(\.time), grid: grid)
    }

    func updateGridBPM() {
        let bpm = grid?.bpm(at: playhead)
        if bpm != gridBPM { gridBPM = bpm }
    }

}
