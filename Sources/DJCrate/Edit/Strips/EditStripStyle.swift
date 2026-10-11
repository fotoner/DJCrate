import DJCDomain
import SwiftUI

/// 편집 창의 구간 색(늘 어두운 파형 위·클립 번호 배지). 이웃한 구간이 잘 갈리게 황금각으로 돌린다.
enum EditColors {
    static func entry(_ index: Int) -> Color {
        Color(hue: (0.55 + Double(index) * 0.618).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.97)
    }

    static let seam = Color.white
    /// 원곡에서 끌어 고른 구간(늘 어두운 파형 위)
    static let selection = Color(red: 0.35, green: 0.80, blue: 1.0)
}

/// 두 줄이 함께 쓰는 치수
enum EditMetrics {
    /// 위 눈금 띠. 누르거나 끌면 재생선만 옮긴다(아래 파형은 고르기·클립 조작).
    static let ruler: CGFloat = 16
    /// 편집 창 좌표 이름(원곡 줄에서 결과 줄로 끌어 넣을 때 두 줄 자리를 맞춘다)
    static let space = "trackEdit"
}

/// 마디 눈금: 폭에 맞춰 1·4·8·16…마디마다 번호를 적는다.
func drawBarRuler(_ context: GraphicsContext, layout: BarLayout, bars: ClosedRange<Int>, x: (Double) -> CGFloat,
                          height: CGFloat, width: CGFloat) {
    let pixelsPerBar = max(0.1, Double(x(layout.start(ofBar: 2)) - x(layout.start(ofBar: 1))))
    let step: Int = [1, 2, 4, 8, 16, 32, 64, 128].first(where: { Double($0) * pixelsPerBar >= 28 }) ?? 256
    context.fill(Path(CGRect(x: 0, y: 0, width: width, height: height)), with: .color(.white.opacity(0.05)))
    for bar in bars where bar >= 1 {
        let px = x(layout.start(ofBar: bar))
        let labeled = (bar - 1) % step == 0
        guard labeled || pixelsPerBar >= 4 else { continue }
        var tick = Path()
        tick.move(to: CGPoint(x: px, y: 0))
        tick.addLine(to: CGPoint(x: px, y: labeled ? 7 : 3))
        context.stroke(tick, with: .color(Palette.rulerText.opacity(labeled ? 0.9 : 0.4)), lineWidth: 1)
        if labeled, px < width - 8 {
            context.draw(Text(verbatim: "\(bar)").font(.system(size: 9).monospacedDigit()).foregroundStyle(Palette.rulerText),
                         at: CGPoint(x: px + 2, y: height), anchor: .bottomLeading)
        }
    }
}

/// 줄 테두리: 스페이스바·←→가 움직이는 줄은 강조색으로 두른다.
struct LaneFrame: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .background(Palette.well)
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2))
    }
}

// MARK: - 재생선

/// 재생선(재생 중에만 초당 30번 다시 그린다). 누르지 않는다.
struct EditPlayhead: View {
    let model: TrackEditModel
    let lane: TrackEditModel.Lane

    var body: some View {
        if model.playing == lane {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in line(model.position(lane)) }
        } else {
            line(model.position(lane))
        }
    }

    private func line(_ time: Double) -> some View {
        let view = model.viewport(lane), length = model.extent(lane)
        return Canvas { context, size in
            guard length > 0 else { return }
            let px = CGFloat(view.x(of: time, width: Double(size.width), length: length))
            guard px >= -6, px <= size.width + 6 else { return }
            context.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(Palette.cue))
            var head = Path()
            head.move(to: CGPoint(x: px - 5, y: 0))
            head.addLine(to: CGPoint(x: px + 5, y: 0))
            head.addLine(to: CGPoint(x: px, y: 7))
            head.closeSubpath()
            context.fill(head, with: .color(Palette.cue))
        }
        .allowsHitTesting(false)
    }
}

/// 보이는 자리의 마디(눈금은 이것만 그린다)
func visibleBars(_ layout: BarLayout, _ visible: ClosedRange<Double>) -> ClosedRange<Int> {
    let first = max(1, layout.bar(at: visible.lowerBound))
    return first...max(first, min(max(1, layout.count), layout.bar(at: visible.upperBound) + 1))
}
