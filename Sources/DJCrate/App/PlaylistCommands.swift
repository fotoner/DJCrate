import DJCDomain
import SwiftUI

/// 메뉴 '재생 목록'(#39·#40). 바꾼 것은 모두 초안이고 반영(⇧⌘E) 때 rekordbox에 쓴다.
struct PlaylistCommands: View {
    let store: LibraryStore?
    /// 막힌 재생 목록 비교 시트를 여는 rekordbox 쓰기 화면 쪽
    var reflection: ReflectionCoordinator?

    private var enabled: Bool {
        guard let store, case .loaded = store.phase else { return false }
        return store.writeLockPolicy.allowsLibraryInteraction
    }

    private var tracks: [TrackRow] { store?.selectedRows.filter { !$0.isStaged } ?? [] }

    var body: some View {
        Button(.ui("새 재생 목록")) { store?.createPlaylist(isFolder: false) }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!enabled)
        Button(.ui("새 폴더")) { store?.createPlaylist(isFolder: true) }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!enabled)
        Button(.ui("고른 곡으로 새 재생 목록")) { store?.createPlaylist(isFolder: false, tracks: tracks) }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(!enabled || tracks.isEmpty)
        Divider()
        if let last = store?.lastUsedPlaylist {
            Button(.ui("‘\(last.name)’에 넣기")) { store?.addSelectionToLastPlaylist() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!enabled || tracks.isEmpty)
        } else {
            Button(.ui("마지막에 쓴 목록에 넣기")) {}
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(true)
        }
        Button(.ui("재생 목록에 넣기…")) { store?.openPlaylistPicker() }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!enabled || tracks.isEmpty)
        Button(.ui("이 목록에서 빼기")) { store?.removeSelectedFromPlaylist() }
            .disabled(!enabled || store?.editablePlaylistID == nil || tracks.isEmpty)
        Divider()
        Button(.ui("재생 목록 초안 버리기")) { if let store { PlaylistPanels.discardAll(store: store) } }
            .disabled(!enabled || store?.hasPlaylistDrafts != true)
        if let store, store.blockedPlaylistEditCount > 0 {
            Button(.ui("재생 목록 현재값 가져오기…")) { reflection?.startPlaylistRecovery() }
                .disabled(!enabled)
        }
    }
}
