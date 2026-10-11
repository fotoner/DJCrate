import AppKit
import DJCDomain
import SwiftUI

struct CueListView: View {
    @Environment(\.textScale) private var textScale
    @Bindable var deck: DeckModel
    @State private var storedFilter = ObservedSetting(SettingKeys.cueListFilter)

    private var filter: CueListFilter {
        CueListFilter(rawValue: storedFilter.value) ?? .all
    }
    private var visibleCues: [EditableCue] { (deck.draft?.cues ?? []).filter(filter.includes) }
    private var changedCueIDs: Set<EditableCue.ID> {
        Set((deck.draft?.changes ?? []).compactMap { change in
            switch change {
            case let .added(cue), let .modified(_, cue): cue.id
            case .removed: nil
            }
        })
    }

    var body: some View {
        let _ = PerfProbe.body(Self.self)
        let cues = deck.draft?.cues ?? []
        let hotCount = cues.filter { if case .hot = $0.kind { true } else { false } }.count
        let changedIDs = changedCueIDs
        let segmentHeight = CGFloat(TextScale.length(28, scale: textScale))
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let segmentWidth = max(0, (geometry.size.width - 8) / 3)
                HStack(spacing: 2) {
                    ForEach(CueListFilter.allCases, id: \.self) { option in
                        Button { storedFilter.value = option.rawValue } label: {
                            filterLabel(option, total: cues.count, hot: hotCount)
                                .font(.scaled(.caption, textScale).bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .foregroundStyle(option == filter ? Color.white : Color.primary)
                                .frame(width: segmentWidth, height: segmentHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(option == filter ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityAddTraits(option == filter ? [.isSelected] : [])
                    }
                }
                .padding(2)
                .frame(width: geometry.size.width, height: segmentHeight + 4, alignment: .leading)
                .background(UIColors.subtleFill, in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: segmentHeight + 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(.ui("큐 목록 보기"))
            List(selection: $deck.selectedCueID) {
                ForEach(visibleCues) { cue in
                    CueRow(deck: deck, cue: cue, expectedTrackUUID: deck.row?.track.uuid)
                        .tag(cue.id)
                        // 선택색은 List가 그리도록 두고, 선택하지 않은 초안 행만 물들인다.
                        .listRowBackground(changedIDs.contains(cue.id) && deck.selectedCueID != cue.id
                                           ? UIColors.cueDraftFill : Color.clear)
                }
            }
            .listStyle(.bordered)
            // 곡이 바뀌어 행이 통째로 교체되면 SwiftUI가 표의 행 높이를 이 기본값으로 되돌린다(기본 24pt). 되돌려도 28pt가 되게 한다.
            .environment(\.defaultMinListRowHeight, segmentHeight)
            .background {
                CueListFixedRowHeight(height: segmentHeight)
                    .allowsHitTesting(false)
            }
            .onChange(of: visibleCues.map(\.id), initial: true) { _, ids in
                // 탭이나 큐 종류를 바꿔 숨긴 행을 키보드로 잘못 편집하지 않게 한다.
                if let selected = deck.selectedCueID, !ids.contains(selected) { deck.selectedCueID = nil }
            }
            HStack {
                Spacer()
                Button(.ui("큐 초안 버리기")) { deck.revertDraft() }
                    .buttonStyle(.plain)
                    .font(.scaled(.caption, textScale))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(deck.draft?.hasChanges == true ? UIColors.cueDraftFill : UIColors.subtleFill,
                                in: RoundedRectangle(cornerRadius: 6))
                    .disabled(deck.draft?.hasChanges != true)
                    .opacity(deck.draft?.hasChanges == true ? 1 : 0.5)
                    .help(.ui("큐 초안을 버리고 rekordbox에서 불러온 큐로 돌아갑니다."))
            }

            if let issues = deck.draft?.issues(duration: deck.duration), !issues.isEmpty {
                Label(issues.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                    .font(.scaled(.caption, textScale)).foregroundStyle(UIColors.warning.color)
            }
            if deck.isWriteLocked {
                Text(.ui("rekordbox에 쓰는 중이라 큐 편집을 잠시 막았습니다.")).font(.scaled(.caption2, textScale)).foregroundStyle(.secondary)
            }
        }
    }

    private func filterLabel(_ option: CueListFilter, total: Int, hot: Int) -> Text {
        switch option {
        case .all: Text(.ui("전체 \(total)"))
        case .hot: Text(.ui("핫큐 \(hot)"))
        case .memory: Text(.ui("메모리 \(total - hot)"))
        }
    }
}

/// SwiftUI List의 AppKit 표가 큐 행마다 자동 높이를 다시 재지 않게 한다.
private struct CueListFixedRowHeight: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> CueListRowHeightProbe { CueListRowHeightProbe(frame: .zero) }

    func updateNSView(_ view: CueListRowHeightProbe, context: Context) {
        view.rowHeight = height
        view.scheduleConfiguration()
    }
}

private final class CueListRowHeightProbe: NSView {
    var rowHeight: CGFloat = 28
    private weak var table: NSTableView?
    private var scheduled = false
    private var retries = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        table = nil
        retries = 0
        scheduleConfiguration()
    }

    override func layout() {
        super.layout()
        scheduleConfiguration()
    }

    func scheduleConfiguration() {
        guard window != nil, !scheduled else { return }
        if let table, table.window === window,
           !table.usesAutomaticRowHeights, table.rowHeight == rowHeight { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.configure()
        }
    }

    private func configure() {
        guard let window, let content = window.contentView else { return }
        if table?.window !== window {
            let point = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            table = findTable(in: content, covering: point)
        }
        guard let table else {
            if retries < 3 {
                retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.scheduleConfiguration() }
            }
            return
        }
        if table.usesAutomaticRowHeights { table.usesAutomaticRowHeights = false }
        if table.rowHeight != rowHeight { table.rowHeight = rowHeight }
    }

    private func findTable(in view: NSView, covering point: NSPoint) -> NSTableView? {
        if let table = view as? NSTableView,
           let scrollView = table.enclosingScrollView,
           scrollView.convert(scrollView.bounds, to: nil).contains(point) {
            return table
        }
        for child in view.subviews {
            if let table = findTable(in: child, covering: point) { return table }
        }
        return nil
    }
}

struct CueRow: View {
    @Environment(\.textScale) private var textScale
    let deck: DeckModel
    let cue: EditableCue
    var expectedTrackUUID: String? = nil
    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 6) {
            rowMain
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
            deleteButton
                .frame(width: TextScale.length(20, scale: textScale),
                       height: TextScale.length(28, scale: textScale))
                .fixedSize()
                .contentShape(Rectangle())
        }
        .frame(height: TextScale.length(28, scale: textScale))
        .controlSize(ControlSize.small.scaled(textScale))
        .frame(maxWidth: .infinity, alignment: .leading)
        // 빈 곳은 이동하되, 위에 놓인 종류·이름·삭제 컨트롤은 자기 동작만 받는다.
        .background {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { deck.selectCueFromList(cue.id) }
        }
    }

    private var rowMain: some View {
        // 좁게 고정된 큐 목록에서는 한 가지 행만 그려 높이 측정 때 두 배치를 비교하지 않는다.
        HStack(spacing: 6) {
            Circle().fill(UIColors.color(for: cue)).frame(width: 6, height: 6)
                .allowsHitTesting(false)
            Picker(.ui("종류"), selection: Binding(get: { cue.kind }, set: { deck.setKind(cue.id, $0, expectedTrackUUID: expectedTrackUUID) })) {
                Text(.ui("메모리")).tag(EditableCue.Kind.memory)
                ForEach(0..<8, id: \.self) { slot in
                    Text(.ui("핫큐 \(String(UnicodeScalar(UInt8(65 + slot))))")).tag(EditableCue.Kind.hot(slot))
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(minWidth: TextScale.length(76, scale: textScale))
            .foregroundStyle(.primary)

            // 자동 큐 표시는 시각 칸 옆에 둔다(좁은 배치에서도 이름을 가리지 않게, #145).
            HStack(spacing: 2) {
                Button { deck.selectCueFromList(cue.id) } label: {
                    Text(cue.time.clockText).font(.scaled(.caption, textScale).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 20, minHeight: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(.ui("이 위치로 이동"))
                autoBadge
            }
            .frame(minWidth: TextScale.length(56, scale: textScale), alignment: .leading)
            .layoutPriority(1)
            Text(cue.name).font(.scaled(.caption, textScale)).lineLimit(1).layoutPriority(-1)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
            Button { showDetails.toggle() } label: {
                Image(systemName: cue.loop == nil ? "ellipsis.circle" : "repeat.circle")
            }
            .buttonStyle(.borderless)
            .help(.ui("큐 이름·루프 편집"))
            .accessibilityLabel(.ui("큐 세부 편집"))
            .popover(isPresented: $showDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(cue.time.clockText).font(.scaled(.caption, textScale).monospacedDigit().bold())
                            .lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                        loopControls
                    }
                    nameField.textFieldStyle(.roundedBorder)
                }
                .controlSize(ControlSize.small.scaled(textScale))
                .padding(10)
                .frame(width: TextScale.length(200, scale: textScale))
            }
        }
    }

    @ViewBuilder private var loopControls: some View {
        let presets: [Double] = [1, 2, 4, 8, 16, 32]
        let current = cue.loop.map { loop in
            loop.beats ?? deck.loopBeats(cue).map(Double.init) ?? (loop.end - cue.time) * (deck.gridBPM ?? 120) / 60
        }
        Menu {
            Picker(.ui("루프 길이"), selection: Binding(get: { current }, set: { beats in
                // 프리셋 밖 현재 값을 다시 골라도 기존 루프 끝은 그대로 둔다.
                guard beats != current else { return }
                deck.setLoop(cue.id, beats: beats.map(Int.init), expectedTrackUUID: expectedTrackUUID)
            })) {
                Text(.ui("루프 없음")).tag(nil as Double?)
                if let current, !presets.contains(current) {
                    Text(.ui("\(LoopRules.text(current))박 루프")).tag(Optional(current))
                }
                ForEach(presets, id: \.self) { beats in
                    Text(.ui("\(LoopRules.text(beats))박 루프")).tag(Optional(beats))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(cue.loop == nil ? .ui("루프") : .ui("\(cue.loop?.beats.map(LoopRules.text) ?? deck.loopBeats(cue).map(String.init) ?? "?")박"))
                .font(.scaled(.caption, textScale).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(cue.loop == nil ? Color.secondary : UIColors.loop.color)
        .help(.ui("이 큐를 루프로 만들거나 길이를 바꿉니다"))
        if cue.loop != nil {
            Button { deck.toggleActiveLoop(cue.id) } label: {
                Image(systemName: "repeat.circle")
                    .symbolVariant(cue.loop?.active == true ? .fill : .none)
                    .foregroundStyle(cue.loop?.active == true ? UIColors.loop.color : .secondary)
            }
            .buttonStyle(.borderless)
            .help(cue.loop?.active == true ? .ui("활성 루프(곡을 불러오면 자동 반복) — 눌러서 끄기") : .ui("활성 루프로 만들기(곡을 불러오면 이 루프를 자동 반복)"))
            .accessibilityLabel(.ui("활성 루프"))
            .accessibilityValue(cue.loop?.active == true ? .ui("켜짐") : .ui("꺼짐"))
            .accessibilityAddTraits(.isToggle)
        }

    }

    /// rekordbox가 분석 때 넣은 자동 큐(#145). 일반 메모리 큐와 똑같이 고치며, 고치면 이름이 비어 표시가 빠진다.
    @ViewBuilder private var autoBadge: some View {
        if cue.isAutoGenerated {
            Text(.ui("자동"))
                .font(.scaled(.caption2, textScale).bold())
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 3).padding(.vertical, 1)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: Capsule())
                .help(.ui("rekordbox가 분석 때 넣은 메모리 큐입니다. 고치면 일반 큐가 됩니다"))
                .accessibilityLabel(.ui("rekordbox 자동 큐"))
        }
    }

    private var nameField: some View {
        TextField(.ui("이름"), text: Binding(get: { cue.name }, set: { deck.rename(cue.id, $0, expectedTrackUUID: expectedTrackUUID) }))
            .textFieldStyle(.plain)
            .font(.scaled(.caption, textScale))
    }

    private var deleteButton: some View {
        Button(role: .destructive) { deck.delete(cue.id, expectedTrackUUID: expectedTrackUUID) } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .foregroundStyle(UIColors.memory.color)
            .help(.ui("삭제"))
            .accessibilityLabel(.ui("큐 삭제"))
    }
}
