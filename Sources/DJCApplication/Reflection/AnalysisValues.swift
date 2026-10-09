import DJCDomain
import Foundation

/// 분석을 붙일 곡의 음량 → 쓰기 관문에 넘길 값. 곡 넣기(앱·`djc track-add`)와 분석 붙이기가 같은 계산을 쓴다.
extension RekordboxTrackAnalysis {
    public init(segments: [GridSegment], loudness: Loudness?) {
        self.init(segments: segments, loudness: loudness?.integrated, peak: Self.peak(loudness))
    }

    /// 샘플 피크(dBFS) → 선형. 음량을 재지 못했으면 1(오토게인은 음량이 없으면 0dB)
    public static func peak(_ loudness: Loudness?) -> Double { loudness.map { pow(10, $0.peak / 20) } ?? 1 }
}

extension RekordboxAnalysisInput {
    public init(duration: Double, loudness: Loudness?, artwork: Data?) {
        self.init(duration: duration, loudness: loudness?.integrated, peak: RekordboxTrackAnalysis.peak(loudness), artwork: artwork)
    }
}
