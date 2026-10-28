import AppKit
import DJCApplication
import DJCDomain
import SwiftUI

struct StorageSettingsView: View {
    @State var model: StorageSettingsModel

    var body: some View {
        let blocked = model.blockReason
        Form {
            Section {
                ForEach(DJCCacheKind.allCases, id: \.self) { kind in
                    let held = model.blockReason(of: kind)
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(size(of: kind))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Button(.ui("비우기")) { model.startClear([kind]) }
                                .disabled(model.isWorking || (model.clearable[kind] ?? 0) == 0)
                                .disabled(because: held)
                        }
                    } label: {
                        Text(kind.title)
                        if let detail = kind.detail { Text(detail) }
                    }
                }
                HStack {
                    if let message = blocked ?? model.message {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(.ui("모두 비우기")) { model.startClear(DJCCacheKind.allCases) }
                        .disabled(model.isWorking || !model.clearable.values.contains { $0 > 0 })
                        .disabled(because: blocked)
                }
            } header: {
                Text(.ui("캐시"))
            } footer: {
                Text(.ui("캐시는 다시 만들어집니다. 초안·백업은 지우지 않습니다."))
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(model.backups, id: \.kind) { backup in
                    LabeledContent(title(of: backup.kind)) {
                        Text(.ui("\(backup.count)개 · 최대 \(StorageSize.text(backup.bytes))"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $model.autoSnapshotEnabled) {
                    Text(.ui("하루 한 번 자동 시점 스냅샷"))
                    Text(model.autoSnapshotCaption)
                }
                .disabled(because: model.autoSnapshotNote, announcedAs: .hint)
                Stepper(value: $model.autoSnapshotDays, in: 1...90) {
                    LabeledContent(.ui("자동 시점 스냅샷 보관")) {
                        Text(.ui("\(model.autoSnapshotDays)일"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Text(.ui("백업(읽기만)"))
                    InfoPopoverButton(label: String(ui: "보관 규칙"), lines: Self.retentionLines)
                }
            } footer: {
                Text(.ui("오래된 것부터 자동 정리되며 고정한 스냅샷은 남습니다."))
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(.ui("데이터 폴더")) {
                    HStack(spacing: 10) {
                        Text((model.paths.root.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button(.ui("Finder에서 보기")) {
                            NSWorkspace.shared.activateFileViewerSelecting([model.paths.root])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
        .task { await model.refresh() }
    }

    /// 백업 구역 ⓘ 팝오버: 처음 한 번만 필요한 보관 규칙과 용량 읽는 법
    private static var retentionLines: [String] {
        [String(ui: "백업과 자동 시점 스냅샷은 오래된 것부터 저절로 정리됩니다."),
         String(ui: "rekordbox 수동·고정 시점 스냅샷은 지우지 않습니다."),
         String(ui: "USB 시점 스냅샷은 볼륨마다 최근 5개와 고정한 것을 남깁니다."),
         String(ui: "같은 디스크의 복사본은 공간을 나눠 써서 실제로 차지하는 공간은 더 작을 수 있습니다.")]
    }

    private func bytes(of kind: DJCCacheKind) -> Int64? { model.usage?.first { $0.kind == kind }?.bytes }

    private func size(of kind: DJCCacheKind) -> String {
        bytes(of: kind).map(StorageSize.text) ?? String(ui: "계산 중…")
    }

    private func title(of kind: DJCBackupUsage.Kind) -> String {
        switch kind {
        case .rekordboxBackups: String(ui: "rekordbox 쓰기 전 백업")
        case .pointSnapshots: String(ui: "rekordbox 시점 스냅샷")
        case .usbBackups: String(ui: "USB 쓰기 전 백업")
        case .usbPointSnapshots: String(ui: "USB 시점 스냅샷")
        }
    }
}
