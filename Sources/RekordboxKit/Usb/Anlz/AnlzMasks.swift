import Foundation

/// USB 분석 파일에서만 가려 쓰는 태그의 XOR 마스크. 로컬 share의 평문 태그를 USB로 옮길 때 씌운다(새로 만들지 않는다).
public enum AnlzMasks {
    /// PSSI(프레이즈) 마스크. 바이트 18부터 `b[i] ^= (마스크[(i − 18) % 19] + 항목 수) & 0xFF`.
    /// pyrekordbox(MIT)의 XOR 규칙(제3자 고지 참조). rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)로 다시 확인했다.
    public static let pssiMask: [UInt8] = [0xCB, 0xE1, 0xEE, 0xFA, 0xE5, 0xEE, 0xAD, 0xEE, 0xE9, 0xD2,
                                           0xE9, 0xEB, 0xE1, 0xE9, 0xF3, 0xE8, 0xE9, 0xF4, 0xE1]

    /// PVDI(보컬) 키. 바이트 24부터 `b[i] ^= 키[(i − 24) % 19]`(태그 길이와 관계없이 같다).
    /// 골든 USB와 로컬의 같은 곡 PVDI를 XOR해 얻은 값이다. rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    public static let pvdiKey: [UInt8] = [0x1E, 0xDD, 0x1E, 0x19, 0x02, 0x19, 0x1B, 0x11, 0x19, 0x23,
                                          0x18, 0x19, 0x24, 0x11, 0xFB, 0x11, 0x1E, 0x2A, 0x15]

    /// PSSI 머리에서 마스크가 시작하는 자리(항목 수 u16 @0x10, mood u16 @0x12)
    static let pssiMaskStart = 18
    /// PVDI 머리 0x0C: 로컬 0x00, USB 0x80. rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    static let pvdiFlagOffset = 12
    static let pvdiMaskedFlag: UInt8 = 0x80
    static let pvdiBodyStart = 24
    /// PVDI 머리 0x0C–0x13(`00 00 04 00` · `56 22 00 01`). 로컬·골든의 PVDI 모두 이 값이었다.
    /// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    static let pvdiHeaderConstants: [UInt8] = [0x00, 0x00, 0x04, 0x00, 0x56, 0x22, 0x00, 0x01]

    /// 로컬에 PVDI가 없는 곡의 .2EX 끝에 붙이는 빈 PVDI(본문 없음, 플래그 0)
    public static let emptyPVDI = Data(Array("PVDI".utf8) + RekordboxWaveforms.be32(0x18) + RekordboxWaveforms.be32(0x18)
                                       + pvdiHeaderConstants + RekordboxWaveforms.be32(0))

    /// mood(u16 @0x12). 평문이면 1…3이다. 태그가 짧으면 nil
    public static func pssiMood(_ tag: Data) -> UInt16? {
        let b = [UInt8](tag)
        guard b.count >= 0x14 else { return nil }
        return UInt16(b[0x12]) << 8 | UInt16(b[0x13])
    }

    public static func maskPSSI(_ tag: Data) -> Data { xorPSSI(tag) }

    /// 마스크와 같은 XOR(대칭)
    public static func unmaskPSSI(_ tag: Data) -> Data { xorPSSI(tag) }

    static func xorPSSI(_ tag: Data) -> Data {
        var b = [UInt8](tag)
        guard b.count > pssiMaskStart else { return tag }
        // 항목 수는 마스크 밖(0x10)에 있어 씌우기 전후가 같다.
        let count = b[0x11]
        for i in pssiMaskStart..<b.count { b[i] ^= pssiMask[(i - pssiMaskStart) % pssiMask.count] &+ count }
        return Data(b)
    }

    /// 평문(플래그 0x00)만 마스크한다. 이미 마스크된 것(0x80)과 모르는 모양은 그대로 돌려준다.
    public static func maskPVDI(_ tag: Data) -> Data {
        var b = [UInt8](tag)
        guard b.count >= pvdiBodyStart, b[pvdiFlagOffset] == 0 else { return tag }
        b[pvdiFlagOffset] = pvdiMaskedFlag
        xorPVDIBody(&b)
        return Data(b)
    }

    public static func unmaskPVDI(_ tag: Data) -> Data {
        var b = [UInt8](tag)
        guard b.count >= pvdiBodyStart, b[pvdiFlagOffset] == pvdiMaskedFlag else { return tag }
        b[pvdiFlagOffset] = 0
        xorPVDIBody(&b)
        return Data(b)
    }

    static func xorPVDIBody(_ b: inout [UInt8]) {
        for i in pvdiBodyStart..<b.count { b[i] ^= pvdiKey[(i - pvdiBodyStart) % pvdiKey.count] }
    }

    /// PVDI 머리 0x0C의 플래그가 평문(0x00)인지
    static func isPlainPVDI(_ tag: Data) -> Bool {
        tag.count >= pvdiBodyStart && tag[tag.startIndex + pvdiFlagOffset] == 0
    }

    /// PVDI 머리 0x0C의 플래그가 USB 마스크(0x80)인지. 평문도 이것도 아니면 모르는 모양이다.
    static func isMaskedPVDI(_ tag: Data) -> Bool {
        tag.count >= pvdiBodyStart && tag[tag.startIndex + pvdiFlagOffset] == pvdiMaskedFlag
    }
}
