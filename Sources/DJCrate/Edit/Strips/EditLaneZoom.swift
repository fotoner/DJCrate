import AppKit
import DJCDomain
import SwiftUI

// MARK: - 보기(확대·가로 스크롤)

/// 줄의 시각 ↔ 가로 위치(지금 보이는 자리 기준, #134)
struct EditLaneScale {
    let view: EditViewport
    let length: Double
    let width: CGFloat

    @MainActor
    init(_ model: TrackEditModel, _ lane: TrackEditModel.Lane, width: CGFloat) {
        view = model.viewport(lane)
        length = model.extent(lane)
        self.width = width
    }

    var visible: ClosedRange<Double> { view.visible(length: length) }
    func x(_ time: Double) -> CGFloat { CGFloat(view.x(of: time, width: Double(width), length: length)) }
    func time(_ x: CGFloat) -> Double { view.time(atX: Double(x), width: Double(width), length: length) }
    /// 한 포인트의 길이(초)
    var secondsPerPoint: Double { (visible.upperBound - visible.lowerBound) / Double(max(width, 1)) }
}

/// 줄 위 스크롤 휠·트랙패드. SwiftUI에는 휠 이벤트가 없어 로컬 이벤트 모니터로 받는다(덱 확대 파형과 같다).
/// 세로: 포인터 자리를 두고 확대·축소, 가로(트랙패드·Shift+휠): 보이는 자리 옮기기. 무엇을 받을지는 `WaveformScrollPolicy`가 정한다.
@MainActor
final class EditScrollHandler {
    weak var probe: NSView?
    weak var model: TrackEditModel?
    var lane: TrackEditModel.Lane = .source
    private var monitor: Any?
    private var policy = WaveformScrollPolicy()

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let model = self.model, let probe = self.probe, event.window === probe.window else { return event }
            let point = probe.convert(event.locationInWindow, from: nil)
            let scale = EditLaneScale(model, self.lane, width: probe.bounds.width)
            guard scale.length > 0 else { return event }
            let span = scale.visible.upperBound - scale.visible.lowerBound
            switch self.policy.handle(.init(event, over: probe.bounds.contains(point)), zoomSeconds: span, width: Double(probe.bounds.width)) {
            case .pass:
                return event
            case .swallow:
                return nil
            case let .zoom(factor):
                // 덱과 같은 방향: factor는 보이는 길이에 곱한다.
                model.zoom(self.lane, by: 1 / factor, around: scale.time(point.x))
                return nil
            case let .scrub(seconds):
                model.scroll(self.lane, by: seconds)
                return nil
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// 줄마다 휠·핀치 확대(포인터 자리 기준)
struct LaneZoomGestures: ViewModifier {
    let model: TrackEditModel
    let lane: TrackEditModel.Lane
    @State private var scroll = EditScrollHandler()
    @State private var pinch: CGFloat?
    @State private var width: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let last = pinch ?? 1
                        pinch = value.magnification
                        let scale = EditLaneScale(model, lane, width: width)
                        guard last > 0, scale.length > 0 else { return }
                        model.zoom(lane, by: value.magnification / last, around: scale.time(value.startLocation.x))
                    }
                    .onEnded { _ in pinch = nil }
            )
            .background { HitProbe { scroll.probe = $0 } }
            .onAppear {
                scroll.model = model
                scroll.lane = lane
                scroll.install()
            }
            .onDisappear { scroll.remove() }
    }
}

extension View {
    /// VoiceOver 확대·축소 동작(줄 접근성 요소에 붙인다)
    func laneZoomAction(_ model: TrackEditModel, _ lane: TrackEditModel.Lane) -> some View {
        accessibilityZoomAction { action in
            model.zoom(lane, by: action.direction == .zoomIn ? 2 : 0.5)
        }
    }
}

/// 줄 아래: 보이는 자리 막대(끌어 옮기기)와 확대·축소·전체 단추. 줄 전체를 보는 동안에는 확대하는 법을 적는다.
struct EditZoomBar: View {
    let model: TrackEditModel
    let lane: TrackEditModel.Lane

    var body: some View {
        let length = model.extent(lane)
        let view = model.viewport(lane)
        let visible = view.visible(length: length)
        let zoomed = view.isZoomed(length: length)
        let closest = visible.upperBound - visible.lowerBound <= model.minimumSpan + 1e-6
        let name = lane == .source ? String(ui: "원곡") : String(ui: "결과")
        HStack(spacing: 6) {
            if zoomed {
                EditScroller(model: model, lane: lane)
                    .frame(height: 8)
                    .accessibilityElement()
                    .accessibilityLabel(.ui("\(name) 보이는 자리"))
                    .accessibilityValue(Text(verbatim: "\(visible.lowerBound.clockText)–\(visible.upperBound.clockText)"))
                    .accessibilityAdjustableAction { direction in
                        let span = visible.upperBound - visible.lowerBound
                        model.scroll(lane, by: direction == .increment ? span / 2 : -span / 2)
                    }
                Text(verbatim: String(format: "×%.1f", view.scale(length: length)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(.ui("세로 휠·핀치·= 키로 확대합니다"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .opacity(length > 0 ? 1 : 0)
                Spacer(minLength: 0)
            }
            HStack(spacing: 2) {
                Button { model.zoom(lane, by: 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(!zoomed)
                    .help(.ui("축소합니다(− 키)"))
                    .accessibilityLabel(.ui("\(name) 축소"))
                Button { model.zoom(lane, by: 2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(length <= 0 || closest)
                    .help(.ui("재생선을 두고 확대합니다(= 키). 세로 휠·핀치는 포인터 자리를 둡니다"))
                    .accessibilityLabel(.ui("\(name) 확대"))
                Button { model.fit(lane) } label: { Image(systemName: "arrow.left.and.right.square") }
                    .disabled(!zoomed)
                    .help(.ui("줄 전체를 봅니다(0 키)"))
                    .accessibilityLabel(.ui("\(name) 전체 보기"))
            }
            .buttonStyle(.borderless)
        }
        .controlSize(.mini)
        .frame(height: 16)
    }
}

/// 보이는 자리 막대: 손잡이를 끌거나, 빈 곳을 누르면 그 자리를 가운데로 옮겨 이어 끈다.
private struct EditScroller: View {
    let model: TrackEditModel
    let lane: TrackEditModel.Lane
    /// 누른 자리와 손잡이 왼쪽 끝의 거리(초)
    @State private var grab: Double?

    var body: some View {
        GeometryReader { geo in
            let length = model.extent(lane), visible = model.viewport(lane).visible(length: length)
            let width = geo.size.width, span = visible.upperBound - visible.lowerBound
            let x = { (t: Double) in CGFloat(t / max(length, 0.001)) * width }
            ZStack(alignment: .leading) {
                Capsule().fill(UIColors.subtleFill)
                Capsule().fill(Color.secondary.opacity(0.55))
                    .frame(width: max(12, x(visible.upperBound) - x(visible.lowerBound)))
                    .offset(x: x(visible.lowerBound))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let time = Double(value.location.x / max(width, 1)) * length
                if grab == nil {
                    let start = Double(value.startLocation.x / max(width, 1)) * length
                    grab = visible.contains(start) ? start - visible.lowerBound : span / 2
                }
                model.scroll(lane, to: time - (grab ?? 0))
            }.onEnded { _ in grab = nil })
        }
    }
}
