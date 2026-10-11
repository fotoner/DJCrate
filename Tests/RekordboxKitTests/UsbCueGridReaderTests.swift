import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

@Suite("USB 큐·그리드 읽기")
struct UsbCueGridReaderTests {
    let path = "/Contents/시험/곡.mp3"
    let beats = AnlzBuilder.beats(bpm: 120, first: 100, count: 24)

    func files(_ cues: [UsbCueInput]) throws -> UsbAnlzResult {
        try UsbAnlzTransform.transform(localDAT: AnlzBuilder.localDAT(beats: beats),
                                       localEXT: AnlzBuilder.localEXT(beats: beats), local2EX: nil,
                                       contentsPath: path, cues: cues, fileType: 1)
    }

    @Test func 핫큐_여덟칸_메모리_박루프_주석을_읽는다() throws {
        let hot = (0..<8).map { slot in
            UsbCueInput(id: "h\(slot)", kind: slot < 3 ? slot + 1 : slot + 2, inMsec: 1_000 + slot * 500,
                        comment: "핫 \(slot)")
        }
        let source = try files(hot + [UsbCueInput(id: "m", kind: 0, inMsec: 6_000, outMsec: 8_000,
                                                comment: "루프", beatLoopSize: 4 << 16 | 1)])
        let result = try UsbCueGridReader.decode(dat: source.dat, ext: source.ext, expectedPath: path)
        let cues = try #require(result.cues)
        #expect(cues.count == 9)
        #expect(Set(cues.compactMap { $0.kind.slotLetter }) == Set(["A", "B", "C", "D", "E", "F", "G", "H"]))
        #expect(cues.last?.name == "루프" && cues.last?.loop?.beats == 4)
        #expect(cues.last?.loop?.end == 8)
        #expect(result.grid?.beats.count == beats.count)
        #expect(result.cueIssue == nil && result.gridIssue == nil)
    }

    @Test func DAT만_있으면_기본_큐를_읽는다() throws {
        let source = try files([UsbCueInput(id: "a", kind: 1, inMsec: 1_000)])
        let result = try UsbCueGridReader.decode(dat: source.dat, ext: nil, expectedPath: path)
        #expect(result.cues?.first?.kind == .hot(0))
        #expect(result.usesLegacyCues && result.grid != nil)
    }

    @Test func DAT만_있는_루프는_박수_손실을_막는다() throws {
        let source = try files([UsbCueInput(id: "m", kind: 0, inMsec: 1_000, outMsec: 3_000, beatLoopSize: 4 << 16 | 1)])
        let result = try UsbCueGridReader.decode(dat: source.dat, ext: nil, expectedPath: path)
        #expect(result.cues == nil && result.cueIssue != nil)
        #expect(result.grid != nil)
    }

    @Test func 색큐는_큐만_건너뛴다() throws {
        let source = try files([UsbCueInput(id: "a", kind: 1, inMsec: 1_000, colorTableIndex: 4)])
        let result = try UsbCueGridReader.decode(dat: source.dat, ext: source.ext, expectedPath: path)
        #expect(result.cues == nil && result.cueIssue != nil)
        #expect(result.grid != nil)
    }

    @Test func 다른곡_PPTH는_전체를_거부한다() throws {
        let source = try files([])
        #expect(throws: UsbCueGridReader.ReadFailure.self) {
            try UsbCueGridReader.decode(dat: source.dat, ext: source.ext, expectedPath: "/Contents/다른곡.mp3")
        }
    }

    @Test func DAT와_EXT_큐가_다르면_그리드만_읽는다() throws {
        let a = try files([UsbCueInput(id: "a", kind: 1, inMsec: 1_000)])
        let b = try files([UsbCueInput(id: "a", kind: 1, inMsec: 2_000)])
        let result = try UsbCueGridReader.decode(dat: a.dat, ext: b.ext, expectedPath: path)
        #expect(result.cues == nil && result.cueIssue != nil)
        #expect(result.grid != nil)
    }

    @Test func 중복_핫큐_슬롯은_거부한다() throws {
        let duplicate = [UsbCueInput(id: "a1", kind: 1, inMsec: 1_000), UsbCueInput(id: "a2", kind: 1, inMsec: 2_000)]
        let dat = AnlzBuilder.file([AnlzPathTag.encode(path), BeatGridTags.pqtz(beats),
                                   AnlzCueTags.pcob(kind: 1, cues: duplicate), AnlzCueTags.pcob(kind: 0, cues: [])])
        let result = try UsbCueGridReader.decode(dat: dat, ext: nil, expectedPath: path)
        #expect(result.cues == nil)
    }

    @Test func 잘못된_박번호는_그리드만_거부한다() throws {
        let source = try files([])
        var dat = try AnlzFile(data: source.dat)
        dat.replace("PQTZ", with: BeatGridTags.pqtz([.init(number: 5, bpm100: 12_000, time: 100)]))
        let result = try UsbCueGridReader.decode(dat: dat.serialized(), ext: nil, expectedPath: path)
        #expect(result.grid == nil && result.gridIssue != nil)
        #expect(result.cues != nil)
    }
}
