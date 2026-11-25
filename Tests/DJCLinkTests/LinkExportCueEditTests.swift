@testable import DJCLink
import Testing

/// CDJ가 LINK로 보낸 큐 저장·삭제(#280): 서버가 내어 주는 큐 목록을 바꿔 CDJ에 돌려준다.
/// 거절하면 서버가 빈 목록으로 답해 CDJ의 메모리 큐가 모두 사라졌다(2026-10-16 실기, CDJ-2000nexus).
@Suite("LINK 큐 저장·삭제")
struct LinkExportCueEditTests {
    typealias Served = LinkExportServer.ServedCue
    let cues = [Served(kind: 0, positionMs: 10_000, outMs: 0, colour: 0), Served(kind: 1, positionMs: 20_000, outMs: 0, colour: 5)]

    @Test func MEMORY는_메모리_큐를_더하고_같은_자리는_다시_더하지_않는다() {
        let added = LinkExportServer.editedCues(cues, deleted: false, kind: 0, inMs: 15_000, outMs: 0)
        #expect(added.map(\.positionMs) == [10_000, 15_000, 20_000])
        #expect(LinkExportServer.editedCues(added, deleted: false, kind: 0, inMs: 15_020, outMs: 0) == added)
    }

    @Test func 핫큐는_그_칸을_바꾸고_DELETE는_가까운_메모리_큐나_그_칸을_지운다() {
        let moved = LinkExportServer.editedCues(cues, deleted: false, kind: 1, inMs: 30_000, outMs: 0)
        #expect(moved.filter { $0.kind == 1 }.map(\.positionMs) == [30_000])
        #expect(LinkExportServer.editedCues(cues, deleted: true, kind: 0, inMs: 10_010, outMs: 0).map(\.kind) == [1])
        #expect(LinkExportServer.editedCues(cues, deleted: true, kind: 1, inMs: 0, outMs: 0).map(\.kind) == [0])
        #expect(LinkExportServer.editedCues(cues, deleted: true, kind: 0, inMs: 50_000, outMs: 0) == cues)
    }

    @Test func CDJ_응답도_같은_자리의_점과_루프_끝을_가린다() {
        let first = LinkExportServer.editedCues(cues, deleted: false, kind: 0, inMs: 10_000, outMs: 12_000)
        let both = LinkExportServer.editedCues(first, deleted: false, kind: 0, inMs: 10_000, outMs: 14_000)
        #expect(both.filter { $0.kind == 0 }.map(\.outMs) == [0, 12_000, 14_000])
        let next = LinkExportServer.editedCues(both, deleted: true, kind: 0, inMs: 10_010, outMs: 12_000)
        #expect(next.filter { $0.kind == 0 }.map(\.outMs) == [0, 14_000])
    }

    @Test func CDJ_응답은_프레임_끝의_고유한_루프만_찾고_모호하면_그대로_둔다() {
        for (ends, remaining): ([UInt32], [UInt32]) in [([12_001, 12_050], [12_050]), ([12_001, 12_005], [12_001, 12_005]),
                                                        ([12_001, 12_007], [12_001]), ([12_010], [])] {
            let loops = ends.map { Served(kind: 0, positionMs: 10_000, outMs: $0, colour: 0) }
            #expect(LinkExportServer.editedCues(loops, deleted: false, kind: 0, inMs: 10_000, outMs: 12_007) == loops)
            #expect(LinkExportServer.editedCues(loops, deleted: true, kind: 0, inMs: 10_000, outMs: 12_007).map(\.outMs) == remaining)
        }
    }

    @Test func 메모리_한도에서_새_루프가_CDJ_응답에만_남지_않는다() {
        let full = (0..<10).map { Served(kind: 0, positionMs: UInt32($0 * 1000), outMs: 0, colour: 0) }
        #expect(LinkExportServer.editedCues(full, deleted: false, kind: 0, inMs: 1000, outMs: 2000) == full)
    }

    @Test func 활성_루프는_하나만_둔다() {
        let first = LinkExportServer.editedCues(cues, deleted: false, kind: 4, inMs: 1_000, outMs: 2_000)
        let second = LinkExportServer.editedCues(first, deleted: false, kind: 4, inMs: 3_000, outMs: 4_000)
        #expect(second.filter { $0.kind == 4 }.map(\.positionMs) == [3_000])
        #expect(second.first { $0.positionMs == 1_000 }?.kind == 0)
    }
}
