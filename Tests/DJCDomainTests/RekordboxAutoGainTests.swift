@testable import DJCDomain
import Foundation
import Testing

@Suite("rekordbox 오토게인")
struct RekordboxAutoGainTests {
    @Test func 두_칸을_32비트_실수로() {
        // 라이브러리 실제 값: 16185/15481 → 0.7236(−2.81dB), 16256/0 → 1.0
        let gain = RekordboxAutoGain.float(high: 16185, low: 15481)
        #expect(abs(gain - 0.7236) < 0.0001)
        #expect(RekordboxAutoGain.float(high: 16256, low: 0) == 1)
        #expect(abs(RekordboxAutoGain(gain: Double(gain), peak: 1).gainDB - -2.81) < 0.01)
    }
}
