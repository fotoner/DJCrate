import DJCDomain
import SwiftUI

struct ITunesSyncView: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    private var model: ITunesSyncModel { store.iTunesSync }

    var body: some View {
        let tree = model.tree
        let preview = model.preview
        let nodes = model.nodes
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(.ui("iTunes 동기화")).font(.title2.bold())
                Spacer()
                Button {
                    Task { await model.load(store: store, forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading || model.isSyncing || model.isWaitingForMusic || store.isLoading || store.isWritingRekordbox)
                .help(.ui("iTunes 동기화 목록 새로고침"))
                .accessibilityLabel(.ui("iTunes 동기화 목록 새로고침"))
                .accessibilityIdentifier("itunes-sync-refresh")
            }
            Text(.ui("동기화할 폴더와 플레이리스트를 선택하세요. 폴더를 선택하면 하위 목록도 포함됩니다."))
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                PlaylistSyncPane(tree: tree, isLoading: model.isLoading,
                                 emptyMessage: String(ui: "읽을 수 있는 iTunes 목록이 없습니다"),
                                 selection: PlaylistSyncSelectionControls(state: { node in
                                     let id = String(node.id.dropFirst("itunes:".count))
                                     return model.selection.state(of: id, in: nodes)
                                 }, toggle: { node in
                                     let id = String(node.id.dropFirst("itunes:".count))
                                     let currentNodes = model.nodes
                                     model.selection.setSelected(model.selection.state(of: id, in: currentNodes) != .on,
                                                                 id: id, in: currentNodes)
                                 }, identifier: { node in
                                     "itunes-sync-\(node.id.dropFirst("itunes:".count))"
                                 })) {
                    HStack {
                        Text(verbatim: "iTunes").font(.headline)
                        Spacer()
                        Button(.ui("전체 선택")) { model.selection = ITunesSyncSelection(selectedIDs: ["0"]) }
                        Button(.ui("선택 해제")) { model.selection = ITunesSyncSelection() }
                    }
                }
                Image(systemName: "arrow.right").font(.title2).foregroundStyle(.secondary)
                PlaylistSyncPane(tree: preview.tree, emptyMessage: String(ui: "동기화할 목록을 선택하세요")) {
                    HStack {
                        Text(.ui("rekordbox 동기화 목록")).font(.headline)
                        Spacer()
                        Text(.ui("목록 \(preview.playlistCount)개")).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(model.isLoading || model.isSyncing || model.source.status != .ready)
            if let message = model.error {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if model.isWaitingForMusic {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(ITunesSyncModel.waitingForMusicMessage).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let message = model.source.status.message {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(.ui("선택한 목록을 rekordbox와 DJCrate에 동일하게 반영합니다. 먼저 rekordbox를 종료하세요."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(.ui("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(model.isSyncing)
                Button(.ui("동기화")) {
                    Task { if await model.sync(store: store) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSync || store.isLoading || store.isWritingRekordbox)
                .accessibilityIdentifier("itunes-sync-apply")
            }
        }
        .padding(24)
        .frame(width: 860, height: 560)
        .interactiveDismissDisabled(model.isSyncing)
        .task { await model.load(store: store) }
    }
}

