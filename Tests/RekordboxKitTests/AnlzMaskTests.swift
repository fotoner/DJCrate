import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

@Suite("ANLZ 마스크(PSSI·PVDI)")
struct AnlzMaskTests {
    @Test("PSSI 마스크는 되돌리면 원래 바이트")
    func pssiMaskRoundTrip() {
        for entries in [1, 3, 20] {
            let plain = AnlzBuilder.pssi(mood: 2, entries: entries)
            let masked = AnlzMasks.maskPSSI(plain)
            #expect(masked != plain)
            #expect(masked.count == plain.count)
            #expect(AnlzMasks.unmaskPSSI(masked) == plain)
        }
    }

    @Test("PSSI 바이트 0–17은 그대로, 18부터는 (마스크 + 항목 수) XOR")
    func pssiMaskBytes0to17Unchanged() {
        let plain = [UInt8](AnlzBuilder.pssi(mood: 3, entries: 5))
        let masked = [UInt8](AnlzMasks.maskPSSI(Data(plain)))
        #expect(Array(masked[0..<18]) == Array(plain[0..<18]))
        #expect(AnlzMasks.pssiMask.count == 19)
        for i in 18..<plain.count {
            let key = AnlzMasks.pssiMask[(i - 18) % 19] &+ 5
            #expect(masked[i] == plain[i] ^ key, "byte \(i)")
        }
    }

    @Test("mood(u16 @0x12)로 평문인지 가린다")
    func pssiMoodDetection() {
        for mood in 1...3 {
            #expect(AnlzMasks.pssiMood(AnlzBuilder.pssi(mood: mood, entries: 2)) == UInt16(mood))
        }
        let masked = AnlzMasks.maskPSSI(AnlzBuilder.pssi(mood: 2, entries: 2))
        let maskedMood = AnlzMasks.pssiMood(masked)
        #expect(maskedMood != nil && !(1...3).contains(maskedMood!))
        #expect(AnlzMasks.pssiMood(Data("PSSI".utf8)) == nil)
    }

    @Test("PVDI 마스크: 바이트 12를 0x80으로, 24부터 키 XOR")
    func pvdiMaskFlagAndXor() {
        let plain = [UInt8](AnlzBuilder.pvdi(bodyBytes: 50))
        let masked = [UInt8](AnlzMasks.maskPVDI(Data(plain)))
        #expect(plain[12] == 0x00 && masked[12] == 0x80)
        #expect(Array(masked[0..<12]) == Array(plain[0..<12]))
        #expect(Array(masked[13..<24]) == Array(plain[13..<24]))
        #expect(AnlzMasks.pvdiKey.count == 19)
        for i in 24..<plain.count {
            #expect(masked[i] == plain[i] ^ AnlzMasks.pvdiKey[(i - 24) % 19], "byte \(i)")
        }
    }

    @Test("PVDI 마스크는 되돌리면 원래 바이트, 이미 마스크된 것은 그대로")
    func pvdiRoundTrip() {
        for body in [0, 1, 19, 200] {
            let plain = AnlzBuilder.pvdi(bodyBytes: body)
            let masked = AnlzMasks.maskPVDI(plain)
            #expect(AnlzMasks.unmaskPVDI(masked) == plain)
            #expect(AnlzMasks.maskPVDI(masked) == masked)
            #expect(AnlzMasks.unmaskPVDI(plain) == plain)
        }
    }

    @Test("빈 PVDI 24바이트")
    func emptyPVDIBytes() {
        let expected: [UInt8] = Array("PVDI".utf8) + [0, 0, 0, 0x18, 0, 0, 0, 0x18, 0, 0, 0x04, 0, 0x56, 0x22, 0, 0x01, 0, 0, 0, 0]
        #expect([UInt8](AnlzMasks.emptyPVDI) == expected)
    }
}
