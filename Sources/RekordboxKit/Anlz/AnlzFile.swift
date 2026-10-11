import DJCDomain
import Foundation

/// rekordbox 분석 파일(ANLZ) 태그 단위 읽기·고쳐 쓰기. 바꾸지 않는 태그는 바이트 그대로 둔다.
///
/// 파일: `PMAI` 헤더(len_header, 전체 길이) 뒤에 태그가 이어진다. 태그는 `fourcc, len_header(u32), len_tag(u32)`로 시작한다.
public struct AnlzFile: Sendable {
    public var header: Data
    public var tags: [Tag]

    public struct Tag: Sendable, Hashable {
        public var fourcc: String
        /// 태그 전체(태그 헤더 포함)
        public var bytes: Data
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4] == [0x50, 0x4D, 0x41, 0x49] else { throw DJCError.invalidAnalysisFile(String(ui: "PMAI 아님")) }
        let headerLength = Int(Self.u32(bytes, 4))
        guard Int(Self.u32(bytes, 8)) == bytes.count, headerLength >= 12, headerLength <= bytes.count else {
            throw DJCError.invalidAnalysisFile(String(ui: "PMAI 길이가 맞지 않음"))
        }
        header = Data(bytes[0..<headerLength])
        tags = []
        var p = headerLength
        while p + 12 <= bytes.count {
            let length = Int(Self.u32(bytes, p + 8))
            guard length >= 12, p + length <= bytes.count else { throw DJCError.invalidAnalysisFile(String(ui: "태그 길이가 맞지 않음")) }
            tags.append(Tag(fourcc: String(decoding: bytes[p..<p + 4], as: UTF8.self), bytes: Data(bytes[p..<p + length])))
            p += length
        }
        guard p == bytes.count else { throw DJCError.invalidAnalysisFile(String(ui: "끝에 남는 바이트")) }
    }

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// 파일 바이트(PMAI 전체 길이를 다시 적는다)
    public func serialized() -> Data {
        var out = header
        for tag in tags { out.append(tag.bytes) }
        let total = UInt32(out.count).bigEndian
        withUnsafeBytes(of: total) { out.replaceSubrange(8..<12, with: $0) }
        return out
    }

    public func tag(_ fourcc: String) -> Tag? { tags.first { $0.fourcc == fourcc } }

    /// 같은 이름의 첫 태그를 바꾼다(없으면 false).
    @discardableResult
    public mutating func replace(_ fourcc: String, with bytes: Data) -> Bool {
        guard let i = tags.firstIndex(where: { $0.fourcc == fourcc }) else { return false }
        tags[i].bytes = bytes
        return true
    }

    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }
}

/// rekordbox 비트 그리드 태그.
///
/// - PQTZ(.DAT): 박마다 `박 번호(u16, 1~4) · BPM×100(u16) · 시각 ms(u32, 정수)`
/// - PQT2(.EXT): 머리에 첫 박·마지막 박(같은 8바이트 형식)·박 수·정체 모를 u32, 본문은 박마다 u16 =
///   그 박 시각의 ms 아래 소수 × 1024. 즉 정밀 시각 = PQTZ ms + 값/1024 ms. 본문이 비고 머리가 0인 PQT2도 rekordbox가 쓴다.
public enum BeatGridTags {
    public struct Beat: Hashable, Sendable {
        public var number: Int
        public var bpm100: Int
        /// 정밀 시각(ms)
        public var time: Double

        public init(number: Int, bpm100: Int, time: Double) {
            self.number = number
            self.bpm100 = bpm100
            self.time = time
        }

        var wholeMs: UInt32 { UInt32((max(0, time) + 1e-6).rounded(.down)) }
        var fraction1024: UInt16 { UInt16(min(1023, max(0, ((time - time.rounded(.down)) * 1024).rounded(.down)))) }
    }

    /// PQTZ 태그 바이트
    public static func pqtz(_ beats: [Beat]) -> Data {
        var out = Data()
        out.append(contentsOf: Array("PQTZ".utf8))
        out.appendBE(UInt32(24))
        out.appendBE(UInt32(24 + 8 * beats.count))
        out.appendBE(UInt32(0))
        out.appendBE(UInt32(0x0008_0000))
        out.appendBE(UInt32(beats.count))
        for beat in beats { out.appendEntry(beat) }
        return out
    }

    /// PQT2 태그 바이트. `unknown`은 머리의 정체 모를 u32(기존 값을 그대로 넘긴다).
    public static func pqt2(_ beats: [Beat], unknown: UInt32) -> Data {
        var out = Data()
        out.append(contentsOf: Array("PQT2".utf8))
        out.appendBE(UInt32(56))
        out.appendBE(UInt32(56 + (beats.isEmpty ? 0 : 2 * beats.count)))
        out.appendBE(UInt32(0))
        out.appendBE(UInt32(0x0100_0002))
        out.appendBE(UInt32(0))
        if let first = beats.first, let last = beats.last {
            out.appendEntry(first)
            out.appendEntry(last)
            out.appendBE(UInt32(beats.count))
            out.appendBE(unknown)
        } else {
            out.append(Data(count: 8 + 8 + 4 + 4))
        }
        out.append(Data(count: 8))
        for beat in beats { out.appendBE(beat.fraction1024) }
        return out
    }

    /// 두 태그에서 정밀 박을 읽는다(PQT2가 비었거나 없으면 ms 정수 그대로).
    public static func decode(pqtz: Data, pqt2: Data?) -> (beats: [Beat], unknown: UInt32?) {
        let z = [UInt8](pqtz)
        guard z.count >= 24 else { return ([], nil) }
        let headerLength = Int(AnlzFile.u32(z, 4))
        let count = Int(AnlzFile.u32(z, 20))
        var beats: [Beat] = []
        for i in 0..<count {
            let p = headerLength + 8 * i
            guard p + 8 <= z.count else { break }
            beats.append(Beat(number: Int(AnlzFile.u16(z, p)), bpm100: Int(AnlzFile.u16(z, p + 2)), time: Double(AnlzFile.u32(z, p + 4))))
        }
        guard let pqt2, pqt2.count >= 56 else { return (beats, nil) }
        let e = [UInt8](pqt2)
        let length = Int(AnlzFile.u32(e, 8))
        let bodyCount = (length - 56) / 2
        guard bodyCount == beats.count, bodyCount > 0 else { return (beats, bodyCount == 0 ? nil : AnlzFile.u32(e, 44)) }
        for i in 0..<bodyCount { beats[i].time += Double(AnlzFile.u16(e, 56 + 2 * i)) / 1024 }
        return (beats, AnlzFile.u32(e, 44))
    }
}

extension Data {
    mutating func appendBE(_ value: UInt32) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
    mutating func appendBE(_ value: UInt16) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
    mutating func appendEntry(_ beat: BeatGridTags.Beat) {
        appendBE(UInt16(beat.number))
        appendBE(UInt16(beat.bpm100))
        appendBE(beat.wholeMs)
    }
}
