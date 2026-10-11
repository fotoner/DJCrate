import DJCDomain
import Foundation
@testable import RekordboxKit
import Testing

/// 칸 값은 rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
@Suite("ANLZ 큐 태그(PCOB·PCPT, PCO2·PCP2)")
struct AnlzCueTagTests {
    func cue(_ id: String = "c", kind: Int, inMsec: Int = 1_000, outMsec: Int = -1, comment: String = "",
             colorTableIndex: Int? = nil, color: Int? = nil, beatLoopSize: Int = 0,
             inSeek: String? = nil, outSeek: String? = nil) -> UsbCueInput {
        UsbCueInput(id: id, kind: kind, inMsec: inMsec, outMsec: outMsec, comment: comment, colorTableIndex: colorTableIndex,
                    color: color, beatLoopSize: beatLoopSize, createdAtRaw: "2026-01-01 00:00:00.000 +00:00",
                    inSeek: UsbSeekInfo.parse(inSeek), outSeek: UsbSeekInfo.parse(outSeek))
    }

    func u8(_ data: Data, _ at: Int) -> UInt8 { [UInt8](data)[at] }
    func u16(_ data: Data, _ at: Int) -> UInt16 { let b = [UInt8](data); return UInt16(b[at]) << 8 | UInt16(b[at + 1]) }
    func u32(_ data: Data, _ at: Int) -> UInt32 { let b = [UInt8](data); return (0..<4).reduce(0) { $0 << 8 | UInt32(b[at + $1]) } }
    func u64(_ data: Data, _ at: Int) -> UInt64 { let b = [UInt8](data); return (0..<8).reduce(0) { $0 << 8 | UInt64(b[at + $1]) } }
    func bytes(_ data: Data, _ range: Range<Int>) -> [UInt8] { Array([UInt8](data)[range]) }

    /// PCOB 안 i번째 PCPT(머리 24바이트 뒤 56바이트씩)
    func pcpt(_ tag: Data, _ i: Int) -> Data { tag.subdata(in: 24 + 56 * i..<24 + 56 * (i + 1)) }

    /// PCO2 안 PCP2 항목들(길이가 주석마다 다르다)
    func pcp2s(_ tag: Data) -> [Data] {
        var out: [Data] = [], p = 20
        while p < tag.count {
            let length = Int(u32(tag, p + 8))
            out.append(tag.subdata(in: p..<p + length))
            p += length
        }
        return out
    }

    /// PCP2의 색 4바이트 자리(주석 뒤)
    func colorOffset(_ entry: Data) -> Int { 0x2C + Int(u32(entry, 0x28)) }

    @Test("빈 PCOB·PCO2는 로컬 새 곡이 쓰는 빈 태그와 같다")
    func emptyPCOBEqualsExisting() {
        for kind: UInt32 in [1, 0] {
            #expect(AnlzCueTags.pcob(kind: kind, cues: []) == TrackAnalysisFiles.emptyPCOB(kind: kind))
            #expect(AnlzCueTags.pco2(kind: kind, cues: [], fileType: 1) == RekordboxWaveforms.emptyPCO2(kind: kind))
        }
    }

    @Test("PCOB 머리: 핫은 0xFFFFFFFF, 메모리는 n − 1")
    func pcobHeaderHotFFFF_memoryNMinus1() {
        let hot = AnlzCueTags.pcob(kind: 1, cues: [cue(kind: 1), cue(kind: 3, inMsec: 2_000)])
        #expect(bytes(hot, 0..<4) == Array("PCOB".utf8))
        #expect(u32(hot, 4) == 0x18 && u32(hot, 8) == 24 + 56 * 2 && hot.count == 24 + 56 * 2)
        #expect(u32(hot, 12) == 1 && u16(hot, 16) == 0 && u16(hot, 18) == 2)
        #expect(u32(hot, 20) == 0xFFFF_FFFF)
        let memory = AnlzCueTags.pcob(kind: 0, cues: [cue(kind: 0), cue(kind: 0, inMsec: 2_000), cue(kind: 0, inMsec: 3_000)])
        #expect(u32(memory, 12) == 0 && u16(memory, 18) == 3)
        #expect(u32(memory, 20) == 2)
        #expect(u32(AnlzCueTags.pcob(kind: 0, cues: [cue(kind: 0)]), 20) == 0)
    }

    @Test("PCPT 앞뒤 항목: 메모리는 사슬, 핫은 0xFFFF")
    func pcptLinksMemoryChainHotFFFF() {
        let memory = AnlzCueTags.pcob(kind: 0, cues: (0..<3).map { cue("m\($0)", kind: 0, inMsec: 1_000 * ($0 + 1)) })
        let links = (0..<3).map { (u16(pcpt(memory, $0), 0x18), u16(pcpt(memory, $0), 0x1A)) }
        #expect(links.map(\.0) == [0xFFFF, 0, 1])
        #expect(links.map(\.1) == [1, 2, 0xFFFF])
        let single = AnlzCueTags.pcob(kind: 0, cues: [cue(kind: 0)])
        #expect(u16(pcpt(single, 0), 0x18) == 0xFFFF && u16(pcpt(single, 0), 0x1A) == 0xFFFF)
        let hot = AnlzCueTags.pcob(kind: 1, cues: [cue(kind: 1), cue(kind: 2), cue(kind: 3)])
        for i in 0..<3 {
            #expect(u16(pcpt(hot, i), 0x18) == 0xFFFF && u16(pcpt(hot, i), 0x1A) == 0xFFFF)
        }
    }

    @Test("PCPT 루프는 종류 2와 OutMsec, 아니면 종류 1과 0xFFFFFFFF")
    func pcptLoopOutOrFFFF() {
        let tag = AnlzCueTags.pcob(kind: 1, cues: [cue(kind: 1, inMsec: 1_500), cue(kind: 2, inMsec: 2_000, outMsec: 5_750)])
        #expect(u8(pcpt(tag, 0), 0x1C) == 1 && u32(pcpt(tag, 0), 0x20) == 1_500 && u32(pcpt(tag, 0), 0x24) == 0xFFFF_FFFF)
        #expect(u8(pcpt(tag, 1), 0x1C) == 2 && u32(pcpt(tag, 1), 0x20) == 2_000 && u32(pcpt(tag, 1), 0x24) == 5_750)
        // OutMsec 0(루프 아님)
        let zeroOut = AnlzCueTags.pcob(kind: 0, cues: [cue(kind: 0, inMsec: 700, outMsec: 0)])
        #expect(u8(pcpt(zeroOut, 0), 0x1C) == 1 && u32(pcpt(zeroOut, 0), 0x24) == 0xFFFF_FFFF)
    }

    @Test("PCPT 고정 칸")
    func pcptConstants() {
        let tag = AnlzCueTags.pcob(kind: 1, cues: [cue(kind: 6, inMsec: 12_345)])
        let entry = pcpt(tag, 0)
        #expect(bytes(entry, 0..<4) == Array("PCPT".utf8))
        #expect(u32(entry, 0x04) == 0x1C && u32(entry, 0x08) == 0x38)
        #expect(u32(entry, 0x0C) == 5)
        #expect(u32(entry, 0x10) == 0)
        #expect(u32(entry, 0x14) == 0x0001_0000)
        #expect(u8(entry, 0x1D) == 0 && u16(entry, 0x1E) == 0x03E8)
        #expect(u32(entry, 0x20) == 12_345)
        #expect(bytes(entry, 0x28..<0x38) == [UInt8](repeating: 0, count: 16))
        let memory = pcpt(AnlzCueTags.pcob(kind: 0, cues: [cue(kind: 0)]), 0)
        #expect(u32(memory, 0x0C) == 0)
    }

    @Test("PCO2 머리")
    func pco2Header() {
        let tag = AnlzCueTags.pco2(kind: 1, cues: [cue(kind: 1), cue(kind: 2, comment: "가")], fileType: 1)
        #expect(bytes(tag, 0..<4) == Array("PCO2".utf8))
        #expect(u32(tag, 4) == 0x14 && u32(tag, 8) == UInt32(tag.count))
        #expect(u32(tag, 12) == 1 && u16(tag, 16) == 2 && u16(tag, 18) == 0)
        #expect(tag.count == 20 + 0x58 + (0x58 + 4))
    }

    @Test("PCP2 핫큐 색 바이트 00 1A FF 00")
    func pcp2HotColorBytes() {
        let entry = pcp2s(AnlzCueTags.pco2(kind: 1, cues: [cue(kind: 1)], fileType: 1))[0]
        #expect(bytes(entry, colorOffset(entry)..<colorOffset(entry) + 4) == [0x00, 0x1A, 0xFF, 0x00])
        #expect(u8(entry, 0x10) == 1)
        #expect(u32(entry, 0x18) == 0xFFFF_FFFF)
    }

    @Test("PCP2 핫 루프 색 바이트 00 FF 8C 00")
    func pcp2HotLoopColorBytes() {
        let entry = pcp2s(AnlzCueTags.pco2(kind: 1, cues: [cue(kind: 2, inMsec: 1_000, outMsec: 4_000, beatLoopSize: 8 << 16 | 1)],
                                           fileType: 1))[0]
        #expect(bytes(entry, colorOffset(entry)..<colorOffset(entry) + 4) == [0x00, 0xFF, 0x8C, 0x00])
        #expect(u8(entry, 0x10) == 2 && u32(entry, 0x14) == 1_000 && u32(entry, 0x18) == 4_000)
        #expect(u32(entry, 0x0C) == 2)
    }

    @Test("PCP2 메모리 큐 색은 0, 색 id는 v1 규칙")
    func pcp2MemoryZeroColor() {
        let entries = pcp2s(AnlzCueTags.pco2(kind: 0, cues: [cue(kind: 0, color: 255), cue(kind: 0, color: 5), cue(kind: 0, color: nil)],
                                             fileType: 1))
        for entry in entries {
            #expect(bytes(entry, colorOffset(entry)..<colorOffset(entry) + 4) == [0, 0, 0, 0])
            #expect(u32(entry, 0x0C) == 0)
        }
        #expect(entries.map { u8($0, 0x1C) } == [0, 5, 0])
        let hot = pcp2s(AnlzCueTags.pco2(kind: 1, cues: [cue(kind: 1, colorTableIndex: 0), cue(kind: 2, colorTableIndex: 3),
                                                         cue(kind: 3)], fileType: 1))
        #expect(hot.map { u8($0, 0x1C) } == [0, 3, 0])
    }

    @Test("PCP2 고정 칸")
    func pcp2Constants() {
        let entry = pcp2s(AnlzCueTags.pco2(kind: 1, cues: [cue(kind: 9, inMsec: 777)], fileType: 1))[0]
        #expect(bytes(entry, 0..<4) == Array("PCP2".utf8))
        #expect(u32(entry, 0x04) == 0x10)
        #expect(u32(entry, 0x0C) == 8)
        #expect(u8(entry, 0x11) == 0 && u16(entry, 0x12) == 0x03E8)
        #expect(u32(entry, 0x14) == 777)
        #expect(u8(entry, 0x1D) == 1 && u16(entry, 0x1E) == 0 && u32(entry, 0x20) == 0)
    }

    @Test("PCP2 주석은 UTF-16BE와 끝 NUL, 패딩 없음")
    func pcp2CommentUTF16BENul() {
        let entry = pcp2s(AnlzCueTags.pco2(kind: 0, cues: [cue(kind: 0, comment: "큐 A")], fileType: 1))[0]
        let text: [UInt8] = [0xD0, 0x50, 0x00, 0x20, 0x00, 0x41, 0x00, 0x00]
        #expect(u32(entry, 0x28) == UInt32(text.count))
        #expect(bytes(entry, 0x2C..<0x2C + text.count) == text)
        #expect(u32(entry, 0x08) == UInt32(0x58 + text.count) && entry.count == 0x58 + text.count)
    }

    @Test("주석이 없으면 len_comment 0, 항목 0x58바이트")
    func pcp2NoCommentLen0x58() {
        let entry = pcp2s(AnlzCueTags.pco2(kind: 0, cues: [cue(kind: 0)], fileType: 1))[0]
        #expect(u32(entry, 0x28) == 0)
        #expect(u32(entry, 0x08) == 0x58 && entry.count == 0x58)
    }

    @Test("박 루프 크기는 분자·분모 u16 두 칸")
    func pcp2BeatLoopNumeratorDenominator() {
        let entry = pcp2s(AnlzCueTags.pco2(kind: 1, cues: [cue(kind: 1, inMsec: 0, outMsec: 3_000, beatLoopSize: 0x0008_0001)],
                                           fileType: 1))[0]
        #expect(u16(entry, 0x24) == 8 && u16(entry, 0x26) == 1)
        let noSize = pcp2s(AnlzCueTags.pco2(kind: 1, cues: [cue(kind: 1)], fileType: 1))[0]
        #expect(u16(noSize, 0x24) == 0 && u16(noSize, 0x26) == 0)
    }

    @Test("FLAC은 SeekInfo를 프레임·바이트 위치·블록 칸에")
    func pcp2FlacSeekFields() {
        let loop = cue(kind: 1, inMsec: 1_000, outMsec: 9_000, comment: "루프", beatLoopSize: 16 << 16 | 1,
                       inSeek: "123,456,4096", outSeek: "789,1011,4096")
        let entry = pcp2s(AnlzCueTags.pco2(kind: 1, cues: [loop], fileType: 5))[0]
        let c = colorOffset(entry)
        #expect(u64(entry, c + 0x04) == 123 && u64(entry, c + 0x0C) == 789)
        #expect(u64(entry, c + 0x14) == 456 && u64(entry, c + 0x1C) == 1_011)
        #expect(u32(entry, c + 0x24) == 4_096 && u32(entry, c + 0x28) == 4_096)
        #expect(entry.count == c + 0x2C)
        // 루프가 아니면 Out 칸은 0
        let point = cue(kind: 0, inMsec: 1_000, inSeek: "123,456,4096", outSeek: "789,1011,4096")
        let pointEntry = pcp2s(AnlzCueTags.pco2(kind: 0, cues: [point], fileType: 5))[0]
        let p = colorOffset(pointEntry)
        #expect(u64(pointEntry, p + 0x04) == 123 && u64(pointEntry, p + 0x14) == 456 && u32(pointEntry, p + 0x24) == 4_096)
        #expect(u64(pointEntry, p + 0x0C) == 0 && u64(pointEntry, p + 0x1C) == 0 && u32(pointEntry, p + 0x28) == 0)
    }

    @Test("FLAC이 아니면 탐색 칸은 모두 0")
    func pcp2NonFlacZero() {
        let loop = cue(kind: 1, inMsec: 1_000, outMsec: 9_000, inSeek: "123,456,4096", outSeek: "789,1011,4096")
        for fileType in [1, 4, 11, 12] {
            let entry = pcp2s(AnlzCueTags.pco2(kind: 1, cues: [loop], fileType: fileType))[0]
            let c = colorOffset(entry)
            #expect(bytes(entry, c + 4..<c + 0x2C) == [UInt8](repeating: 0, count: 0x28), "fileType \(fileType)")
        }
    }

    @Test("만든 태그를 다시 읽으면 같은 값")
    func decodeRoundTrip() throws {
        let hot = [cue("a", kind: 1, inMsec: 500, comment: "시작"),
                   cue("b", kind: 7, inMsec: 2_000, outMsec: 6_000, colorTableIndex: 2, beatLoopSize: 8 << 16 | 1,
                       inSeek: "1,2,4096", outSeek: "3,4,4096")]
        let memory = [cue("m", kind: 0, inMsec: 300, color: 4), cue("n", kind: 0, inMsec: 100, comment: "🎵")]

        let decodedHot = try AnlzCueTags.decodePCOB(AnlzCueTags.pcob(kind: 1, cues: hot))
        #expect(decodedHot.kind == 1)
        #expect(decodedHot.entries.map(\.hotCue) == [1, 6])
        #expect(decodedHot.entries.map(\.type) == [1, 2])
        #expect(decodedHot.entries.map(\.inMsec) == [500, 2_000])
        #expect(decodedHot.entries.map(\.outMsec) == [0xFFFF_FFFF, 6_000])
        let decodedMemory = try AnlzCueTags.decodePCOB(AnlzCueTags.pcob(kind: 0, cues: memory))
        #expect(decodedMemory.kind == 0)
        #expect(decodedMemory.entries.map(\.previous) == [0xFFFF, 0])
        #expect(decodedMemory.entries.map(\.next) == [1, 0xFFFF])

        let all = try AnlzCueTags.decodePCO2(AnlzCueTags.pco2(kind: 1, cues: hot, fileType: 5))
        #expect(all.kind == 1)
        #expect(all.entries.map(\.comment) == ["시작", ""])
        #expect(all.entries.map(\.hotCue) == [1, 6])
        #expect(all.entries.map(\.colorID) == [0, 2])
        #expect(all.entries[1].beatNumerator == 8 && all.entries[1].beatDenominator == 1)
        #expect(all.entries[1].color == [0x00, 0xFF, 0x8C, 0x00])
        #expect(all.entries[1].inFrame == 1 && all.entries[1].inOffset == 2 && all.entries[1].inBlock == 4_096)
        #expect(all.entries[1].outFrame == 3 && all.entries[1].outOffset == 4 && all.entries[1].outBlock == 4_096)
        let allMemory = try AnlzCueTags.decodePCO2(AnlzCueTags.pco2(kind: 0, cues: memory, fileType: 1))
        #expect(allMemory.entries.map(\.comment) == ["", "🎵"])
        #expect(allMemory.entries.map(\.colorID) == [4, 0])
    }

    @Test("모양이 다른 큐 태그는 거부한다")
    func decodeRejectsMalformed() {
        let pcob = [UInt8](AnlzCueTags.pcob(kind: 0, cues: [cue(kind: 0)]))
        let pco2 = [UInt8](AnlzCueTags.pco2(kind: 0, cues: [cue(kind: 0, comment: "가")], fileType: 1))
        var pcobCount = pcob; pcobCount[19] = 2
        var pcobName = pcob; pcobName[24] = 0x58
        var pco2Count = pco2; pco2Count[17] = 3
        var pco2Entry = pco2; pco2Entry[20 + 11] = 0xFF
        var pco2Comment = pco2; pco2Comment[20 + 0x2B] = 0x7F
        for (name, bytes) in [("PCOB 수", pcobCount), ("PCPT 이름", pcobName), ("PCOB 잘림", Array(pcob.prefix(30)))] {
            #expect(throws: UsbError.self, "\(name)") { try AnlzCueTags.decodePCOB(Data(bytes)) }
        }
        #expect(throws: UsbError.self) { try AnlzCueTags.decodePCOB(Data(pco2)) }
        for (name, bytes) in [("PCO2 수", pco2Count), ("PCP2 길이", pco2Entry), ("주석 길이", pco2Comment), ("PCO2 잘림", Array(pco2.prefix(40)))] {
            #expect(throws: UsbError.self, "\(name)") { try AnlzCueTags.decodePCO2(Data(bytes)) }
        }
        #expect(throws: UsbError.self) { try AnlzCueTags.decodePCO2(Data(pcob)) }
    }
}
