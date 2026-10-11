import DJCDomain
import AppKit
import SwiftUI

// MARK: - 재생 목록(#39)

extension TrackListCoordinator {
    /// 오른쪽 클릭 메뉴: '재생 목록에 넣기 ▸'(최근 목록 → 폴더 트리 → 찾아서 넣기·새 목록), 목록을 볼 때 '이 목록에서 빼기'
    func addPlaylistItems(to menu: NSMenu, targets: [TrackRow]) {
        let tracks = targets.filter { !$0.isStaged }
        guard !tracks.isEmpty, store.snapshotURL != nil else { return }
        menu.addItem(.separator())
        let add = NSMenuItem(title: String(ui: "재생 목록에 넣기"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let recent = store.playlists.recentPlaylists
        for item in recent { submenu.addItem(playlistItem(item, path: store.playlists.playlistProjection.layout.ancestors(of: item.id).map(\.name))) }
        if !recent.isEmpty { submenu.addItem(.separator()) }
        fillPlaylistTree(submenu, parent: PlaylistLayout.root)
        if submenu.items.last?.isSeparatorItem == false { submenu.addItem(.separator()) }
        let find = NSMenuItem(title: String(ui: "찾아서 넣기…"), action: #selector(pickPlaylist), keyEquivalent: "")
        find.target = self
        submenu.addItem(find)
        let create = NSMenuItem(title: String(ui: "새 재생 목록으로 (\(tracks.count)곡)"), action: #selector(createPlaylistFromTracks), keyEquivalent: "")
        create.target = self
        submenu.addItem(create)
        add.submenu = submenu
        menu.addItem(add)
        if let id = store.playlists.editablePlaylistID, let name = store.playlists.playlistItem(id)?.name {
            let remove = NSMenuItem(title: String(ui: "‘\(name)’에서 빼기 (\(tracks.count)곡)"), action: #selector(removeFromPlaylist), keyEquivalent: "\u{8}")
            remove.keyEquivalentModifierMask = []
            remove.target = self
            menu.addItem(remove)
        }
    }

    func fillPlaylistTree(_ menu: NSMenu, parent: String) {
        for item in store.playlists.playlistProjection.layout.children(of: parent) where !item.isSmart {
            if item.isFolder {
                let folder = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
                folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu()
                fillPlaylistTree(submenu, parent: item.id)
                if submenu.items.isEmpty {
                    let empty = NSMenuItem(title: String(ui: "(빈 폴더)"), action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    submenu.addItem(empty)
                }
                folder.submenu = submenu
                menu.addItem(folder)
            } else {
                menu.addItem(playlistItem(item, path: []))
            }
        }
    }

    func playlistItem(_ item: PlaylistLayout.Item, path: [String]) -> NSMenuItem {
        let title = path.isEmpty ? item.name : (path + [item.name]).joined(separator: " › ")
        let menuItem = NSMenuItem(title: title, action: #selector(addToPlaylist(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = item.id
        menuItem.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)
        return menuItem
    }

    @objc func addToPlaylist(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.playlists.addTracks(menuTargets(), toPlaylist: id)
    }

    @objc func removeFromPlaylist() {
        guard let id = store.playlists.editablePlaylistID else { return }
        store.playlists.removeTracks(menuTargets(), fromPlaylist: id)
    }

    @objc func pickPlaylist() {
        store.playlists.openPlaylistPicker(tracks: menuTargets())
    }

    @objc func createPlaylistFromTracks() {
        store.playlists.createPlaylist(isFolder: false, tracks: menuTargets())
    }
}
