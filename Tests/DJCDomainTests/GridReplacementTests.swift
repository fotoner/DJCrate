import DJCDomain
import Foundation
import Testing

@Suite("명시 대체 그리드 검증")
struct GridReplacementTests {
    func original(offset: Double = 0.003) -> BeatGrid {
        var beats = (0..<10).map { BeatGrid.Beat(number: $0 % 4 + 1, bpm: 120, time: 0.5 + Double($0) / 2) }
        beats[2].time += offset
        return BeatGrid(beats: beats)
    }

    func replacement(_ grid: BeatGrid) -> GridDraft {
        GridDraft(trackUUID: "replacement", base: GridDraft.segments(from: grid),
                  segments: [.init(start: 0.25, bpm: 128, firstBeatNumber: 1)])
    }

    @Test func 구간값이_같아도_원본의_내부_박이_바뀌면_승인을_버린다() throws {
        let source = original(), changed = original(offset: 0.002)
        #expect(GridDraft.segments(from: source) == GridDraft.segments(from: changed))
        let approved = try #require(replacement(source).approvingReplacement(of: source, duration: 5))
        #expect(approved.isVerifiedReplacement(of: source, duration: 5))
        #expect(!approved.isVerifiedReplacement(of: changed, duration: 5))
        var changedNumber = source.beats
        changedNumber[2].number = 4
        #expect(!approved.isVerifiedReplacement(of: BeatGrid(beats: changedNumber), duration: 5))
        var changedTempo = source.beats
        changedTempo[2].bpm = 120.01
        #expect(!approved.isVerifiedReplacement(of: BeatGrid(beats: changedTempo), duration: 5))
    }

    @Test func 구간은_같아도_복잡_원본을_명시_대체하면_저장할_변경이다() throws {
        let source = original()
        let fresh = GridDraft(trackUUID: "replacement", grid: source)
        #expect(!fresh.hasChanges)
        var approved = try #require(fresh.approvingReplacement(of: source, duration: 5))
        #expect(approved.segments == approved.base && approved.hasChanges)
        #expect(approved.isVerifiedReplacement(of: source, duration: 5))
        approved.revert()
        #expect(!approved.hasChanges && approved.replacementSource == nil)
        let normal = original(offset: 0)
        #expect(GridDraft(trackUUID: "replacement", grid: normal).approvingReplacement(of: normal, duration: 5) == nil)
    }

    @Test func 옛_초안은_읽을_수_있지만_복잡_원본의_대체_승인이_아니다() throws {
        let source = original()
        let old = Data("{\"trackUUID\":\"replacement\",\"base\":[{\"start\":0.5,\"bpm\":120,\"firstBeatNumber\":1}],\"segments\":[{\"start\":0.25,\"bpm\":128,\"firstBeatNumber\":1}]}".utf8)
        let decoded = try JSONDecoder().decode(GridDraft.self, from: old)
        #expect(decoded == replacement(source) && decoded.replacementSource == nil)
        #expect(!decoded.isVerifiedReplacement(of: source, duration: 5))
        let approved = try #require(decoded.approvingReplacement(of: source, duration: 5))
        #expect(try JSONDecoder().decode(GridDraft.self, from: JSONEncoder().encode(approved)) == approved)
        var tampered = approved
        tampered.replacementSource = "invalid"
        #expect(!tampered.isVerifiedReplacement(of: source, duration: 5))
    }

    @Test func 지원_밖_구간과_잘못된_기준은_승인하지_않는다() throws {
        let source = original()
        let approved = try #require(replacement(source).approvingReplacement(of: source, duration: 5))
        let invalid: [[GridSegment]] = [[], approved.segments + [.init(start: 2, bpm: 140, firstBeatNumber: 1)],
            [.init(start: .nan, bpm: 128, firstBeatNumber: 1)], [.init(start: .infinity, bpm: 128, firstBeatNumber: 1)],
            [.init(start: 5, bpm: 128, firstBeatNumber: 1)], [.init(start: 0, bpm: .nan, firstBeatNumber: 1)],
            [.init(start: 0, bpm: 19.99, firstBeatNumber: 1)], [.init(start: 0, bpm: 655.36, firstBeatNumber: 1)],
            [.init(start: 0, bpm: 128, firstBeatNumber: 0)]]
        for segments in invalid {
            var draft = approved
            draft.segments = segments
            #expect(draft.approvingReplacement(of: source, duration: 5) == nil)
            #expect(!draft.isVerifiedReplacement(of: source, duration: 5))
        }
        var stale = approved
        stale.base[0].start += 0.01
        #expect(!stale.isVerifiedReplacement(of: source, duration: 5))
        #expect(approved.approvingReplacement(of: source, duration: .nan) == nil)
        #expect(approved.approvingReplacement(of: BeatGrid(beats: []), duration: 5) == nil)
    }
}
