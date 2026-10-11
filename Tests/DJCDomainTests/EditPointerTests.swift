@testable import DJCDomain
import Foundation
import Testing

/// 편집 창 두 줄의 누르기·끌기 → 편집 동작(순수). 창 모델은 돌려준 동작을 차례로 한다.
@Suite("곡 편집 창 누르기·끌기")
struct EditPointerTests {
    /// 120 BPM(1마디 2초), 첫 다운비트 0.5초, 20.5초 = 0마디 + 10마디
    let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]

    func context(_ entries: [EditEntry] = [], selection: BarRange? = nil) throws -> EditPointerContext {
        let layout = try BarLayout(grid: grid, duration: 20.5)
        let bars = entries.map(\.range)
        let edit = bars.isEmpty ? nil : try? TrackEdit(grid: grid, sourceDuration: 20.5, bars: bars)
        return EditPointerContext(layout: layout, entries: entries, clips: edit?.clips ?? TrackEdit.place(bars, in: layout),
                                  selection: selection, hasEdit: edit != nil)
    }

    /// 출력 0~4, 4~8, 8~12초
    let three = [BarRange(1, 2), BarRange(5, 6), BarRange(9, 10)].map { EditEntry(id: UUID(), range: $0) }

    @Test func 원곡_줄_누르기와_끌기() throws {
        let context = try context()
        var pointer = EditPointer()
        // 파형을 조금만 움직였다 떼면 누르기: 재생선만 옮긴다
        #expect(pointer.source(context, from: 8.7, to: 8.8, inRuler: false, moved: 2) == [.focus(.source)])
        #expect(pointer.endSource(at: 8.8) == [.seek(.source, to: 8.8)] && pointer.mode == nil)
        // 끌면 마디 구간을 고르고, 떼면 재생선을 구간 처음에
        #expect(pointer.source(context, from: 4.4, to: 5, inRuler: false, moved: 3) == [.focus(.source)])
        #expect(pointer.source(context, from: 4.4, to: 8.6, inRuler: false, moved: 40) == [.select(from: 4.4, to: 8.6)])
        #expect(pointer.endSource(at: 10.4) == [.finishSelection])
        // 눈금을 끌면 재생선만(멈췄다가 손을 떼면 잇는다)
        #expect(pointer.source(context, from: 12, to: 12, inRuler: true, moved: 0) == [.scrub(.source, to: 12)])
        #expect(pointer.source(context, from: 12, to: 14, inRuler: true, moved: 20) == [.scrub(.source, to: 14)])
        #expect(pointer.endSource(at: 14) == [.endScrub])
    }

    @Test func 결과_줄_누르기와_클립_끌기() throws {
        let context = try context(three)
        let ids = three.map(\.id)
        var pointer = EditPointer()
        // 클립을 누르면 고르고 재생선을 그 자리로
        #expect(pointer.output(context, from: 5, to: 5, inRuler: false, moved: 0) == [.focus(.output)])
        #expect(pointer.endOutput(context, at: 5) == [.selectClip(ids[1]), .seek(.output, to: 5)])
        // 세 번째 클립(8~12초)을 맨 앞으로 끌어 놓는다. 끄는 동안 놓을 자리를 보여 준다.
        #expect(pointer.output(context, from: 10, to: 9.5, inRuler: false, moved: 3) == [.focus(.output)] && pointer.dragging == nil)
        #expect(pointer.output(context, from: 10, to: 1, inRuler: false, moved: 90).isEmpty)
        #expect(pointer.dragging == ids[2] && pointer.dropOffset == 0)
        #expect(pointer.endOutput(context, at: 1) == [.moveClip(ids[2], toOffset: 0)])
        #expect(pointer.dragging == nil && pointer.dropOffset == nil)
        // 빈 곳(결과 밖)을 누르면 고른 클립을 놓는다
        _ = pointer.output(context, from: 30, to: 30, inRuler: false, moved: 0)
        #expect(pointer.endOutput(context, at: 30) == [.selectClip(nil), .seek(.output, to: 30)])
        // 눈금은 재생선만
        #expect(pointer.output(context, from: 3, to: 7, inRuler: true, moved: 40) == [.scrub(.output, to: 7)])
        #expect(pointer.endOutput(context, at: 7) == [.endScrub])
    }

    @Test func 규칙에_맞지_않는_결과는_클립만_고르고_재생선은_두지_않는다() throws {
        let entries = [BarRange(1, 2), BarRange(0, 2)].map { EditEntry(id: UUID(), range: $0) }
        let context = try context(entries)
        #expect(!context.hasEdit && context.clips.count == 2)
        var pointer = EditPointer()
        _ = pointer.output(context, from: 1, to: 1, inRuler: false, moved: 0)
        #expect(pointer.endOutput(context, at: 1) == [.selectClip(entries[0].id)])
    }

    @Test func 결과_클립_가장자리를_끌어_마디_줄에_붙여_다듬는다() throws {
        let context = try context(three)
        let ids = three.map(\.id)
        var pointer = EditPointer()
        // 한 포인트 = 0.04초라 가장자리는 0.2초 안. 첫 클립 끝(4초) 바로 앞을 눌러 오른쪽으로 2.1초 끌면 3마디까지
        _ = pointer.output(context, from: 3.9, to: 3.9, inRuler: false, moved: 0, secondsPerPoint: 0.04)
        // 끄는 동안에는 목록을 바꾸지 않는다(손을 뗄 때 한 번에, 실행 취소 하나)
        #expect(pointer.output(context, from: 3.9, to: 6.0, inRuler: false, moved: 52, secondsPerPoint: 0.04).isEmpty)
        #expect(pointer.trimming == EditPointer.Trim(id: ids[0], clip: 0, edge: .end, range: BarRange(1, 3)) && pointer.dragging == nil)
        #expect(pointer.endOutput(context, at: 6.0) == [.trim(ids[0], to: BarRange(1, 3))] && pointer.trimming == nil)
        // 마지막 클립(8~12초)의 시작을 왼쪽으로 2.2초: 원곡 16.5 − 2.2 = 14.3초 → 8마디 시작(14.5초)
        _ = pointer.output(context, from: 8.1, to: 8.1, inRuler: false, moved: 0, secondsPerPoint: 0.04)
        _ = pointer.output(context, from: 8.1, to: 5.9, inRuler: false, moved: 55, secondsPerPoint: 0.04)
        #expect(pointer.endOutput(context, at: 5.9) == [.trim(ids[2], to: BarRange(8, 10))])
        // 가장자리를 눌렀다 떼기만 하면 클립 고르기와 재생선
        _ = pointer.output(context, from: 3.95, to: 3.96, inRuler: false, moved: 0.25, secondsPerPoint: 0.04)
        #expect(pointer.endOutput(context, at: 3.96) == [.selectClip(ids[0]), .seek(.output, to: 3.96)])
        // 가운데를 끌면 그대로 순서 바꾸기
        _ = pointer.output(context, from: 6, to: 6, inRuler: false, moved: 0, secondsPerPoint: 0.04)
        _ = pointer.output(context, from: 6, to: 1, inRuler: false, moved: 125, secondsPerPoint: 0.04)
        #expect(pointer.dragging == ids[1] && pointer.trimming == nil)
        #expect(pointer.endOutput(context, at: 1) == [.moveClip(ids[1], toOffset: 0)])
    }

    @Test func 원곡에서_고른_구간을_결과의_원하는_자리로_끌어_넣는다() throws {
        // 원곡에서 3~4마디(4.5~8.5초)를 고른 상태
        let context = try context(three, selection: BarRange(3, 4))
        var pointer = EditPointer()
        // 고른 구간 안을 눌러 아래(결과 쪽)로 끌면 넣기. 결과 위를 지나는 동안 놓을 자리를 보여 준다
        #expect(pointer.source(context, from: 6, to: 6.1, inRuler: false, moved: 2, rise: 6) == [.preview(nil)] && pointer.mode == .carry)
        let insertion = EditInsertion(offset: 2, range: BarRange(3, 4))
        #expect(pointer.source(context, from: 6, to: 6.3, inRuler: false, moved: 8, rise: 120, output: 7) == [.preview(insertion)])
        #expect(pointer.endSource(at: 6.3) == [.insert(insertion), .preview(nil)] && pointer.mode == nil)
        // 결과 밖에서 놓으면 넣지 않는다
        _ = pointer.source(context, from: 5, to: 5, inRuler: false, moved: 0, rise: 10)
        #expect(pointer.source(context, from: 5, to: 5, inRuler: false, moved: 0, rise: 30, output: nil) == [.preview(nil)])
        #expect(pointer.endSource(at: 5) == [.preview(nil)])
        // 고른 구간 밖에서 아래로 끌면 누르기(재생선), 안에서 옆으로 끌면 예전처럼 새로 고르기
        #expect(pointer.source(context, from: 12, to: 12.2, inRuler: false, moved: 1, rise: 20) == [.focus(.source)])
        #expect(pointer.endSource(at: 12.2) == [.seek(.source, to: 12.2)])
        #expect(pointer.source(context, from: 6, to: 10.4, inRuler: false, moved: 60, rise: 2) == [.select(from: 6, to: 10.4)])
        #expect(pointer.endSource(at: 10.4) == [.finishSelection])
    }

    @Test func 다듬은_구간은_곡_머리는_맨_앞에만_곡_끝은_맨_뒤에만() throws {
        let context = try context(three)
        // 첫 클립 시작을 왼쪽으로 끌면 곡 머리(0마디)까지, 가운데 클립은 1마디까지
        #expect(context.trimmed(three[0].id, edge: .start, by: -10) == BarRange(0, 2))
        #expect(context.trimmed(three[1].id, edge: .start, by: -20) == BarRange(1, 6))
        #expect(context.trimmed(UUID(), edge: .start, by: 1) == nil)
        #expect(context.selectionContains(5) == false)
        #expect(try self.context(three, selection: BarRange(3, 4)).selectionContains(5))
    }
}
