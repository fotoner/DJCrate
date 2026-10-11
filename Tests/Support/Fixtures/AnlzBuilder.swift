import Foundation
import RekordboxKit

/// 합성 rekordbox 분석 파일(ANLZ). PMAI 머리 + 태그들. 그리드 밖 태그는 바이트 보존 검사용으로 채워 둔다.
public enum AnlzBuilder {
    /// PWV3·PWV4·PWV5 합성 칸. 잘못된 길이 시험에서도 머리만 따로 바꿀 수 있다.
    public static func waveform(_ tag: String, entryBytes: Int, samples: [UInt8]) -> Data {
        var out = Data(tag.utf8)
        out.append(be(24)); out.append(be(UInt32(24 + samples.count)))
        out.append(be(UInt32(entryBytes))); out.append(be(UInt32(samples.count / entryBytes)))
        out.append(be(0)); out.append(contentsOf: samples)
        return out
    }

    /// PWAV: 상위 3비트는 흰 정도, 하위 5비트는 높이.
    public static func pwav(_ samples: [UInt8]) -> Data {
        var out = Data("PWAV".utf8)
        out.append(be(20)); out.append(be(UInt32(20 + samples.count)))
        out.append(be(UInt32(samples.count))); out.append(be(0x0001_0000))
        out.append(contentsOf: samples)
        return out
    }

    /// `.DAT`: PPTH(경로) · PVBR(가짜 400칸) · PQTZ(그리드) · PWAV(가짜 미리보기)
    public static func dat(beats: [BeatGridTags.Beat], path: String = "/Music/시험.mp3") -> Data {
        file([ppth(path), opaque("PVBR", bytes: 1600), BeatGridTags.pqtz(beats), opaque("PWAV", bytes: 400)])
    }

    /// `.EXT`: PPTH · PWV3(가짜 상세 파형) · PQT2(박마다 소수) · PWV5(가짜)
    public static func ext(beats: [BeatGridTags.Beat], path: String = "/Music/시험.mp3") -> Data {
        file([ppth(path), opaque("PWV3", bytes: 3000), BeatGridTags.pqt2(beats, unknown: 0x1234), opaque("PWV5", bytes: 600)])
    }

    /// 일정한 BPM의 박(정밀 시각 ms). 박 번호는 1부터.
    public static func beats(bpm: Double, first: Double, count: Int, firstNumber: Int = 1) -> [BeatGridTags.Beat] {
        (0..<count).map { k in
            BeatGridTags.Beat(number: (firstNumber - 1 + k) % 4 + 1, bpm100: Int((bpm * 100).rounded()),
                              time: first + Double(k) * 60_000 / bpm)
        }
    }

    public static func file(_ tags: [Data]) -> Data {
        var body = Data()
        for tag in tags { body.append(tag) }
        var out = Data("PMAI".utf8)
        out.append(be(28)); out.append(be(UInt32(28 + body.count)))
        out.append(Data(count: 16))
        out.append(body)
        return out
    }

    static func ppth(_ path: String) -> Data {
        var text = Data()
        for unit in (path + "\0").utf16 { text.append(contentsOf: [UInt8(unit >> 8), UInt8(unit & 0xFF)]) }
        var out = Data("PPTH".utf8)
        out.append(be(16)); out.append(be(UInt32(16 + text.count))); out.append(be(UInt32(text.count)))
        out.append(text)
        return out
    }

    /// 내용은 의미 없는 가짜 태그(바이트가 그대로 남는지 보려고 값을 채운다)
    static func opaque(_ fourcc: String, bytes: Int) -> Data {
        var out = Data(fourcc.utf8)
        out.append(be(12)); out.append(be(UInt32(12 + bytes)))
        out.append(Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }))
        return out
    }

    static func be(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}
