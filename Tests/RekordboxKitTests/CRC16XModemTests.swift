import Foundation
import RekordboxKit
import Testing

@Suite("CRC-16/XMODEM")
struct CRC16XModemTests {
    @Test("표준 검사 값: \"123456789\" → 0x31C3")
    func crc16XmodemCheckValue() {
        #expect(CRC16XModem.checksum(Array("123456789".utf8)) == 0x31C3)
    }

    @Test("빈 입력은 초깃값 0")
    func emptyIsZero() {
        #expect(CRC16XModem.checksum([UInt8]()) == 0)
    }

    @Test("Data 조각도 시작 위치와 상관없이 같은 값")
    func dataSliceMatchesArray() {
        let data = Data("xx123456789".utf8)
        #expect(CRC16XModem.checksum(data.dropFirst(2)) == 0x31C3)
    }

    @Test("바이트 하나만 바뀌어도 값이 바뀐다")
    func singleByteChangesValue() {
        var bytes = Array("123456789".utf8)
        bytes[4] ^= 0x01
        #expect(CRC16XModem.checksum(bytes) != 0x31C3)
    }
}
