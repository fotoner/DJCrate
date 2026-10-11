import Foundation

public enum WaveformColorMode: String, CaseIterable, Codable, Sendable {
    case blue, rgb, threeBand

    public var title: String {
        switch self {
        case .blue: String(ui: "블루")
        case .rgb: "RGB"
        case .threeBand: String(ui: "3밴드")
        }
    }
}

public struct WaveformRGB: Equatable, Codable, Sendable {
    public var red, green, blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
}

/// 화면·파일 형식과 독립적인 파형 한 칸(모든 값은 0~1).
public struct WaveformColumn: Equatable, Codable, Sendable {
    public var height, low, mid, high, whiteness: Double
    public var rgb: WaveformRGB

    /// 분석 파일이 없을 때: 전체 높이는 밴드 최대, 흰 정도는 고음 비율, RGB는 밴드 비율이다.
    public init(low: Double, mid: Double, high: Double) {
        self.low = low; self.mid = mid; self.high = high
        height = max(low, mid, high)
        let sum = low + mid + high
        whiteness = sum > 0 ? high / sum : 0
        rgb = WaveformRGB(red: height > 0 ? low / height : 0,
                          green: height > 0 ? mid / height : 0,
                          blue: height > 0 ? high / height : 0)
    }

    /// 짧은 피크·마지막 칸을 남기고, RGB는 최고 피크의 색을 유지한다(서로 다른 색을 섞지 않는다).
    public static func downsample(_ columns: [Self], to points: Int) -> [Self] {
        guard points > 0 else { return [] }
        guard columns.count > points else { return columns }
        return (0..<points).map { index in
            let range = index * columns.count / points..<(index + 1) * columns.count / points
            var peak = columns[range.lowerBound]
            var low = peak.low, mid = peak.mid, high = peak.high
            for column in columns[range] {
                if column.height > peak.height { peak = column }
                low = max(low, column.low); mid = max(mid, column.mid); high = max(high, column.high)
            }
            peak.low = low; peak.mid = mid; peak.high = high
            return peak
        }
    }
}
