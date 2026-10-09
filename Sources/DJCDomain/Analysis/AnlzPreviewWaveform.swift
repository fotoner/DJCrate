import Foundation

/// 목록용 PWAV·PWV4 미리 보기. 재생 시각과 무관한 줄인 원자료다(값, #167). 분석 파일에서 읽는 일은 RekordboxKit(`init(file:)`·`readAnalysis`)에 있다.
public struct AnlzPreviewWaveform: Sendable, Equatable, Codable {
    public let heights: [UInt8]
    public let blueColumns: [WaveformColumn]
    public let colorColumns: [WaveformColumn]?

    /// 분석 파일에서 읽은 높이(PWAV 하위 5비트)를 그대로 둘 때
    public init(heights: [UInt8], blue: [WaveformColumn], color: [WaveformColumn]?) {
        self.heights = heights
        blueColumns = blue
        colorColumns = color
    }

    public init(blue: [WaveformColumn], color: [WaveformColumn]?) {
        self.init(heights: blue.map { UInt8(($0.height * 31).rounded()) }, blue: blue, color: color)
    }

    /// 짧은 피크와 곡 끝이 사라지지 않도록 겹치지 않는 구간의 최대값을 남긴다.
    public func downsampled(to points: Int) -> Self {
        Self(blue: WaveformColumn.downsample(blueColumns, to: points),
             color: colorColumns.map { WaveformColumn.downsample($0, to: points) })
    }
}
