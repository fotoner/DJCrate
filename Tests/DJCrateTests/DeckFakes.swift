@testable import DJCrate
import DJCAnalysis
@testable import DJCAdapters
import DJCApplication
import DJCDomain
import DJCEnvironment
import DJCTestKit
import Foundation
import Synchronization

/// 소리를 내지 않는 재생 엔진. 위치는 시험이 직접 옮긴다.
@MainActor
final class FakeDeckAudio: DeckAudioEngine {
    var volume: Float = 1
    var metronome = false
    var metronomeVolume: Float = 1
    var idleSeconds = 0.0
    var rate = 1.0
    var keyLock = true
    var gainDB: Float = 0
    let meter = LevelMeter()
    var needsChroma = true
    var onChroma: ((KeyAnalyzer.Chroma) -> Void)?
    var onLoudness: ((Loudness) -> Void)?
    var onRecovered: (() -> Void)?
    var onInterrupted: ((Double) -> Void)?

    var isLoaded = false
    var isPlaying = false
    var duration = 0.0
    var position = 0.0
    var handlesLoop = false
    var hasPendingJump = false
    var isOutputUnavailable = false
    /// 불러오면 이 길이가 된다
    var trackLength = 180.0
    /// 걸려 있는 루프(오디오 쪽)
    var loop: ClosedRange<Double>?
    var log: [String] = []
    var loadError: (any Error)?
    var onPlayedRun: ((PlayedRun) -> Void)?
    /// 지금 재생에서 아직 알리지 않은 구간의 시작(재생 중이 아니면 nil). 시험이 옮긴 `position`까지를 한 구간으로 알린다.
    private var runStart: Double?

    private func endRun(continuing: Bool) {
        guard isPlaying, let start = runStart else { return }
        runStart = nil
        onPlayedRun?(PlayedRun(spans: [PlayedSpan(start: start, end: position)], continuing: continuing))
    }

    func takePlayedRun() -> PlayedRun? {
        guard isPlaying, let start = runStart else { return nil }
        runStart = position
        return PlayedRun(spans: [PlayedSpan(start: start, end: position)], continuing: true)
    }

    /// 출력 장치가 빠져 이어 재생을 세 번 모두 실패했다: 재생 노드가 멈추고 덱에 알린다.
    /// - Parameter continuing: 그 재생을 이어진 재생으로 알렸는지(실제 엔진은 false. 덱이 그와 상관없이 잇지 않는지 본다)
    func simulateOutputLost(continuing: Bool) {
        endRun(continuing: continuing)
        isPlaying = false
        hasPendingJump = false
        log.append("output lost")
        onInterrupted?(position)
    }

    /// 마지막으로 연 음원의 인코더 지연(rekordbox 시간축 − 음원 시간축)
    var loadedOffset: Double?
    func load(url: URL, timelineOffset: Double) throws {
        if let loadError { throw loadError }
        isLoaded = true; duration = trackLength; loadedOffset = timelineOffset; log.append("load")
    }
    func unload() { endRun(continuing: false); isLoaded = false; isPlaying = false }
    func play(from position: Double) -> Bool {
        endRun(continuing: true)
        runStart = position
        self.position = position
        hasPendingJump = false
        isPlaying = true
        handlesLoop = loop != nil
        log.append(String(format: "play %.3f", position))
        return true
    }
    func pause() { endRun(continuing: false); isPlaying = false; hasPendingJump = false; log.append("pause") }
    func stop() { endRun(continuing: false); isPlaying = false; hasPendingJump = false; log.append("stop") }
    func seekWhilePaused(_ position: Double) { self.position = position }
    func recoverIfStalled() {}
    func scheduleClicks(_ grid: BeatGrid?) {}
    func resetClicks() { log.append("resetClicks") }
    func setLoop(_ range: ClosedRange<Double>?, reschedule: Bool) -> Bool {
        handlesLoop = range != nil && isPlaying
        // 실제 엔진처럼 같은 루프를 다시 걸면 아무 일도 하지 않는다(예약한 점프를 지우지 않게).
        guard range != loop else { return true }
        loop = range
        log.append(range.map { String(format: "loop %.3f~%.3f", $0.lowerBound, $0.upperBound) } ?? "loop off")
        return true
    }
    /// false면 샘플 단위 점프 예약을 못 하는 엔진(곡을 메모리에 풀기 전)처럼 군다.
    var schedulesJumps = true
    func scheduleJump(to cue: Double, loop: ClosedRange<Double>?, quantize: PlayQuantize) -> PlayQuantize.Jump? {
        guard schedulesJumps, isPlaying else { return nil }
        let jump = quantize.jump(earliest: position, to: cue, loopEnd: loop?.upperBound)
        self.loop = loop
        hasPendingJump = true
        handlesLoop = loop != nil
        log.append(String(format: "jump %.3f→%.3f", jump.at, jump.to)
                   + (loop.map { String(format: " loop %.3f~%.3f", $0.lowerBound, $0.upperBound) } ?? ""))
        return jump
    }
    /// 음원을 열지 못한 이유는 실제 엔진과 같은 규칙으로 가른다(계약 시험 `AudioEngineContractTests`).
    func failureState(for error: any Error) -> AudioSourceState { AudioSourceFailure.state(for: error) }
    /// 덱 조작 기록(실제는 오디오 사건 기록 파일). 재생 순서 기록(`log`)과 섞지 않는다.
    var events: [String] = []
    func recordEvent(_ message: String) { events.append(message) }
    func debugStopEngine() {}
    func debugConfigurationChange() {}
}

extension DeckStorage {
    /// 메모리 초안 저장소(`MemoryDrafts`: 디스크·UserDefaults 표준 영역을 건드리지 않는다, 실제 구현과 같은 규칙인지는 계약 시험이 본다)
    static func memory(_ drafts: MemoryDrafts,
                       settings: SettingsStore = SettingsStore(defaults: TestDefaults.make("deck"),
                                                               persist: false)) -> DeckStorage {
        memory(drafts.store, settings: settings)
    }

    /// 저장을 바꿔 넣은 초안 저장소(저장 실패·완료 순서를 시험이 정한다)
    static func memory(_ store: DraftStore,
                       settings: SettingsStore = SettingsStore(defaults: TestDefaults.make("deck"),
                                                               persist: false)) -> DeckStorage {
        let storage = DeckStorage(drafts: store, settings: settings)
        testDeckStores.withLock { $0[ObjectIdentifier(settings)] = store }
        return storage
    }

    /// 이 시험 덱 저장소를 만든 초안 저장소(덱은 저장소를 들지 않는다. 시험의 덱 읽기가 같은 초안을 읽게 이 표로 찾는다)
    var testDraftStore: DraftStore {
        guard let store = testDeckStores.withLock({ $0[ObjectIdentifier(settings)] }) else {
            preconditionFailure("DeckStorage.memory로 만든 덱 저장소만 시험 초안 저장소가 있습니다")
        }
        return store
    }
}

/// 시험 덱 저장소의 설정 객체별 초안 저장소(`DeckStorage.memory`가 채운다)
private let testDeckStores = Mutex<[ObjectIdentifier: DraftStore]>([:])

extension TrackAssetReader {
    /// 파일을 읽지 않는 덱 읽기(`MemoryTrackAssets`): 음원은 있다고 보고(가짜 오디오가 연다), 초안은 덱 저장소에서 읽는다.
    /// 인코더 지연·rekordbox 원본 그리드처럼 실제 읽기가 곡마다 내는 값을 줄 수 있다(같은 규칙인지는 DJCAdaptersTests의 계약 시험).
    static func memory(_ storage: DeckStorage, _ assets: MemoryTrackAssets = MemoryTrackAssets()) -> TrackAssetReader {
        assets.reader(drafts: storage.testDraftStore)
    }
}

extension AnalyzeDeckTrack {
    /// 시험 덱의 분석: 실제 분석기(조성 흐름·메모리 큐 제안 계산, 무거운 분석은 `runsAnalysis`가 끈다)와 메모리 캐시
    static func test(_ cache: MemoryAnalysisStore = MemoryAnalysisStore()) -> AnalyzeDeckTrack {
        AnalyzeDeckTrack(analyzer: .live(paths: .current), cache: cache.store)
    }
}

extension DeckModel {
    /// 시험 덱(조립 지점 대신). 읽기를 주지 않으면 옛 기본값처럼 실제 파일과 `storage`의 초안을 읽는다. 분석 캐시는 메모리다.
    static func test(audio: any DeckAudioEngine, storage: DeckStorage, reader: TrackAssetReader? = nil,
                     analysis: AnalyzeDeckTrack = .test(), runsAnalysis: Bool = true) -> DeckModel {
        DeckModel(audio: audio, storage: storage, assets: reader ?? .live(drafts: storage.testDraftStore), analysis: analysis,
                  runsAnalysis: runsAnalysis)
    }
}

/// 덱 하나 + 가짜 오디오 + 메모리 저장소 + 가짜 읽기(음원·DB 파일 없음)
@MainActor
final class DeckHarness {
    let deck: DeckModel
    let audio: FakeDeckAudio
    let drafts: MemoryDrafts
    let root: URL

    /// - Parameter gridBase: 그리드 초안의 "rekordbox 원래 그리드"(되돌리기 대상). 비우면 분석 전 곡처럼 원래 그리드가 없다.
    /// - Parameter audioFile: 음원 파일을 실제로 둔다(덱 밖에서 파일 있음을 다시 보는 안내 시험용).
    /// - Parameter timelineOffset: 음원의 인코더 지연(실제 읽기가 압축 음원에서 내는 값, 덱 시각은 rekordbox 시간축)
    init(cues: [Cue] = [], grid: [GridSegment]? = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)],
         gridBase: [GridSegment] = [], autoGain: RekordboxAutoGain? = nil, key: String? = "8B", audioFile: Bool = false,
         timelineOffset: Double = 0) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "djc-deck-\(UUID().uuidString)")
        audio = FakeDeckAudio()
        drafts = MemoryDrafts()
        let storage = DeckStorage.memory(drafts)
        var assets = MemoryTrackAssets(defaultOffset: timelineOffset)
        var analysisPath: String?
        if let grid, grid == gridBase, !grid.isEmpty {
            // 고친 것이 없는 그리드 초안은 저장소에 남지 않는다(실제 저장소와 같다): rekordbox 분석 파일의 그리드로 준다.
            let original = GridDraft(trackUUID: "track-1", base: grid, segments: grid).grid(duration: 181)
            analysisPath = "/PIONEER/USBANLZ/harness/ANLZ0000.DAT"
            assets.analysis[analysisPath!] = .init(grid: .grid(original))
        }
        let reader = TrackAssetReader.memory(storage, assets)
        deck = DeckModel.test(audio: audio, storage: storage, reader: reader, runsAnalysis: false)
        // 시험이 쓰는 폴더(초안 폴더 등)의 뿌리. 음원은 가짜 오디오가 열어 파일이 없다.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root.appending(path: "audio/silence.wav")
        if audioFile {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            url = try AudioFixture.wav(seconds: 1, in: url.deletingLastPathComponent())
        }
        let track = Track(id: "1", uuid: "track-1", title: "시험 곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                          composer: nil, releaseYear: nil, trackNumber: nil, key: key, bpm: 120, lengthSeconds: 180,
                          folderPath: url.path, comment: "", importedOn: nil, analysisDataPath: analysisPath, imagePath: nil, isDeleted: false)
        // 고친 그리드는 초안으로 준다(원본이 없으면 분석 경로가 없는 곡)
        if let grid { drafts.save(GridDraft(trackUUID: track.uuid, base: gridBase, segments: grid)) }
        deck.load(TrackRow(track: track, cues: cues, playCount: 0, autoGain: autoGain))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// 백그라운드에서 초안·그리드를 다 읽을 때까지
    func loaded() async throws {
        for _ in 0..<200 where deck.draft == nil { try await Task.sleep(for: .milliseconds(10)) }
        if deck.draft == nil { throw FixtureError("덱이 곡을 다 읽지 못함") }
    }
}
