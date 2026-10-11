@testable import DJCDomain
import Foundation
import Testing

@Suite("곡 편집 타임라인: 끌어 고르기·자르기·옮기기·마디 이동")
struct EditTimelineTests {
    /// 120 BPM(1마디 2초), 첫 다운비트 0.5초
    let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    // MARK: - 원곡에서 끌어 고르기

    @Test func 끌어서_고른_구간은_가까운_마디_줄에_붙는다() throws {
        let bars = try BarLayout(grid: grid, duration: 100.5)
        // 32.4초 → 17마디 시작(32.5초), 64.7초 → 33마디 시작(64.5초): 17~32마디
        #expect(bars.selection(from: 32.4, to: 64.7) == BarRange(17, 32))
        // 거꾸로 끌어도 같다
        #expect(bars.selection(from: 64.7, to: 32.4) == BarRange(17, 32))
        // 한 마디 안에서 조금만 끌면 그 마디 하나
        #expect(bars.selection(from: 33.0, to: 33.3) == BarRange(17, 17))
        #expect(bars.selection(from: 33.0, to: 33.0) == BarRange(17, 17))
    }

    @Test func 곡_머리와_곡_끝까지_고를_수_있다() throws {
        let bars = try BarLayout(grid: grid, duration: 100.5)
        // 곡 시작 쪽이 가까우면 곡 머리(0마디)부터
        #expect(bars.selection(from: 0.1, to: 8.4) == BarRange(0, 4))
        // 곡 끝(마지막 마디 끝)까지, 곡 밖으로 끌어도 곡 안으로
        #expect(bars.selection(from: 90.0, to: 100.5) == BarRange(46, 50))
        #expect(bars.selection(from: 90.0, to: 130) == BarRange(46, 50))
        #expect(bars.selection(from: -5, to: 2.4) == BarRange(0, 1))
        // 끝에서 잘린 마지막 마디는 곡 끝이 그 마디의 끝이다
        let cut = try BarLayout(grid: grid, duration: 101.5)
        #expect(cut.selection(from: 95, to: 101.5) == BarRange(48, 51))
        #expect(cut.selection(from: 101.2, to: 101.4) == BarRange(51, 51))
        // 곡 머리가 없는 곡은 1마디부터
        let flush = try BarLayout(grid: [GridSegment(start: 0, bpm: 120, firstBeatNumber: 1)], duration: 60)
        #expect(flush.selection(from: 0, to: 3.9) == BarRange(1, 2))
    }

    @Test func 곡_머리는_맨_앞에_넣을_때만_살린다() {
        #expect(BarRange(0, 16).fitted(leading: true) == BarRange(0, 16))
        #expect(BarRange(0, 16).fitted(leading: false) == BarRange(1, 16))
        // 곡 머리뿐이면 뒤에 넣을 마디가 없다
        #expect(BarRange(0, 0).fitted(leading: false) == nil)
        #expect(BarRange(0, 0).fitted(leading: true) == BarRange(0, 0))
        #expect(BarRange(5, 8).fitted(leading: false) == BarRange(5, 8))
    }

    // MARK: - 결과 타임라인의 클립

    @Test func 목록_구간마다_출력_자리를_합치지_않고_센다() throws {
        // 0-2와 3-4는 원본에서 이어져 한 조각이지만 클립은 둘이다
        let edit = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: [BarRange(0, 2), BarRange(3, 4), BarRange(1, 2)])
        #expect(edit.pieces.count == 2 && edit.clips.map(\.bars) == [BarRange(0, 2), BarRange(3, 4), BarRange(1, 2)])
        #expect(edit.clips.map(\.outputStart) == [0, 4.5, 8.5] && edit.clips.map(\.outputEnd) == [4.5, 8.5, 12.5])
        #expect(near(edit.clips[1].sourceStart, 4.5) && near(edit.clips[1].sourceEnd, 8.5))
        // 끝에서 잘린 마지막 마디가 든 클립은 그 길이만큼
        let cut = try TrackEdit(grid: grid, sourceDuration: 21.5, bars: [BarRange(1, 2), BarRange(10, 11)])
        #expect(near(cut.clips[1].outputStart, 4) && near(cut.clips[1].outputEnd, 7) && near(cut.duration, 7))
    }

    @Test func 규칙에_맞지_않는_목록도_화면에_놓는다() throws {
        let bars = try BarLayout(grid: grid, duration: 20.5)
        // 가운데 곡 머리는 렌더할 수 없지만 고칠 수 있게 클립 자리는 준다(곡 머리는 빼고 마디만)
        let clips = TrackEdit.place([BarRange(1, 2), BarRange(0, 2)], in: bars)
        #expect(clips.map(\.outputStart) == [0, 4] && clips.map(\.outputEnd) == [4, 8])
        #expect(clips.clipIndex(atOutput: 5) == 1 && clips.dropOffset(atOutput: 7) == 2)
        #expect(TrackEdit.place([], in: bars).isEmpty)
    }

    @Test func 출력_시각이_든_클립을_찾는다() throws {
        let edit = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: [BarRange(0, 2), BarRange(3, 4), BarRange(1, 2)])
        #expect(edit.clipIndex(atOutput: 0) == 0 && edit.clipIndex(atOutput: 4.4) == 0)
        #expect(edit.clipIndex(atOutput: 4.5) == 1 && edit.clipIndex(atOutput: 12.4) == 2)
        // 끝(재생이 멈춘 자리)은 마지막 클립, 밖은 없음
        #expect(edit.clipIndex(atOutput: 12.5) == 2 && edit.clipIndex(atOutput: 13) == nil && edit.clipIndex(atOutput: -0.1) == nil)
    }

    @Test func 끌어서_놓을_자리는_클립_가운데를_지난_수다() throws {
        // 클립 가운데: 2.25, 6.5, 10.5
        let edit = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: [BarRange(0, 2), BarRange(3, 4), BarRange(1, 2)])
        #expect([-1, 1, 3, 7, 12, 99].map { edit.dropOffset(atOutput: $0) } == [0, 0, 1, 2, 3, 3])
    }

    // MARK: - 자르기

    @Test func 마디_구간을_둘로_나눈다() {
        #expect(BarRange(1, 8).split(at: 4) == [BarRange(1, 3), BarRange(4, 8)])
        #expect(BarRange(1, 8).split(at: 8) == [BarRange(1, 7), BarRange(8, 8)])
        #expect(BarRange(0, 8).split(at: 2) == [BarRange(0, 1), BarRange(2, 8)])
        // 구간 끝·밖, 곡 머리만 떼는 자르기는 없다(0마디는 1마디와 붙어 있다)
        for bar in [1, 9, 0, -1] { #expect(BarRange(1, 8).split(at: bar) == nil) }
        #expect(BarRange(0, 8).split(at: 1) == nil && BarRange(5, 5).split(at: 5) == nil)
    }

    @Test func 재생선에서_가장_가까운_마디_줄로_자른다() throws {
        let edit = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: [BarRange(1, 8)])
        // 5.2초 → 6.0초(4마디 시작)
        #expect(edit.split(atOutput: 5.2) == EditSplit(clip: 0, bar: 4, outputTime: 6))
        #expect(edit.split(atOutput: 6.9) == EditSplit(clip: 0, bar: 4, outputTime: 6))
        // 클립 끝이 가장 가까우면 자를 곳이 없다
        #expect(edit.split(atOutput: 0.9) == nil && edit.split(atOutput: 15.5) == nil && edit.split(atOutput: 20) == nil)
        // 곡 머리가 든 클립: 1마디는 0.5초 뒤부터
        let lead = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: [BarRange(0, 4), BarRange(1, 4)])
        #expect(lead.split(atOutput: 2.3) == EditSplit(clip: 0, bar: 2, outputTime: 2.5))
        #expect(lead.split(atOutput: 0.6) == nil)
        // 뒤 클립(8.5초부터)은 그 클립 안에서 센다
        #expect(lead.split(atOutput: 12.3) == EditSplit(clip: 1, bar: 3, outputTime: 12.5))
        // 1마디짜리는 자를 수 없다
        let one = try TrackEdit(grid: grid, sourceDuration: 20.5, bars: [BarRange(5, 5)])
        #expect(one.split(atOutput: 1) == nil)
    }

    @Test func 끝에서_잘린_마지막_마디_앞도_자를_수_있다() throws {
        // 21.5초: 11마디는 1초뿐
        let edit = try TrackEdit(grid: grid, sourceDuration: 21.5, bars: [BarRange(9, 11)])
        #expect(edit.split(atOutput: 3.9) == EditSplit(clip: 0, bar: 11, outputTime: 4))
        let parts = try #require(edit.clips[0].bars.split(at: 11))
        #expect(try TrackEdit(grid: grid, sourceDuration: 21.5, bars: parts).duration == edit.duration)
    }

    // MARK: - 마디 단위 이동(←→)

    @Test func 앞뒤_마디_줄로_옮긴다() throws {
        let bars = try BarLayout(grid: grid, duration: 100.5)
        #expect(bars.step(from: 0, by: 1) == 0.5 && bars.step(from: 0.5, by: 1) == 2.5 && bars.step(from: 1.7, by: 1) == 2.5)
        #expect(bars.step(from: 3.0, by: -1) == 2.5 && bars.step(from: 2.5, by: -1) == 0.5 && bars.step(from: 0.5, by: -1) == 0)
        // 여러 마디, 곡 끝·앞에서 멈춤
        #expect(bars.step(from: 0.5, by: 4) == 8.5 && bars.step(from: 100, by: 1) == 100.5 && bars.step(from: 100.5, by: 1) == 100.5)
        #expect(bars.step(from: 0, by: -1) == 0)
    }

    // MARK: - 클립 가장자리 다듬기(#134)

    @Test func 가장자리를_끌면_가까운_마디_줄에_붙여_다듬는다() throws {
        // 0마디 0~0.5초, 1마디 0.5~2.5초 … 10마디 18.5~20.5초. 3~6마디 = 원곡 4.5~12.5초
        let bars = try BarLayout(grid: grid, duration: 20.5)
        let range = BarRange(3, 6)
        func trim(_ edge: EditEdge, _ seconds: Double, leading: Bool = false, trailing: Bool = false) -> BarRange {
            bars.trimmed(range, edge: edge, by: seconds, leading: leading, trailing: trailing)
        }
        // 끝: 12.5 + 1.2 = 13.7초 → 14.5초(8마디 시작) 줄이 가깝다 → 7마디까지. 반 마디를 못 넘으면 그대로
        #expect(trim(.end, 1.2) == BarRange(3, 7) && trim(.end, 0.9) == range && trim(.end, 0) == range)
        #expect(trim(.end, -3.1) == BarRange(3, 4))
        // 시작: 4.5 + 2.1 = 6.6초 → 4마디 시작(6.5초), 4.5 − 3.9 = 0.6초 → 1마디 시작
        #expect(trim(.start, 2.1) == BarRange(4, 6) && trim(.start, -3.9) == BarRange(1, 6))
        // 적어도 1마디를 남기고, 곡 끝·곡 앞에서 멈춘다
        #expect(trim(.end, -100) == BarRange(3, 3) && trim(.start, 100) == BarRange(6, 6))
        #expect(trim(.end, 100) == BarRange(3, 10) && trim(.start, -100) == BarRange(1, 6))
        // 곡 머리(0마디)는 맨 앞 클립만 가진다
        #expect(trim(.start, -100, leading: true) == BarRange(0, 6))
    }

    @Test func 곡_머리와_끝에서_잘린_마디는_맨_앞_맨_뒤_클립만_가진다() throws {
        let bars = try BarLayout(grid: grid, duration: 20.5)
        // 곡 머리가 든 맨 앞 클립: 0.3초 넘게 밀면(1마디 시작 0.5초가 더 가깝다) 곡 머리를 뺀다
        #expect(bars.trimmed(BarRange(0, 4), edge: .start, by: 0.2, leading: true, trailing: false) == BarRange(0, 4))
        #expect(bars.trimmed(BarRange(0, 4), edge: .start, by: 0.3, leading: true, trailing: false) == BarRange(1, 4))
        // 21.5초: 11마디(20.5~21.5초)는 끝에서 잘려 맨 뒤 클립만 가진다
        let cut = try BarLayout(grid: grid, duration: 21.5)
        #expect(cut.trimmed(BarRange(8, 10), edge: .end, by: 5, leading: false, trailing: true) == BarRange(8, 11))
        #expect(cut.trimmed(BarRange(8, 10), edge: .end, by: 5, leading: false, trailing: false) == BarRange(8, 10))
        #expect(cut.trimmed(BarRange(8, 11), edge: .end, by: -1.2, leading: false, trailing: true) == BarRange(8, 10))
    }

    @Test func 누른_자리의_클립_가장자리를_찾는다() throws {
        let bars = try BarLayout(grid: grid, duration: 20.5)
        // 클립 0~4, 4~8, 8~12초
        let clips = TrackEdit.place([BarRange(1, 2), BarRange(5, 6), BarRange(9, 10)], in: bars)
        func hit(_ time: Double, _ tolerance: Double = 0.2) -> EditEdgeHit? { clips.edge(atOutput: time, tolerance: tolerance) }
        #expect(hit(0.1) == EditEdgeHit(clip: 0, edge: .start) && hit(-0.1) == EditEdgeHit(clip: 0, edge: .start))
        // 두 클립이 맞닿은 줄: 누른 쪽 클립(줄 위는 뒤 클립의 시작)
        #expect(hit(3.9) == EditEdgeHit(clip: 0, edge: .end) && hit(4) == EditEdgeHit(clip: 1, edge: .start))
        #expect(hit(4.1) == EditEdgeHit(clip: 1, edge: .start) && hit(12.1) == EditEdgeHit(clip: 2, edge: .end))
        #expect(hit(6) == nil && hit(12.5) == nil && hit(-0.5) == nil && hit(3.9, 0) == nil)
        // 좁게 보이는 클립은 가운데 절반을 옮기기로 남긴다(가장자리는 클립 길이의 ¼까지)
        #expect(hit(4.9, 3) == EditEdgeHit(clip: 1, edge: .start) && hit(7.1, 3) == EditEdgeHit(clip: 1, edge: .end) && hit(5.5, 3) == nil)
        #expect([TrackEdit.Piece]().edge(atOutput: 0, tolerance: 1) == nil)
    }

    // MARK: - 원곡 구간을 끌어 넣기(#134)

    @Test func 끌어_넣을_자리는_클립_가운데를_지난_수다() throws {
        let bars = try BarLayout(grid: grid, duration: 20.5)
        // 클립 0~4, 4~8, 8~12초(가운데 2, 6, 10초)
        let clips = TrackEdit.place([BarRange(1, 2), BarRange(5, 6), BarRange(9, 10)], in: bars)
        #expect(clips.insertion(of: BarRange(3, 4), atOutput: 1) == EditInsertion(offset: 0, range: BarRange(3, 4)))
        #expect(clips.insertion(of: BarRange(3, 4), atOutput: 7) == EditInsertion(offset: 2, range: BarRange(3, 4)))
        #expect(clips.insertion(of: BarRange(3, 4), atOutput: 30) == EditInsertion(offset: 3, range: BarRange(3, 4)))
        // 곡 머리는 맨 앞에 놓을 때만 살린다. 곡 머리뿐이면 맨 앞이 아닌 자리에 넣을 마디가 없다
        #expect(clips.insertion(of: BarRange(0, 4), atOutput: 1) == EditInsertion(offset: 0, range: BarRange(0, 4)))
        #expect(clips.insertion(of: BarRange(0, 4), atOutput: 7) == EditInsertion(offset: 2, range: BarRange(1, 4)))
        #expect(clips.insertion(of: BarRange(0, 0), atOutput: 7) == nil)
        // 빈 결과에는 맨 앞
        #expect([TrackEdit.Piece]().insertion(of: BarRange(0, 4), atOutput: 3) == EditInsertion(offset: 0, range: BarRange(0, 4)))
    }

    @Test func 곡_머리로_시작하는_결과의_맨_앞에는_넣지_않는다() throws {
        let bars = try BarLayout(grid: grid, duration: 20.5)
        // 곡 머리는 맨 앞에만 있어야 해서 그 클립 뒤에 넣는다
        let clips = TrackEdit.place([BarRange(0, 2), BarRange(5, 6)], in: bars)
        #expect(clips.insertion(of: BarRange(3, 4), atOutput: 0.2) == EditInsertion(offset: 1, range: BarRange(3, 4)))
        #expect(clips.insertion(of: BarRange(0, 4), atOutput: 0.2) == EditInsertion(offset: 1, range: BarRange(1, 4)))
    }
}
