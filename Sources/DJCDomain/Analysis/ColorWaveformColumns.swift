import Foundation

/// rekordbox 분석 파일(.EXT)에서 읽은 색 파형 칸(rekordbox 시간축, 초당 `rate`칸). 덱이 비트맵으로 그린다.
public struct ColorWaveformColumns: Sendable {
    public var columns: [WaveformColumn]
    public var rate: Double

    public init(columns: [WaveformColumn], rate: Double) {
        self.columns = columns
        self.rate = rate
    }
}
