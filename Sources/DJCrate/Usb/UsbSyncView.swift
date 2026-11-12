import DJCApplication
import DJCDomain
import SwiftUI

/// USB의 현재 목록과 동기화 결과를 구분한다. 실제 쓰기 확인은 기존 USB 쓰기 창구에 맡긴다.
struct UsbSyncView: View {
    let store: LibraryStore
    let usb: UsbStore
    let request: UsbSyncSheetRequest
    @State private var model: UsbSyncModel
    @Environment(\.dismiss) private var dismiss

    init(store: LibraryStore, usb: UsbStore, request: UsbSyncSheetRequest) {
        self.store = store
        self.usb = usb
        self.request = request
        _model = State(initialValue: UsbSyncModel(volumeKey: request.volumeKey, library: usb.libraries[request.volumeKey]))
    }

    private var isOperating: Bool { model.isSyncing || model.isImporting }
    private var controlsDisabled: Bool {
        model.isLoading || isOperating || store.isLoading || store.libraryBusy
            || usb.activeWrite != nil || usb.busyVolumes.contains(request.volumeKey)
            || usb.ejecting.contains(request.volumeKey) || usb.volume(request.volumeKey) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Toggle(.ui("장치와 플레이리스트 동기화"), isOn: Binding(get: { model.syncPlaylists }, set: { model.syncPlaylists = $0 }))
                .disabled(controlsDisabled)
                .accessibilityIdentifier("usb-sync-playlists")
            HStack(spacing: 16) {
                PlaylistSyncPane(tree: model.iTunesTree, isLoading: model.isLoading,
                                 emptyMessage: String(ui: "읽을 수 있는 iTunes 목록이 없습니다"),
                                 selection: sourceSelection, lockedReason: model.selectionLockedReason) {
                    HStack {
                        Text(.ui("iTunes 동기화 목록")).font(.headline)
                        Spacer()
                        PlaylistSyncCheckbox(name: String(ui: "iTunes 동기화 목록"),
                                             state: model.selection.state(of: UsbSyncSource.iTunesSelectionID, in: model.nodes),
                                             identifier: "usb-sync-source-itunes") { model.toggle(UsbSyncSource.iTunesSelectionID) }
                            .frame(width: 18, height: 18)
                        Button(.ui("전체 선택")) { model.selectAllITunes() }
                        Button(.ui("선택 해제")) { model.clearITunesSelection() }
                    }
                    .help(model.selectionLockedReason ?? "")
                }
                .disabled(controlsDisabled || !model.canEditSelection)
                PlaylistSyncPane(tree: model.rekordboxTree, isLoading: model.isLoading,
                                 emptyMessage: String(ui: "읽을 수 있는 rekordbox 목록이 없습니다"),
                                 selection: sourceSelection, lockedReason: model.selectionLockedReason) {
                    HStack {
                        Text(verbatim: "rekordbox").font(.headline)
                        Spacer()
                        PlaylistSyncCheckbox(name: "rekordbox",
                                             state: model.selection.state(of: UsbSyncSource.rekordboxSelectionID, in: model.nodes),
                                             identifier: "usb-sync-source-rekordbox") { model.toggle(UsbSyncSource.rekordboxSelectionID) }
                            .frame(width: 18, height: 18)
                        Button(.ui("전체 선택")) { model.selectAllRekordbox() }
                        Button(.ui("선택 해제")) { model.clearRekordboxSelection() }
                    }
                    .help(model.selectionLockedReason ?? "")
                }
                .disabled(controlsDisabled || !model.canEditSelection)
                transferButtons
                targetPane
            }
            HStack {
                Text(.ui("선택한 곡 \(model.trackCount)개")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(.ui("USB에 쓰기 전에 변경 내용을 확인합니다."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            // rekordbox의 내보내기 기록처럼 넣지 못할 곡을 알리기만 한다(동기화는 나머지 곡으로 한다)
            if let skipped = model.skippedSummary(store: store) {
                Text(verbatim: skipped).font(.caption).foregroundStyle(.orange).lineLimit(3).help(skipped)
                    .accessibilityIdentifier("usb-sync-skipped")
            }
            if let message = store.music.library.status.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.nativeSelectionIssues.isEmpty {
                ScrollView {
                    Text(model.nativeSelectionIssues.joined(separator: "\n"))
                        .font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 92)
            }
            if let error = model.error {
                ScrollView { Text(error).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 92)
            } else if let message = model.message {
                ScrollView { Text(message).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 92)
            }
            HStack(alignment: .bottom) {
                Text(.ui("USB의 큐·그리드는 로컬이 더 새로워도 USB 값으로 바꾸는 편집으로 가져옵니다."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(.ui("닫기")) {
                    model.closeTapped(store: store, usb: usb) { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isOperating || usb.activeWrite != nil)
            }
        }
        .padding(24)
        .frame(width: 1160, height: 600)
        .interactiveDismissDisabled(isOperating || usb.activeWrite != nil)
        .task { await model.load(store: store, usb: usb) }
    }

    /// USB 동기화 목록. 줄마다 붙는 표시는 본문에서 한 번 계산해 둔다
    private var targetPane: some View {
        let style = model.targetRowStyle
        return PlaylistSyncPane(tree: model.targetTree, isLoading: model.isLoading,
                                emptyMessage: model.targetEmptyMessage,
                                dimmed: style.isDimmed, note: style.note(of:), hint: style.hint(of:)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(.ui("USB 동기화 목록")).font(.headline)
                    Spacer()
                    Text(.ui("목록 \(model.targetPlaylistCount)개")).foregroundStyle(.secondary)
                }
                Picker(.ui("USB 목록 표시"), selection: Binding(get: { model.targetDisplay }, set: { model.targetDisplay = $0 })) {
                    ForEach(UsbSyncTargetDisplay.allCases, id: \.self) { display in
                        Text(verbatim: display.title).tag(display)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(controlsDisabled || !model.syncPlaylists)
                .help(model.selectionLockedReason ?? "")
                .accessibilityIdentifier("usb-sync-target-display")
            }
        }
        .disabled(controlsDisabled)
    }

    private var sourceSelection: PlaylistSyncSelectionControls<PlaylistOutlineNode> {
        PlaylistSyncSelectionControls(state: { node in
            model.selection.state(of: node.id, in: model.nodes)
        }, toggle: { node in
            model.toggle(node.id)
        }, identifier: { node in
            "usb-sync-playlist-\(node.id)"
        })
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(.ui("USB 동기화")).font(.title2.bold())
                if let volume = usb.volume(request.volumeKey) {
                    Label(volume.name, systemImage: "externaldrive").foregroundStyle(.secondary)
                } else {
                    Text(.ui("USB를 다시 연결한 뒤 동기화 창을 여세요"))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                model.refreshTapped(store: store, usb: usb)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(controlsDisabled)
            .help(.ui("USB 동기화 목록 새로고침"))
            .accessibilityLabel(.ui("USB 동기화 목록 새로고침"))
            .accessibilityIdentifier("usb-sync-refresh")
        }
    }

    private var transferButtons: some View {
        VStack(spacing: 16) {
            Button {
                model.syncTapped(store: store, usb: usb) { dismiss() }
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: "SYNC")
                    Image(systemName: "chevron.right")
                }
                .frame(minWidth: 112)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(controlsDisabled || !model.canSync)
            .accessibilityLabel(.ui("USB와 동기화…"))
            .accessibilityIdentifier("usb-sync-apply")
            Button {
                model.importTapped(store: store, usb: usb)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                    Text(verbatim: "CUE GRID INFO").font(.caption)
                }
                .frame(minWidth: 112)
            }
            .disabled(controlsDisabled || !model.canImport)
            .help(.ui("USB의 큐·그리드를 로컬 편집으로 가져옵니다"))
            .accessibilityLabel(.ui("USB 큐·그리드 가져오기…"))
            .accessibilityIdentifier("usb-sync-import-cue-grid")
            if isOperating {
                ProgressView().controlSize(.small)
            }
        }
    }
}
