import AppKit
import DJCDomain
import SwiftUI

/// rekordbox식 그리드 편집. 모든 변경은 DJCrate 초안에만 저장된다.
struct GridEditorBar: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel
    @State private var bpm: Double?
    @State private var bpmFieldRevision = 0
    @FocusState private var bpmFocused: Bool

    private var invalidBPM: Bool { bpm.map { !GridDraft.bpmRange.contains($0) } ?? true }
    private var bpmWarning: String { String(ui: "BPM은 20…655.35 사이로 입력하세요") }

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        let controlHeight = CGFloat(TextScale.length(24, scale: textScale))
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 12, justified: true, centerItems: true) {
                headerTitle
                GridEditorHeaderInfo(deck: deck)
                headerActions
            }
            .frame(maxWidth: .infinity)
            if let reason = deck.gridUnavailableReason ?? deck.gridSourceNotice {
                Label(reason, systemImage: "lock").font(.scaled(.caption, textScale)).foregroundStyle(UIColors.warning.color)
            }
            FlowLayout(spacing: 12, justified: true) {
                HStack(spacing: 4) {
                    Button { deck.setGridAnchorAtPlayhead() } label: {
                        GridAnchorIcon()
                    }
                    .buttonStyle(GridEditorControlStyle(height: controlHeight, darkBackground: true))
                    .accessibilityLabel(.ui("여기서 그리드 시작"))
                    .help(.ui("플레이헤드 위치에 박을 정확히 놓고 1박으로"))
                }
                HStack(spacing: 4) {
                    TextField("BPM" as String, value: $bpm, format: .number.precision(.fractionLength(2)))
                        .id(bpmFieldRevision)
                        .focused($bpmFocused)
                        .frame(width: TextScale.length(64, scale: textScale), height: controlHeight)
                        .onSubmit { bpmFocused = false }
                        .onChange(of: bpmFocused) { _, focused in
                            if !focused { commitBPM() }
                        }
                        .onAppear { bpm = deck.gridBPM }
                        .onChange(of: deck.gridBPM) { bpm = deck.gridBPM }
                        .onChange(of: deck.row?.track.uuid) {
                            bpm = deck.gridBPM
                            bpmFocused = false
                            bpmFieldRevision += 1
                        }
                        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                            guard bpmFocused, deck.gridEditing, deck.canEditGrid,
                                  press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
                                  let value = bpm ?? deck.gridBPM, value.isFinite else { return .ignored }
                            let range = GridDraft.bpmRange
                            let hundredths = Int((min(max(value, range.lowerBound), range.upperBound) * 100).rounded())
                            let step = press.key == .upArrow ? 1 : -1
                            bpm = Double(min(max(hundredths + step, Int(range.lowerBound * 100)),
                                             Int(range.upperBound * 100))) / 100
                            return .handled
                        }
                        .help((invalidBPM ? bpmWarning : String(ui: "현재 템포 구간의 BPM (엔터를 누르거나 칸을 벗어나면 적용)"))
                              + " · " + String(ui: "↑·↓로 0.01씩 조정하고 길게 누르면 반복합니다"))
                    if invalidBPM && deck.gridDraft != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(UIColors.warning.color)
                            .accessibilityLabel(bpmWarning)
                            .help(bpmWarning)
                    }
                    Button("×2" as String) { deck.scaleGridBPM(2) }
                        .disabled(deck.gridBPM.map { !GridDraft.bpmRange.contains($0 * 2) } ?? true)
                        .help(deck.gridBPM.map { GridDraft.bpmRange.contains($0 * 2) } == true ? String(ui: "현재 템포 구간의 BPM을 두 배로 바꿉니다") : bpmWarning)
                    Button("÷2" as String) { deck.scaleGridBPM(0.5) }
                        .disabled(deck.gridBPM.map { !GridDraft.bpmRange.contains($0 * 0.5) } ?? true)
                        .help(deck.gridBPM.map { GridDraft.bpmRange.contains($0 * 0.5) } == true ? String(ui: "현재 템포 구간의 BPM을 절반으로 바꿉니다") : bpmWarning)
                    HStack(spacing: 0) {
                        Button { deck.tapTempo() } label: { Text(verbatim: "TAP") }
                            .help(String(ui: "박자에 맞춰 여러 번 눌러 BPM을 측정합니다") + " · "
                                  + String(ui: "탭 템포 (\(deck.shortcuts.keyLabel(for: .tapTempo)))") + " · "
                                  + String(ui: "우클릭: TAP 초기화"))
                            .accessibilityAction(named: .ui("TAP 초기화")) { deck.resetTapTempo() }
                    }
                    .background {
                        GeometryReader { geometry in
                            TapResetClickArea { deck.resetTapTempo() }
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .allowsHitTesting(false)
                        }
                    }
                    Button { if let tap = deck.tapBPM { deck.setGridBPM(tap) } } label: {
                        HStack(spacing: 4) {
                            if let tap = deck.tapBPM {
                                Text(verbatim: tap.formatted(.number.precision(.fractionLength(2)).grouping(.never)))
                                Text(.ui("적용"))
                            }
                        }
                        .font(.scaled(.caption, textScale).monospacedDigit())
                        .frame(width: TextScale.length(88, scale: textScale), height: controlHeight)
                    }
                    .disabled(deck.tapBPM.map { !GridDraft.bpmRange.contains($0) } ?? true)
                    .opacity(deck.tapBPM == nil ? 0 : 1)
                    .allowsHitTesting(deck.tapBPM != nil)
                    .accessibilityHidden(deck.tapBPM == nil)
                    .help(deck.tapBPM.map { GridDraft.bpmRange.contains($0) } == true ? String(ui: "측정한 TAP BPM을 현재 템포 구간에 적용합니다") : bpmWarning)
                }
                HStack(spacing: 4) {
                    ForEach([-10.0, -1.0, 1.0, 10.0], id: \.self) { milliseconds in
                        GridShiftButton(deck: deck, milliseconds: milliseconds)
                            .fixedSize()
                            .background(UIColors.gridControlFill, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .font(.scaled(.caption, textScale))
            .buttonStyle(GridEditorControlStyle(height: controlHeight))
            .disabled(!deck.gridEditing || !deck.canEditGrid)
        }
        .controlSize(ControlSize.small.scaled(textScale))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UIColors.draftFill, in: RoundedRectangle(cornerRadius: 6))
    }

    private var headerTitle: some View {
        HStack(spacing: 6) {
            Button { deck.gridEditing.toggle() } label: {
                Image(systemName: deck.gridEditing ? "lock.open.fill" : "lock.fill")
                    .font(.scaled(.caption, textScale))
                    .frame(width: TextScale.length(24, scale: textScale),
                           height: TextScale.length(24, scale: textScale))
                    .foregroundStyle(deck.gridEditing ? UIColors.draft.color : Color.secondary)
                    .background(UIColors.gridControlFill, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(!deck.canEditGrid)
            .accessibilityAddTraits(.isToggle)
            .accessibilityLabel(.ui("그리드 편집"))
            .accessibilityValue(deck.gridEditing ? String(ui: "켜짐") : String(ui: "꺼짐"))
            .help(deck.gridUnavailableReason ?? String(ui: "켜면 아래 막대로 그리드를 옮기고 BPM·1박·변속 지점을 고칩니다."))
            Text(.ui("그리드 편집"))
                .font(.scaled(.subheadline, textScale).weight(.semibold))
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Toggle(.ui("큐도 함께(핫큐·메모리)"), isOn: $deck.carryCues)
                .toggleStyle(.checkbox)
                .disabled(!deck.gridEditing || !deck.canEditGrid)
                .help(.ui("켜면 그리드를 옮기거나 BPM을 바꿀 때 핫큐·메모리 큐(루프 포함)가 같은 박을 따라 움직입니다"))
            Button(.ui("그리드 초안 버리기")) { deck.revertGrid() }
                .disabled(!deck.canDiscardGridDraft)
                .buttonStyle(GridEditorControlStyle(height: TextScale.length(24, scale: textScale)))
                .help(.ui("그리드 초안을 버리고 원래 그리드로 되돌립니다"))
        }
        .fixedSize()
    }

    private func commitBPM() {
        if let bpm { deck.setGridBPM(bpm) }
        bpm = deck.gridBPM
        // 숫자로 해석할 수 없어 바인딩이 바뀌지 않은 입력도 원래 표시로 돌린다.
        bpmFieldRevision += 1
    }
}

/// 재생 중 바뀌는 구간 정보만 관찰해 BPM 입력칸 등 편집 막대의 재평가를 줄인다.
private struct GridEditorHeaderInfo: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    @ViewBuilder var body: some View {
        if let draft = deck.gridDraft, !draft.segments.isEmpty {
            let index = draft.segmentIndex(at: deck.displayTime)
            let segment = draft.segments[index]
            HStack(spacing: 8) {
                Text(verbatim: "\(index + 1) / \(draft.segments.count)  ·  \(segment.start.clockText)  ·  \(segment.bpm.formatted(.number.precision(.fractionLength(2)).grouping(.never))) BPM")
                    .font(.scaled(.caption, textScale).monospacedDigit())
                    .foregroundStyle(.secondary)
                if draft.hasChanges {
                    Text(.ui("그리드 초안 변경됨"))
                        .font(.scaled(.caption, textScale).bold())
                        .foregroundStyle(UIColors.draft.color)
                }
            }
        }
    }
}

/// 버튼의 왼쪽 클릭은 SwiftUI에 맡기고, 오른쪽 클릭만 해당 영역에서 받는다.
private struct TapResetClickArea: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> TapResetMonitorView { TapResetMonitorView(frame: .zero) }

    func updateNSView(_ view: TapResetMonitorView, context: Context) {
        view.action = action
        view.isActive = context.environment.isEnabled
    }

    static func dismantleNSView(_ view: TapResetMonitorView, coordinator: ()) {
        view.stopMonitoring()
        view.action = nil
    }
}

private final class TapResetMonitorView: NSView {
    var action: (() -> Void)?
    var isActive = false
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, self.isActive, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return event }
                self.action?()
                return nil
            }
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

/// 현재 위치의 그리드 시작점을 가리키는 두 색 세로선.
private struct GridAnchorIcon: View {
    var body: some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 3, height: 18)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.memory).frame(height: 9)
            }
            .frame(width: 17, height: 18)
    }
}

/// 그리드 편집 막대의 아이콘·숫자 버튼을 같은 높이로 맞춘다.
private struct GridEditorControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let height: CGFloat
    var darkBackground = false

    func makeBody(configuration: Configuration) -> some View {
        let background = darkBackground
            ? (configuration.isPressed && isEnabled ? Color(white: 0.28) : Palette.controlRail)
            : (configuration.isPressed && isEnabled ? UIColors.draft.color.opacity(0.3) : UIColors.gridControlFill)
        return configuration.label
            .foregroundStyle(Color.primary)
            .opacity(isEnabled ? 1 : 0.7)
            .frame(minWidth: height, minHeight: height)
            .frame(height: height)
            .padding(.horizontal, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 전체 파형과 같은 시간축에 템포 구간을 그린다.
struct GridTempoSegments: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel

    var body: some View {
        let segments = deck.gridDraft?.segments ?? []
        let current = deck.gridDraft?.segmentIndex(at: deck.displayTime) ?? 0
        let duration = max(deck.duration, 1)
        let height = CGFloat(TextScale.length(28, scale: textScale))
        GeometryReader { geometry in
            let cursorX = geometry.size.width * CGFloat(min(max(deck.displayTime, 0), duration) / duration)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        let start = index == 0 ? 0 : min(max(segment.start, 0), duration)
                        let end = index + 1 < segments.count
                            ? min(max(segments[index + 1].start, 0), duration) : duration
                        let width = geometry.size.width * CGFloat(max(0, end - start) / duration)
                        if width > 0 {
                            GridTempoSegmentCell(deck: deck, index: index, segment: segment,
                                                 width: width, height: height, isCurrent: index == current)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: height, alignment: .leading)
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 1.5, height: height)
                    .position(x: cursorX, y: height / 2)
                    .allowsHitTesting(false)
                if deck.gridEditing && deck.gridDraft != nil {
                    Button { deck.addTempoChangeAtPlayhead() } label: {
                        Image(systemName: "plus")
                            .font(.scaled(.caption, textScale).bold())
                            .frame(width: height - 4, height: height - 4)
                            .background(UIColors.draftFill, in: Circle())
                            .overlay(Circle().stroke(UIColors.draft.color, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(UIColors.draft.color)
                    .disabled(!deck.canEditGrid)
                    .accessibilityLabel(.ui("여기서 BPM 변경"))
                    .help(deck.quantize ? String(ui: "변속곡: 가장 가까운 박부터 새 템포 구간을 시작합니다(Q를 끄면 재생 위치 그대로)")
                                          : String(ui: "변속곡: 재생 위치에서 새 템포 구간을 시작합니다(Q를 켜면 가장 가까운 박)"))
                    .position(x: min(max(cursorX, height / 2), max(height / 2, geometry.size.width - height / 2)),
                              y: height / 2)
                }
            }
        }
        .controlSize(ControlSize.small.scaled(textScale))
        .frame(height: height)
        .background(deck.gridDraft == nil ? UIColors.subtleFill : UIColors.draftFill)
        .overlay(alignment: .top) {
            Rectangle().fill(deck.gridDraft == nil ? Color.secondary.opacity(0.2) : UIColors.draft.color.opacity(0.35))
                .frame(height: 1)
        }
    }
}

/// 띠의 너비는 다음 변속 지점까지의 실제 재생 시간에 비례한다.
private struct GridTempoSegmentCell: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    let index: Int
    let segment: GridSegment
    let width: CGFloat
    let height: CGFloat
    let isCurrent: Bool

    private var name: String { String(ui: "템포 구간 \(index + 1)") }
    private var shortName: String { String(ui: "템포") + " \(index + 1)" }
    private var bpmText: String { segment.bpm.formatted(.number.precision(.fractionLength(2)).grouping(.never)) }
    private var seekHelp: String {
        [name, bpmText, segment.start.clockText, String(ui: "누르면 이 자리로 옮깁니다")].joined(separator: " · ")
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            seekButton
            if deck.gridEditing && index > 0 {
                removeButton
            }
        }
        .frame(width: width, height: height)
        .background(isCurrent ? UIColors.draft.color.opacity(0.2) : Color.clear)
        .overlay(alignment: .leading) {
            if index > 0 {
                Rectangle().fill(UIColors.draft.color.opacity(0.75)).frame(width: 1)
            }
        }
        .clipped()
    }

    private var seekButton: some View {
        Button { deck.seek(segment.start) } label: { seekLabel }
            .buttonStyle(.plain)
            .help(seekHelp)
    }

    private var seekLabel: some View {
        let trailing = deck.gridEditing && index > 0 ? CGFloat(23) : CGFloat(7)
        let labelWidth = max(0, width - 7 - trailing)
        return ViewThatFits(in: .horizontal) {
            Text(verbatim: name + " · " + bpmText).fixedSize(horizontal: true, vertical: false)
            Text(verbatim: shortName).fixedSize(horizontal: true, vertical: false)
            Text(verbatim: bpmText).lineLimit(1).minimumScaleFactor(0.65)
        }
        .font(.scaled(.caption, textScale).monospacedDigit())
        .frame(width: labelWidth, height: height, alignment: .leading)
        .padding(.leading, 7)
        .padding(.trailing, trailing)
        .frame(width: width, height: height, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var removeButton: some View {
        Button { deck.removeTempoChange(at: index) } label: {
            Image(systemName: "xmark.circle.fill")
                .frame(width: 20, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!deck.canEditGrid)
        .accessibilityLabel(.ui("이 변속 지점 삭제"))
        .help(.ui("이 변속 지점 삭제"))
    }
}
