import DJCApplication
import DJCDomain
import SwiftUI

/// 사이드바 "USB 쓰기 대기": 이 볼륨의 초안 편집 목록 · 미리 보기 · USB에 쓰기… · 편집 빼기 · 초안 버리기
/// 볼륨이 빠져 있어도 초안은 보이고 고칠 수 있다(쓰기만 막힌다)
struct UsbPendingView: View {
    @State private var model: UsbPendingModel

    init(store: LibraryStore, usb: UsbStore, volumeKey: String) {
        _model = State(initialValue: UsbPendingModel(store: store, usb: usb, volumeKey: volumeKey))
    }

    var body: some View {
        let list = model.list
        VStack(alignment: .leading, spacing: 0) {
            header(list)
            Divider()
            List {
                ForEach(list.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(row.id).").monospacedDigit().foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: row.text)
                            if let status = row.statusText {
                                Label { Text(verbatim: status) } icon: {
                                    Image(systemName: row.isWarning ? WarningMark.symbol : "checkmark.circle")
                                }
                                .font(.caption)
                                .foregroundStyle(row.isWarning ? UIColors.warning.color : Color.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            model.removeTapped(row.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isBusy)
                        .help(.ui("이 편집을 초안에서 뺍니다"))
                        .accessibilityLabel(.ui("\(row.id)번 편집 빼기"))
                    }
                }
                if !list.summaryLines.isEmpty {
                    Section(.ui("미리 보기")) {
                        ForEach(Array(list.summaryLines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if list.rows.isEmpty {
                    ContentUnavailableView {
                        Label(.ui("쓸 USB 편집이 없습니다"), systemImage: "externaldrive")
                    } description: {
                        Text(.ui("곡을 오른쪽 클릭해 ‘USB에 넣기’를 고르거나 USB 곡·재생 목록을 오른쪽 클릭해 편집을 더하세요."))
                    }
                }
            }
        }
        // 초안이 바뀌면(편집 동작·쓰기 뒤) 다시 읽고 앞의 미리 보기를 버린다
        .task(id: model.draftRevision) { await model.reload() }
    }

    private func header(_ list: UsbPendingList) -> some View {
        HStack(spacing: 10) {
            Label {
                Text(verbatim: list.volumeName)
            } icon: {
                Image(systemName: list.isConnected ? "externaldrive.fill" : "externaldrive.badge.xmark")
            }
            .font(.headline)
            if !list.isConnected {
                Text(.ui("연결 안 됨")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.isPreviewing { ProgressView().controlSize(.small) }
            Button(.ui("미리 보기")) { model.previewTapped() }
                .disabled(!list.canPreview || model.isPreviewing)
                .help(.ui("초안을 지금 USB 상태로 계획해 편집마다 쓸지·막힐지 봅니다. USB에는 쓰지 않습니다."))
            Button(.ui("USB에 쓰기…")) { model.writeTapped() }
                .disabled(!list.canWrite || model.isPreviewing)
                .help(list.writeHelp)
            Button(.ui("초안 버리기"), role: .destructive) {
                model.discardTapped()
            }
            .disabled(list.rows.isEmpty || model.isBusy)
            .help(.ui("이 USB에 아직 쓰지 않은 편집을 모두 버립니다. 편집 › 실행 취소(⌘Z)로 되살립니다."))
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.edge)
        .padding(.vertical, 8)
    }
}
