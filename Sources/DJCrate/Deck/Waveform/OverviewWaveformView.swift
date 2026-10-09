import DJCDomain
import AppKit
import SwiftUI

struct OverviewWaveformView: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel
    @State private var scrubbing = false

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        GeometryReader { geo in
            let duration = max(deck.duration, 1)
            let metrics = WaveformMetrics(scale: textScale)
            ZStack(alignment: .bottom) {
                OverviewStaticLayer(deck: deck, duration: duration, metrics: metrics)
                if deck.isAnalyzingSections {
                    // 섹션 칸(아래 띠) 자리에 분석 진행 표시
                    HStack(spacing: 6) {
                        ProgressView().progressViewStyle(.linear).tint(Palette.section)
                        Text(.ui("섹션 분석 중")).font(.scaled(.caption2, textScale)).foregroundStyle(Palette.section)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: metrics.sectionBandHeight + 2)
                    .padding(.bottom, metrics.keyBandHeight + 3)
                    .allowsHitTesting(false)
                    .accessibilityLabel(.ui("섹션 분석 중"))
                }
                OverviewPlayheadLayer(deck: deck, duration: duration, metrics: metrics)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !scrubbing { scrubbing = true; deck.beginScrub() }
                    deck.scrub(to: Double(value.location.x / max(geo.size.width, 1)) * duration)
                }
                .onEnded { _ in
                    scrubbing = false
                    deck.endScrub()
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(.ui("재생 위치"))
            .accessibilityHint(.ui("클릭하거나 끌어서 위치를 옮깁니다. 조절하면 1박씩 옮깁니다. 로터로 큐·섹션·조성 변화·제안으로 갈 수 있습니다"))
            .waveformAccessibility(deck: deck, kind: .overview)
        }
        .background(Palette.well)
        .environment(\.colorScheme, .dark)
        .modifier(OverviewAccessibilityMarkers(deck: deck))
    }
}

/// 전체 파형의 VoiceOver 로터(큐·섹션·조성 변화·제안). 로터가 가리킬 투명 요소를 그 자리에 하나씩 놓는다.
/// 요소를 누르면(VO-Space) 그 자리로 옮기고, 제안은 메모리 큐로 받을 수도 있다. 재생 위치를 읽지 않아 재생 중에는 다시 계산하지 않는다.
struct OverviewAccessibilityMarkers: ViewModifier {
    let deck: DeckModel
    @Namespace private var rotorSpace

    func body(content: Content) -> some View {
        let duration = max(deck.duration, 1)
        let cues = WaveformAccessibility.cueMarkers(deck.draft?.cues ?? [])
        let sections = WaveformAccessibility.sectionMarkers(deck.sectionEnergies.map { (start: $0.span.start, score: $0.score) })
        let keys = WaveformAccessibility.keyChangeMarkers(deck.keySegments.map { (start: $0.start, name: deck.keyName(for: $0)) })
        let suggestions = WaveformAccessibility.suggestionMarkers(deck.suggestions)
        let suggestionIDs = Set(suggestions.map(\.id))
        content
            .overlay {
                GeometryReader { geo in
                    ForEach(cues + sections + keys + suggestions) { marker in
                        Color.clear
                            .frame(width: 8, height: geo.size.height)
                            .position(x: CGFloat(marker.time / duration) * geo.size.width, y: geo.size.height / 2)
                            .accessibilityElement()
                            .accessibilityLabel(marker.label)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint(.ui("누르면 이 자리로 옮깁니다"))
                            .accessibilityAction { if !deck.isWriteLocked { deck.seek(marker.time) } }
                            .accessibilityActions {
                                if suggestionIDs.contains(marker.id) {
                                    Button(.ui("메모리 큐로 받기")) { deck.acceptSuggestion(marker.time) }
                                }
                            }
                            .accessibilityRotorEntry(id: marker.id, in: rotorSpace)
                    }
                }
                .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(.ui("전체 파형"))
            .accessibilityRotor(.ui("큐")) { entries(cues) }
            .accessibilityRotor(.ui("섹션")) { entries(sections) }
            .accessibilityRotor(.ui("조성 변화")) { entries(keys) }
            .accessibilityRotor(.ui("제안")) { entries(suggestions) }
    }

    private func entries(_ markers: [WaveformAccessibility.Marker]) -> some AccessibilityRotorContent {
        ForEach(markers) { AccessibilityRotorEntry(Text($0.label), id: $0.id, in: rotorSpace) }
    }
}

/// 파형·섹션 띠·큐·제안. 재생 위치를 읽지 않으므로 재생 중에는 다시 그려지지 않는다.
struct OverviewStaticLayer: View {
    @State private var bandPaths = WaveformBandPathCache()
    @Environment(\.colorSchemeContrast) private var contrast
    let deck: DeckModel
    let duration: Double
    var metrics = WaveformMetrics()

    var body: some View {
        let waveform = deck.waveform
        let colorWaveform = deck.colorWaveform
        let mode = deck.waveformColorMode
        let energies = deck.sectionEnergies
        let suggestions = deck.suggestions
        let cues = deck.draft?.cues ?? []
        let instantLoop = deck.instantLoop
        let selected = deck.selectedCueID
        let cuePoint = deck.cuePoint
        let audioOffset = deck.timelineOffset
        let keys = deck.keySegments.map { (segment: $0, name: deck.keyName(for: $0)) }
        let keyChanges = deck.keySegments.count > 1
        let metrics = metrics
        Canvas { context, size in
            let start = PerfProbe.beginInterval()
            defer { PerfProbe.endInterval("overview.static.draw", from: start) }
            let xOf = { (t: Double) in CGFloat(t / duration) * size.width }
            let waveHeight = size.height - metrics.overviewBandsHeight
            if mode == .threeBand, let waveform {
                let rect = CGRect(x: 0, y: 2, width: size.width, height: waveHeight - 2)
                let paths = bandPaths.paths(waveform: waveform, from: -audioOffset, to: duration - audioOffset, in: rect)
                var clipped = context
                clipped.clip(to: Path(rect.insetBy(dx: 0, dy: -rect.height)))
                for (path, color) in zip(paths, [Palette.low, Palette.mid, Palette.high]) {
                    clipped.fill(path, with: .color(color))
                }
            } else {
                colorWaveform?.draw(context, from: 0, to: duration,
                                    in: CGRect(x: 0, y: 2, width: size.width, height: waveHeight - 2), full: true)
            }
            let scores = energies.map(\.score).filter(\.isFinite)
            let lo = scores.min() ?? 0, hi = scores.max() ?? 1
            for e in energies {
                let norm = e.score.isFinite && hi > lo ? (e.score - lo) / (hi - lo) : 0
                let rect = CGRect(x: xOf(e.span.start), y: waveHeight + 3,
                                  width: max(1, xOf(e.span.end) - xOf(e.span.start) - 1), height: metrics.sectionBandHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Palette.section.opacity(0.1 + 0.62 * norm * norm)))
            }
            // 조성 띠(섹션 띠 아래). 바뀌는 곳이 있으면 진하게. 이름은 띠 안에 다 들어갈 때만 쓴다(글자를 줄이지 않는다).
            for key in keys {
                let rect = CGRect(x: xOf(key.segment.start), y: waveHeight + 3 + metrics.sectionBandHeight + 2,
                                  width: max(1, xOf(key.segment.end) - xOf(key.segment.start) - 1), height: metrics.keyBandHeight)
                let color = Palette.keyColor(key.name)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(Palette.keyBandOpacity(changes: keyChanges))))
                let label = context.resolve(Text(key.name).font(.system(size: metrics.labelSize, weight: .bold)).foregroundStyle(Color.white))
                if label.measure(in: CGSize(width: 200, height: 40)).width + 8 <= rect.width {
                    context.draw(label, at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
                }
            }
            for s in suggestions {
                var line = Path()
                line.move(to: CGPoint(x: xOf(s), y: 0)); line.addLine(to: CGPoint(x: xOf(s), y: waveHeight))
                context.stroke(line, with: .color(.black.opacity(0.5)), lineWidth: 3)
                context.stroke(line, with: .color(contrast == .increased ? Color.white : Palette.suggestion), style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
            }
            if let loop = instantLoop {
                let band = CGRect(x: xOf(loop.start), y: 0, width: max(2, xOf(loop.end) - xOf(loop.start)), height: waveHeight)
                context.fill(Path(band), with: .color(Palette.loop.opacity(contrast == .increased ? 0.65 : 0.45)))
            }
            for cue in cues {
                if let loop = cue.loop {
                    let band = CGRect(x: xOf(cue.time), y: 0, width: max(1.5, xOf(loop.end) - xOf(cue.time)), height: waveHeight)
                    context.fill(Path(band), with: .color(Palette.loop.opacity(contrast == .increased ? (loop.active ? 0.55 : 0.4) : (loop.active ? 0.35 : 0.2))))
                }
                var line = Path()
                line.move(to: CGPoint(x: xOf(cue.time), y: 0)); line.addLine(to: CGPoint(x: xOf(cue.time), y: waveHeight))
                context.stroke(line, with: .color(Palette.color(for: cue)), lineWidth: cue.id == selected ? 2.5 : 1.2)
                // 색만으로 나누지 않게 모양을 더한다: 메모리 큐는 CUE 삼각형 아래 작은 삼각형(확대 파형과 같은 모양).
                if cue.kind == .memory {
                    let x = xOf(cue.time), range = OverviewCueMarks.memoryTriangle
                    var tri = Path()
                    tri.addLines([CGPoint(x: x - 4, y: range.lowerBound), CGPoint(x: x + 4, y: range.lowerBound), CGPoint(x: x, y: range.upperBound)])
                    tri.closeSubpath()
                    // 밝은 파형 위에서도 보이게 어두운 테두리를 두른다(제안 선과 같은 방식).
                    context.stroke(tri, with: .color(.black.opacity(0.6)), lineWidth: 1.5)
                    context.fill(tri, with: .color(Palette.color(for: cue)))
                    if cue.id == selected { context.stroke(tri, with: .color(.white), lineWidth: 1) }
                }
            }
            // 핫큐는 파형 아래쪽에 슬롯 글자 칩(확대 파형 칩을 전체 파형 높이에 맞게 낮춘 것). 겹치는 칩은 뺀다.
            for mark in OverviewCueMarks.chips(for: cues, xOf: xOf, metrics: metrics) {
                chip(context, mark.loop ? Text("\(mark.letter)\(Image(systemName: "repeat"))") : Text(mark.letter),
                     at: CGPoint(x: mark.x, y: waveHeight - metrics.overviewChipHeight - 1),
                     color: mark.loop ? Palette.loop : Palette.hot, selected: mark.id == selected, maxX: size.width,
                     metrics: metrics, height: metrics.overviewChipHeight)
            }
            var tri = Path()
            let cx = xOf(cuePoint)
            tri.addLines([CGPoint(x: cx - 5, y: 0), CGPoint(x: cx + 5, y: 0), CGPoint(x: cx, y: OverviewCueMarks.cueTriangleHeight)])
            tri.closeSubpath()
            context.fill(tri, with: .color(Palette.cue))
        }
    }
}

/// 전체 파형의 큐 모양 표식. 핫큐(초록)·메모리 큐(빨강)를 색만으로 나누지 않는다(적록 색각에서도 구분되게).
enum OverviewCueMarks {
    /// CUE 지점 삼각형 높이(위쪽 0~8pt)
    static let cueTriangleHeight: CGFloat = 8
    /// 메모리 큐 삼각형: CUE 삼각형과 겹치지 않게 그 아래(위아래 y)
    static let memoryTriangle: ClosedRange<CGFloat> = 9...15

    struct Chip: Equatable {
        var id: EditableCue.ID
        var x: CGFloat
        var letter: String
        var loop: Bool
    }

    /// 핫큐 슬롯 글자 칩(왼쪽부터). 앞 칩과 겹치면 뺀다: 글자를 줄이지 않고 칩 수를 줄인다(선은 그대로 남는다).
    static func chips(for cues: [EditableCue], xOf: (Double) -> CGFloat, metrics: WaveformMetrics) -> [Chip] {
        let hot = cues.compactMap { cue in
            cue.kind.slotLetter.map { Chip(id: cue.id, x: xOf(cue.time), letter: $0, loop: cue.loop != nil) }
        }.sorted { $0.x < $1.x }
        let spans = hot.map { chip -> (start: Double, end: Double) in
            // 굵은 대문자 한 자 ≈ 글자 크기 0.7배, 반복 심볼 ≈ 1.3배, 좌우 여백 8pt
            let width = metrics.labelSize * (chip.loop ? 2 : 0.7) + 8
            return (chip.x - width / 2, chip.x + width / 2)
        }
        return zip(hot, WaveformMetrics.visibleLabels(spans, gap: 2)).filter(\.1).map(\.0)
    }
}

/// 재생선과 확대 창 범위만 그린다(매 프레임).
struct OverviewPlayheadLayer: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let deck: DeckModel
    let duration: Double
    var metrics = WaveformMetrics()

    var body: some View {
        // 전체 파형은 넓어서 초당 15번이면 충분하다(창 전체 갱신을 매 프레임 일으키지 않게).
        let t = deck.displayTime
        let zoom = deck.zoomSeconds
        let metrics = metrics
        Canvas { context, size in
            let start = PerfProbe.beginInterval()
            defer { PerfProbe.endInterval("overview.playhead.draw", from: start) }
            let xOf = { (time: Double) in CGFloat(time / duration) * size.width }
            let waveHeight = size.height - metrics.overviewBandsHeight
            let window = CGRect(x: xOf(t - zoom / 2), y: 0, width: xOf(zoom), height: waveHeight)
            context.fill(Path(window), with: .color(.white.opacity(0.08)))
            context.stroke(Path(window), with: .color(.white.opacity(contrast == .increased ? 0.7 : 0.3)), lineWidth: 1)
            var head = Path()
            head.move(to: CGPoint(x: xOf(t), y: 0)); head.addLine(to: CGPoint(x: xOf(t), y: size.height))
            context.stroke(head, with: .color(.white), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}
