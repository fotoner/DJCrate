import DJCDomain
import Foundation
import Testing

@Suite("USB 분석 파일 큐 배치")
struct UsbCuePlacementTests {
    /// 기본은 루프 아닌 큐. 시각이 겹치지 않게 ID마다 다른 created_at을 준다.
    func cue(_ id: String, kind: Int, inMsec: Int = 1_000, createdAt: String = "2026-01-01 00:00:00.000 +00:00") -> UsbCueInput {
        UsbCueInput(id: id, kind: kind, inMsec: inMsec, createdAtRaw: createdAt)
    }

    func stamp(_ second: Int) -> String { String(format: "2026-01-01 00:00:%02d.000 +00:00", second) }

    /// 메모리 2개 · 핫 A–C · 핫 D–H
    var everyKind: [UsbCueInput] {
        [0, 0, 1, 2, 3, 5, 6, 7, 8, 9].enumerated().map { index, kind in
            cue("c\(index)", kind: kind, inMsec: 1_000 * (index + 1), createdAt: stamp(index))
        }
    }

    @Test("핫큐 A–C는 .DAT, D–H는 .EXT PCOB에")
    func placesHotAtoCInDatDtoHInExt() {
        let layout = UsbCuePlacement.layout(everyKind)
        #expect(Set(layout.datHot.map(\.kind)) == [1, 2, 3])
        #expect(Set(layout.extHot.map(\.kind)) == [5, 6, 7, 8, 9])
        #expect(layout.datMemory.map(\.kind) == [0, 0])
        #expect(layout.dropped.isEmpty)
    }

    @Test(".EXT의 메모리 PCOB는 늘 비운다")
    func extMemoryAlwaysEmpty() {
        #expect(UsbCuePlacement.layout(everyKind).extMemory.isEmpty)
        #expect(UsbCuePlacement.layout([cue("m", kind: 0)]).extMemory.isEmpty)
    }

    @Test("PCO2에는 핫큐 A–H 전부와 메모리 큐 전부")
    func pco2HasAllHotAndAllMemory() {
        let layout = UsbCuePlacement.layout(everyKind)
        #expect(Set(layout.extAllHot.map(\.kind)) == [1, 2, 3, 5, 6, 7, 8, 9])
        #expect(layout.extAllHot.count == 8)
        #expect(layout.extAllMemory.map(\.id) == layout.datMemory.map(\.id))
        #expect(layout.extAllMemory.count == 2)
    }

    @Test("Kind 6은 핫큐 5번(E)")
    func kind6IsHotCue5() {
        let input = cue("e", kind: 6)
        #expect(input.hotCueNumber == 5)
        #expect(cue("c", kind: 3).hotCueNumber == 3)
        #expect(cue("h", kind: 9).hotCueNumber == 8)
        #expect(cue("m", kind: 0).hotCueNumber == nil)
        let layout = UsbCuePlacement.layout([input])
        #expect(layout.extHot.map(\.id) == ["e"])
        #expect(layout.datHot.isEmpty)
    }

    @Test("Kind 4는 어느 목록에도 넣지 않고 따로 모은다")
    func kind4Dropped() {
        let layout = UsbCuePlacement.layout([cue("x", kind: 4), cue("y", kind: 12), cue("a", kind: 1)])
        #expect(layout.dropped.map(\.id) == ["x", "y"])
        #expect(layout.datHot.map(\.id) == ["a"])
        #expect(layout.extAllHot.map(\.id) == ["a"])
        #expect(layout.extHot.isEmpty && layout.datMemory.isEmpty && layout.extAllMemory.isEmpty)
    }

    @Test("순서: created_at 내림차순, 같으면 InMsec 내림차순")
    func orderCreatedAtDescThenInMsecDesc() {
        let same = stamp(30)
        let cues = [
            cue("early", kind: 0, inMsec: 9_000, createdAt: stamp(10)),
            cue("same1", kind: 0, inMsec: 1_000, createdAt: same),
            cue("late", kind: 0, inMsec: 500, createdAt: stamp(50)),
            cue("same3", kind: 0, inMsec: 3_000, createdAt: same),
            cue("same2", kind: 0, inMsec: 2_000, createdAt: same),
        ]
        let expected = ["late", "same3", "same2", "same1", "early"]
        let layout = UsbCuePlacement.layout(cues)
        #expect(layout.datMemory.map(\.id) == expected)
        #expect(layout.extAllMemory.map(\.id) == expected)
        // 핫큐 목록도 같은 규칙
        let hot = cues.map { input -> UsbCueInput in
            var copy = input
            copy.kind = 1
            return copy
        }
        #expect(UsbCuePlacement.layout(hot).datHot.map(\.id) == expected)
        #expect(UsbCuePlacement.layout(hot).extAllHot.map(\.id) == expected)
    }

    @Test("created_at은 글자가 아니라 시각으로 비교한다(밀리초·시간대 생략형 섞임)")
    func createdAtParsedNotStringCompared() {
        // 글자로는 "10:00:00 +09:00"이 가장 늦지만 시각으로는 01:00 UTC로 가장 이르다.
        let cues = [
            cue("tokyo", kind: 0, inMsec: 1_000, createdAt: "2026-01-01 10:00:00 +09:00"),
            cue("utcMs", kind: 0, inMsec: 2_000, createdAt: "2026-01-01 02:00:00.250 +00:00"),
            cue("noZone", kind: 0, inMsec: 3_000, createdAt: "2026-01-01 03:00:00"),
            cue("noMs", kind: 0, inMsec: 4_000, createdAt: "2026-01-01 02:00:00 +00:00"),
        ]
        let layout = UsbCuePlacement.layout(cues)
        #expect(layout.datMemory.map(\.id) == ["noZone", "utcMs", "noMs", "tokyo"])
        #expect(cues.allSatisfy { $0.createdAt != nil })
    }

    @Test("풀 수 없는 created_at이 있으면 그 목록은 글자로 비교한다")
    func unparsedCreatedAtFallsBackToText() {
        let cues = [
            cue("b", kind: 0, inMsec: 1_000, createdAt: "b-not-a-date"),
            cue("a", kind: 0, inMsec: 2_000, createdAt: "2026-01-01 00:00:00 +00:00"),
            cue("c", kind: 0, inMsec: 3_000, createdAt: "b-not-a-date"),
        ]
        #expect(cues[0].createdAt == nil)
        // "b…" > "2026…"(글자), 같은 글자면 InMsec 내림차순
        #expect(UsbCuePlacement.layout(cues).datMemory.map(\.id) == ["c", "b", "a"])
    }

    @Test("created_at 형식")
    func parseCreatedAtFormats() throws {
        let base = try #require(UsbCuePlacement.parseCreatedAt("2026-09-27 11:41:08.000 +00:00"))
        #expect(base == Date(timeIntervalSince1970: 1_790_509_268))
        #expect(UsbCuePlacement.parseCreatedAt("2026-09-27 11:41:08 +00:00") == base)
        #expect(UsbCuePlacement.parseCreatedAt("2026-09-27 11:41:08") == base)
        #expect(UsbCuePlacement.parseCreatedAt("2026-09-27T11:41:08.000+00:00") == base)
        #expect(UsbCuePlacement.parseCreatedAt("2026-09-27 20:41:08.000 +09:00") == base)
        #expect(UsbCuePlacement.parseCreatedAt("2026-09-27 11:41:08.5 +00:00") == base.addingTimeInterval(0.5))
        #expect(UsbCuePlacement.parseCreatedAt("2026-09-27 11:41:08.500 -01:30") == base.addingTimeInterval(5_400.5))
        for bad in ["", "2026-09-27", "2026-13-01 00:00:00", "2026-09-27 25:00:00", "2026-09-27 11:41:08 +0x:00", "garbage"] {
            #expect(UsbCuePlacement.parseCreatedAt(bad) == nil, "\(bad)")
        }
    }

    @Test("SeekInfo 글자")
    func seekInfoParse() {
        #expect(UsbSeekInfo.parse("123,456,4096") == UsbSeekInfo(frame: 123, offset: 456, block: 4096))
        #expect(UsbSeekInfo.parse(" 1, 2 ,3 ") == UsbSeekInfo(frame: 1, offset: 2, block: 3))
        for empty in [nil, "", "0,0,0", "1,2", "a,b,c", "1,2,3,4", "-1,2,3"] as [String?] {
            #expect(UsbSeekInfo.parse(empty) == nil, "\(empty ?? "nil")")
        }
    }

    @Test("큐 모양 → 규칙 분류 입력")
    func traitsCarryShape() {
        let input = UsbCueInput(id: "l", kind: 2, inMsec: 1_000, outMsec: 5_000, comment: "x", colorTableIndex: 3, color: 7,
                                activeLoop: 1, beatLoopSize: 8 << 16 | 1, inMpegFrame: 12)
        #expect(input.traits == UsbCueTraits(kind: 2, colorTableIndex: 3, color: 7, inMsec: 1_000, outMsec: 5_000,
                                             activeLoop: 1, beatLoopSize: 8 << 16 | 1, inMpegFrame: 12))
        #expect(input.isLoop)
        #expect(!cue("m", kind: 0).isLoop)
    }
}
