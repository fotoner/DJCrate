@testable import DJCrate
import AppKit
import Testing

@Suite("목록 글자 높이 재사용")
@MainActor
struct TrackTextHeightTests {
    @Test func 같은_글자와_글꼴이면_높이를_한_번만_잰다() {
        var height = TrackTextHeight()
        var measurements = 0
        let font = NSFont.systemFont(ofSize: 13)
        for _ in 0..<10 {
            #expect(height.height(text: "합성 곡 🎵", font: font) {
                measurements += 1
                return 17
            } == 17)
        }
        #expect(measurements == 1)
    }

    @Test func 글자와_글꼴이_바뀌면_다시_잰다() {
        var height = TrackTextHeight()
        var measurements = 0
        func measure() -> CGFloat { measurements += 1; return CGFloat(measurements) }
        let font = NSFont.systemFont(ofSize: 13)
        #expect(height.height(text: "합성 곡", font: font, measure: measure) == 1)
        #expect(height.height(text: "🎵", font: font, measure: measure) == 2)
        #expect(height.height(text: "🎵", font: .systemFont(ofSize: 20), measure: measure) == 3)
        #expect(height.height(text: "🎵", font: .systemFont(ofSize: 20), measure: measure) == 3)
        #expect(measurements == 3)
    }

    @Test func backing이_바뀌어_무효화하면_같은_글자도_다시_잰다() {
        var height = TrackTextHeight()
        var measurements = 0
        func measure() -> CGFloat { measurements += 1; return CGFloat(measurements) }
        #expect(height.height(text: "합성 곡", font: nil, measure: measure) == 1)
        #expect(height.height(text: "합성 곡", font: nil, measure: measure) == 1)
        height.invalidate()
        #expect(height.height(text: "합성 곡", font: nil, measure: measure) == 2)
        #expect(measurements == 2)
    }

    @Test func 셀의_폭만_바꾸면_높이를_다시_재지_않고_같은_프레임도_다시_쓰지_않는다() {
        let label = MeasuringLabel(labelWithString: "")
        let cell = TrackTextCell(label: label)
        cell.set("합성 곡", color: .labelColor)
        cell.frame = .init(x: 0, y: 0, width: 220, height: 24)
        cell.layout()
        let measurements = label.measurements
        for width: CGFloat in [90, 400, 220] {
            cell.setFrameSize(.init(width: width, height: 24))
            cell.layout()
            #expect(label.alignmentRect(forFrame: label.frame).maxX == width - 2)
        }
        #expect(label.measurements == measurements)
        let assignments = label.frameAssignments
        cell.layout()
        cell.layout()
        #expect(label.frameAssignments == assignments)
    }

    @Test func 셀에서_글자와_글꼴과_backing과_편집_상태가_바뀌면_높이를_다시_잰다() {
        let label = MeasuringLabel(labelWithString: "")
        let cell = TrackTextCell(label: label)
        cell.frame = .init(x: 0, y: 0, width: 220, height: 36)
        cell.set("합성 곡", color: .labelColor)
        cell.layout()
        let measurements = label.measurements
        cell.set("🎵", color: .labelColor)
        cell.layout()
        #expect(label.measurements == measurements + 1)
        cell.fonts = .init(scale: 1.5)
        cell.set("🎵", color: .labelColor)
        cell.layout()
        #expect(label.measurements == measurements + 2)
        label.measuredHeight = 23
        cell.viewDidChangeBackingProperties()
        cell.layout()
        #expect(label.measurements == measurements + 3)
        #expect(label.frame.height == 23)
        let field = cell.beginEditing(text: "편집 중", placeholder: nil)
        #expect(label.measurements == measurements + 4)
        field.font = .systemFont(ofSize: 25)
        cell.layout()
        #expect(field.frame.height == field.intrinsicContentSize.height)
        cell.endEditing()
        cell.layout()
        #expect(label.measurements == measurements + 5)
        #expect(!label.isHidden && field.superview == nil)
    }

    @Test(arguments: [15, 16, 17])
    func 홀수_픽셀_높이도_픽셀에_맞춰_가운데에_둔다(heightInPixels: Int) {
        let label = MeasuringLabel(labelWithString: "")
        let cell = TrackTextCell(label: label)
        cell.frame = .init(x: 0, y: 0, width: 220, height: 36)
        label.measuredHeight = cell.convertFromBacking(.init(width: 0, height: CGFloat(heightInPixels))).height
        cell.set("", color: .labelColor)
        cell.layout()
        #expect(label.frame.height == label.measuredHeight)
        expectPixelAlignedCenter(cell)
    }

    @Test(arguments: ["合成曲 🎵", "합성 곡", "", "Synthetic title"])
    func 실제_글자_높이와_정렬을_보존한다(text: String) {
        let cell = TrackTextCell()
        cell.frame = .init(x: 0, y: 0, width: 220, height: 36)
        for scale in [1.0, 1.5, 0.85] {
            cell.fonts = .init(scale: scale)
            cell.set(text, color: .labelColor)
            cell.layout()
            #expect(cell.label.frame.height == cell.label.intrinsicContentSize.height)
            expectPixelAlignedCenter(cell)
        }
    }

    private func expectPixelAlignedCenter(_ cell: TrackTextCell) {
        let frame = cell.convertToBacking(cell.label.frame)
        // 홀수 픽셀 높이는 양끝을 픽셀에 맞추면 중심이 최대 반 픽셀 옮겨진다.
        #expect(abs(frame.midY - cell.convertToBacking(cell.bounds).midY) <= 0.5)
        #expect(frame.minY == frame.minY.rounded())
        #expect(frame.maxY == frame.maxY.rounded())
    }
}

@MainActor
private final class MeasuringLabel: NSTextField {
    var measurements = 0
    var frameAssignments = 0
    var measuredHeight: CGFloat = 17

    override var intrinsicContentSize: NSSize {
        measurements += 1
        return .init(width: 100, height: measuredHeight)
    }

    override var frame: NSRect {
        get { super.frame }
        set {
            frameAssignments += 1
            super.frame = newValue
        }
    }
}
