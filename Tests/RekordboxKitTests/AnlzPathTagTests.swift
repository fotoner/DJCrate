import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

@Suite("ANLZ 경로 태그(PPTH)")
struct AnlzPathTagTests {
    func be32(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(value).bigEndian) { Array($0) } }

    /// 식으로 계산한 PPTH: 머리 16바이트 · UTF-16BE 경로 · 끝 NUL 2바이트
    func expected(_ path: String) -> Data {
        var text: [UInt8] = path.utf16.flatMap { unit -> [UInt8] in [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        text += [0, 0]
        var out: [UInt8] = Array("PPTH".utf8)
        out += be32(0x10)
        out += be32(0x10 + text.count)
        out += be32(text.count)
        return Data(out + text)
    }

    @Test("USB 경로는 UTF-16BE와 끝 NUL로 적고 그대로 읽힌다")
    func roundTripContentsPathUTF16BENul() throws {
        let path = "/Contents/시험 아티스트/시험 앨범/시험 곡.mp3"
        let tag = AnlzPathTag.encode(path)
        #expect(tag == expected(path))
        let bytes = [UInt8](tag)
        #expect(Array(bytes.suffix(2)) == [0, 0])
        #expect(Array(bytes[16..<20]) == [0x00, 0x2F, 0x00, 0x43])   // "/C"
        #expect(try AnlzPathTag.decode(tag) == path)
    }

    @Test("보충 평면 글자(대리 쌍)도 그대로 읽힌다")
    func nonBMPPathRoundTrip() throws {
        let path = "/Contents/🎵 시험/UnknownAlbum/곡 𝄞.flac"
        let tag = AnlzPathTag.encode(path)
        #expect(tag == expected(path))
        #expect(try AnlzPathTag.decode(tag) == path)
    }

    @Test("로컬 PPTH 바이트는 그대로")
    func localPPTHBytesUnchanged() {
        #expect(TrackAnalysisFiles.ppth(fileName: "시험.mp3") == expected("?/시험.mp3"))
        #expect(TrackAnalysisFiles.ppth(path: "/Contents/a/b/시험.mp3") == expected("/Contents/a/b/시험.mp3"))
    }

    @Test("모양이 다른 PPTH는 거부한다")
    func decodeRejectsMalformed() {
        let good = [UInt8](AnlzPathTag.encode("/Contents/a.mp3"))
        var wrongName = good; wrongName[0] = 0x58
        var wrongLength = good; wrongLength[11] &+= 2
        var wrongPathLength = good; wrongPathLength[15] &+= 2
        let oddPath: [UInt8] = Array("PPTH".utf8) + be32(0x10) + be32(0x10 + 3) + be32(3) + [0, 0x41, 0]
        var noNul = good; noNul[noNul.count - 1] = 0x41
        for (name, bytes) in [("이름", wrongName), ("태그 길이", wrongLength), ("경로 길이", wrongPathLength), ("홀수 길이", oddPath),
                              ("끝 NUL 없음", noNul), ("잘림", Array(good.prefix(10)))] {
            #expect(throws: UsbError.self, "\(name)") { try AnlzPathTag.decode(Data(bytes)) }
        }
    }
}
