import DJCDomain
import Foundation
import RekordboxKit
import Testing

@Suite("Device Library 문자열")
struct PdbStringTests {
    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func shortASCIIHeaderByte() {
        #expect(PdbStringEncoder.shortASCIIHeader(length: 0) == 0x03)
        #expect(PdbStringEncoder.shortASCIIHeader(length: 1) == 0x05)
        #expect(PdbStringEncoder.shortASCIIHeader(length: 126) == 0xFF)
        #expect(PdbStringEncoder.encode("") == Data([0x03]))
        #expect(PdbStringEncoder.encode("AB") == Data([0x07, 0x41, 0x42]))
    }

    @Test func decodeShortASCII() throws {
        let row = Data([0xAA, 0x0B, 0x74, 0x65, 0x73, 0x74, 0x03])
        let first = try PdbStringDecoder.decode(row, at: 1)
        #expect(first.value == "test" && first.kind == .shortASCII && first.byteLength == 5)
        let empty = try PdbStringDecoder.decode(row, at: 6)
        #expect(empty.value == "" && empty.kind == .shortASCII && empty.byteLength == 1)
        // 126자까지
        let long = String(repeating: "x", count: 126)
        let encoded = PdbStringEncoder.encode(long)
        #expect(encoded.count == 127)
        #expect(try PdbStringDecoder.decode(encoded, at: 0).value == long)
    }

    @Test func decodeUTF16() throws {
        // 90, u16 길이(머리 4 포함), 00, UTF-16LE
        let row = Data([0, 0, 0, 0, 0x90, 0x08, 0x00, 0x00, 0xDC, 0xC2, 0xD8, 0xD5])
        let decoded = try PdbStringDecoder.decode(row, at: 4)
        #expect(decoded.value == "시험" && decoded.kind == .utf16LE && decoded.byteLength == 8)
        // ASCII가 아닌 글자가 있으면 UTF-16LE로 쓴다
        #expect(PdbStringEncoder.encode("시험") == Data([0x90, 0x08, 0x00, 0x00, 0xDC, 0xC2, 0xD8, 0xD5]))
        // 126자를 넘는 순수 ASCII는 긴 ASCII(0x40)로 쓴다. UTF-16LE는 부르는 쪽이 명시할 때만(메뉴 이름 등)
        let long = String(repeating: "y", count: 127)
        #expect(PdbStringEncoder.encode(long).first == 0x40)
        let encoded = PdbStringEncoder.encodeUTF16(long)
        #expect(encoded.first == 0x90 && encoded.count == 4 + 254)
        #expect(try PdbStringDecoder.decode(encoded, at: 0).value == long)
        // 짝이 맞지 않는 대리 쌍·홀수 길이는 오류
        #expect(throws: UsbError.self) { try PdbStringDecoder.decode(Data([0x90, 0x06, 0x00, 0x00, 0x00, 0xD8]), at: 0) }
        #expect(throws: UsbError.self) { try PdbStringDecoder.decode(Data([0x90, 0x07, 0x00, 0x00, 0x41, 0x00, 0x42]), at: 0) }
    }

    @Test func decodeLongASCII0x40() throws {
        let row = Data([0x40, 0x07, 0x00, 0x00, 0x61, 0x62, 0x63])
        let decoded = try PdbStringDecoder.decode(row, at: 0)
        #expect(decoded.value == "abc" && decoded.kind == .longASCII && decoded.byteLength == 7)
    }

    /// rekordbox 7.2.x 경계 실험(2026-10-08): 'A' × 127·236·244·250은 `40`, u16 길이 = 4 + n, `00`, ASCII n바이트(끝 표시 없음)
    @Test func encodeLongASCII0x40() throws {
        for count in [127, 236, 244, 250] {
            let value = String(repeating: "A", count: count)
            let encoded = PdbStringEncoder.encode(value)
            #expect(Array(encoded.prefix(4)) == [0x40, UInt8((4 + count) & 0xFF), UInt8((4 + count) >> 8), 0x00])
            #expect(encoded.count == 4 + count && encoded.dropFirst(4).allSatisfy { $0 == 0x41 })
            let decoded = try PdbStringDecoder.decode(encoded, at: 0)
            #expect(decoded.value == value && decoded.kind == .longASCII && decoded.byteLength == 4 + count)
        }
    }

    @Test func decodeISRCSpecial() throws {
        // 90, u16 길이 = 4 + 1 + k + 1, 00, 03, ASCII k, 00
        let row = Data([0x90, 0x09, 0x00, 0x00, 0x03, 0x41, 0x42, 0x43, 0x00])
        let decoded = try PdbStringDecoder.decode(row, at: 0, isrcAllowed: true)
        #expect(decoded.value == "ABC" && decoded.kind == .isrc && decoded.byteLength == 9)
        #expect(PdbStringEncoder.encodeISRC("ABC") == row)
        // 트랙 문자열 0이 아닌 곳에서는 같은 바이트도 UTF-16으로 읽는다(짝수 길이면)
        let utf16 = Data([0x90, 0x08, 0x00, 0x00, 0x03, 0x01, 0x41, 0x00])
        #expect(try PdbStringDecoder.decode(utf16, at: 0, isrcAllowed: false).kind == .utf16LE)
        // 기본은 특수형을 보지 않는다: 첫 글자 아래 바이트가 3이고 끝 바이트가 0인 UTF-16("七A")을 ISRC로 잘못 읽지 않게
        let seven = try PdbStringDecoder.decode(Data([0x90, 0x08, 0x00, 0x00, 0x03, 0x4E, 0x41, 0x00]), at: 0)
        #expect(seven.value == "七A" && seven.kind == .utf16LE)
        // 끝 00이 없으면 오류
        #expect(throws: UsbError.self) {
            try PdbStringDecoder.decode(Data([0x90, 0x09, 0x00, 0x00, 0x03, 0x41, 0x42, 0x43, 0x44]), at: 0, isrcAllowed: true)
        }
    }

    @Test func unknownFirstByteIsError() {
        for first: UInt8 in [0x00, 0x02, 0x80, 0x92] {
            #expect(throws: UsbError.self) { try PdbStringDecoder.decode(Data([first, 0x41, 0x42, 0x43]), at: 0) }
        }
        // 행 밖으로 나가는 길이
        #expect(throws: UsbError.self) { try PdbStringDecoder.decode(Data([0x09, 0x41]), at: 0) }
        #expect(throws: UsbError.self) { try PdbStringDecoder.decode(Data([0x90, 0x10, 0x00, 0x00, 0x41, 0x00]), at: 0) }
        #expect(throws: UsbError.self) { try PdbStringDecoder.decode(Data([0x03]), at: 1) }
        // 짧은 ASCII에 ASCII가 아닌 바이트
        #expect(throws: UsbError.self) { try PdbStringDecoder.decode(Data([0x05, 0xC3]), at: 0) }
    }
}
