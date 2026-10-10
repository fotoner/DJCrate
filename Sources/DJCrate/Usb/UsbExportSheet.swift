import DJCApplication
import DJCDomain
import SwiftUI

/// "USB로 내보내기…" 시트: 대상 볼륨 · 형식 · 원본(목록 트리·고른 곡) · 미리 보기(곡·목록 수, 공간, 막힘 이유별 수).
/// 시트에 볼륨 줄(실물이면 "실물 USB입니다")과 미리 보기를 보이고, [USB에 쓰기]를 쓰기 동의로 본다. 시트를 닫은 뒤 코디네이터가 확인 창 없이 쓴다(#212)
struct UsbExportSheet: View {
    let store: LibraryStore
    @State private var model: UsbExportSheetModel
    @Environment(\.dismiss) private var dismiss

    init(store: LibraryStore, usb: UsbStore, request: UsbExportSheetRequest) {
        self.store = store
        _model = State(initialValue: UsbExportSheetModel(store: store, usb: usb, request: request))
    }

    private var selection: UsbExportSelection { model.selection }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            formatsSection
            sourceSection
            previewSection
            // 미리 보기를 막은 안내(rekordbox 켜짐·쓰는 중)는 창 대신 토스트로 알린다. 토스트는 시트 뒤에 가리므로 여기에도 보인다(#230)
            if let toast = store.toast, toast.isNotice, toast.isUsb {
                AppMessageView(message: AppMessage(kind: toast.kind, text: [toast.title, toast.detail].compactMap { $0 }.joined(separator: " — ")),
                               onClose: { store.toast = nil })
            }
            HStack {
                Spacer()
                Button(.ui("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(.ui("미리 보기")) { model.previewTapped() }
                    .disabled(!model.canPreview)
                Button(.ui("USB에 쓰기")) { model.writeTapped(dismiss: { dismiss() }) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canExport)
            }
        }
        .onDisappear { model.disappeared() }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("USB로 내보내기")).font(.title3.weight(.semibold))
            HStack(spacing: 6) {
                Label {
                    Text(verbatim: selection.volume.name)
                } icon: {
                    Image(systemName: "externaldrive")
                }
                if selection.isTestVolume {
                    Text(.ui("시험 볼륨"))
                        .font(.caption)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            .foregroundStyle(.secondary)
            // 쓰기 확인 창 대신 여기서 어느 볼륨에 쓰는지 보인다(실물 USB 쓰기 동의, #212)
            if !selection.isTestVolume {
                ForEach(UsbWriteFlow.volumeLines(selection.volume, isTestVolume: false), id: \.self) { line in
                    Text(verbatim: line).font(.callout)
                }
            }
        }
    }

    private var formatsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("형식")).font(.headline)
            HStack(spacing: 16) {
                ForEach(UsbFormat.allCases, id: \.self) { format in
                    Toggle(isOn: Binding(get: { model.selection.formats.contains(format) }, set: { model.selection.setFormat(format, on: $0) })) {
                        Text(verbatim: format.displayName)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("원본")).font(.headline)
            if selection.hasFixedSource {
                Text(.ui("동기화 재시도의 원본 선택은 고정되어 있습니다. 선택을 바꾸거나 원본이 갱신되었으면 USB 동기화 창에서 다시 준비하세요"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(.ui("USB 동기화…")) { model.syncTapped(dismiss: { dismiss() }) }
                    .disabled(!model.canOpenSync)
            }
            List {
                let layout = model.layout
                ForEach(model.rows) { row in
                    let covered = selection.isCovered(row.id, layout: layout)
                    Toggle(isOn: Binding(get: { covered || model.selection.isSelected(row.id) },
                                         set: { model.selection.setPlaylist(row.id, selected: $0) })) {
                        Label {
                            Text(verbatim: row.name).lineLimit(1)
                        } icon: {
                            Image(systemName: row.isFolder ? "folder" : row.isSmart ? "gearshape" : "music.note.list")
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.leading, CGFloat(row.depth) * 16)
                    .disabled(selection.hasFixedSource || covered || row.isSmart)
                    .help(row.isSmart ? String(ui: "인텔리전트 재생 목록은 내보내지 않습니다") : row.name)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 160)
            Toggle(isOn: $model.selection.includesSelectedTracks) {
                Text(.ui("곡 목록에서 고른 곡 \(selection.selectedTrackIDs.count)개도 넣기"))
            }
            .toggleStyle(.checkbox)
            .disabled(selection.hasFixedSource || selection.selectedTrackIDs.isEmpty)
        }
    }

    @ViewBuilder private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.ui("미리 보기")).font(.headline)
            if model.isPreviewing {
                ProgressView().controlSize(.small)
            } else if let summary = selection.summary {
                Text(.ui("곡 \(summary.trackCount)개 · 재생 목록 \(summary.playlistCount)개 · 빼고 쓰는 곡 \(summary.blockedTrackCount)개"))
                Text(verbatim: summary.spaceText)
                    .foregroundStyle(summary.isShortOfSpace ? UIColors.warning.color : Color.secondary)
                ForEach(summary.stopping, id: \.self) { message in
                    Label { Text(verbatim: message) } icon: { Image(systemName: WarningMark.symbol) }
                        .foregroundStyle(UIColors.warning.color)
                }
                ForEach(UsbWriteFlow.blockLines(summary), id: \.self) { line in
                    Text(verbatim: line).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(.ui("형식과 원본을 고른 뒤 미리 보기를 누르세요")).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// USB에 쓰는 동안 창 전체를 덮는다: 단계·파일 수·바이트, DB 교체 전까지만 취소
struct UsbWritingOverlay: View {
    @Environment(\.textScale) private var textScale
    let model: UsbWriteProgressModel
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
            VStack(spacing: 10) {
                if let fraction = model.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().controlSize(.regular)
                }
                Text(verbatim: model.title).font(.scaled(.body, textScale).weight(.semibold))
                if let phase = model.phase {
                    Text(verbatim: [phase, model.items, model.bytes].compactMap { $0 }.joined(separator: " · "))
                        .font(.scaled(.caption, textScale).monospacedDigit())
                }
                Text(.ui("끝날 때까지 USB를 뽑지 마세요"))
                    .font(.scaled(.caption, textScale)).foregroundStyle(.secondary)
                if model.showsCancel {
                    Button(.ui("취소"), action: onCancel).keyboardShortcut(.cancelAction)
                }
            }
            .frame(minWidth: 280)
            .padding(.horizontal, 28).padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
