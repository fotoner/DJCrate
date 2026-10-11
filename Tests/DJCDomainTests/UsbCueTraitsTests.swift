import DJCDomain
import Foundation
import Testing

@Suite("USB 큐 규칙 분류")
struct UsbCueTraitsTests {
    let memory = UsbCueTraits(kind: 0, inMsec: 1_000, outMsec: -1)
    func hot(_ kind: Int) -> UsbCueTraits { UsbCueTraits(kind: kind, colorTableIndex: 0, inMsec: 2_000, outMsec: -1) }
    func loop(kind: Int = 1, beats: Int, denominator: Int = 1) -> UsbCueTraits {
        UsbCueTraits(kind: kind, inMsec: 3_000, outMsec: 7_000, beatLoopSize: beats << 16 | denominator)
    }

    /// 골든에 있던 모양(메모리 큐, 핫큐 A–C·E, 8·16박 핫 루프)
    var goldenCues: [UsbCueTraits] {
        [memory, hot(1), hot(2), hot(3), hot(6), loop(beats: 8), loop(kind: 2, beats: 16),
         UsbCueTraits(kind: 3, colorTableIndex: nil, color: 255, inMsec: 500, outMsec: 0)]
    }

    @Test("골든에 있던 모양은 규칙이 필요 없다")
    func goldenShapesNeedNoRule() {
        for fileType in [5, 4, 1] {
            #expect(UsbCueRules.rules(fileType: fileType, cues: goldenCues).isEmpty, "fileType \(fileType)")
        }
        #expect(UsbCueRules.rules(fileType: 11, cues: []).isEmpty)
    }

    @Test("확인하지 않은 모양은 하나씩 cueVariant")
    func variantsFlagged() {
        var colored = hot(1)
        colored.colorTableIndex = 3
        var coloredMemory = memory
        coloredMemory.color = 3
        let memoryLoop = UsbCueTraits(kind: 0, inMsec: 1_000, outMsec: 5_000, beatLoopSize: 8 << 16 | 1)
        var active = loop(beats: 8)
        active.activeLoop = 1
        let freeLoop = UsbCueTraits(kind: 1, inMsec: 1_000, outMsec: 1_700, beatLoopSize: 0)
        let variants: [(String, UsbCueTraits)] = [
            ("색 핫큐", colored), ("메모리 색 3", coloredMemory), ("메모리 루프", memoryLoop), ("activeLoop 1", active),
            ("박 아닌 루프", freeLoop), ("4박 루프", loop(beats: 4)), ("분모 2 루프", loop(beats: 8, denominator: 2)),
            ("핫큐 D", hot(5)), ("핫큐 F", hot(7)), ("핫큐 G", hot(8)), ("핫큐 H", hot(9)),
        ]
        for (name, cue) in variants {
            #expect(UsbCueRules.rules(fileType: 5, cues: [memory, cue]) == [.cueVariant], "\(name)")
        }
        // 메모리 큐의 색 없음(255·nil)과 핫큐 색 인덱스 0은 골든 모양이다.
        var noColor = memory
        noColor.color = 255
        #expect(UsbCueRules.rules(fileType: 5, cues: [noColor]).isEmpty)
    }

    @Test("탐색 칸을 확인하지 않은 형식은 cueSeekFields")
    func seekFieldsFlagged() {
        #expect(UsbCueRules.rules(fileType: 11, cues: [memory]) == [.cueSeekFields])
        var framed = memory
        framed.inMpegFrame = 1_234
        #expect(UsbCueRules.rules(fileType: 1, cues: [memory, framed]) == [.cueSeekFields])
        #expect(UsbCueRules.rules(fileType: 11, cues: []).isEmpty)
        #expect(UsbCueRules.rules(fileType: 11, cues: [hot(5)]) == [.cueSeekFields, .cueVariant])
    }

    @Test("핫큐 번호는 4를 건너뛴다")
    func hotCueNumbers() {
        let table: [Int: Int?] = [0: nil, 1: 1, 2: 2, 3: 3, 4: nil, 5: 4, 6: 5, 7: 6, 8: 7, 9: 8, 10: nil, -1: nil]
        for (kind, number) in table {
            #expect(UsbCueRules.hotCueNumber(kind: kind) == number, "kind \(kind)")
        }
    }

    @Test func codableRoundTrip() throws {
        let cue = loop(beats: 16)
        #expect(try JSONDecoder().decode(UsbCueTraits.self, from: JSONEncoder().encode(cue)) == cue)
    }
}
