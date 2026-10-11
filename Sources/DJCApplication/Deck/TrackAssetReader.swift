import CoreGraphics
import DJCDomain
import Foundation

/// 덱이 곡을 올릴 때 읽는 것(포트): 음원·rekordbox 분석 파일·그림·초안.
/// 실제 구현(`.live`)은 DJCAdapters가 주고 조립 지점이 고른다. 모두 메인 스레드 밖에서 불린다.
public struct TrackAssetReader: Sendable {
    public var audioFileExists: @Sendable (URL) -> Bool
    /// rekordbox 시간축 − 음원 시간축(초, 인코더 지연)
    public var timelineOffset: @Sendable (URL) -> Double
    /// 곡 UUID → 오토게인 초안(dB)
    public var gainDraft: @Sendable (String) -> Double?
    public var cueDraft: @Sendable (String) -> CueDraft?
    /// 초안에 새로 들이는 큐의 ID(초안 저장소가 준다, `DraftStore.newCueID`)
    public var newCueID: @Sendable () -> UUID
    public var gridDraft: @Sendable (String) -> GridDraft?
    /// rekordbox 분석 경로(`/PIONEER/USBANLZ/…`)를 share 뿌리(nil이면 기본 rekordbox 폴더)에서 읽은 원본 그리드
    public var rekordboxGrid: @Sendable (String?, URL?) -> AnalysisGridRead
    /// 분석 경로·share 뿌리 → 분석 파일 상태(분석 전·파형 파일 없음)
    public var analysisState: @Sendable (String?, URL?) -> RekordboxAnalysisState
    /// rekordbox 분석 파일의 색 파형(파랑·RGB 모드, 없거나 3밴드면 nil)
    public var colorWaveform: @Sendable (String?, URL?, WaveformColorMode) -> ColorWaveformColumns?
    /// rekordbox 그림 경로를 share 뿌리에서 읽어 긴 변이 `maxPixels` 이하가 되게 줄인 그림
    public var artwork: @Sendable (String?, URL?, Int) -> DeckArtwork?
    /// 음원 파일에 들어 있는 그림(rekordbox 그림이 없을 때)
    public var embeddedArtwork: @Sendable (URL) async -> DeckArtwork?

    public init(audioFileExists: @escaping @Sendable (URL) -> Bool,
                timelineOffset: @escaping @Sendable (URL) -> Double,
                gainDraft: @escaping @Sendable (String) -> Double?,
                cueDraft: @escaping @Sendable (String) -> CueDraft?,
                newCueID: @escaping @Sendable () -> UUID,
                gridDraft: @escaping @Sendable (String) -> GridDraft?,
                rekordboxGrid: @escaping @Sendable (String?, URL?) -> AnalysisGridRead,
                analysisState: @escaping @Sendable (String?, URL?) -> RekordboxAnalysisState,
                colorWaveform: @escaping @Sendable (String?, URL?, WaveformColorMode) -> ColorWaveformColumns?,
                artwork: @escaping @Sendable (String?, URL?, Int) -> DeckArtwork?,
                embeddedArtwork: @escaping @Sendable (URL) async -> DeckArtwork?) {
        self.audioFileExists = audioFileExists
        self.timelineOffset = timelineOffset
        self.gainDraft = gainDraft
        self.cueDraft = cueDraft
        self.newCueID = newCueID
        self.gridDraft = gridDraft
        self.rekordboxGrid = rekordboxGrid
        self.analysisState = analysisState
        self.colorWaveform = colorWaveform
        self.artwork = artwork
        self.embeddedArtwork = embeddedArtwork
    }
}

/// 덱 커버 그림. CGImage는 만든 뒤 바뀌지 않아 스레드 사이로 넘겨도 된다.
public struct DeckArtwork: @unchecked Sendable, Equatable {
    public let image: CGImage
    public init(image: CGImage) { self.image = image }
}
