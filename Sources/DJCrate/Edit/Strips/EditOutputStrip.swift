import DJCDomain
import SwiftUI

// MARK: - 결과 타임라인

/// 편집 결과: 클립(목록 구간)을 이어 놓은 타임라인. 클립을 누르면 고르고 재생선을 옮기며, 끌면 순서를 바꾸고,
/// 가장자리를 끌면 마디 줄에 붙여 다듬는다. 위 눈금을 누르거나 끌면 재생선만 옮긴다. 아래 줄의 가위 단추로 이음새 앞뒤를 들어 본다.
/// 조작은 글이 아니라 커서(클립 위 손, 가장자리 위 좌우 화살표)·마우스를 올리면 나타나는 가장자리 핸들·다듬는 동안의 값이 알린다.
/// 비면 점선 놓기 칸이 뜬다.
struct EditOutputStrip: View {
    let model: TrackEditModel
    /// 클립 줄 자리를 알린다(편집 창 좌표). 원곡에서 고른 구간을 끌어 놓을 자리를 찾는다.
    let onLaneFrame: (CGRect) -> Void
    @State private var pointer: EditPointer

    /// - Parameters:
    ///   - pointer: 처음 누르기·끌기 상태(끄는 중 모습을 캡처할 때)
    ///   - hover: 처음 마우스를 올린 자리(올린 모습을 캡처할 때)
    init(model: TrackEditModel, pointer: EditPointer = EditPointer(), hover: EditHover? = nil,
         onLaneFrame: @escaping (CGRect) -> Void = { _ in }) {
        self.model = model
        self.onLaneFrame = onLaneFrame
        _pointer = State(initialValue: pointer)
        _hover = State(initialValue: hover)
    }
    /// 마우스가 올라 있는 클립·가장자리(커서 모양과 핸들)
    @State private var hover: EditHover?
    @State private var spot = EditHoverSpot()

    /// 마지막 마우스 자리를 지금 목록·보이는 자리로 다시 읽는다.
    private func refreshHover() {
        var next: EditHover?
        if let point = spot.point, spot.width > 0 {
            let scale = EditLaneScale(model, .output, width: spot.width)
            next = model.pointerContext.outputHover(atOutput: scale.time(point.x), inRuler: point.y < EditMetrics.ruler,
                                                    secondsPerPoint: scale.secondsPerPoint)
        }
        if hover != next { hover = next }
    }

    /// 끄는 중이 아닐 때만 올린 모습을 보인다. 끄는 동안은 다듬기 표시·놓을 자리가 맡는다.
    private var idleHover: EditHover? { pointer.mode == nil ? hover : nil }

    private var cursor: PointerStyle? {
        if pointer.trimming != nil { return .columnResize }
        if pointer.dragging != nil { return .grabActive }
        switch hover {
        case .edge?: return .columnResize
        case .clip?: return .grabIdle
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let scale = EditLaneScale(model, .output, width: geo.size.width)
                ZStack {
                    EditOutputLayer(model: model, scale: scale, dragging: pointer.dragging)
                    EditEmptyDrop(model: model)
                    if let hover = idleHover {
                        EditHoverHandles(model: model, scale: scale, hover: hover)
                    }
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
                    if case let .active(point) = phase {
                        spot.point = point
                        spot.width = geo.size.width
                    } else {
                        spot.point = nil
                    }
                    refreshHover()
                }
                .pointerStyle(cursor)
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    model.apply(pointer.output(model.pointerContext, from: scale.time(value.startLocation.x), to: scale.time(value.location.x),
                                               inRuler: value.startLocation.y < EditMetrics.ruler, moved: abs(value.translation.width),
                                               secondsPerPoint: scale.secondsPerPoint))
                }.onEnded { value in
                    model.apply(pointer.endOutput(model.pointerContext, at: scale.time(value.location.x)))
                    // 끄는 동안에는 올림 이벤트가 오지 않는다. 손을 뗀 자리로 다시 정한다(순서·구간이 바뀌었을 수 있다).
                    spot.point = value.location
                    spot.width = geo.size.width
                    refreshHover()
                })
            }
            .onChange(of: model.entries) { refreshHover() }
            .onChange(of: model.viewport(.output)) { refreshHover() }
            .modifier(LaneZoomGestures(model: model, lane: .output))
            .modifier(LaneFrame(focused: model.focus == .output))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(EditMetrics.space)) } action: { onLaneFrame($0) }
            .selfTestFrame("editOutput")
            .accessibilityElement(children: .contain)
            .accessibilityLabel(.ui("편집 결과 타임라인"))
            // 컨테이너 힌트는 읽히지 않을 수 있어 클립이 있을 때의 힌트는 클립마다 둔다(아래).
            .accessibilityHint(model.entries.isEmpty ? Text(.ui("비어 있습니다. 원곡에서 구간을 고른 뒤 결과에 넣기를 누르세요")) : Text(verbatim: ""))
            .laneZoomAction(model, .output)
            .accessibilityChildren {
                // VoiceOver로 클립을 고른다(끌어 옮기기는 아래 앞으로·뒤로 단추, 다듬기는 마디 칸).
                HStack(spacing: 0) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        Rectangle()
                            .accessibilityLabel(.ui("클립 \(index + 1), 마디 \(entry.range.description)"))
                            .accessibilityHint(.ui("클립을 고른 뒤 아래 클립 칸의 앞으로·뒤로 단추로 순서를 바꾸고 마디 칸으로 다듬습니다"))
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
            // 비면 점선 놓기 칸(`EditEmptyDrop`)이 맡는다.
            guard !EditOutputBlank.isBlank(clips: clips, entryCount: entries.count) else { return }
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
            let text = context.resolve(Text(verbatim: trim.range.liveText).font(.system(size: 10, weight: .semibold).monospacedDigit())
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

/// 결과가 비었는지(클립이 없거나 길이가 0이거나 목록과 어긋남)
enum EditOutputBlank {
    static func isBlank(clips: [TrackEdit.Piece], entryCount: Int) -> Bool {
        (clips.last?.outputEnd ?? 0) <= 0 || clips.count != entryCount
    }
}

/// 빈 결과 줄: 점선 놓기 칸과 첫 행동 한 줄. 원곡에서 고른 구간을 끌어 오면 칸이 강조색으로 바뀐다.
/// 칸이 따로 뷰인 것은 끄는 동안 바뀌는 값(`insertPreview`)을 큰 클립 층이 읽지 않게 하려는 것이다(UI-1).
private struct EditEmptyDrop: View {
    let model: TrackEditModel

    var body: some View {
        if EditOutputBlank.isBlank(clips: model.clipLayout, entryCount: model.entries.count) {
            let hot = model.insertPreview != nil
            Canvas { context, size in
                let box = Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10), cornerRadius: 8)
                if hot { context.fill(box, with: .color(Color.accentColor.opacity(0.18))) }
                context.stroke(box, with: .color(hot ? Color.accentColor : Palette.rulerText.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                context.draw(Text(.ui("고른 구간을 여기로 끌어 놓으세요")).font(.callout)
                    .foregroundStyle(hot ? Color.white : Palette.rulerText), at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
            .allowsHitTesting(false)
        }
    }
}

/// 마우스를 올린 클립의 양쪽 가장자리 핸들. 포인터가 가장자리 위면 그쪽 핸들이 또렷해진다(누르면 다듬기).
/// 클립이 좁으면(양쪽 핸들이 겹치면) 포인터가 있는 가장자리 핸들만 그린다.
private struct EditHoverHandles: View {
    let model: TrackEditModel
    let scale: EditLaneScale
    let hover: EditHover

    var body: some View {
        let clips = model.clipLayout
        let scale = scale
        let target: (index: Int, edge: EditEdge?) = switch hover {
        case let .edge(hit): (hit.clip, hit.edge)
        case let .clip(index): (index, nil)
        default: (-1, nil)
        }
        Canvas { context, size in
            guard clips.indices.contains(target.index) else { return }
            let clip = clips[target.index]
            let from = scale.x(clip.outputStart), to = scale.x(clip.outputEnd)
            let width: CGFloat = 7, top = EditMetrics.ruler + 2, lane = size.height - top - 2
            let height = min(40, max(18, lane * 0.4))
            func handle(_ edge: EditEdge) {
                let px = edge == .start ? from : to
                guard px >= -width, px <= size.width + width else { return }
                // 클립 안쪽에 그려 이웃 클립 가장자리와 겹치지 않게 한다.
                let x = edge == .start ? max(px, 0) + 1 : min(px, size.width) - width - 1
                let rect = CGRect(x: x, y: top + (lane - height) / 2, width: width, height: height)
                let active = target.edge == edge
                let shape = Path(roundedRect: rect, cornerRadius: 3)
                // 밝은 파형 위에서도 어두운 파형 위에서도 보이게 어두운 바탕에 흰 테두리. 포인터가 있는 쪽은 흰 바탕에 강조 테두리.
                context.fill(shape, with: .color(active ? .white : .black.opacity(0.7)))
                context.stroke(shape, with: .color(active ? .accentColor : .white.opacity(0.85)), lineWidth: active ? 2 : 1)
                for dx in [CGFloat(2.5), 4.5] {
                    context.fill(Path(CGRect(x: rect.minX + dx, y: rect.minY + 6, width: 1, height: height - 12)),
                                 with: .color(active ? .black.opacity(0.5) : .white.opacity(0.7)))
                }
            }
            if to - from >= 2 * (width + 4) {
                handle(.start)
                handle(.end)
            } else if let edge = target.edge {
                handle(edge)
            }
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
                    .help(.ui("이음새 앞뒤 2마디 듣기"))
                    .accessibilityLabel(playing ? String(ui: "멈추기") : String(ui: "이음새 \(piece) 듣기"))
                    .position(x: min(max(scale.x(item.outputStart), 20), geo.size.width - 20), y: geo.size.height / 2)
                }
            }
        }
    }
}
