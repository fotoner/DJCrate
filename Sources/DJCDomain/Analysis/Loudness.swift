/// 곡 음량 값: ITU-R BS.1770-4 통합 음량(LUFS)과 샘플 피크, 원본 클리핑 흔적. 오토게인과 "너무 센 곡" 경고에 쓴다.
/// 재는 일(K-가중 필터·게이트)은 DJCAnalysis `Loudness.measure`에 있다(#167). 음량 캐시(`loudness.json`)의 칸 이름을 바꾸지 않는다.
public struct Loudness: Codable, Hashable, Sendable {
    /// 통합 음량(LUFS). 무음이면 nil.
    public var integrated: Double?
    /// 샘플 피크(dBFS). 무음이면 −∞ 대신 −120.
    public var peak: Double
    /// 풀스케일(|x| ≥ 0.9999)에 3샘플 이상 붙어 있는 곳의 수(마스터링 단계 클리핑 흔적)
    public var clippedRuns: Int

    public init(integrated: Double?, peak: Double, clippedRuns: Int) {
        self.integrated = integrated
        self.peak = peak
        self.clippedRuns = clippedRuns
    }

    /// 목표 음량에 맞추는 게인(dB). 피크 보호를 켜면 올릴 때만 피크가 `ceiling` dBFS를 넘지 않을 만큼으로 줄인다
    /// (원본 피크가 이미 0dBFS를 넘는 곡을 조용한데도 깎지는 않는다).
    public func autoGain(target: Double, peakProtection: Bool, ceiling: Double = -0.3) -> Double {
        guard let integrated else { return 0 }
        var gain = target - integrated
        if peakProtection, gain > 0 { gain = min(gain, max(0, ceiling - peak)) }
        return min(max(gain, -24), 24)
    }

    /// 매우 큰 마스터 기준(LUFS). 애니송 라이브러리 표본 40곡의 중앙값이 −7.4, 상위 약 18%가 −6을 넘었다(2026-09-26).
    public static let hotLoudness = -6.0
    /// 심한 클리핑 기준(풀스케일 구간 수). 표본 대부분은 0, 심한 곡은 수천 곳이었다.
    public static let heavyClipping = 1000

    public var isLoud: Bool { (integrated ?? -100) > Self.hotLoudness }
    public var isHeavilyClipped: Bool { clippedRuns >= Self.heavyClipping }
    /// 곡 자체가 과하게 센가(매우 큰 마스터이거나 심한 클리핑)
    public var isHot: Bool { isLoud || isHeavilyClipped }
}
