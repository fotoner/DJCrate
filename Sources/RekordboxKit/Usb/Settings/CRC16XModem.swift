import Foundation

/// CRC-16/XMODEM: 다항식 0x1021, 초깃값 0, 비트 반사·끝 XOR 없음. 기기 설정 파일(MYSETTING 등) 끝의 검사 값이다.
public enum CRC16XModem {
    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
