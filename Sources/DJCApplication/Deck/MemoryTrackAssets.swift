import DJCDomain
import Foundation

/// 파일 없이 정해 둔 값을 내는 덱 읽기(`TrackAssetReader`의 메모리 구현). 덱 시험·하네스가 음원·분석 파일 없이 쓴다.
/// 실제 구현과 같은 규칙을 따른다: 분석 경로가 없으면 원본 그리드 없음·분석 전, 파형 파일이 없으면 파형 없음.
/// 인코더 지연·원본 그리드처럼 실제 읽기가 곡마다 다르게 내는 값도 정해 줄 수 있다(adv4 T7). 같은 규칙인지는 DJCAdaptersTests의 계약 시험이 본다.
public struct MemoryTrackAssets: Sendable {
    /// 있는 음원(경로) → 인코더 지연(초). nil이면 모든 음원이 있고 지연은 `defaultOffset`이다
    public var audio: [String: Double]?
    public var defaultOffset: Double
    /// 분석 경로(`/PIONEER/USBANLZ/…/ANLZ0000.DAT`) → 그 분석 파일의 그리드 읽기 결과와 파형 파일(.EXT)이 있는지
    public var analysis: [String: AnalysisFile]
    /// 분석 경로가 빈 곡에 그리드 초안을 쓸 때 분석 파일을 붙이는지(실제는 `RekordboxWriter.attachesAnalysis`)
    public var attachesAnalysis: Bool
    /// 그림 경로 → 그림
    public var artwork: [String: DeckArtwork]

    public struct AnalysisFile: Sendable {
        public var grid: AnalysisGridRead
        public var hasWaveform: Bool
        public init(grid: AnalysisGridRead, hasWaveform: Bool = true) {
            self.grid = grid
            self.hasWaveform = hasWaveform
        }
    }

    public init(audio: [String: Double]? = nil, defaultOffset: Double = 0, analysis: [String: AnalysisFile] = [:],
                attachesAnalysis: Bool = true, artwork: [String: DeckArtwork] = [:]) {
        self.audio = audio
        self.defaultOffset = defaultOffset
        self.analysis = analysis
        self.attachesAnalysis = attachesAnalysis
        self.artwork = artwork
    }

    /// 이 값을 내는 읽기. 초안은 초안 저장소(`drafts`)에서 읽는다
    public func reader(drafts: DraftStore) -> TrackAssetReader {
        let assets = self
        @Sendable func file(_ path: String?) -> AnalysisFile? { path.flatMap { $0.isEmpty ? nil : assets.analysis[$0] } }
        return TrackAssetReader(
            audioFileExists: { url in assets.audio.map { $0[url.path] != nil } ?? true },
            timelineOffset: { url in assets.audio?[url.path] ?? assets.defaultOffset },
            gainDraft: { drafts.currentGain($0) },
            cueDraft: { drafts.currentCue($0) },
            newCueID: drafts.newCueID,
            gridDraft: { drafts.currentGrid($0) },
            rekordboxGrid: { path, _ in file(path)?.grid ?? .missing },
            analysisState: { path, _ in
                guard let path, !path.isEmpty else { return .notAnalyzed(attachesAnalysis: assets.attachesAnalysis) }
                return file(path)?.hasWaveform == true ? .ready : .waveformMissing
            },
            colorWaveform: { _, _, _ in nil },
            artwork: { path, _, _ in path.flatMap { assets.artwork[$0] } },
            embeddedArtwork: { _ in nil })
    }
}
