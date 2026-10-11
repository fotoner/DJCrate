import Foundation

/// 덱 게인(볼륨 페이더 앞). rekordbox 오토게인·DJCrate 측정·곡 초안·트림을 합친다.
public struct GainPolicy: Sendable, Equatable {
    /// 오토게인 켜기
    public var enabled = true
    /// rekordbox 오토게인을 그대로 쓴다(없으면 DJCrate 측정)
    public var useRekordbox = true
    /// 수동 트림(dB)
    public var trim = 0.0

    public init() {}

    public static let range: ClosedRange<Double> = -24...24
    /// rekordbox 값과 DJCrate 계산이 이만큼 넘게 다르면 이상한 값으로 본다(dB)
    public static let suspiciousMismatch = 1.5

    /// 쓰는 오토게인: 곡 초안 > rekordbox > DJCrate 측정
    public func autoGainDB(rekordbox: Double?, measured: Double?, draft: Double?) -> Double {
        guard enabled else { return 0 }
        if let draft { return draft }
        if useRekordbox, let rekordbox { return rekordbox }
        return measured ?? 0
    }

    /// 실제로 걸리는 게인(dB, 오토 + 트림, ±24dB)
    public func applied(autoGainDB: Double) -> Double {
        min(max(autoGainDB + trim, Self.range.lowerBound), Self.range.upperBound)
    }

    /// rekordbox 오토게인과 같은 −10 LUFS 기준으로 계산한 값의 차이(dB)
    public static func mismatch(rekordbox: Double?, integratedLoudness: Double?) -> Double? {
        guard let rekordbox, let integratedLoudness else { return nil }
        return rekordbox - (RekordboxAutoGain.targetLoudness - integratedLoudness)
    }

    public static func isSuspicious(mismatch: Double?) -> Bool { abs(mismatch ?? 0) > suspiciousMismatch }

    /// 곡 오토게인 초안: 범위로 자르고, rekordbox 값과 사실상 같으면(0.05dB 안) 초안을 두지 않는다.
    public static func draft(for value: Double, rekordbox: Double?) -> Double? {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        if let rekordbox, abs(clamped - rekordbox) < 0.05 { return nil }
        return clamped
    }
}
