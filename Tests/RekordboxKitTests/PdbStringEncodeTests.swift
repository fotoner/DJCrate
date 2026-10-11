import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

@Suite("Device Library 문자열 쓰기")
struct PdbStringEncodeTests {
    // rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    @Test func ascii126IsShortFF() throws {
        let value = String(repeating: "a", count: 126)
        let encoded = PdbStringEncoder.encoded(value)
        #expect(encoded.kind == .shortASCII)
        #expect(encoded.bytes.count == 127 && encoded.bytes.first == 0xFF)
        #expect(encoded.rules.isEmpty)
        #expect(try PdbStringDecoder.decode(encoded.bytes, at: 0).value == value)
    }

    /// rekordbox 7.2.x 경계 실험(2026-10-08): 127자 순수 ASCII는 긴 ASCII(0x40).
    /// 트랙 행 문자열·아티스트·앨범 이름(본 칸)에는 규칙을 붙이지 않고, 그 밖의 칸에는 pdbLongAscii를 붙인다
    @Test func ascii127IsLongASCII() throws {
        let value = String(repeating: "a", count: 127)
        let encoded = PdbStringEncoder.encoded(value)
        #expect(encoded.kind == .longASCII)
        #expect(encoded.rules == [.pdbLongAscii])
        #expect(Array(encoded.bytes.prefix(4)) == [0x40, UInt8(4 + 127), 0x00, 0x00])
        #expect(encoded.bytes.count == 4 + 127 && encoded.needsAlignment)
        let decoded = try PdbStringDecoder.decode(encoded.bytes, at: 0)
        #expect(decoded.value == value && decoded.kind == .longASCII)
        let observed = PdbStringEncoder.encoded(value, longASCIIObserved: true)
        #expect(observed.bytes == encoded.bytes && observed.kind == .longASCII && observed.rules.isEmpty)
        // 짧은 ASCII·UTF-16은 본 칸이든 아니든 같다
        #expect(PdbStringEncoder.encoded("abc", longASCIIObserved: true) == PdbStringEncoder.encoded("abc"))
    }

    @Test func emptyIs03() {
        let encoded = PdbStringEncoder.encoded("")
        #expect(encoded.bytes == Data([0x03]) && encoded.kind == .shortASCII && encoded.rules.isEmpty)
    }

    @Test func nonASCIIUtf16Len() throws {
        let korean = PdbStringEncoder.encoded("시험")
        #expect(korean.bytes == Data([0x90, 0x08, 0x00, 0x00, 0xDC, 0xC2, 0xD8, 0xD5]))
        #expect(korean.kind == .utf16LE && korean.rules.isEmpty)
        // 길이는 UTF-16 단위로 센다(대리 쌍은 둘)
        let pair = PdbStringEncoder.encoded("a\u{1F3B5}")
        #expect(pair.bytes.count == 4 + 2 * 3 && pair.bytes[1] == 10)
        #expect(try PdbStringDecoder.decode(pair.bytes, at: 0).value == "a\u{1F3B5}")
        // ASCII가 아닌 글자가 있으면 127자를 넘어도 확인한 모양이다
        let long = PdbStringEncoder.encoded(String(repeating: "a", count: 200) + "é")
        #expect(long.kind == .utf16LE && long.rules.isEmpty)
    }

    @Test func isrcSpecial() throws {
        let encoded = PdbStringEncoder.encodedISRC("ZZ0000000001")
        #expect(encoded.kind == .isrc && encoded.rules.isEmpty)
        #expect(Array(encoded.bytes.prefix(5)) == [0x90, UInt8(4 + 1 + 12 + 1), 0x00, 0x00, 0x03])
        #expect(encoded.bytes.last == 0x00 && encoded.bytes.count == 18)
        let decoded = try PdbStringDecoder.decode(encoded.bytes, at: 0, isrcAllowed: true)
        #expect(decoded.value == "ZZ0000000001" && decoded.kind == .isrc)
    }

    @Test func isrcEmptyShort03() {
        let encoded = PdbStringEncoder.encodedISRC("")
        #expect(encoded.bytes == Data([0x03]) && encoded.kind == .shortASCII)
    }

    @Test func columnsWrapped() throws {
        let encoded = PdbStringEncoder.encodedMenuName("MENU")
        #expect(encoded.kind == .utf16LE && encoded.rules.isEmpty)
        #expect(encoded.bytes == PdbStringEncoder.encodeUTF16("\u{FFFA}MENU\u{FFFB}"))
        #expect(try PdbStringDecoder.decode(encoded.bytes, at: 0).value == "\u{FFFA}MENU\u{FFFB}")
    }

    /// 앞 문자열 끝이 4의 배수가 아니면 UTF-16 문자열 앞을 0으로 채운다. 짧은 ASCII는 바로 뒤에 붙는다
    @Test func utf16AlignedWithinRow() throws {
        var track = UsbTrack(id: 1, lyricist: "시험", fileName: "a.mp3", fileType: 1)
        track.isrc = ""
        let row = try PdbRowEncoder.track(track).row.bytes
        func u16(_ at: Int) -> Int { Int(row[at]) | Int(row[at + 1]) << 8 }
        // 문자열 0(빈 ISRC)은 0x88의 03, 문자열 1(UTF-16)은 0x8C
        #expect(u16(0x5E) == 0x88 && row[0x88] == 0x03)
        #expect(u16(0x60) == 0x8C)
        #expect(Array(row[0x89..<0x8C]) == [0, 0, 0])
        #expect(row[0x8C] == 0x90)
        // 문자열 2(짧은 ASCII)는 UTF-16 바로 뒤
        #expect(u16(0x62) == 0x8C + 8)
    }

    /// 긴 ASCII도 4바이트 경계로 앞을 0으로 채운다.
    /// rekordbox 7.2.x 경계 실험(2026-10-08) 때 뜬 USB의 트랙 행 경로(문자열 20)에서 본 모양
    @Test func longASCIIAlignedWithinRow() throws {
        var track = UsbTrack(id: 1, fileName: "a.mp3", fileType: 1)
        track.isrc = ""
        track.path = "/Contents/" + String(repeating: "p", count: 120) + "/a.mp3"
        let (encoded, kinds) = try PdbRowEncoder.track(track)
        let row = encoded.bytes
        func u16(_ at: Int) -> Int { Int(row[at]) | Int(row[at + 1]) << 8 }
        let offset = u16(0x5E + 2 * 20)
        #expect(offset % 4 == 0 && row[offset] == 0x40 && kinds[20] == .longASCII)
        // 앞 문자열(19, 파일 이름) 끝에서 경계까지는 0
        let previousEnd = u16(0x5E + 2 * 19) + 1 + "a.mp3".utf8.count
        #expect(previousEnd <= offset && row[previousEnd..<offset].allSatisfy { $0 == 0 })
        #expect(try PdbStringDecoder.decode(row, at: offset).value == track.path)
        // 트랙 행 문자열은 본 칸이라 규칙이 없다
        #expect(encoded.rules.isEmpty)
    }

    /// 쓰기 판정은 계획기의 문자열 규칙과 같은 기준이다
    @Test func encoderAgreesWithTrackRules() {
        for length in 0...200 {
            let ascii = String(repeating: "x", count: length)
            let mixed = length == 0 ? "é" : "é" + String(repeating: "x", count: length - 1)
            for value in [ascii, mixed] {
                let flagged = PdbStringEncoder.encoded(value).rules.contains(.pdbLongAscii)
                #expect(flagged == !UsbTrackRules.pdbStringRules([value]).isEmpty, "길이 \(length)")
            }
        }
    }
}
