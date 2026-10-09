import DJCDomain
import AppKit
import SwiftUI

/// 파형 위 스크롤 휠 처리. SwiftUI에는 휠 이벤트가 없어서 로컬 이벤트 모니터로 받는다.
/// 세로 휠: 확대·축소 / 가로 스크롤(트랙패드·Shift+휠): 위치 이동. 파형 영역 밖에서 시작한 스크롤은 건드리지 않는다.
/// 무엇을 받을지는 `WaveformScrollPolicy`가 정한다(트랙패드 제스처는 관성까지 한 덩어리로).
@MainActor
final class WaveformScrollHandler {
    /// 파형 자리의 AppKit 뷰(창 좌표로 마우스가 파형 위인지 본다)
    weak var probe: NSView?
    weak var deck: DeckModel?
    private var monitor: Any?
    private var policy = WaveformScrollPolicy()

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let deck = self.deck, let probe = self.probe, event.window === probe.window else { return event }
            let over = probe.bounds.contains(probe.convert(event.locationInWindow, from: nil))
            let action = self.policy.handle(.init(event, over: over), zoomSeconds: deck.zoomSeconds, width: Double(probe.bounds.width))
#if DEBUG
            HotCueScrollTrace.record(event, action: action)
#endif
            switch action {
            case .pass:
                return event
            case .swallow:
                return nil
            case let .zoom(factor):
                deck.zoom(by: factor)
                return nil
            case let .scrub(seconds):
                // 가로 이동은 이벤트마다 오디오를 다시 시작하지 않고 모아서 처리한다.
                deck.scrubCoalesced(to: deck.currentTime + seconds)
                return nil
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct ZoomWaveformView: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel
    @State private var drag: DragMode?
    @State private var dragTrackUUID: String?
    /// 포인터 아래 대상(바뀔 때만 다시 그린다)
    @State private var hover = ZoomPointerTarget.empty
    @State private var width: CGFloat = 1
    @State private var scroll = WaveformScrollHandler()
    /// 끄는 동안 핫큐 키(제스처가 키 이벤트를 삼켜 KeyRouter까지 오지 않는다, #133)
    @State private var hotCueKeys = DragHotCueKeys()
    @State private var pinchBase: Double?
    /// 해석한 글자(마디.박·큐 이름·칩)를 다음 프레임에도 쓴다(#139)
    @State private var texts = WaveformTextCache()

    /// `hover`: 처음 보일 포인터 아래 대상(미리 보기·캡처용)
    init(deck: DeckModel, hover: ZoomPointerTarget = .empty) {
        self.deck = deck
        _hover = State(initialValue: hover)
    }

    private enum DragMode {
        /// 큐를 잡았다. 3px 넘게 끌기 전에는 움직이지 않는다(클릭만으로 큐가 바뀌지 않도록).
        case cue(EditableCue.ID, originalTime: Double)
        /// 끈 거리의 기준점은 덱이 든다(끄는 중 핫큐로 옮기면 기준도 옮긴다, `ScrubAnchor`).
        case scrub

        /// 끄는 동안의 포인터 모양은 끌기 시작한 대상을 따른다.
        var target: ZoomPointerTarget {
            switch self {
            case let .cue(id, _): .cue(id)
            case .scrub: .empty
            }
        }
    }

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        GeometryReader { geo in
                let center = deck.currentTime
                let window = deck.zoomSeconds
                let start = center - window / 2
                let time = { (x: CGFloat) in start + Double(x / max(geo.size.width, 1)) * window }
                let xOf = { (t: Double) in CGFloat((t - start) / window) * geo.size.width }

                let state = DrawState(deck, hover: hover, metrics: WaveformMetrics(scale: textScale))
                Canvas { context, size in
                    PerfProbe.measureDraw { draw(context, size: size, state: state, texts: texts, start: start, window: window, xOf: xOf) }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
#if DEBUG
                            ScrubHotCueTrace.recordDrag(ended: false)
#endif
                            if drag == nil {
                                dragTrackUUID = deck.row?.track.uuid
                                switch pointerTarget(atX: value.startLocation.x, xOf: xOf, suggestions: []) {
                                case let .cue(hit):
                                    deck.selectedCueID = hit
                                    drag = .cue(hit, originalTime: deck.cue(hit)?.time ?? center)
                                case .empty, .suggestion:
                                    deck.beginScrubDrag()
                                    drag = .scrub
                                }
                                hotCueKeys.begin(deck: deck)
                            }
                            guard dragTrackUUID == deck.row?.track.uuid else { return }
                            let secondsPerPoint = window / Double(max(geo.size.width, 1))
                            switch drag {
                            case let .cue(id, originalTime):
                                guard abs(value.translation.width) > 3 else { break }
                                deck.move(id, to: originalTime + Double(value.translation.width) * secondsPerPoint, save: false, expectedTrackUUID: dragTrackUUID)
                            case .scrub:
                                deck.dragScrub(by: -Double(value.translation.width) * secondsPerPoint)
                            case nil:
                                break
                            }
                        }
                        .onEnded { value in
#if DEBUG
                            ScrubHotCueTrace.recordDrag(ended: true)
#endif
                            hotCueKeys.end()
                            guard dragTrackUUID == deck.row?.track.uuid else { drag = nil; return }
                            switch drag {
                            case .cue:
                                if abs(value.translation.width) > 3 { deck.commitDraft() }
                            case .scrub:
                                // 제안 마커를 짧게 클릭하면 메모리 큐로 받아들인다.
                                if abs(value.translation.width) < 2,
                                   case let .suggestion(s) = pointerTarget(atX: value.location.x, xOf: xOf) {
                                    deck.acceptSuggestion(s)
                                }
                                deck.endScrub()
                            case nil:
                                break
                            }
                            drag = nil
                        }
                )
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).onEnded { value in
                        if !deck.gridEditing, hitCue(atX: value.location.x, xOf: xOf) == nil {
                            deck.addMemoryCue(at: time(value.location.x))
                        }
                    }
                )
        }
        // 누르기 전에 무엇이 잡힐지 보인다: 포인터 모양을 바꾸고 큐 선은 굵게, 제안 배지는 밝게 그린다.
        // 매 프레임 다시 그리는 위 본문 밖에 두고, 위치는 이벤트 때 읽는다(재생 위치를 본문에서 읽지 않게).
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onContinuousHover { phase in
            var target = ZoomPointerTarget.empty
            if case let .active(point) = phase {
                let start = deck.currentTime - deck.zoomSeconds / 2, window = deck.zoomSeconds, width = width
                target = pointerTarget(atX: point.x, xOf: { CGFloat(($0 - start) / window) * width })
            }
            if hover != target { hover = target }
        }
        .pointerStyle(ZoomPointerTarget.pointer(hover: hover, drag: drag?.target).style)
        .background(Palette.well)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if pinchBase == nil { pinchBase = deck.zoomSeconds }
                    deck.setZoom((pinchBase ?? deck.zoomSeconds) / max(value.magnification, 0.05))
                }
                .onEnded { _ in pinchBase = nil }
        )
        .background { HitProbe { scroll.probe = $0 } }
        .selfTestFrame("zoomWaveform")
        .onAppear { scroll.deck = deck; scroll.install() }
        .onDisappear { scroll.remove(); hotCueKeys.end() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(.ui("확대 파형"))
        .accessibilityHint(.ui("드래그로 스크럽하고, 큐를 끌어 옮기고, 더블클릭으로 메모리 큐를 추가합니다. 휠로 확대·축소합니다. 조절하면 1박씩 옮깁니다"))
        .waveformAccessibility(deck: deck, kind: .zoom)
    }

    /// 끌기 시작·짧은 클릭·호버가 같은 규칙으로 대상을 고른다.
    private func pointerTarget(atX x: CGFloat, xOf: (Double) -> CGFloat, suggestions: [Double]? = nil) -> ZoomPointerTarget {
        ZoomPointerTarget.at(x: x, cues: deck.draft?.cues ?? [], suggestions: suggestions ?? deck.suggestions, xOf: xOf)
    }

    private func hitCue(atX x: CGFloat, xOf: (Double) -> CGFloat) -> EditableCue.ID? {
        if case let .cue(id) = pointerTarget(atX: x, xOf: xOf, suggestions: []) { return id }
        return nil
    }

    private func draw(_ context: GraphicsContext, size: CGSize, state: DrawState, texts: WaveformTextCache, start: Double, window: Double, xOf: (Double) -> CGFloat) {
        let end = start + window
        let metrics = state.metrics
        let ruler = metrics.rulerHeight
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: ruler)), with: .color(.black.opacity(0.35)))
        // 비트 그리드 (rekordbox PQTZ): 창 안의 박만 이진 탐색으로 찾아 돈다.
        if let grid = state.grid {
            var i = grid.firstIndex(atOrAfter: start)
            while i < grid.beats.count, grid.beats[i].time <= end {
                let beat = grid.beats[i]
                i += 1
                let x = xOf(beat.time)
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                let strong = contrast == .increased
                    ? (beat.isDownbeat ? 0.8 : 0.5)
                    : state.gridEditing ? (beat.isDownbeat ? 0.55 : 0.22) : (beat.isDownbeat ? 0.22 : 0.07)
                context.stroke(line, with: .color((state.gridEditing ? Palette.mid : .white).opacity(strong)),
                               lineWidth: beat.isDownbeat && state.gridEditing ? 1.5 : 1)
                let beatWidth = size.width / window * 60 / max(beat.bpm, 1)
                if state.gridEditing,
                   BeatRulerLabel.showsBeatNumber(isDownbeat: beat.isDownbeat, beatWidth: beatWidth, charWidth: metrics.charWidth) {
                    context.draw(texts.resolved(.text("\(beat.number)", size: metrics.labelSize, weight: beat.isDownbeat ? .bold : .regular, digits: true,
                                                      color: beat.isDownbeat ? Palette.mid : Palette.rulerText), in: context),
                                 at: CGPoint(x: x + 2, y: size.height - metrics.beatNumberInset), anchor: .leading)
                }
                // 상단 위치 표시(마디.박, rekordbox처럼 박은 1부터). 자리가 모자라면 글자를 줄이지 않고 라벨 수를 줄인다(`BeatRulerLabel`).
                if let label = BeatRulerLabel.text(bar: grid.bar(at: beat.time), beat: max(beat.number, 1),
                                                   isDownbeat: beat.isDownbeat, beatWidth: beatWidth, charWidth: metrics.charWidth),
                   x + 3 + CGFloat(label.count) * metrics.charWidth < size.width - 1 {
                    context.draw(texts.resolved(.text(label, size: metrics.labelSize, weight: beat.isDownbeat ? .semibold : .regular, digits: true,
                                                      color: contrast == .increased ? Color.white : Palette.rulerText), in: context),
                                 at: CGPoint(x: x + 3, y: ruler / 2), anchor: .leading)
                }
            }
        }
        // 그리드가 없는 곡: 적용 전 추정 박을 점선으로 미리 보여 준다.
        if let preview = state.previewGrid {
            var i = preview.firstIndex(atOrAfter: start)
            while i < preview.beats.count, preview.beats[i].time <= end {
                let beat = preview.beats[i]
                i += 1
                var line = Path()
                line.move(to: CGPoint(x: xOf(beat.time), y: 0)); line.addLine(to: CGPoint(x: xOf(beat.time), y: size.height))
                context.stroke(line, with: .color(Palette.suggestion.opacity(contrast == .increased ? (beat.isDownbeat ? 1 : 0.7) : (beat.isDownbeat ? 0.6 : 0.25))),
                               style: StrokeStyle(lineWidth: beat.isDownbeat ? 1.5 : 1, dash: [3, 4]))
            }
        }
        if !PerfProbe.skipBands {
            let rect = CGRect(x: 0, y: 16, width: size.width, height: size.height - 34)
            if state.waveformColorMode == .threeBand, let waveform = state.waveform {
                drawBands(context, waveform: waveform, from: start - state.audioOffset, to: end - state.audioOffset, in: rect)
            } else {
                state.colorWaveform?.draw(context, from: start, to: end, in: rect)
            }
        }
        // 변속 지점(템포 구간 경계)
        for segment in state.segments.dropFirst() where segment.start > start && segment.start < end {
            let x = xOf(segment.start)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.yellow), lineWidth: 2)
            let nearRight = x > size.width - 80 * metrics.scale
            let bpmText = segment.bpm.formatted(.number.precision(.fractionLength(2)).grouping(.never)) + " BPM"
            context.draw(texts.resolved(.text(bpmText, size: metrics.labelSize, weight: .bold, color: .yellow), in: context),
                         at: CGPoint(x: nearRight ? x - 4 : x + 4, y: ruler + 4), anchor: nearRight ? .trailing : .leading)
        }
        // MU 섹션 경계
        for section in state.sections where section.start > start && section.start < end {
            var line = Path()
            line.move(to: CGPoint(x: xOf(section.start), y: 16)); line.addLine(to: CGPoint(x: xOf(section.start), y: size.height))
            context.stroke(line, with: .color(Palette.section), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        }
        // 메모리 큐 제안: 밝은 파형 위에서도 보이게 어두운 테두리 위에 굵은 점선, 아래에 "+" 배지(누르면 메모리 큐)
        for s in state.suggestions where s > start && s < end {
            let x = xOf(s)
            let hovered = state.hoveredSuggestion == s
            let side = metrics.badgeSize
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height - side - 4))
            context.stroke(line, with: .color(.black.opacity(0.55)), lineWidth: hovered ? 5 : 4)
            context.stroke(line, with: .color(contrast == .increased || hovered ? Color.white : Palette.suggestion),
                           style: StrokeStyle(lineWidth: hovered ? 3 : 2, dash: [6, 3]))
            // 포인터가 올라가면 배지를 키우고 밝게(흰 테두리) 그려 누르면 받는다는 것을 보인다.
            let badge = CGRect(x: x - side / 2, y: size.height - side - 3, width: side, height: side)
                .insetBy(dx: hovered ? -1.5 : 0, dy: hovered ? -1.5 : 0)
            context.fill(Path(ellipseIn: badge.insetBy(dx: -1.5, dy: -1.5)), with: .color(.black.opacity(0.6)))
            context.fill(Path(ellipseIn: badge), with: .color(Palette.suggestion))
            if hovered {
                context.fill(Path(ellipseIn: badge), with: .color(.white.opacity(0.35)))
                context.stroke(Path(ellipseIn: badge), with: .color(.white), lineWidth: 1.5)
            }
            context.draw(texts.resolved(.init(content: .symbol("plus"), style: .init(size: side * 0.6, weight: .bold, color: .black)), in: context),
                         at: CGPoint(x: badge.midX, y: badge.midY))
        }
        // 루프 구간(큐 선보다 먼저 칠한다). 활성 루프는 진하게 + 반복 심볼
        for cue in state.cues {
            guard let loop = cue.loop, loop.end >= start, cue.time <= end else { continue }
            let x0 = xOf(cue.time), x1 = xOf(loop.end)
            let band = CGRect(x: x0, y: ruler, width: max(1, x1 - x0), height: size.height - ruler)
            let engaged = state.engagedLoop == cue.id
            context.fill(Path(band), with: .color(Palette.loop.opacity(contrast == .increased ? (engaged ? 0.55 : loop.active ? 0.42 : 0.32) : (engaged ? 0.35 : loop.active ? 0.22 : 0.12))))
            let top = CGRect(x: x0, y: ruler, width: max(1, x1 - x0), height: 4)
            context.fill(Path(top), with: .color(Palette.loop.opacity(contrast == .increased ? 1 : (loop.active ? 0.95 : 0.6))))
            var endLine = Path()
            endLine.move(to: CGPoint(x: x1, y: ruler)); endLine.addLine(to: CGPoint(x: x1, y: size.height))
            context.stroke(endLine, with: .color(Palette.loop.opacity(contrast == .increased ? 1 : 0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if loop.active, x1 - x0 > 16 * metrics.scale {
                context.draw(texts.resolved(.init(content: .symbol("repeat"), style: .init(size: metrics.labelSize, weight: .bold, color: Palette.loop)), in: context),
                             at: CGPoint(x: x0 + 3, y: ruler + metrics.loopLabelOffset), anchor: .leading)
            }
        }
        // 즉석 루프(아직 큐가 아님): 진한 주황 + 양끝 실선 + 반복 심볼과 박 수
        if let loop = state.instantLoop, loop.end >= start, loop.start <= end {
            let x0 = xOf(loop.start), x1 = xOf(loop.end)
            let band = CGRect(x: x0, y: ruler, width: max(1, x1 - x0), height: size.height - ruler)
            context.fill(Path(band), with: .color(Palette.loop.opacity(contrast == .increased ? 0.5 : 0.3)))
            context.fill(Path(CGRect(x: x0, y: ruler, width: max(1, x1 - x0), height: 4)), with: .color(Palette.loop))
            for x in [x0, x1] {
                var edge = Path()
                edge.move(to: CGPoint(x: x, y: ruler)); edge.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(edge, with: .color(Palette.loop), lineWidth: 1.5)
            }
            if x1 - x0 > 30 * metrics.scale {
                context.draw(texts.resolved(.init(content: .symbolThenText(symbol: "repeat", text: state.loopSizeText),
                                                  style: .init(size: metrics.labelSize, weight: .bold, color: Palette.loop)), in: context),
                             at: CGPoint(x: x0 + 5, y: ruler + metrics.loopLabelOffset), anchor: .leading)
            }
        }
        // 큐 (초안)
        for cue in state.cues where cue.time >= start - 1 && cue.time <= end + 1 {
            let x = xOf(cue.time)
            let selected = cue.id == state.selected
            // 포인터가 올라간 큐 선은 한 단계 굵게(끌어 옮길 수 있다는 표시)
            let hoverWidth: CGFloat = cue.id == state.hoveredCue ? 1.5 : 0
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            switch cue.kind {
            case .memory:
                context.stroke(line, with: .color(Palette.color(for: cue)), lineWidth: (selected ? 2.5 : 1.2) + hoverWidth)
                var tri = Path()
                tri.addLines([CGPoint(x: x - 6, y: ruler), CGPoint(x: x + 6, y: ruler), CGPoint(x: x, y: ruler + 10)])
                tri.closeSubpath()
                context.fill(tri, with: .color(Palette.color(for: cue)))
                if selected { context.stroke(tri, with: .color(.white), lineWidth: 1.2) }
            case .hot:
                context.stroke(line, with: .color(Palette.color(for: cue)), lineWidth: (selected ? 2.5 : 1.8) + hoverWidth)
                // 루프 핫큐는 슬롯 글자 옆에 반복 심볼을 같은 글꼴로 붙인다(덱 패드와 같다).
                let letter = cue.kind.slotLetter ?? ""
                let content: WaveformTextCache.Content = cue.loop == nil ? .text(letter) : .textThenSymbol(text: letter, symbol: "repeat")
                let label = texts.label(.init(content: content, style: .init(size: metrics.labelSize, weight: .bold, color: .black)),
                                        proposal: WaveformMetrics.chipProposal, in: context)
                chip(context, resolved: label.text, size: label.size,
                     at: CGPoint(x: x, y: size.height - metrics.chipHeight - 2), color: Palette.color(for: cue), selected: selected,
                     maxX: size.width, metrics: metrics)
            }
        }
        // 큐 이름(선 위에 겹쳐 그린다). 앞 이름과 겹치면 뺀다: 글자 배율이 커도 글자를 줄이지 않는다.
        var names: [(label: WaveformTextCache.Label, x: CGFloat, trailing: Bool)] = []
        for cue in state.cues where !cue.name.isEmpty && cue.time >= start - 1 && cue.time <= end + 1 {
            let x = xOf(cue.time)
            let trailing = x > size.width - 90 * metrics.scale
            let label = texts.label(.text(WaveformAccessibility.cueName(cue), size: metrics.labelSize, weight: .semibold, color: .white),
                                    proposal: CGSize(width: size.width, height: 100), in: context)
            names.append((label, trailing ? x - 5 : x + 5, trailing))
        }
        let spans = names.map { name -> (start: Double, end: Double) in
            name.trailing ? (name.x - name.label.size.width, name.x) : (name.x, name.x + name.label.size.width)
        }
        for (name, visible) in zip(names, WaveformMetrics.visibleLabels(spans, gap: 4)) where visible {
            context.draw(name.label.text, at: CGPoint(x: name.x, y: ruler + metrics.cueNameOffset), anchor: name.trailing ? .trailing : .leading)
        }
        // CUE 지점: 위쪽 주황 삼각형(메모리 큐 삼각형보다 위)
        if state.cuePoint >= start, state.cuePoint <= end {
            let x = xOf(state.cuePoint)
            var tri = Path()
            tri.addLines([CGPoint(x: x - 6, y: 0), CGPoint(x: x + 6, y: 0), CGPoint(x: x, y: 10)])
            tri.closeSubpath()
            context.fill(tri, with: .color(Palette.cue))
            var line = Path()
            line.move(to: CGPoint(x: x, y: 10)); line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(Palette.cue.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
        // 플레이헤드: 위 눈금 줄(마디.박 표시) 아래부터 긋고, 눈금 줄에는 작은 삼각형만 둔다(숫자를 가리지 않게).
        let px = xOf(state.playhead)
        var head = Path()
        head.move(to: CGPoint(x: px, y: ruler)); head.addLine(to: CGPoint(x: px, y: size.height))
        context.stroke(head, with: .color(.white), lineWidth: 2)
        var marker = Path()
        marker.addLines([CGPoint(x: px - 4, y: ruler - 5), CGPoint(x: px + 4, y: ruler - 5), CGPoint(x: px, y: ruler)])
        marker.closeSubpath()
        context.fill(marker, with: .color(.white))
        // 다음 메모리 큐까지: 재생선 바로 왼쪽 위 알약(파형 높이에 맞춰 글자 크기를 줄인다)
        if let text = Self.countdown(to: state.cues, from: state.playhead, grid: state.grid) {
            let fontSize = min(13 * metrics.scale, max(metrics.labelSize, size.height / 9))
            let label = texts.label(.text(text, size: fontSize, weight: .bold, digits: true, color: Palette.memory),
                                    proposal: WaveformMetrics.chipProposal, in: context)
            let textSize = label.size
            let width = textSize.width + 12
            let pill = CGRect(x: max(2, px - width - 3), y: ruler + 4, width: width, height: textSize.height + 4)
            context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.black.opacity(0.65)))
            context.draw(label.text, at: CGPoint(x: pill.midX, y: pill.midY))
        }
    }

    /// 다음 메모리 큐까지 남은 박(규칙은 `CueCountdown`)
    static func countdown(to cues: [EditableCue], from time: Double, grid: BeatGrid?) -> String? {
        CueCountdown.text(to: cues, from: time, grid: grid)
    }
}

/// 확대 파형에서 포인터 아래 대상. 끌기 시작(큐·스크럽)·제안 짧은 클릭·호버 표시가 같은 규칙을 쓴다.
/// 그리드 편집 중에도 같다: 그리드는 편집 막대의 ‹ ›·단축키로만 옮긴다(rekordbox처럼, #117).
enum ZoomPointerTarget: Equatable {
    case empty
    case cue(EditableCue.ID)
    case suggestion(Double)

    /// 큐 선 7pt, 제안 11pt 안(가장 가까운 것). 큐가 제안보다 먼저다.
    static func at(x: CGFloat, cues: [EditableCue], suggestions: [Double], xOf: (Double) -> CGFloat) -> Self {
        if let hit = cues.map({ ($0.id, abs(xOf($0.time) - x)) }).filter({ $0.1 < 7 }).min(by: { $0.1 < $1.1 }) {
            return .cue(hit.0)
        }
        if let hit = suggestions.map({ ($0, abs(xOf($0) - x)) }).filter({ $0.1 < 11 }).min(by: { $0.1 < $1.1 }) {
            return .suggestion(hit.0)
        }
        return .empty
    }

    enum Pointer: Equatable {
        case grabIdle, grabActive, columnResize, arrow

        var style: PointerStyle {
            switch self {
            case .grabIdle: .grabIdle
            case .grabActive: .grabActive
            case .columnResize: .columnResize
            case .arrow: .default
            }
        }
    }

    /// 빈 곳은 펼친 손(끌면 스크럽), 끄는 중은 쥔 손, 큐 선은 좌우 화살표, 제안 배지는 기본 화살표(누르면 받기).
    static func pointer(hover: Self, drag: Self?) -> Pointer {
        if let drag {
            switch drag {
            case .cue: return .columnResize
            case .empty, .suggestion: return .grabActive
            }
        }
        switch hover {
        case .cue: return .columnResize
        case .suggestion: return .arrow
        case .empty: return .grabIdle
        }
    }

    var cue: EditableCue.ID? { if case let .cue(id) = self { id } else { nil } }
    var suggestion: Double? { if case let .suggestion(time) = self { time } else { nil } }
}

// MARK: - 전체 개요
