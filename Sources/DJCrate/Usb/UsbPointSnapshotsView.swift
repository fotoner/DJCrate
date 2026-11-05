import DJCApplication
import DJCDomain
import SwiftUI

struct UsbPointSnapshotsView: View {
    @Bindable var model: UsbPointSnapshotsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(.ui("USB 시점 스냅샷")).font(.title2.bold())
            Text(verbatim: model.volume.name).foregroundStyle(.secondary)
            HStack {
                TextField(.ui("스냅샷 이름(선택)"), text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.startCreate() }
                Button(.ui("스냅샷 만들기")) { model.startCreate() }
                    .disabled(model.isBusy || !model.canUseVolume)
            }
            List {
                if model.entries.isEmpty {
                    Text(.ui("이 USB의 시점 스냅샷이 없습니다. 만들기를 눌러 지금 상태를 남기세요."))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.entries) { entry in
                    UsbPointSnapshotRow(entry: entry, busy: model.isBusy, canRestore: model.canUseVolume,
                                        onPin: { model.startTogglePinned(entry) }, onDelete: { model.startDelete(entry) },
                                        onRestore: { model.startRestore(entry) })
                }
            }
            .listStyle(.bordered)
            Text(.ui("DB·분석 파일·앨범아트·기기 설정을 Mac에 남깁니다. 음원과 동기화 선택은 담지 않습니다. 최근 5개와 고정한 스냅샷을 남깁니다."))
                .font(.callout).foregroundStyle(.secondary)
            if !model.canUseVolume {
                Text(.ui("USB 연결이 바뀌었습니다. 창을 닫고 같은 USB에서 다시 여세요."))
                    .foregroundStyle(UIColors.warning.color)
            }
            if let message = model.message {
                Text(message).foregroundStyle(model.isError ? UIColors.warning.color : Color.secondary)
            }
            HStack {
                if model.undoBackup != nil {
                    Button(.ui("되돌리기 취소…")) { model.startUndoRestore() }
                        .disabled(model.isBusy || !model.canUseVolume)
                }
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button(.ui("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(model.isWorking)
            }
        }
        .padding(20)
        .frame(width: 780, height: 520)
        .task { await model.refresh() }
        .overlay {
            if let write = model.activeWrite {
                UsbWritingOverlay(model: UsbWriteProgressModel(write), onCancel: { model.cancelWrite() })
            }
        }
        .interactiveDismissDisabled(model.isWorking)
    }
}

private struct UsbPointSnapshotRow: View {
    let entry: UsbPointSnapshotEntry
    let busy: Bool
    let canRestore: Bool
    let onPin: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: entry.displayName).fontWeight(.medium).lineLimit(1)
                Text(entry.metadata.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(StorageSize.text(entry.metadata.totalSize)).monospacedDigit().foregroundStyle(.secondary)
            Button(action: onPin) {
                Label(entry.metadata.pinned ? String(ui: "고정 풀기") : String(ui: "고정"),
                      systemImage: entry.metadata.pinned ? "pin.fill" : "pin")
            }
            .disabled(busy)
            Button(.ui("지우기…"), role: .destructive, action: onDelete)
                .disabled(busy || entry.metadata.pinned)
                .help(entry.metadata.pinned ? String(ui: "고정을 푼 뒤 지우세요") : "")
            Button(.ui("되돌리기…"), action: onRestore).disabled(busy || !canRestore)
        }
        .padding(.vertical, 8)
    }
}
