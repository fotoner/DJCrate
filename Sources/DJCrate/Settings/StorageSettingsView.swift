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
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(size(of: kind))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Button(.ui("비우기")) { model.startClear([kind]) }
                                .disabled(blocked != nil || model.isWorking || (model.clearable[kind] ?? 0) == 0)
                                .help(blocked ?? String(ui: "\(kind.title) 캐시를 비웁니다"))
                        }
                    } label: {
                        Text(kind.title)
                        Text(kind.detail)
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
                        .disabled(blocked != nil || model.isWorking || !model.clearable.values.contains { $0 > 0 })
                        .help(blocked ?? String(ui: "모든 캐시를 비웁니다. 초안·백업은 그대로 둡니다"))
                }
            } header: {
                Text(.ui("캐시"))
            } footer: {
                Text(.ui("캐시는 다시 만들어지므로 확인 없이 비웁니다. 초안·추가 목록·백업은 지우지 않습니다."))
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
                    Text(model.autoSnapshotNote ?? String(ui: "rekordbox가 꺼져 있고 라이브러리가 바뀌었을 때 뒤에서 조용히 남깁니다."))
                }
                Stepper(value: $model.autoSnapshotDays, in: 1...90) {
                    LabeledContent(.ui("자동 시점 스냅샷 보관")) {
                        Text(.ui("\(model.autoSnapshotDays)일"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(.ui("백업(읽기만)"))
            } footer: {
                Text(.ui("같은 디스크의 복사본은 공간을 나눠 써서 실제로 차지하는 공간은 더 작을 수 있습니다. 백업과 자동 시점 스냅샷은 오래된 것부터 저절로 정리되고, 수동·고정 시점 스냅샷은 지우지 않습니다."))
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

    private func bytes(of kind: DJCCacheKind) -> Int64? { model.usage?.first { $0.kind == kind }?.bytes }

    private func size(of kind: DJCCacheKind) -> String {
        bytes(of: kind).map(StorageSize.text) ?? String(ui: "계산 중…")
    }

    private func title(of kind: DJCBackupUsage.Kind) -> String {
        switch kind {
        case .rekordboxBackups: String(ui: "rekordbox 쓰기 전 백업")
        case .pointSnapshots: String(ui: "rekordbox 시점 스냅샷")
        case .usbBackups: String(ui: "USB 쓰기 전 백업")
        }
    }
}
