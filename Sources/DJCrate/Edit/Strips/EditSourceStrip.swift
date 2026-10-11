import DJCDomain
import SwiftUI

// MARK: - 원곡 줄

/// 원곡: 눈금·파형·결과에 쓴 구간·끌어 고른 구간·재생선. 확대하면 보이는 자리만 그린다.
/// 위 눈금을 누르거나 끌면 재생선, 파형을 누르면 재생선, 옆으로 끌면 마디 구간 고르기, 고른 구간을 아래로 끌면 결과에 넣기.
struct EditSourceStrip: View {
    let model: TrackEditModel
    /// 결과 줄 자리(이 줄 좌표). 고른 구간을 끌어 놓을 자리를 찾는다.
    let outputFrame: CGRect
    @State private var pointer: EditPointer

    /// - Parameter pointer: 처음 누르기·끌기 상태(끄는 중 모습을 캡처할 때)
    init(model: TrackEditModel, outputFrame: CGRect = .zero, pointer: EditPointer = EditPointer()) {
        self.model = model
        self.outputFrame = outputFrame
        _pointer = State(initialValue: pointer)
    }

    var body: some View {
        GeometryReader { geo in
            let scale = EditLaneScale(model, .source, width: geo.size.width)
            let output = { (point: CGPoint) -> Double? in
                guard outputFrame.width > 0, outputFrame.contains(point) else { return nil }
                return EditLaneScale(model, .output, width: outputFrame.width).time(point.x - outputFrame.minX)
            }
            ZStack {
                EditSourceLayer(model: model, scale: scale)
                EditSelectionLayer(model: model, scale: scale, carrying: pointer.mode == .carry)
                EditPlayhead(model: model, lane: .source)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                model.apply(pointer.source(model.pointerContext, from: scale.time(value.startLocation.x), to: scale.time(value.location.x),
                                           inRuler: value.startLocation.y < EditMetrics.ruler, moved: abs(value.translation.width),
                                           rise: abs(value.translation.height), output: output(value.location)))
            }.onEnded { value in
                model.apply(pointer.endSource(at: scale.time(value.location.x)))
            })
        }
        .modifier(LaneZoomGestures(model: model, lane: .source))
        .modifier(LaneFrame(focused: model.focus == .source))
        .selfTestFrame("editSource")
        .accessibilityElement()
        .accessibilityLabel(.ui("원곡 파형"))
        .accessibilityValue(model.selection.map { String(ui: "고른 구간 마디 \($0.description)") } ?? String(ui: "고른 구간 없음"))
        .accessibilityHint(.ui("끌어서 마디 구간을 고르고, 눌러서 재생선을 옮깁니다. 고른 구간을 아래로 끌면 결과에 넣습니다"))
        .laneZoomAction(model, .source)
    }
}

/// 파형·눈금·결과에 쓴 구간(재생 위치·고르기를 읽지 않아 끄는 동안 다시 그리지 않는다)
private struct EditSourceLayer: View {
    let model: TrackEditModel
    let scale: EditLaneScale

    var body: some View {
        let entries = model.entries
        let scale = scale
        Canvas { context, size in
            let x = { (t: Double) in scale.x(t) }
            let visible = scale.visible
            let ruler = EditMetrics.ruler
            let wave = CGRect(x: 0, y: ruler, width: size.width, height: size.height - ruler - 14)
            if let waveform = model.waveform, visible.upperBound > visible.lowerBound {
                drawBands(context, waveform: waveform, from: visible.lowerBound - model.timelineOffset,
                          to: visible.upperBound - model.timelineOffset, in: wave)
            }
            guard let layout = model.layout else { return }
            // 결과에 쓴 구간: 아래 가는 띠 + 번호(같은 자리에서 시작하는 구간은 번호를 옆으로 민다)
            var chipX = -CGFloat.infinity
            for (index, entry) in entries.enumerated() {
                let color = EditColors.entry(index)
                let from = x(layout.start(ofBar: entry.range.first)), to = x(layout.end(ofBar: entry.range.last))
                guard to >= 0, from <= size.width else { continue }
                context.fill(Path(CGRect(x: from, y: size.height - 13, width: max(1, to - from), height: 3)), with: .color(color))
                chipX = max(max(from, 0) + 1, chipX + 16)
                if chipX < size.width - 10 {
                    context.draw(Text(verbatim: "\(index + 1)").font(.system(size: 8, weight: .bold).monospacedDigit()).foregroundStyle(color),
                                 at: CGPoint(x: chipX, y: size.height - 1), anchor: .bottomLeading)
                }
            }
            drawBarRuler(context, layout: layout, bars: visibleBars(layout, visible), x: x, height: ruler, width: size.width)
        }
    }
}

/// 끌어 고른 구간(고르는 동안 이 층만 다시 그린다). 결과로 끄는 동안은 점선으로 그린다.
private struct EditSelectionLayer: View {
    let model: TrackEditModel
    let scale: EditLaneScale
    let carrying: Bool

    var body: some View {
        let selection = model.selection
        let scale = scale, carrying = carrying
        Canvas { context, size in
            guard let selection, let layout = model.layout else { return }
            let from = scale.x(layout.start(ofBar: selection.first)), to = scale.x(layout.end(ofBar: selection.last))
            let band = CGRect(x: from, y: EditMetrics.ruler, width: max(2, to - from), height: size.height - EditMetrics.ruler)
            context.fill(Path(band), with: .color(EditColors.selection.opacity(carrying ? 0.35 : 0.22)))
            context.stroke(Path(band.insetBy(dx: 0.75, dy: 0.75)), with: .color(EditColors.selection),
                           style: StrokeStyle(lineWidth: 1.5, dash: carrying ? [5, 3] : []))
        }
        .allowsHitTesting(false)
    }
}
