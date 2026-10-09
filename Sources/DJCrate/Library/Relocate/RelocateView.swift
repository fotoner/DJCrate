import AppKit
import DJCApplication
import DJCDomain
import SwiftUI

/// '폴더에서 찾기…'(#62): 파일 없는 곡 ↔ 새 위치 후보를 미리 보고, 애매한 곡은 사람이 고른다.
/// 읽기만 한다. 경로를 rekordbox에 쓰는 단추는 쓰기 규칙을 확인하기 전까지 막아 두었다.
struct RelocateView: View {
    let model: RelocateModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.phase {
            case let .scanning(progress): scanning(progress)
            case .reviewing: review
            case let .failed(message): failure(message)
            }
            footer
        }
        .padding(20)
        .frame(width: 860, height: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(.ui("파일 없는 곡의 새 위치 찾기")).font(.title2.bold())
                Spacer()
                Button(.ui("다른 폴더에서 찾기…")) {
                    if let folder = RelocatePanels.chooseFolder() { model.rescan(in: folder) }
                }
                .disabled(model.isScanning)
            }
            Label {
                Text(verbatim: model.folder.path).lineLimit(1).truncationMode(.head)
            } icon: {
                Image(systemName: "folder")
            }
            .font(.callout).foregroundStyle(.secondary)
            .help(model.folder.path)
        }
    }

    private func scanning(_ progress: RelocateProgress) -> some View {
        VStack(spacing: 12) {
            Spacer()
            if progress.phase == .reading, progress.filesToRead > 0 {
                ProgressView(value: Double(progress.filesRead), total: Double(progress.filesToRead)).frame(width: 320)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(verbatim: RelocateText.progress(progress)).foregroundStyle(.secondary)
            Button(.ui("찾기 취소")) { model.cancel() }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Label { Text(verbatim: message) } icon: { Image(systemName: WarningMark.symbol) }
                .foregroundStyle(UIColors.warning.color)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = model.summary {
                Text(.ui("폴더의 음원 파일 \(summary.audioFiles)개 중 이름이나 크기가 맞는 \(summary.comparedFiles)개의 길이와 태그를 읽어 맞췄습니다."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            let offline = model.unmountedVolumeCount
            if offline > 0 {
                Label(.ui("외장 디스크가 연결되지 않아 없는 곡이 \(offline)곡 있습니다. 디스크를 연결하면 옛 위치 그대로 찾을 수 있는지 먼저 확인하세요."),
                      systemImage: "externaldrive.badge.xmark")
                    .font(.callout).foregroundStyle(UIColors.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker(selection: Bindable(model).filter) {
                ForEach(RelocateModel.Filter.allCases, id: \.self) { filter in
                    Text(verbatim: "\(RelocateText.filterTitle(filter)) \(model.count(filter))").tag(filter)
                }
            } label: {
                Text(.ui("분류"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("relocate-filter")
            let rows = model.visibleResults
            // 고른 후보·겹침은 목록 전체에서 한 번만 구해 행에 넘긴다(행마다 보고서를 다시 훑지 않게).
            let chosen = model.selection.chosenCandidates
            let conflictPaths = Set(model.selection.conflicts.keys)
            List(rows) { result in
                let pick = chosen[result.id]
                RelocateRowView(result: result, chosen: pick, conflicted: pick.map { conflictPaths.contains($0.file.path) } ?? false,
                                absence: model.absence(for: result.id), model: model)
            }
            .overlay {
                if rows.isEmpty { Text(.ui("이 분류에 해당하는 곡이 없습니다")).foregroundStyle(.secondary) }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.phase == .reviewing {
                    let chosen = model.selection.chosenCount
                    Text(.ui("연결할 곡으로 고른 것 \(chosen)곡")).font(.callout)
                    let conflicts = model.selection.conflicts.count
                    if conflicts > 0 {
                        Label(.ui("같은 파일을 둘 이상의 곡에 고른 경우가 \(conflicts)건 있습니다"), systemImage: WarningMark.symbol)
                            .font(.callout).foregroundStyle(UIColors.warning.color)
                    }
                }
                Spacer()
                Button(.ui("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
                // 경로 바꾸기 쓰기는 만들지 않았다: 곡 행·분석 파일의 어느 칸을 어떻게 바꾸는지 rekordbox 실험으로 확인하기 전이다.
                Button(.ui("rekordbox에 쓰기…")) {}
                    .disabled(true)
                    .help(RelocateModel.writeBlockedReason)
                    .accessibilityIdentifier("relocate-write")
            }
            Label { Text(verbatim: RelocateModel.writeBlockedReason) } icon: { Image(systemName: "lock") }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 곡 하나와 그 후보: 확실이면 확인 체크, 애매하면 후보 고르기, 없음이면 안내.
private struct RelocateRowView: View {
    let result: RelocateResult
    /// 이 곡에 고른 후보와, 그 파일을 다른 곡에도 골랐는지(목록에서 한 번에 구해 넘긴다)
    let chosen: RelocateCandidate?
    let conflicted: Bool
    /// 외장 디스크가 연결되지 않아 없는 곡이면 디스크 이름을 붙인다(대상에서 빼지 않는다).
    let absence: RelocateAbsence?
    let model: RelocateModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: result.target.title).fontWeight(.semibold).lineLimit(1)
                if let artist = result.target.artist, !artist.isEmpty {
                    Text(verbatim: artist).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(.ui("옛 파일: \(result.target.fileName)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(result.target.oldPath)
                if let absence, let text = RelocateText.absence(absence) {
                    Label { Text(verbatim: text) } icon: { Image(systemName: "externaldrive.badge.xmark") }
                        .font(.caption).foregroundStyle(UIColors.warning.color).lineLimit(1).truncationMode(.middle)
                        .help(.ui("이 곡의 외장 디스크가 지금 연결돼 있지 않습니다. 디스크를 연결하면 옛 위치 그대로 찾을 수도 있습니다."))
                        .accessibilityIdentifier("relocate-offline-\(result.id)")
                }
            }
            .frame(width: 260, alignment: .leading)
            candidates.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: some View {
        let (symbol, color, label): (String, Color, LocalizedStringResource) = switch result.outcome {
        case .confident: ("checkmark.circle.fill", UIColors.hot.color, .ui("확실"))
        case .ambiguous: ("questionmark.circle.fill", UIColors.warning.color, .ui("애매"))
        case .none: ("minus.circle", Color.secondary, .ui("없음"))
        }
        return Image(systemName: symbol).foregroundStyle(color).frame(width: 20)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var candidates: some View {
        switch result.outcome {
        case let .confident(candidate):
            Toggle(isOn: Binding(
                get: { chosen != nil },
                set: { model.choose($0 ? candidate.file.path : nil, for: result.id) }
            )) {
                candidateText(candidate)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("relocate-confident-\(result.id)")
        case let .ambiguous(reason, options):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: RelocateText.reason(reason)).font(.caption).foregroundStyle(UIColors.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(selection: Binding<String?>(
                    get: { chosen?.file.path },
                    set: { model.choose($0, for: result.id) }
                )) {
                    Text(.ui("고르지 않음")).tag(String?.none)
                    ForEach(options) { option in
                        Text(verbatim: "\(model.displayPath(option.file.path)) · " + String(ui: "\(option.score)점"))
                            .tag(Optional(option.file.path))
                    }
                } label: {
                    Text(.ui("후보"))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("relocate-picker-\(result.id)")
                if let chosen {
                    Text(verbatim: RelocateText.evidence(chosen.evidence)).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .none:
            Text(.ui("후보 없음")).foregroundStyle(.secondary)
        }
        if conflicted {
            Label(.ui("다른 곡에도 같은 파일을 골랐습니다"), systemImage: WarningMark.symbol)
                .font(.caption).foregroundStyle(UIColors.warning.color)
        }
    }

    private func candidateText(_ candidate: RelocateCandidate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: model.displayPath(candidate.file.path)).lineLimit(1).truncationMode(.middle)
                .help(candidate.file.path)
            Text(verbatim: RelocateText.evidence(candidate.evidence) + " · " + String(ui: "\(candidate.score)점"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 후보 폴더 고르기(읽기만 한다).
enum RelocatePanels {
    @MainActor
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(ui: "이 폴더에서 찾기")
        panel.message = String(ui: "파일 없는 곡의 새 위치를 찾을 폴더를 고르세요. 하위 폴더까지 훑습니다.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// 파일 없음 필터의 작업 줄에 놓는 '폴더에서 찾기…' 단추. 고른 폴더로 후보를 맞추는 창(시트)을 연다.
struct RelocateEntryButton: View {
    let store: LibraryStore
    @State private var model: RelocateModel?

    var body: some View {
        Button { open() } label: { Label(.ui("폴더에서 찾기…"), systemImage: "folder.badge.questionmark") }
            .disabled(store.isCheckingFiles || store.missingFiles.trackIDs.isEmpty || store.snapshotURL == nil)
            .help(.ui("고른 폴더에서 파일 없는 곡의 새 위치 후보를 찾아 미리 봅니다. rekordbox에는 쓰지 않습니다."))
            // 창을 닫을 때(어떤 방법이든) 훑는 중이던 일을 멈춘다.
            .sheet(item: Binding(get: { model }, set: { next in
                if next == nil { model?.cancel() }
                model = next
            })) { RelocateView(model: $0) }
    }

    private func open() {
        guard let folder = RelocatePanels.chooseFolder() else { return }
        let next = RelocateModel(tracks: store.rows.filter { $0.fileMissing && !$0.isStaged }.map(\.track), snapshot: store.snapshotURL, folder: folder,
                                 relocate: store.useCases.relocate)
        next.start()
        model = next
    }
}
