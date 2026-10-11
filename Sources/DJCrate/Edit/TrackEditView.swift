import DJCApplication
import DJCDomain
import SwiftUI

/// 곡 편집 창: 원곡 줄(재생·끌어 고르기) → 결과 타임라인(재생·자르기·복제·지우기·끌어 옮기기·실행 취소) → 고른 클립 → 렌더.
struct TrackEditView: View {
    @Bindable var model: TrackEditModel
    let deck: DeckModel
    var store: LibraryStore? = nil
    var reflection: ReflectionCoordinator? = nil
    /// 두 줄의 처음 누르기·끌기 상태(끄는 중 모습을 캡처할 때)
    var sourcePointer = EditPointer()
    var outputPointer = EditPointer()
    /// 두 줄 자리(편집 창 좌표). 원곡에서 고른 구간을 결과 줄로 끌어 넣을 때 쓴다.
    @State private var sourceFrame = CGRect.zero
    @State private var outputFrame = CGRect.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditHeader(model: model)
            if let reason = model.blockedReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(UIColors.warning.color)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(UIColors.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                if let store, store.recoveryKinds(for: model.row).contains(.grid) {
                    Button(.ui("그리드 현재값 가져오기…")) {
                        reflection?.startRecovery(row: model.row, kind: .grid, anchor: .editWindow)
                    }
                }
                Spacer(minLength: 0)
            } else {
                SourceLaneBar(model: model)
                VStack(spacing: 3) {
                    EditSourceStrip(model: model, outputFrame: outputFrame.offsetBy(dx: -sourceFrame.minX, dy: -sourceFrame.minY),
                                    pointer: sourcePointer)
                        .frame(height: 104)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(EditMetrics.space)) } action: { sourceFrame = $0 }
                    EditZoomBar(model: model, lane: .source)
                }
                Divider().padding(.vertical, 4)
                OutputLaneBar(model: model)
                VStack(spacing: 3) {
                    EditOutputStrip(model: model, pointer: outputPointer) { outputFrame = $0 }
                        .frame(minHeight: 140, maxHeight: 260)
                    EditZoomBar(model: model, lane: .output)
                }
                ClipInspector(model: model)
                Spacer(minLength: 0)
                Divider()
                EditFooter(model: model)
            }
        }
        .padding(16)
        .coordinateSpace(.named(EditMetrics.space))
        .frame(minWidth: 760, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        // 덱을 다시 재생하면 창의 재생은 멈춘다(두 소리가 겹치지 않게).
        .onChange(of: deck.isPlaying) { _, playing in if playing { model.pause() } }
        // 이 창에서 연 막힌 초안 복구 시트는 이 창에 붙인다(#232).
        .modifier(RecoverySheetHost(store: store, anchor: .editWindow))
    }
}

// MARK: - 머리

private struct EditHeader: View {
    let model: TrackEditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.row.title).font(.title3.bold()).lineLimit(1)
                Text(model.row.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            if let layout = model.layout {
                let notes = [
                    layout.segment.bpm.formatted(.number.precision(.fractionLength(2)).grouping(.never)) + " BPM",
                    String(ui: "마디 \(layout.count)개"),
                    String(ui: "1마디 \(layout.barLength, specifier: "%.3f")초"),
                    layout.hasLeadIn ? String(ui: "첫 다운비트 앞 곡 머리(0마디) \(layout.firstDownbeat.clockText)") : nil,
                    layout.lastBarIsPartial ? String(ui: "마지막 마디는 곡 끝에서 잘림") : nil,
                ].compactMap { $0 }
                Text(notes.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 줄 머리

/// 줄마다 재생·일시정지
private struct LanePlayButton: View {
    let model: TrackEditModel
    let lane: TrackEditModel.Lane

    var body: some View {
        let playing = model.playing == lane
        Button {
            if playing { model.pause() } else { model.play(lane) }
        } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .frame(width: 16)
        }
        .disabled(!model.canPlay(lane))
        .help(lane == .source
              ? String(ui: "원곡을 재생·일시정지합니다. 스페이스바는 마지막으로 누른 줄을 재생합니다")
              : String(ui: "편집 결과를 재생·일시정지합니다. 스페이스바는 마지막으로 누른 줄을 재생합니다"))
        .accessibilityLabel(playing ? String(ui: "일시정지") : lane == .source ? String(ui: "원곡 재생") : String(ui: "결과 재생"))
    }
}

/// 재생선 시각과 마디(재생 중에만 초당 15번 바뀐다. 이 글자만 따로 그린다)
private struct LaneClock: View {
    let model: TrackEditModel
    let lane: TrackEditModel.Lane

    var body: some View {
        if model.playing == lane {
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { _ in label(model.position(lane)) }
        } else {
            label(model.position(lane))
        }
    }

    private func label(_ time: Double) -> some View {
        let layout = lane == .source ? model.layout : model.outputLayout
        let bar = layout?.bar(at: time)
        return HStack(spacing: 6) {
            Text(lane == .source ? time.clockText : "\(time.clockText) / \(model.length(.output).clockText)")
                .monospacedDigit()
            if let bar {
                // 몇 번째 마디(위치)는 마디 수(개수, "%lld마디")와 번역이 달라서 문자열로 넣어 키("%@마디")를 나눈다.
                Text(bar == 0 ? String(ui: "곡 머리(0마디)") : String(ui: "\(String(bar))마디")).monospacedDigit().bold()
            }
        }
        .font(.callout)
    }
}

private struct SourceLaneBar: View {
    let model: TrackEditModel

    var body: some View {
        HStack(spacing: 8) {
            LanePlayButton(model: model, lane: .source)
            Text(.ui("원곡")).font(.headline)
            LaneClock(model: model, lane: .source)
            if !model.isAudioReady, model.message == nil {
                ProgressView().controlSize(.mini)
                    .help(.ui("원곡을 메모리에 푸는 중입니다"))
            }
            Spacer(minLength: 8)
            if let selection = model.selection, let layout = model.layout {
                let bars = String(ui: "\(selection.last - max(selection.first, 1) + 1)마디")
                let start = layout.start(ofBar: selection.first).clockText, end = layout.end(ofBar: selection.last).clockText
                Text(selection.first == 0
                     ? String(ui: "고른 구간 마디 \(selection.description) · \(bars) + 곡 머리 · \(start)–\(end)")
                     : String(ui: "고른 구간 마디 \(selection.description) · \(bars) · \(start)–\(end)"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(.ui("파형을 끌어 마디 구간을 고르세요"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.addSelection()
            } label: {
                Label(.ui("결과에 넣기"), systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selection == nil)
            .help(model.selection == nil ? String(ui: "넣을 구간이 없으니 원곡 파형을 끌어 마디 구간을 고르세요") : String(ui: "고른 구간을 고른 클립 뒤(없으면 끝)에 넣습니다(⏎). 결과로 끌면 원하는 자리에 넣습니다"))
        }
        .controlSize(.small)
    }
}

private struct OutputLaneBar: View {
    let model: TrackEditModel

    var body: some View {
        HStack(spacing: 8) {
            LanePlayButton(model: model, lane: .output)
            Text(.ui("결과")).font(.headline)
            LaneClock(model: model, lane: .output)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button { model.splitAtPlayhead() } label: { Label(.ui("자르기"), systemImage: "scissors") }
                    .disabled(model.edit == nil)
                    .help(model.edit == nil ? String(ui: "자를 결과가 없으니 원곡 구간을 먼저 결과에 넣으세요") : String(ui: "결과 재생선에서 가장 가까운 마디 줄로 클립을 둘로 나눕니다(⌘B)"))
                Button { model.duplicateSelected() } label: { Label(.ui("복제"), systemImage: "plus.square.on.square") }
                    .disabled(model.selectedClip == nil)
                    .help(model.selectedClip == nil ? String(ui: "복제할 클립을 결과에서 먼저 고르세요") : String(ui: "고른 클립 바로 뒤에 같은 구간을 하나 더 둡니다(⌘D). 인트로를 늘일 때 씁니다"))
                Button { model.removeSelected() } label: { Label(.ui("지우기"), systemImage: "trash") }
                    .disabled(model.selectedClip == nil)
                    .help(model.selectedClip == nil ? String(ui: "지울 클립을 결과에서 먼저 고르세요") : String(ui: "고른 클립을 결과에서 뺍니다(⌫)"))
                Divider().frame(height: 16).padding(.horizontal, 4)
                Button { model.undo() } label: { Label(.ui("실행 취소"), systemImage: "arrow.uturn.backward") }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canUndo)
                    .help(model.canUndo ? String(ui: "실행 취소(⌘Z)") : String(ui: "취소할 편집이 없으니 구간을 편집한 뒤 실행 취소하세요"))
                Button { model.redo() } label: { Label(.ui("실행 복귀"), systemImage: "arrow.uturn.forward") }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canRedo)
                    .help(model.canRedo ? String(ui: "실행 복귀(⇧⌘Z)") : String(ui: "복귀할 편집이 없으니 실행 취소한 뒤 실행 복귀하세요"))
            }
        }
        .controlSize(.small)
    }
}

// MARK: - 고른 클립

private struct ClipInspector: View {
    let model: TrackEditModel

    var body: some View {
        HStack(spacing: 8) {
            if let index = model.selectedIndex, let layout = model.layout {
                let entry = model.entries[index]
                let minFirst = layout.hasLeadIn ? 0 : 1
                Text(verbatim: "\(index + 1)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.black)
                    .frame(width: 22, height: 18)
                    .background(EditColors.entry(index), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel(.ui("클립 \(index + 1)"))
                Text(.ui("마디")).foregroundStyle(.secondary)
                BarField(label: String(ui: "시작 마디"), value: entry.range.first, range: minFirst...max(minFirst, entry.range.last)) {
                    model.setFirst(entry.id, $0)
                }
                Text(verbatim: "–")
                BarField(label: String(ui: "끝 마디"), value: entry.range.last, range: max(1, entry.range.first)...max(1, layout.count)) {
                    model.setLast(entry.id, $0)
                }
                let bars = String(ui: "\(entry.range.last - max(entry.range.first, 1) + 1)마디")
                let start = layout.start(ofBar: entry.range.first).clockText, end = layout.end(ofBar: entry.range.last).clockText
                Text(entry.range.first == 0 ? String(ui: "\(bars) + 곡 머리 · 원곡 \(start)–\(end)") : String(ui: "\(bars) · 원곡 \(start)–\(end)"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    Button { model.move(entry.id, by: -1) } label: { Image(systemName: "arrow.left") }
                        .disabled(index == 0)
                        .help(index == 0 ? String(ui: "첫 클립은 더 앞으로 옮길 수 없으니 뒤로 옮기거나 다른 클립을 고르세요") : String(ui: "앞으로"))
                        .accessibilityLabel(.ui("클립 \(index + 1) 앞으로"))
                    Button { model.move(entry.id, by: 1) } label: { Image(systemName: "arrow.right") }
                        .disabled(index == model.entries.count - 1)
                        .help(index == model.entries.count - 1 ? String(ui: "마지막 클립은 더 뒤로 옮길 수 없으니 앞으로 옮기거나 다른 클립을 고르세요") : String(ui: "뒤로"))
                        .accessibilityLabel(.ui("클립 \(index + 1) 뒤로"))
                }
                .buttonStyle(.borderless)
            } else {
                Text(.ui("클립을 누르면 고르고, 끌면 순서를 바꾸고, 가장자리를 끌면 마디 단위로 다듬습니다. 위 눈금을 누르거나 끌면 재생선을 옮깁니다"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
        .frame(minHeight: 24)
    }
}

/// 마디 번호 칸(숫자 입력 + 위아래)
private struct BarField: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let set: (Int) -> Void

    var body: some View {
        let binding = Binding(get: { value }, set: { set($0) })
        HStack(spacing: 2) {
            TextField(label, value: binding, format: .number)
                .frame(width: 40)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
            Stepper(label, value: binding, in: range).labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

// MARK: - 결과·렌더

private struct EditFooter: View {
    @Bindable var model: TrackEditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let error = model.planError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(UIColors.warning.color)
                        .textSelection(.enabled)
                } else if let edit = model.edit {
                    Text(summary(edit))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if let message = model.message {
                    Label(message.text, systemImage: message.kind.icon)
                        .font(.caption)
                        .foregroundStyle(message.kind.tint)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
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
                    Button {
                        model.render()
                    } label: {
                        Label(.ui("렌더해서 추가한 곡에 넣기"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRender)
                    .help(model.renderUnavailableReason ?? String(ui: "WAV로 렌더해 ‘추가한 곡’에 넣습니다(그리드는 편집으로 옮긴 값, 큐는 옮긴 위치, 곡 정보는 원곡). 원곡과 rekordbox는 그대로이고, rekordbox로는 추가한 곡에서 넘깁니다"))
                }
            }
            .controlSize(.regular)
        }
    }

    private func summary(_ edit: TrackEdit) -> String {
        var parts = [String(ui: "결과 \(edit.barCount)마디"), edit.duration.clockText, String(ui: "이음새 \(max(0, edit.pieces.count - 1))곳")]
        if let carry = model.carry {
            parts.append(String(ui: "큐 \(carry.placed.count)개 옮김"))
            if !carry.dropped.isEmpty {
                let reasons = Dictionary(grouping: carry.dropped, by: \.reason.label).map { "\($0.key) \($0.value.count)" }.sorted()
                parts.append(String(ui: "\(carry.dropped.count)개 빠짐(\(reasons.joined(separator: ", ")))"))
            }
        }
        return parts.joined(separator: " · ")
    }
}
