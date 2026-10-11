import DJCApplication
import DJCDomain
import Foundation
import Testing

/// 분석 캐시(`AnalysisStore`): 곡 UUID·음원 둘을 열쇠로 두고 읽고, 재분석은 그 곡의 크로마·그리드 추정만 지운다(다른 곡·음량은 그대로).
/// `first`·`second`는 서로 다른 음원
@MainActor
public func analysisStoreContract(_ store: AnalysisStore, first: URL, second: URL) {
    let estimate = GridEstimate(segments: [GridSegment(start: 0.5, bpm: 128, firstBeatNumber: 1)], medianResidualMs: 4,
                                inlierRatio: 0.9, downbeatConfidence: 0.8)
    let chroma = KeyChroma(hop: 0.2, frames: [[Float](repeating: 0.25, count: 12), [Float](repeating: 0.5, count: 12)])
    #expect(store.chroma("a", first) == nil && store.gridEstimate("a", first) == nil && store.loudness(first) == nil)
    store.storeChroma(chroma, "a", first)
    store.storeGridEstimate(estimate, "a", first)
    store.storeChroma(chroma, "b", first)
    store.storeLoudness(Loudness(integrated: -8.5, peak: -0.2, clippedRuns: 3), first)
    #expect(store.chroma("a", first)?.frames == chroma.frames && store.chroma("a", first)?.hop == 0.2)
    #expect(store.gridEstimate("a", first) == estimate)
    #expect(store.loudness(first) == Loudness(integrated: -8.5, peak: -0.2, clippedRuns: 3))
    #expect(store.chroma("a", second) == nil && store.gridEstimate("a", second) == nil && store.loudness(second) == nil)
    store.removeAll("a")
    #expect(store.chroma("a", first) == nil && store.gridEstimate("a", first) == nil)
    #expect(store.chroma("b", first)?.frames == chroma.frames && store.loudness(first) != nil)
}

/// 덱 읽기에 줄 분석 파일 자리: 그리드·파형 파일이 다 있는 곡(`gridPath`, 박 시각 `beatTimes`초), `.DAT`만 있는 반쪽 곡(`halfPath`),
/// 그 파일들이 든 share 뿌리, 인코더 지연이 없는 음원(WAV)
public struct TrackAssetContractFiles: Sendable {
    public var share: URL
    public var gridPath: String
    public var halfPath: String
    public var beatTimes: [Double]
    public var audio: URL
    public var missingAudio: URL

    public init(share: URL, gridPath: String, halfPath: String, beatTimes: [Double], audio: URL, missingAudio: URL) {
        self.share = share
        self.gridPath = gridPath
        self.halfPath = halfPath
        self.beatTimes = beatTimes
        self.audio = audio
        self.missingAudio = missingAudio
    }
}

/// 덱 읽기(`TrackAssetReader`): 원본 그리드는 분석 파일에서 읽고 경로가 없거나 파일이 없으면 없음, 분석 파일 상태(분석 전·준비·파형 없음),
/// 음원 있음·인코더 지연(adv4 T7: 덱 시험이 늘 "지연 0·원본 그리드 없음" 곡만 봤다)
public func trackAssetReaderContract(_ reader: TrackAssetReader, _ files: TrackAssetContractFiles) {
    let share = files.share
    guard case let .grid(grid) = reader.rekordboxGrid(files.gridPath, share) else { Issue.record("그리드를 읽지 못함"); return }
    #expect(grid.beats.map(\.time) == files.beatTimes)
    #expect(reader.rekordboxGrid(nil, share) == .missing && reader.rekordboxGrid("", share) == .missing)
    #expect(reader.rekordboxGrid("/PIONEER/USBANLZ/none/ANLZ0000.DAT", share) == .missing)
    #expect(reader.analysisState(nil, share) == .notAnalyzed(attachesAnalysis: true))
    #expect(reader.analysisState(files.gridPath, share) == .ready)
    #expect(reader.analysisState(files.halfPath, share) == .waveformMissing)
    #expect(reader.analysisState("/PIONEER/USBANLZ/none/ANLZ0000.DAT", share) == .waveformMissing, "분석 경로는 있는데 파일이 없으면 파형 없음")
    #expect(reader.audioFileExists(files.audio) && reader.timelineOffset(files.audio) == 0)
    #expect(!reader.audioFileExists(files.missingAudio))
}
