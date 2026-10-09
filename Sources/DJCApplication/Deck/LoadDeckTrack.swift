import DJCDomain
import Foundation

/// 덱에 올릴 곡(앱의 목록 행이 아니라 읽는 데 필요한 값만)
public struct DeckTrackRequest: Sendable, Equatable {
    public var uuid: String
    /// 음원 파일. 스트리밍 곡이면 nil
    public var audioFile: URL?
    public var analysisPath: String?
    public var imagePath: String?
    /// 분석 파일·그림을 찾을 rekordbox share 뿌리(쓰기 대상 라이브러리와 같은 곳, nil이면 기본 rekordbox 폴더)
    public var shareRoot: URL?
    public var rekordboxCues: [Cue]

    public init(uuid: String, audioFile: URL?, analysisPath: String?, imagePath: String?, shareRoot: URL?, rekordboxCues: [Cue]) {
        self.uuid = uuid
        self.audioFile = audioFile
        self.analysisPath = analysisPath
        self.imagePath = imagePath
        self.shareRoot = shareRoot
        self.rekordboxCues = rekordboxCues
    }
}

/// 음원을 열기 전에 정할 값(파일이 없거나 스트리밍 곡이면 비어 있다)
public struct DeckAudioPreparation: Sendable {
    public var fileExists = false
    /// 덱의 모든 시각은 rekordbox 시간축이다: 음원은 인코더 지연만큼 밀어 재생한다.
    public var timelineOffset: Double = 0
    /// 있으면 디코딩 때 크로마를 다시 계산하지 않는다(음원을 열기 전에 알아야 한다).
    public var cachedChroma: KeyChroma?
    /// 전에 잰 곡이면 디코딩을 기다리지 않고 바로 오토게인을 건다.
    public var loudness: Loudness?
    public var gainDraft: Double?

    public init() {}
}

/// 덱에 한 번에 적용할 곡 내용(큐 초안·그리드 판정·그림·분석 파일 상태)
public struct DeckTrackContent: Sendable {
    public var draft: CueDraft
    public var grid: DeckGridGate
    public var artwork: DeckArtwork?
    public var analysisState: RekordboxAnalysisState
}

/// 덱 곡 불러오기(유스케이스): 덱이 메인 스레드에서 하던 파일 읽기를 메인 밖에서 모아 결과 값 하나로 돌려준다.
/// 음원 열기(오디오 엔진)는 덱이 메인 액터에서 동기로 한다.
public struct LoadDeckTrack: Sendable {
    public var assets: TrackAssetReader
    /// 전에 잰 크로마·음량(`AnalyzeDeckTrack`과 같은 캐시)
    public var cache: AnalysisStore

    public init(assets: TrackAssetReader, cache: AnalysisStore) {
        self.assets = assets
        self.cache = cache
    }

    /// 음원을 열기 전에 필요한 작은 읽기(파일 있음·인코더 지연·조성 크로마·음량 캐시·게인 초안)
    @concurrent
    public func prepareAudio(_ request: DeckTrackRequest) async -> DeckAudioPreparation {
        var prepared = DeckAudioPreparation()
        guard let url = request.audioFile, assets.audioFileExists(url) else { return prepared }
        prepared.fileExists = true
        prepared.timelineOffset = assets.timelineOffset(url)
        prepared.cachedChroma = cache.chroma(request.uuid, url)
        prepared.loudness = cache.loudness(url)
        prepared.gainDraft = assets.gainDraft(request.uuid)
        return prepared
    }

    /// 큐 초안·그리드 판정·그림·분석 파일 상태. `duration`은 음원을 연 뒤의 곡 길이(못 열었으면 rekordbox 길이)다.
    @concurrent
    public func content(_ request: DeckTrackRequest, duration: Double) async -> DeckTrackContent {
        // 자동 큐를 빼고 만든 옛 초안에는 곡의 자동 큐를 채운다(#145, 목록에 메모리 큐로 보인다).
        let draft = assets.cueDraft(request.uuid)?.includingAutoCues(from: request.rekordboxCues, newID: assets.newCueID)
            ?? CueDraft(trackUUID: request.uuid, rekordboxCues: request.rekordboxCues, newID: assets.newCueID)
        let artwork = assets.artwork(request.imagePath, request.shareRoot, 360)
        let read = assets.rekordboxGrid(request.analysisPath, request.shareRoot)
        let grid = DeckGridGate(trackUUID: request.uuid, read: read, savedDraft: assets.gridDraft(request.uuid), duration: duration)
        return DeckTrackContent(draft: draft, grid: grid, artwork: artwork,
                                analysisState: assets.analysisState(request.analysisPath, request.shareRoot))
    }

    /// 소리를 그대로 둔 채 다시 읽기(rekordbox에 쓴 뒤): 곡 내용과 게인 초안
    @concurrent
    public func reloadContent(_ request: DeckTrackRequest, duration: Double) async -> (DeckTrackContent, gainDraft: Double?) {
        let gain = assets.gainDraft(request.uuid)
        return (await content(request, duration: duration), gain)
    }

    /// rekordbox 그림이 없을 때 음원에 든 그림(메인 밖에서 읽는다)
    @concurrent
    public func embeddedArtwork(_ file: URL) async -> DeckArtwork? {
        await assets.embeddedArtwork(file)
    }

    /// 색 파형 모드의 rekordbox 분석 파일 파형(없으면 nil: 덱이 자체 파형으로 그린다)
    @concurrent
    public func colorWaveform(_ request: DeckTrackRequest, mode: WaveformColorMode) async -> ColorWaveformColumns? {
        assets.colorWaveform(request.analysisPath, request.shareRoot, mode)
    }
}
