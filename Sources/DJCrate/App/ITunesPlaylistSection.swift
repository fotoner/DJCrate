import DJCDomain
import SwiftUI

/// iTunes 목록은 구성 편집·드롭 메뉴를 달지 않는다. 반복 곡의 행은 구분하고 편집은 기존 곡에 연결한다.
struct ITunesPlaylistSection: View {
    let store: LibraryStore
    @State private var isExpanded = true

    var body: some View {
        @Bindable var store = store
        Section(isExpanded: $isExpanded) {
            if let message = store.iTunesLibrary.status.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if store.iTunesLibrary.tree.isEmpty {
                Text(.ui("동기화한 iTunes 목록이 없습니다")).foregroundStyle(.secondary)
            }
            if store.iTunesLibrary.unavailablePlaylistCount > 0 {
                Text(.ui("원본에서 찾지 못한 목록 \(store.iTunesLibrary.unavailablePlaylistCount)개 · 동기화 선택을 확인하세요"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            OutlineGroup(store.iTunesLibrary.tree, children: \.children) { node in
                Label(node.name, systemImage: node.isFolder ? "folder" : "music.note.list")
                    .badge(node.trackIDs.count)
                    .lineLimit(1)
                    .help(node.name)
                    .tag(SidebarItem.itunesPlaylist(node.id))
            }
        } header: {
            HStack {
                Text(.ui("iTunes 동기화 목록"))
                Spacer(minLength: 0)
                // 비슷한 원형 화살표 버튼 둘이 펼침 화살표 옆에 붙어 헷갈려 메뉴 하나로 모은다(#120).
                Menu {
                    Button {
                        store.presentITunesSync()
                    } label: {
                        Label(.ui("iTunes 동기화…"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.isLoading || store.isWritingRekordbox || store.snapshotURL == nil)
                    Button {
                        Task { await store.refreshITunesPlaylists() }
                    } label: {
                        Label(.ui("iTunes 동기화 목록 새로고침"), systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isLoading || store.isWritingRekordbox)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(.ui("동기화할 iTunes 목록 고르기·새로고침"))
                .accessibilityLabel(.ui("iTunes 동기화 목록 작업"))
            }
            .sidebarSectionHeader()
        }
        .sheet(isPresented: $store.showingITunesSync) { ITunesSyncView(store: store) }
    }
}
