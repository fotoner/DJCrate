@testable import DJCDomain
import Foundation
import Testing

@Suite("곡 편집 재생 예약표: 렌더하지 않고 결과 어디서든 듣기")
struct EditPlaybackTests {
    /// 120 BPM(1마디 2초), 첫 다운비트 0.5초, 20.5초. 읽기 쉽게 1초 = 1000프레임, 섞기 4프레임.
    let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    func spans(_ bars: [BarRange], offset: Double = 0) throws -> [EditFrameSpan] {
        try TrackEdit(grid: grid, sourceDuration: 20.5, bars: bars).frames(sampleRate: 1000, sourceOffset: offset)
    }

    @Test func 렌더러처럼_조각을_잇고_이음새_앞을_섞는다() throws {
        // 1-2 → 1-10: 조각 둘(원본 500프레임부터 4000·20000프레임), 이음새 4000프레임
        let items = TrackEdit.playbackItems(try spans([BarRange(1, 2), BarRange(1, 2), BarRange(3, 10)]))
        #expect(items == [
            EditPlaybackItem(outputFrame: 0, frameCount: 3996, sourceFrame: 500),
            // 앞 조각 끝(4496~)을 줄이고 뒤 조각 바로 앞 원본(496~)을 키운다. 이음새(4000)에서 끝난다.
            EditPlaybackItem(outputFrame: 3996, frameCount: 4, sourceFrame: 4496,
                             fade: .init(sourceFrame: 496, position: 0, length: 4)),
            EditPlaybackItem(outputFrame: 4000, frameCount: 20000, sourceFrame: 500),
        ])
        // 빈틈없이 출력 끝까지
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.outputFrame + $0.frameCount == $1.outputFrame })
        #expect(items.last.map { $0.outputFrame + $0.frameCount } == 24000)
    }

    @Test func 이음새가_없으면_한_조각이다() throws {
        let items = TrackEdit.playbackItems(try spans([BarRange(0, 4), BarRange(5, 10)]))
        #expect(items == [EditPlaybackItem(outputFrame: 0, frameCount: 20500, sourceFrame: 0)])
    }

    @Test func 인코더_지연만큼_원본을_당겨_읽는다() throws {
        // rekordbox 시간축이 음원보다 0.05초 늦다(MP3): 원본 프레임은 50 앞
        let items = TrackEdit.playbackItems(try spans([BarRange(1, 2), BarRange(1, 2)], offset: 0.05))
        #expect(items.map(\.sourceFrame) == [450, 4446, 450] && items[1].fade?.sourceFrame == 446)
    }

    @Test func 어디서든_시작하면_앞은_버리고_걸친_항목은_자른다() throws {
        let items = TrackEdit.playbackItems(try spans([BarRange(1, 2), BarRange(1, 2), BarRange(3, 10)]))
        #expect(items.starting(at: 0) == items)
        // 섞는 구간 가운데서 시작: 섞기 위치도 함께 민다
        #expect(items.starting(at: 3998) == [
            EditPlaybackItem(outputFrame: 3998, frameCount: 2, sourceFrame: 4498, fade: .init(sourceFrame: 498, position: 2, length: 4)),
            EditPlaybackItem(outputFrame: 4000, frameCount: 20000, sourceFrame: 500),
        ])
        #expect(items.starting(at: 10000) == [EditPlaybackItem(outputFrame: 10000, frameCount: 14000, sourceFrame: 6500)])
        #expect(items.starting(at: 24000).isEmpty && items.starting(at: 30000).isEmpty)
        // 음수는 처음부터
        #expect(items.starting(at: -10) == items)
    }

    @Test func 섞기_세기는_렌더러와_같다() {
        #expect(TrackEdit.crossfadeGain(0, of: 4) == 0.125 && TrackEdit.crossfadeGain(3, of: 4) == 0.875)
        #expect(TrackEdit.crossfadeGain(0, of: 0) == 1)
    }
}
