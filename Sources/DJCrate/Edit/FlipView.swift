import DJCDomain
import SwiftUI

/// Flip 결과 창: 원곡에서 쓴 구간 → 결과(조각·이음새·옮긴 큐, 누르거나 끌어 재생선) → 제목·렌더.
struct FlipView: View {
    @Bindable var model: FlipModel
    let deck: DeckModel
    /// 이 결과를 버리고 덱에서 다시 기록한다.
    var onRerecord: () -> Void = {}
    /// 이 결과를 버리고 창을 닫는다.
    var onDiscard: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlipHeader(model: model)
            Text(.ui("원곡에서 쓴 구간")).font(.caption).foregroundStyle(.secondary)
            FlipSourceStrip(model: model)
                .frame(height: 84)
            Divider().padding(.vertical, 4)
            HStack(spacing: 10) {
                FlipPlayButton(model: model)
                Text(.ui("결과")).font(.headline)
                FlipClock(model: model)
                Spacer(minLength: 0)
            }
            FlipOutputStrip(model: model)
                .frame(minHeight: 120, maxHeight: 240)
            FlipNotes(model: model)
            Spacer(minLength: 0)
            Divider()
            FlipFooter(model: model, onRerecord: onRerecord, onDiscard: onDiscard)
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        // 덱을 다시 재생하면 창의 재생은 멈춘다(두 소리가 겹치지 않게).
        .onChange(of: deck.isPlaying) { _, playing in if playing { model.pause() } }
    }
}

// MARK: - 머리

private struct FlipHeader: View {
    let model: FlipModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.row.title).font(.title3.bold()).lineLimit(1)
                Text(model.row.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(String(ui: "점프 \(model.jumpCount)번 · 결과 \(model.duration.clockText) (원곡 \(model.sourceDuration.clockText))"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 줄

/// 조각 색(이웃한 조각이 잘 갈리게 편집 창과 같은 색을 돌려 쓴다)
private func flipColor(_ index: Int) -> Color { EditColors.entry(index) }

/// 원곡: 파형 + 결과에 쓴 구간(조각 색 띠) + 지금 듣는 원곡 자리. 누르지 않는다.
private struct FlipSourceStrip: View {
    let model: FlipModel

    var body: some View {
        ZStack {
            FlipSourceLayer(model: model)
            FlipPlayhead(model: model, lane: .source)
        }
        .background(Palette.well)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement()
        .accessibilityLabel(.ui("원곡 파형"))
        .accessibilityValue(String(ui: "결과에 쓴 구간 \(model.flip.pieces.count)개"))
    }
}

private struct FlipSourceLayer: View {
    let model: FlipModel

    var body: some View {
        let pieces = model.flip.pieces, length = model.sourceDuration
        Canvas { context, size in
            guard length > 0 else { return }
            let x = { (t: Double) in CGFloat(t / length) * size.width }
            let wave = CGRect(x: 0, y: 2, width: size.width, height: size.height - 14)
            if let waveform = model.waveform {
                drawBands(context, waveform: waveform, from: -model.timelineOffset, to: length - model.timelineOffset, in: wave)
            }
            // 결과에 쓴 구간: 아래 띠를 조각 순서대로 쌓아 뒤 조각이 위에 보인다.
            for (index, piece) in pieces.enumerated() {
                let from = x(piece.sourceStart), to = x(piece.sourceEnd)
                context.fill(Path(CGRect(x: from, y: size.height - 10, width: max(1, to - from), height: 6)),
                             with: .color(flipColor(index)))
            }
        }
    }
}

/// 결과: 조각(색 상자와 원곡 파형)·이음새(흰 점선)·옮긴 큐·재생선. 누르거나 끌면 재생선을 옮긴다.
private struct FlipOutputStrip: View {
    let model: FlipModel

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let time = { (x: CGFloat) in min(max(Double(x / width) * model.duration, 0), model.duration) }
            ZStack {
                FlipOutputLayer(model: model)
                FlipPlayhead(model: model, lane: .output)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if abs(value.translation.width) < 2 { return }
                model.scrub(to: time(value.location.x))
            }.onEnded { value in
                if abs(value.translation.width) < 2 { model.seek(to: time(value.location.x)) } else { model.endScrub() }
            })
        }
        .background(Palette.well)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement()
        .accessibilityLabel(.ui("Flip 결과"))
        .accessibilityValue(String(ui: "조각 \(model.flip.pieces.count)개, \(model.duration.clockText)"))
        .accessibilityHint(.ui("누르거나 끌어서 재생선을 옮깁니다. 스페이스바로 재생합니다"))
    }
}

private struct FlipOutputLayer: View {
    let model: FlipModel

    var body: some View {
        let pieces = model.flip.pieces, length = model.duration
        let seams = model.flip.seams, placed = model.carry.placed
        Canvas { context, size in
            guard length > 0 else { return }
            let x = { (t: Double) in CGFloat(t / length) * size.width }
            let lane = CGRect(x: 0, y: 2, width: size.width, height: size.height - 4)
            for (index, piece) in pieces.enumerated() {
                let color = flipColor(index)
                let rect = CGRect(x: x(piece.outputStart), y: lane.minY, width: max(1, x(piece.outputEnd) - x(piece.outputStart)), height: lane.height)
                var slice = context
                slice.clip(to: Path(rect))
                slice.fill(Path(rect), with: .color(color.opacity(0.16)))
                if let waveform = model.waveform {
                    let wave = CGRect(x: rect.minX, y: rect.minY + 12, width: rect.width, height: rect.height - 12)
                    drawBands(slice, waveform: waveform, from: piece.sourceStart - model.timelineOffset,
                              to: piece.sourceEnd - model.timelineOffset, in: wave)
                }
                slice.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 10)), with: .color(color.opacity(0.85)))
                if rect.width > 70 {
                    slice.draw(Text(verbatim: "\(index + 1) · \(piece.sourceStart.clockText)")
                        .font(.system(size: 8, weight: .semibold).monospacedDigit()).foregroundStyle(.black),
                               at: CGPoint(x: rect.minX + 3, y: rect.minY + 5), anchor: .leading)
                }
            }
            // 이음새(원곡에서 이어지지 않는 경계)
            for seam in seams {
                var line = Path()
                line.move(to: CGPoint(x: x(seam), y: lane.minY))
                line.addLine(to: CGPoint(x: x(seam), y: lane.maxY))
                context.stroke(line, with: .color(EditColors.seam.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            // 옮긴 큐: 머리 띠 아래 작은 삼각형(핫큐 초록·메모리 빨강·루프 주황)
            for cue in placed {
                let px = x(cue.time), top = lane.minY + 10
                var mark = Path()
                mark.move(to: CGPoint(x: px - 4, y: top))
                mark.addLine(to: CGPoint(x: px + 4, y: top))
                mark.addLine(to: CGPoint(x: px, y: top + 6))
                mark.closeSubpath()
                context.fill(mark, with: .color(Palette.color(for: cue)))
            }
        }
    }
}

/// 재생선(재생 중에만 초당 30번 다시 그린다). 원곡 줄에는 지금 듣는 원곡 자리를 그린다.
private struct FlipPlayhead: View {
    enum Lane { case source, output }

    let model: FlipModel
    let lane: Lane

    var body: some View {
        if model.playing {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in line(model.position) }
        } else {
            line(model.position)
        }
    }

    private func line(_ output: Double) -> some View {
        let time = lane == .output ? output : model.flip.sourceTime(atOutput: output) ?? model.sourceDuration
        let length = lane == .output ? model.duration : model.sourceDuration
        return Canvas { context, size in
            guard length > 0 else { return }
            let px = CGFloat(time / length) * size.width
            context.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(Palette.cue))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 재생 단추·시각

private struct FlipPlayButton: View {
    let model: FlipModel

    var body: some View {
        Button {
            model.togglePlay()
        } label: {
            Image(systemName: model.playing ? "pause.fill" : "play.fill")
                .frame(width: 16)
        }
        .disabled(!model.canPlay)
        .help(.ui("Flip 결과를 재생·일시정지합니다(스페이스바)"))
        .accessibilityLabel(model.playing ? String(ui: "일시정지") : String(ui: "결과 재생"))
    }
}

/// 재생선 시각(재생 중에만 초당 15번 바뀐다. 이 글자만 따로 그린다)
private struct FlipClock: View {
    let model: FlipModel

    var body: some View {
        if model.playing {
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { _ in label(model.position) }
        } else {
            label(model.position)
        }
    }

    private func label(_ time: Double) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(time.clockText) / \(model.duration.clockText)").monospacedDigit()
            if let index = model.pieceIndex(atOutput: time) {
                Text(String(ui: "조각 \(index + 1)/\(model.flip.pieces.count)")).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

// MARK: - 알림·렌더

private struct FlipNotes: View {
    let model: FlipModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let notice = model.gridNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(UIColors.warning.color)
                    .textSelection(.enabled)
            }
            if let message = model.message {
                Label(message.text, systemImage: message.kind.icon)
                    .font(.caption)
                    .foregroundStyle(message.kind.tint)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private var summary: String {
        let carry = model.carry
        var parts = [String(ui: "조각 \(model.flip.pieces.count)개"), String(ui: "이음새 \(model.flip.seams.count)곳"),
                     String(ui: "큐 \(carry.placed.count)개 옮김")]
        if !carry.dropped.isEmpty {
            let reasons = Dictionary(grouping: carry.dropped, by: \.reason.label).map { "\($0.key) \($0.value.count)" }.sorted()
            parts.append(String(ui: "\(carry.dropped.count)개 빠짐(\(reasons.joined(separator: ", ")))"))
        }
        if model.grid.count > 1 { parts.append(String(ui: "그리드 구간 \(model.grid.count)개")) }
        return parts.joined(separator: " · ")
    }
}

private struct FlipFooter: View {
    @Bindable var model: FlipModel
    let onRerecord: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(.ui("제목")).foregroundStyle(.secondary)
            TextField(.ui("새 곡 제목"), text: $model.title)
                .frame(minWidth: 180, maxWidth: 320)
                .disabled(model.renderProgress != nil)
            Spacer(minLength: 8)
            if let progress = model.renderProgress {
                ProgressView(value: progress)
                    .frame(width: 120)
                    .accessibilityLabel(.ui("렌더 진행"))
                Button(.ui("취소")) { model.cancelRender() }
            } else {
                Button(.ui("Flip 버리기…"), role: .destructive) { onDiscard() }
                    .help(.ui("이 기록을 버리고 창을 닫습니다. 원곡과 rekordbox는 그대로입니다"))
                Button(.ui("다시 기록…")) { onRerecord() }
                    .help(.ui("이 기록을 버리고 덱에서 Flip 기록을 다시 시작합니다"))
                Button {
                    model.render()
                } label: {
                    Label(.ui("렌더해서 추가한 곡에 넣기"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRender)
                .help(.ui("WAV로 렌더해 ‘추가한 곡’에 넣습니다(그리드·큐는 결과 위치로 옮긴 값, 곡 정보는 원곡). 원곡과 rekordbox는 그대로입니다"))
            }
        }
        .controlSize(.regular)
    }
}
