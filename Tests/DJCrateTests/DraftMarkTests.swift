@testable import DJCrate
import AppKit
import DJCDomain
import Testing

/// 초안·큐를 색만이 아니라 모양과 VoiceOver 글자로도 알린다(#34).
@Suite("초안 표식·큐 모양")
struct DraftMarkTests {
    // MARK: 태그 시트 칸

    @Test func 초안_칸은_모서리_표식과_VoiceOver_값으로도_알린다() {
        let draft = SheetCellAppearance(edited: true, readOnly: false, selected: false, editing: false)
        #expect(draft.tone == .draft)
        #expect(draft.showsDraftMark)
        #expect(draft.accessibilityValue(for: "새 제목") == "새 제목, 초안")
    }

    /// 선택하면 글자색이 기본색으로 바뀌어 색으로는 알 수 없다. 모양과 VoiceOver 값은 남긴다.
    @Test func 선택한_초안_칸도_표식이_남는다() {
        let selected = SheetCellAppearance(edited: true, readOnly: false, selected: true, editing: false)
        #expect(selected.tone == .primary)
        #expect(selected.showsDraftMark)
        #expect(selected.accessibilityValue(for: "새 제목") == "새 제목, 초안")
    }

    /// 입력 중에는 칸 값을 VoiceOver가 그대로 읽어야 한다(값을 덮으면 입력한 글자를 못 듣는다).
    @Test func 편집_중에는_칸_값을_덮지_않는다() {
        let editing = SheetCellAppearance(edited: true, readOnly: false, selected: true, editing: true)
        #expect(editing.tone == .draft)
        #expect(editing.accessibilityValue(for: "새 제목") == nil)
    }

    @Test func 초안이_아니면_표식도_값도_없다() {
        let plain = SheetCellAppearance(edited: false, readOnly: false, selected: false, editing: false)
        #expect(plain.tone == .primary)
        #expect(!plain.showsDraftMark)
        #expect(plain.accessibilityValue(for: "제목") == nil)
        #expect(SheetCellAppearance(edited: false, readOnly: true, selected: false, editing: false).tone == .secondary)
    }

    @MainActor
    @Test func 시트_칸은_초안을_모양과_값으로_보인다() {
        func spoken(_ cell: SheetCell) -> String? {
            let value = cell.label.accessibilityValue()
            return value
        }
        let cell = SheetCell()
        cell.configure(text: "새 제목", edited: true, readOnly: false, selected: true, active: true)
        #expect(cell.showsDraftMark)
        #expect(spoken(cell) == "새 제목, 초안")
        cell.configure(text: "제목", edited: false, readOnly: false, selected: false, active: false)
        #expect(!cell.showsDraftMark)
        #expect(spoken(cell) == "제목")
    }

    // MARK: 전체 파형 큐

    /// 메모리 큐 삼각형은 CUE 지점 삼각형(위쪽 0~8pt) 아래에 둔다.
    @Test func 메모리_큐_삼각형은_CUE_삼각형과_겹치지_않는다() {
        #expect(OverviewCueMarks.memoryTriangle.lowerBound > OverviewCueMarks.cueTriangleHeight)
        #expect(OverviewCueMarks.memoryTriangle.upperBound < 52 - WaveformMetrics().overviewChipHeight)
    }

    @Test func 핫큐만_슬롯_글자_칩을_받는다() {
        let cues = [EditableCue(kind: .memory, time: 10), EditableCue(kind: .hot(0), time: 30),
                    EditableCue(kind: .hot(3), time: 90, loop: .init(end: 92))]
        let chips = OverviewCueMarks.chips(for: cues, xOf: { $0 * 4 }, metrics: WaveformMetrics())
        #expect(chips.map(\.letter) == ["A", "D"])
        #expect(chips.map(\.loop) == [false, true])
        #expect(chips.map(\.x) == [120, 360])
    }

    /// 칩이 겹치면 왼쪽 것만 남긴다(글자를 줄이지 않는다). 선은 그대로라 위치는 보인다.
    @Test func 겹치는_칩은_뺀다() {
        let cues = [EditableCue(kind: .hot(1), time: 30), EditableCue(kind: .hot(0), time: 31), EditableCue(kind: .hot(2), time: 60)]
        let chips = OverviewCueMarks.chips(for: cues, xOf: { $0 * 4 }, metrics: WaveformMetrics())
        #expect(chips.map(\.letter) == ["B", "C"])
    }

    @Test func 개요_칩은_10pt_글자에_맞춘_높이다() {
        #expect(WaveformMetrics().overviewChipHeight == 12)
        #expect(WaveformMetrics(scale: 1.5).overviewChipHeight >= WaveformMetrics(scale: 1.5).labelSize + 2)
    }

    // MARK: 색 이름

    /// 초안과 경고는 같은 계열 주황이라 모양으로 나눈다: 초안은 pencil, 경고는 exclamationmark.triangle.
    @Test func 초안과_경고는_다른_모양을_쓴다() {
        #expect(DraftMark.symbol.hasPrefix("pencil"))
        #expect(WarningMark.symbol.hasPrefix("exclamationmark.triangle"))
        #expect(DraftMark.spoken == "초안")
    }
}
