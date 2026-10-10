import DJCApplication
import DJCDomain
import SwiftUI

/// 막힌 초안 복구 시트(#232): 곡·종류별, 재생 목록별 줄 하나씩. 줄마다 차이 요약 한 줄을 보고
/// "내 편집 유지·다시 적용 / 현재값 사용 / 나중에"를 고른 뒤 [저장]으로 한 번에 저장한다. 취소하면 아무것도 바꾸지 않는다.
struct RecoverySheetView: View {
    let model: RecoverySheetModel
    /// 줄 목록의 높이 한계(내용에 맞추되 시트가 화면을 넘지 않게 한다. 넘으면 목록이 스크롤된다)
    var maxListHeight: CGFloat = 460
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.lines) { RecoveryLineView(model: model, line: $0) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 60), maxListHeight))
            footer
        }
        .padding(20)
        .frame(width: 720)
        .task { await model.load() }
        // 시트가 내려가면 쓰기 흐름이 더 기다리지 않게 한다. 시트가 붙은 창이 코드로 닫히는 경우는 그 창이 시트를 닫는다(곡 편집 창은 `windowWillClose`).
        .onDisappear { model.close() }
        .interactiveDismissDisabled(model.isSaving)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("막힌 초안의 현재값 비교")).font(.title2.bold())
            Text(.ui("초안을 만든 뒤 rekordbox에서 바뀌어 쓸 수 없는 항목입니다. 줄마다 고른 뒤 [저장]을 누르면 한 번에 반영하고, ‘나중에’로 둔 줄은 초안을 그대로 둡니다."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.discardCount > 0 {
                Label(.ui("‘현재값 사용’·‘초안 버리기’로 고른 줄은 내 편집을 버립니다."), systemImage: WarningMark.symbol)
                    .font(.callout).foregroundStyle(UIColors.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if model.isSaving || model.isLoading { ProgressView().controlSize(.small) }
            Button(model.hasSaved ? String(ui: "닫기") : String(ui: "취소")) { model.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isSaving)
            Button(.ui("저장")) { model.startSave() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
        }
    }
}

/// 줄 하나: 곡(또는 목록) 이름·종류 · 고르기 · 차이 요약 한 줄 · 경고 · 펼치는 것(큐 대상 지정·자세히 보기)
private struct RecoveryLineView: View {
    let model: RecoverySheetModel
    let line: RecoveryLine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(verbatim: line.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(verbatim: line.kindLabel)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(UIColors.subtleFill))
                Spacer(minLength: 8)
                choicePicker
            }
            switch line.phase {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(.ui("rekordbox의 현재값을 읽는 중…")).font(.callout).foregroundStyle(.secondary)
                }
            case let .failed(reason):
                Label { Text(verbatim: reason).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: WarningMark.symbol) }
                    .font(.callout).foregroundStyle(UIColors.warning.color)
            case .saved:
                Label(.ui("저장했습니다"), systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                if let note = line.resultNote { Text(verbatim: note).font(.callout).foregroundStyle(.secondary) }
            case .ready:
                ready
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(UIColors.subtleFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(line.title) \(line.kindLabel)"))
    }

    private var symbol: String {
        switch line.request {
        case let .draft(_, kind): switch kind { case .tags: "tag"; case .cues: "mappin"; case .grid: "metronome" }
        case .playlist: "music.note.list"
        }
    }

    @ViewBuilder private var choicePicker: some View {
        if line.phase == .ready {
            Picker(selection: Binding(get: { line.choice }, set: { model.choose($0, for: line) })) {
                ForEach(line.options, id: \.self) { Text(verbatim: line.label(for: $0)).tag($0) }
            } label: {
                Text(.ui("복구 방법"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.isSaving)
            .help(line.consequence ?? "")
            .accessibilityLabel(Text(.ui("복구 방법")))
            .accessibilityValue(Text(verbatim: line.consequence ?? ""))
        }
    }

    @ViewBuilder private var ready: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: line.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !line.details.isEmpty {
                Button(line.detailsExpanded ? String(ui: "접기") : String(ui: "자세히 보기")) { line.detailsExpanded.toggle() }
                    .buttonStyle(.link).font(.callout)
                    .accessibilityHint(Text(.ui("기준·현재·내 편집을 보여 줍니다")))
            }
        }
        if line.discardsEdits, let consequence = line.consequence {
            Label { Text(verbatim: consequence).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: WarningMark.symbol) }
                .font(.callout).foregroundStyle(UIColors.warning.color)
        }
        if !line.canKeep, let reason = line.keepBlockedReason {
            Label { Text(verbatim: reason).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle") }
                .font(.callout).foregroundStyle(.secondary)
        }
        if let mapping = line.cueMapping { cueMapping(mapping) }
        ForEach(line.notes, id: \.self) { note in
            Label { Text(verbatim: note).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: WarningMark.symbol) }
                .font(.callout).foregroundStyle(UIColors.warning.color)
        }
        if line.detailsExpanded {
            Text(verbatim: line.details.joined(separator: "\n"))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        }
    }

    /// 내가 고친 큐가 rekordbox에서 다시 만들어진 줄: 이어 줄 현재 큐를 줄 안에서 펼쳐 고른다.
    private func cueMapping(_ mapping: RecoveryCueMapping) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { line.mappingExpanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: line.mappingExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 12).accessibilityHidden(true)
                    Text(.ui("큐 대상 다시 지정")).font(.callout.weight(.medium))
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(line.mappingExpanded ? .ui("펼침") : .ui("접힘")))
            if line.mappingExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(.ui("시각이나 이름으로 자동 대응하지 않으니 같은 대상인 현재 큐를 직접 고르세요."))
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(mapping.missing) { old in
                        if let source = old.sourceID { mappingRow(old, source: source, mapping: mapping) }
                    }
                    if let failure = line.mappingFailure {
                        Label { Text(verbatim: failure).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: WarningMark.symbol) }
                            .font(.callout).foregroundStyle(UIColors.warning.color)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    private func mappingRow(_ old: EditableCue, source: String, mapping: RecoveryCueMapping) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(.ui("내 큐")).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: RecoverySummary.cueDescription(old)).font(.callout)
            }
            .frame(width: 210, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
            Picker(selection: Binding(get: { mapping.selection[source] }, set: { model.mapCue(source, to: $0, in: line) })) {
                Text(.ui("선택 안 함")).tag(String?.none)
                ForEach(mapping.candidates(for: source), id: \.id) { candidate in
                    Text(verbatim: RecoverySummary.cueDescription(candidate)).tag(candidate.sourceID)
                }
            } label: {
                Text(.ui("이어 줄 현재 큐"))
            }
            .labelsHidden()
            .frame(maxWidth: 300)
            .disabled(model.isSaving)
            .accessibilityLabel(Text(.ui("이어 줄 현재 큐")))
        }
    }
}

/// 메인 창·곡 편집 창에 붙이는 복구 시트. `LibraryStore.recoverySheet`가 이 창(`anchor`)용일 때만 띄운다.
struct RecoverySheetHost: ViewModifier {
    let store: LibraryStore?
    let anchor: RecoverySheetAnchor

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { store?.recoverySheet.flatMap { $0.anchor == anchor ? $0 : nil } },
            set: { if $0 == nil { store?.recoverySheet?.close() } }
        )) { model in
            RecoverySheetView(model: model)
        }
    }
}
