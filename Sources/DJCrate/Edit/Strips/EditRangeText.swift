import DJCDomain
import Foundation

extension BarRange {
    /// 다듬는 동안 클립 가장자리 옆에 보이는 값: 「마디 3-6 · 4마디」. 곡 머리(0마디)가 들면 「마디 0-6 · 6마디 + 곡 머리」.
    var liveText: String {
        let bars = String(ui: "\(barCount)마디")
        return first == 0 ? String(ui: "마디 \(description) · \(bars) + 곡 머리") : String(ui: "마디 \(description) · \(bars)")
    }
}
