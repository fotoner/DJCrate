import DJCDomain
import SwiftUI

// MARK: - 결과 타임라인

/// 편집 결과: 클립(목록 구간)을 이어 놓은 타임라인. 클립을 누르면 고르고 재생선을 옮기며, 끌면 순서를 바꾸고,
/// 가장자리를 끌면 마디 줄에 붙여 다듬는다. 위 눈금을 누르거나 끌면 재생선만 옮긴다. 아래 줄의 가위 단추로 이음새 앞뒤를 들어 본다.
struct EditOutputStrip: View {
    let model: TrackEditModel
    /// 클립 줄 자리를 알린다(편집 창 좌표). 원곡에서 고른 구간을 끌어 놓을 자리를 찾는다.
    let onLaneFrame: (CGRect) -> Void
    @State private var pointer: EditPointer

    /// - Parameter pointer: 처음 누르기·끌기 상태(끄는 중 모습을 캡처할 때)
    init(model: TrackEditModel, pointer: EditPointer = EditPointer(), onLaneFrame: @escaping (CGRect) -> Void = { _ in }) {
        self.model = model
        self.onLaneFrame = onLaneFrame
        _pointer = State(initialValue: pointer)
    }
    /// 포인터가 클립 가장자리 위인지(다듬기 커서)
    @State private var overEdge = false

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let scale = EditLaneScale(model, .output, width: geo.size.width)
                ZStack {
                    EditOutputLayer(model: model, scale: scale, dragging: pointer.dragging)
                    if let offset = pointer.dropOffset {
                        EditDropMarker(model: model, scale: scale, offset: offset, label: nil)
                    }
                    if let trim = pointer.trimming {
                        EditTrimMarker(model: model, scale: scale, trim: trim)
                    }
                    EditInsertMarker(model: model, scale: scale)
                    EditPlayhead(model: model, lane: .output)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    var edge = false
                    if case let .active(point) = phase, point.y >= EditMetrics.ruler {
                        edge = model.clipLayout.edge(atOutput: scale.time(point.x),
                                                     tolerance: EditPointer.edgeReach * scale.secondsPerPoint) != nil
                    }
                    if overEdge != edge { overEdge = edge }
                }
                .pointerStyle(overEdge || pointer.trimming != nil ? .columnResize : nil)
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    model.apply(pointer.output(model.pointerContext, from: scale.time(value.startLocation.x), to: scale.time(value.location.x),
                                               inRuler: value.startLocation.y < EditMetrics.ruler, moved: abs(value.translation.width),
                                               secondsPerPoint: scale.secondsPerPoint))
                }.onEnded { value in
                    model.apply(pointer.endOutput(model.pointerContext, at: scale.time(value.location.x)))
                })
            }
            .modifier(LaneZoomGestures(model: model, lane: .output))
            .modifier(LaneFrame(focused: model.focus == .output))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(EditMetrics.space)) } action: { onLaneFrame($0) }
            .selfTestFrame("editOutput")
            .accessibilityElement(children: .contain)
            .accessibilityLabel(.ui("편집 결과 타임라인"))
            .laneZoomAction(model, .output)
            .accessibilityChildren {
                // VoiceOver로 클립을 고른다(끌어 옮기기는 아래 앞으로·뒤로 단추, 다듬기는 마디 칸).
                HStack(spacing: 0) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        Rectangle()
                            .accessibilityLabel(.ui("클립 \(index + 1), 마디 \(entry.range.description)"))
                            .accessibilityAddTraits(model.selectedClip == entry.id ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { model.selectedClip = entry.id }
                    }
                }
            }
            EditSeamBar(model: model)
                .frame(height: 20)
        }
    }
}

/// 클립·이음새·옮긴 큐·눈금(재생 위치를 읽지 않는다). 확대하면 보이는 자리만 그린다.
private struct EditOutputLayer: View {
    let model: TrackEditModel
    let scale: EditLaneScale
    let dragging: TrackEditModel.Entry.ID?

    var body: some View {
        let clips = model.clipLayout
        let entries = model.entries
        let selected = model.selectedClip
        let seams = model.edit.map { $0.pieces.dropFirst().map(\.outputStart) } ?? []
        let placed = model.carry?.placed ?? []
        let bars = model.outputLayout
        let scale = scale
        Canvas { context, size in
            guard let length = clips.last?.outputEnd, length > 0, clips.count == entries.count else {
                context.draw(Text(.ui("원곡 파형을 끌어 구간을 고른 뒤 ‘결과에 넣기’를 누르거나 여기로 끌어 오면 이어집니다"))
                    .font(.callout).foregroundStyle(Palette.rulerText),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let x = { (t: Double) in scale.x(t) }
            let ruler = EditMetrics.ruler
            let lane = CGRect(x: 0, y: ruler + 2, width: size.width, height: size.height - ruler - 4)
            for (index, clip) in clips.enumerated() {
                let color = EditColors.entry(index)
                let rect = CGRect(x: x(clip.outputStart), y: lane.minY, width: max(2, x(clip.outputEnd) - x(clip.outputStart)), height: lane.height)
                let body = rect.insetBy(dx: 0.5, dy: 0)
                guard body.maxX >= 0, body.minX <= size.width else { continue }
                // 보이는 부분만 그린다(확대하면 클립이 창보다 몇십 배 넓다).
                let shown = body.intersection(CGRect(x: -2, y: body.minY, width: size.width + 4, height: body.height))
                var slice = context
                slice.clip(to: Path(roundedRect: body, cornerRadius: 3))
                slice.opacity = entries[index].id == dragging ? 0.35 : 1
                slice.fill(Path(shown), with: .color(color.opacity(0.16)))
                if let waveform = model.waveform, shown.width > 0 {
                    let from = clip.sourceStart + scale.time(shown.minX) - clip.outputStart
                    let to = clip.sourceStart + scale.time(shown.maxX) - clip.outputStart
                    let wave = CGRect(x: shown.minX, y: body.minY + 16, width: shown.width, height: body.height - 16)
                    drawBands(slice, waveform: waveform, from: from - model.timelineOffset, to: to - model.timelineOffset, in: wave)
                }
                // 머리 띠: 번호와 원곡 마디(확대해 클립 머리가 왼쪽 밖이면 보이는 왼쪽 끝에 붙인다)
                slice.fill(Path(CGRect(x: shown.minX, y: body.minY, width: shown.width, height: 14)), with: .color(color.opacity(0.85)))
                if shown.width > 18 {
                    let label = shown.width > 70 ? "\(index + 1) · \(clip.bars.description)" : "\(index + 1)"
                    slice.draw(Text(verbatim: label).font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundStyle(.black),
                               at: CGPoint(x: max(body.minX, 0) + 4, y: body.minY + 7), anchor: .leading)
                }
                let isSelected = entries[index].id == selected
                context.stroke(Path(roundedRect: body.insetBy(dx: isSelected ? 1 : 0.5, dy: isSelected ? 1 : 0.5), cornerRadius: 3),
                               with: .color(isSelected ? .white : color.opacity(0.9)), lineWidth: isSelected ? 2 : 1)
            }
            // 이음새(원곡에서 이어지지 않는 경계): 흰 점선
            for seam in seams {
                let px = x(seam)
                guard px >= -2, px <= size.width + 2 else { continue }
                var line = Path()
                line.move(to: CGPoint(x: px, y: ruler))
                line.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(line, with: .color(EditColors.seam), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            // 옮긴 큐: 머리 띠 아래 작은 삼각형(핫큐 초록·메모리 빨강·루프 주황)
            for cue in placed {
                let px = x(cue.time), top = lane.minY + 14
                guard px >= -5, px <= size.width + 5 else { continue }
                var mark = Path()
                mark.move(to: CGPoint(x: px - 4, y: top))
                mark.addLine(to: CGPoint(x: px + 4, y: top))
                mark.addLine(to: CGPoint(x: px, y: top + 6))
                mark.closeSubpath()
                context.fill(mark, with: .color(Palette.color(for: cue)))
            }
            if let bars {
                drawBarRuler(context, layout: bars, bars: visibleBars(bars, scale.visible), x: x, height: ruler, width: size.width)
            }
        }
    }
}

/// 끌어 온 클립·구간을 놓을 자리(클립 사이 세로 막대, 넣을 구간이면 그 마디를 적는다)
private struct EditDropMarker: View {
    let model: TrackEditModel
    let scale: EditLaneScale
    let offset: Int
    let label: String?

    var body: some View {
        let clips = model.clipLayout
        let scale = scale, label = label
        Canvas { context, size in
            let time = offset < clips.count ? clips[offset].outputStart : clips.last?.outputEnd ?? 0
            let px = min(max(scale.x(time), 1.5), size.width - 1.5)
            context.fill(Path(CGRect(x: px - 1.5, y: EditMetrics.ruler, width: 3, height: size.height - EditMetrics.ruler)),
                         with: .color(.accentColor))
            if let label {
                let text = context.resolve(Text(verbatim: label).font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white))
                let textSize = text.measure(in: size)
                let chip = CGRect(x: min(px + 4, size.width - textSize.width - 10), y: EditMetrics.ruler + 18,
                                  width: textSize.width + 8, height: textSize.height + 4)
                context.fill(Path(roundedRect: chip, cornerRadius: 4), with: .color(.accentColor))
                context.draw(text, at: CGPoint(x: chip.midX, y: chip.midY))
            }
        }
        .allowsHitTesting(false)
    }
}

/// 원곡에서 고른 구간을 끌어 오는 동안 놓을 자리(끌기는 원곡 줄이 받는다)
private struct EditInsertMarker: View {
    let model: TrackEditModel
    let scale: EditLaneScale

    var body: some View {
        if let insertion = model.insertPreview {
            EditDropMarker(model: model, scale: scale, offset: insertion.offset, label: "+ \(insertion.range.description)")
        }
    }
}

/// 가장자리를 끄는 동안: 새 가장자리(마디 줄에 붙은 자리)와 새 구간. 줄어드는 쪽은 어둡게, 늘어나는 쪽은 강조색으로.
private struct EditTrimMarker: View {
    let model: TrackEditModel
    let scale: EditLaneScale
    let trim: EditPointer.Trim

    var body: some View {
        let clips = model.clipLayout
        let scale = scale, trim = trim
        Canvas { context, size in
            guard let layout = model.layout, clips.indices.contains(trim.clip) else { return }
            let clip = clips[trim.clip]
            let old = trim.edge == .end ? clip.outputEnd : clip.outputStart
            let new = trim.edge == .end ? clip.outputEnd + layout.end(ofBar: trim.range.last) - clip.sourceEnd
                : clip.outputStart + layout.start(ofBar: trim.range.first) - clip.sourceStart
            let top = EditMetrics.ruler + 2, height = size.height - top - 2
            let a = scale.x(min(old, new)), b = scale.x(max(old, new))
            let shrinking = trim.edge == .end ? new < old : new > old
            if b - a > 0.5 {
                context.fill(Path(CGRect(x: a, y: top, width: b - a, height: height)),
                             with: .color(shrinking ? .black.opacity(0.55) : Color.accentColor.opacity(0.3)))
            }
            let px = scale.x(new)
            context.fill(Path(CGRect(x: px - 1, y: top, width: 2, height: height)), with: .color(.accentColor))
            let text = context.resolve(Text(verbatim: trim.range.description).font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white))
            let textSize = text.measure(in: size)
            let x = trim.edge == .end ? px - textSize.width - 12 : px + 4
            let chip = CGRect(x: min(max(x, 2), size.width - textSize.width - 10), y: top + 16,
                              width: textSize.width + 8, height: textSize.height + 4)
            context.fill(Path(roundedRect: chip, cornerRadius: 4), with: .color(.accentColor))
            context.draw(text, at: CGPoint(x: chip.midX, y: chip.midY))
        }
        .allowsHitTesting(false)
    }
}

/// 이음새마다 들어 보기 단추(타임라인 아래, 이음새 자리). 확대하면 보이는 이음새만.
private struct EditSeamBar: View {
    let model: TrackEditModel

    var body: some View {
        GeometryReader { geo in
            if let edit = model.edit, edit.duration > 0 {
                let scale = EditLaneScale(model, .output, width: geo.size.width)
                ForEach(Array(edit.pieces.enumerated().dropFirst()).filter { scale.visible.contains($0.element.outputStart) },
                        id: \.offset) { piece, item in
                    let playing = model.playing == .output && model.auditioning == piece
                    Button {
                        if playing { model.pause() } else { model.auditionSeam(piece) }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "scissors")
                            Image(systemName: playing ? "stop.fill" : "play.fill")
                        }
                        .font(.system(size: 9))
                        .frame(width: 30, height: 14)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!model.canPlay(.output))
                    .help(.ui("이음새 앞 2마디부터 뒤 2마디까지 들어 봅니다(섞는 소리까지 결과와 같습니다)"))
                    .accessibilityLabel(playing ? String(ui: "멈추기") : String(ui: "이음새 \(piece) 듣기"))
                    .position(x: min(max(scale.x(item.outputStart), 20), geo.size.width - 20), y: geo.size.height / 2)
                }
            }
        }
    }
}
