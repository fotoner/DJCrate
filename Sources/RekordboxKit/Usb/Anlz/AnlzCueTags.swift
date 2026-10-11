import DJCDomain
import Foundation

/// USB 분석 파일의 큐 태그. 모든 칸은 빅엔디언. rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기).
/// - PCOB(.DAT·.EXT): 머리 24바이트 · PCPT 항목 56바이트씩
/// - PCO2(.EXT): 머리 20바이트 · PCP2 항목(0x58 + 주석 바이트)씩
/// 목록 종류(머리 0x0C)는 1 핫큐, 0 메모리 큐다.
public enum AnlzCueTags {
    public struct PCPTEntry: Sendable, Hashable {
        /// 메모리 0, 핫큐 1–8
        public var hotCue: UInt32
        public var status: UInt32
        /// 앞·뒤 항목 번호(없으면 0xFFFF)
        public var previous: UInt16
        public var next: UInt16
        /// 1 큐, 2 루프
        public var type: UInt8
        public var inMsec: UInt32
        /// 루프가 아니면 0xFFFFFFFF
        public var outMsec: UInt32
    }

    public struct PCP2Entry: Sendable, Hashable {
        public var hotCue: UInt32
        public var type: UInt8
        public var inMsec: UInt32
        public var outMsec: UInt32
        public var colorID: UInt8
        public var beatNumerator: UInt16
        public var beatDenominator: UInt16
        public var comment: String
        /// 주석 뒤 4바이트 색
        public var color: [UInt8]
        public var inFrame: UInt64
        public var outFrame: UInt64
        public var inOffset: UInt64
        public var outOffset: UInt64
        public var inBlock: UInt32
        public var outBlock: UInt32
    }

    /// 목록 종류(머리 0x0C)
    public static let hotList: UInt32 = 1
    public static let memoryList: UInt32 = 0

    static let pcptLength = 0x38
    static let pcp2FixedLength = 0x58
    /// 없는 항목 번호·루프 아닌 큐의 끝
    static let none16: UInt16 = 0xFFFF
    static let none32: UInt32 = 0xFFFF_FFFF
    /// PCPT 0x14, PCP2 0x12의 고정값. rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    static let pcptConstant: UInt32 = 0x0001_0000
    static let cueConstant: UInt16 = 0x03E8
    /// PCP2 주석 뒤 색 4바이트. rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    static let hotCueColor: [UInt8] = [0x00, 0x1A, 0xFF, 0x00]
    static let hotLoopColor: [UInt8] = [0x00, 0xFF, 0x8C, 0x00]
    static let memoryColor: [UInt8] = [0x00, 0x00, 0x00, 0x00]
    /// FLAC(djmdContent.FileType 5)만 탐색 칸을 채운다.
    static let flacFileType = 5

    // MARK: - 만들기

    /// PCOB 태그 전체. 머리 0x14는 핫이면 0xFFFFFFFF, 메모리면 n − 1(n = 0이면 0xFFFFFFFF).
    /// 메모리 항목은 앞뒤 번호로 사슬을 잇고, 핫 항목은 둘 다 0xFFFF다.
    public static func pcob(kind: UInt32, cues: [UsbCueInput]) -> Data {
        let n = cues.count
        let isMemory = kind == memoryList
        var body = RekordboxWaveforms.be32(kind) + RekordboxWaveforms.be16(0) + RekordboxWaveforms.be16(UInt16(clamping: n))
            + RekordboxWaveforms.be32(isMemory && n > 0 ? UInt32(n - 1) : none32)
        for (i, cue) in cues.enumerated() {
            let previous = isMemory && i > 0 ? UInt16(clamping: i - 1) : none16
            let next = isMemory && i < n - 1 ? UInt16(clamping: i + 1) : none16
            body += pcpt(cue, previous: previous, next: next)
        }
        return RekordboxWaveforms.section("PCOB", headerLength: 0x18, body)
    }

    static func pcpt(_ cue: UsbCueInput, previous: UInt16, next: UInt16) -> [UInt8] {
        var out = Array("PCPT".utf8) + RekordboxWaveforms.be32(0x1C) + RekordboxWaveforms.be32(UInt32(pcptLength))
        out += RekordboxWaveforms.be32(UInt32(cue.hotCueNumber ?? 0))
        // 상태 칸: 활성 루프도 0으로 쓴다(확인한 모양이 아니면 cueVariant로 막힌다).
        out += RekordboxWaveforms.be32(0)
        out += RekordboxWaveforms.be32(pcptConstant)
        out += RekordboxWaveforms.be16(previous) + RekordboxWaveforms.be16(next)
        out += [cue.isLoop ? 2 : 1, 0] + RekordboxWaveforms.be16(cueConstant)
        out += RekordboxWaveforms.be32(UInt32(truncatingIfNeeded: cue.inMsec))
        out += RekordboxWaveforms.be32(cue.isLoop ? UInt32(truncatingIfNeeded: cue.outMsec) : none32)
        out += [UInt8](repeating: 0, count: 16)
        return out
    }

    /// PCO2 태그 전체. `fileType`은 djmdContent.FileType(FLAC이면 SeekInfo를 탐색 칸에 쓴다)
    public static func pco2(kind: UInt32, cues: [UsbCueInput], fileType: Int) -> Data {
        var body = RekordboxWaveforms.be32(kind) + RekordboxWaveforms.be16(UInt16(clamping: cues.count)) + RekordboxWaveforms.be16(0)
        for cue in cues { body += pcp2(cue, fileType: fileType) }
        return RekordboxWaveforms.section("PCO2", headerLength: 0x14, body)
    }

    static func pcp2(_ cue: UsbCueInput, fileType: Int) -> [UInt8] {
        let hot = cue.hotCueNumber
        var comment = [UInt8]()
        if !cue.comment.isEmpty {
            for unit in cue.comment.utf16 { comment += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
            comment += [0, 0]
        }
        // 색 큐는 확인하지 않은 모양(cueVariant)이다. 골든의 큐는 모두 색 id 0이었다.
        let colorID: UInt8
        if hot != nil {
            let index = cue.colorTableIndex ?? 0
            colorID = (0...255).contains(index) ? UInt8(index) : 0
        } else {
            colorID = cue.color.flatMap { (1...8).contains($0) ? UInt8($0) : nil } ?? 0
        }
        let flac = fileType == flacFileType
        let loopSeek = flac && cue.isLoop
        var out = Array("PCP2".utf8) + RekordboxWaveforms.be32(0x10) + RekordboxWaveforms.be32(UInt32(pcp2FixedLength + comment.count))
        out += RekordboxWaveforms.be32(UInt32(hot ?? 0))
        out += [cue.isLoop ? 2 : 1, 0] + RekordboxWaveforms.be16(cueConstant)
        out += RekordboxWaveforms.be32(UInt32(truncatingIfNeeded: cue.inMsec))
        out += RekordboxWaveforms.be32(cue.isLoop ? UInt32(truncatingIfNeeded: cue.outMsec) : none32)
        out += [colorID, 1] + RekordboxWaveforms.be16(0) + RekordboxWaveforms.be32(0)
        out += RekordboxWaveforms.be16(UInt16(truncatingIfNeeded: cue.beatLoopSize >> 16))
            + RekordboxWaveforms.be16(UInt16(truncatingIfNeeded: cue.beatLoopSize & 0xFFFF))
        out += RekordboxWaveforms.be32(UInt32(comment.count)) + comment
        out += hot == nil ? memoryColor : cue.isLoop ? hotLoopColor : hotCueColor
        out += RekordboxWaveforms.be64(flac ? cue.inSeek?.frame ?? 0 : 0)
        out += RekordboxWaveforms.be64(loopSeek ? cue.outSeek?.frame ?? 0 : 0)
        out += RekordboxWaveforms.be64(flac ? cue.inSeek?.offset ?? 0 : 0)
        out += RekordboxWaveforms.be64(loopSeek ? cue.outSeek?.offset ?? 0 : 0)
        out += RekordboxWaveforms.be32(flac ? cue.inSeek?.block ?? 0 : 0)
        out += RekordboxWaveforms.be32(loopSeek ? cue.outSeek?.block ?? 0 : 0)
        return out
    }

    // MARK: - 읽기

    public static func decodePCOB(_ tag: Data) throws -> (kind: UInt32, entries: [PCPTEntry]) {
        let b = [UInt8](tag)
        guard b.count >= 24, b[0..<4].elementsEqual("PCOB".utf8), AnlzFile.u32(b, 4) == 0x18, Int(AnlzFile.u32(b, 8)) == b.count
        else { throw malformed("PCOB", "bad header") }
        let n = Int(AnlzFile.u16(b, 18))
        guard b.count == 24 + pcptLength * n else { throw malformed("PCOB", "bad entry count") }
        let entries = try (0..<n).map { i -> PCPTEntry in
            let p = 24 + pcptLength * i
            guard b[p..<p + 4].elementsEqual("PCPT".utf8), AnlzFile.u32(b, p + 4) == 0x1C, Int(AnlzFile.u32(b, p + 8)) == pcptLength
            else { throw malformed("PCPT", "bad entry \(i)") }
            return PCPTEntry(hotCue: AnlzFile.u32(b, p + 0x0C), status: AnlzFile.u32(b, p + 0x10),
                             previous: AnlzFile.u16(b, p + 0x18), next: AnlzFile.u16(b, p + 0x1A), type: b[p + 0x1C],
                             inMsec: AnlzFile.u32(b, p + 0x20), outMsec: AnlzFile.u32(b, p + 0x24))
        }
        return (AnlzFile.u32(b, 12), entries)
    }

    public static func decodePCO2(_ tag: Data) throws -> (kind: UInt32, entries: [PCP2Entry]) {
        let b = [UInt8](tag)
        guard b.count >= 20, b[0..<4].elementsEqual("PCO2".utf8), AnlzFile.u32(b, 4) == 0x14, Int(AnlzFile.u32(b, 8)) == b.count
        else { throw malformed("PCO2", "bad header") }
        let n = Int(AnlzFile.u16(b, 16))
        var entries: [PCP2Entry] = []
        var p = 20
        for i in 0..<n {
            guard p + pcp2FixedLength <= b.count, b[p..<p + 4].elementsEqual("PCP2".utf8), AnlzFile.u32(b, p + 4) == 0x10
            else { throw malformed("PCP2", "bad entry \(i)") }
            let length = Int(AnlzFile.u32(b, p + 8)), commentLength = Int(AnlzFile.u32(b, p + 0x28))
            guard length == pcp2FixedLength + commentLength, p + length <= b.count, commentLength % 2 == 0,
                  commentLength == 0 || (b[p + 0x2C + commentLength - 2] == 0 && b[p + 0x2C + commentLength - 1] == 0)
            else { throw malformed("PCP2", "bad length \(i)") }
            let units = stride(from: p + 0x2C, to: p + 0x2C + max(0, commentLength - 2), by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }
            let c = p + 0x2C + commentLength
            func u64(_ at: Int) -> UInt64 { UInt64(AnlzFile.u32(b, at)) << 32 | UInt64(AnlzFile.u32(b, at + 4)) }
            entries.append(PCP2Entry(
                hotCue: AnlzFile.u32(b, p + 0x0C), type: b[p + 0x10], inMsec: AnlzFile.u32(b, p + 0x14), outMsec: AnlzFile.u32(b, p + 0x18),
                colorID: b[p + 0x1C], beatNumerator: AnlzFile.u16(b, p + 0x24), beatDenominator: AnlzFile.u16(b, p + 0x26),
                comment: String(decoding: units, as: UTF16.self), color: Array(b[c..<c + 4]),
                inFrame: u64(c + 0x04), outFrame: u64(c + 0x0C), inOffset: u64(c + 0x14), outOffset: u64(c + 0x1C),
                inBlock: AnlzFile.u32(b, c + 0x24), outBlock: AnlzFile.u32(b, c + 0x28)))
            p += length
        }
        guard p == b.count else { throw malformed("PCO2", "trailing bytes") }
        return (AnlzFile.u32(b, 12), entries)
    }

    static func malformed(_ tag: String, _ reason: String) -> UsbError {
        .readFailed(detail: "\(tag): \(reason)")
    }
}
