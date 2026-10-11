import Foundation

/// rekordbox 오토게인(`djmdMixerParam`). rekordbox는 곡을 약 −10 LUFS에 맞추는 선형 게인을 적는다
/// (라이브러리 30곡: 게인dB + DJCrate 측정 LUFS = −9.97 ± 0.25).
public struct RekordboxAutoGain: Sendable, Hashable {
    /// 선형 게인(1 = 0dB)
    public var gain: Double
    /// 샘플 피크(선형, 1 = 0dBFS)
    public var peak: Double

    public init(gain: Double, peak: Double) { self.gain = gain; self.peak = peak }

    public var gainDB: Double { 20 * log10(max(gain, 1e-9)) }

    /// 16비트 두 칸 → 32비트 실수
    public static func float(high: Int, low: Int) -> Float {
        Float(bitPattern: UInt32(truncatingIfNeeded: high & 0xFFFF) << 16 | UInt32(truncatingIfNeeded: low & 0xFFFF))
    }

    /// rekordbox가 맞추는 음량(LUFS)
    public static let targetLoudness = -10.0
}

public extension RekordboxAutoGain {
    /// 32비트 실수 → 16비트 두 칸(상위·하위)
    static func halves(_ value: Float) -> (high: Int, low: Int) {
        let bits = value.bitPattern
        return (Int(bits >> 16), Int(bits & 0xFFFF))
    }
}
