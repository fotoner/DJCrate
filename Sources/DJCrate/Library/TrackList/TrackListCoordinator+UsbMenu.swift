import DJCDomain
import AppKit
import SwiftUI

extension TrackListCoordinator {
    // MARK: USB 초안

    /// 로컬 곡 메뉴 'USB에 넣기 ▸ <볼륨> ▸ 컬렉션·목록'. 막힐 편집은 누를 수 없게 하고 이유를 도움말로 단다
    func addUsbItems(to menu: NSMenu, targets: [TrackRow]) {
        guard let edits = store.usbEdits else { return }
        let tracks = targets.filter { !$0.isStaged && !$0.track.isStreaming }
        let volumes = edits.targets
        guard !tracks.isEmpty, !volumes.isEmpty else { return }
        menu.addItem(.separator())
        let add = NSMenuItem(title: String(ui: "USB에 넣기"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let ids = tracks.map(\.track.id)
        for volume in volumes {
            let title = volume.isConnected ? volume.name : String(ui: "\(volume.name) (연결 안 됨)")
            let volumeItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            volumeItem.image = NSImage(systemSymbolName: volume.isConnected ? "externaldrive.fill" : "externaldrive.badge.xmark",
                                       accessibilityDescription: nil)
            let volumeMenu = NSMenu()
            volumeMenu.addItem(usbAddItem(String(ui: "컬렉션"), target: .collection(volumeKey: volume.volumeKey), ids: ids, edits: edits))
            let nodes = UsbPlaylistTree.build(volume.library)
            if !nodes.isEmpty { volumeMenu.addItem(.separator()) }
            fillUsbPlaylistTree(volumeMenu, nodes: nodes, volumeKey: volume.volumeKey, ids: ids, edits: edits)
            volumeItem.submenu = volumeMenu
            submenu.addItem(volumeItem)
        }
        add.submenu = submenu
        menu.addItem(add)
    }

    func fillUsbPlaylistTree(_ menu: NSMenu, nodes: [UsbPlaylistNode], volumeKey: String, ids: [String], edits: UsbEditActions) {
        for node in nodes where !node.isSmart {
            if node.isFolder {
                let folder = NSMenuItem(title: node.name, action: nil, keyEquivalent: "")
                folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu()
                fillUsbPlaylistTree(submenu, nodes: node.children ?? [], volumeKey: volumeKey, ids: ids, edits: edits)
                if submenu.items.isEmpty {
                    let empty = NSMenuItem(title: String(ui: "(빈 폴더)"), action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    submenu.addItem(empty)
                }
                folder.submenu = submenu
                menu.addItem(folder)
            } else {
                let item = usbAddItem(node.name, target: .playlist(volumeKey: volumeKey, id: node.id), ids: ids, edits: edits)
                item.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
    }

    func usbAddItem(_ title: String, target: UsbSidebarTarget, ids: [String], edits: UsbEditActions) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(addToUsb(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = target
        let playlist: PlaylistRef? = if case let .playlist(_, id) = target { .id(String(id)) } else { nil }
        if let reason = edits.blockReason(.addTracks(localContentIDs: ids, playlist: playlist), volumeKey: target.volumeKey) {
            item.action = nil
            item.toolTip = reason
        }
        return item
    }

    @objc func addToUsb(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? UsbSidebarTarget else { return }
        actions.addToUsb(menuTargets(), target)
    }

    /// 오른쪽 클릭한 USB 줄(선택 밖이면 그 줄만). 같은 곡이 목록에 여러 번 있으면 줄마다
    func usbMenuTargets() -> [TrackRow] {
        guard let table else { return [] }
        let clicked = table.clickedRow
        let indexes = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : table.selectedRowIndexes
        return indexes.compactMap { rows.indices.contains($0) && rows[$0].isUsb ? rows[$0] : nil }
    }

    /// USB 곡 메뉴: 이 목록에서 빼기·USB에서 빼기·로컬 변경 반영(초안). 초안을 받지 않는 USB면 false
    func addUsbEditItems(to menu: NSMenu) -> Bool {
        guard case let .usb(target) = store.sidebar, let edits = store.usbEdits, edits.usb.acceptsEdits(target.volumeKey) else { return false }
        let key = target.volumeKey
        let targets = usbMenuTargets()
        let ids = UsbEditActions.usbContentIDs(targets, volumeKey: key)
        guard !ids.isEmpty else { return false }
        menu.addItem(.separator())
        if case let .playlist(_, playlist) = target, let name = edits.usb.editLibrary(key)?.playlists.first(where: { $0.id == playlist })?.name,
           let edit = UsbEditActions.removeFromPlaylistEdit(targets, volumeKey: key, playlist: playlist) {
            menu.addItem(usbEditItem(String(ui: "‘\(name)’에서 빼기 (\(targets.count)곡)"), #selector(removeFromUsbPlaylist), edit, edits: edits, key: key))
        }
        menu.addItem(usbEditItem(String(ui: "USB에서 빼기 (\(ids.count)곡)"), #selector(removeFromUsb), .removeTracks(usbContentIDs: ids),
                                 edits: edits, key: key))
        let updatable = edits.updatableTracks(volumeKey: key, rows: targets)
        let refreshReason = updatable.isEmpty ? String(ui: "로컬에서 더 고친 곡(갱신 가능)이 없습니다")
            : edits.refreshBlockReason(volumeKey: key, rows: targets)
        let refresh = NSMenuItem(title: String(ui: "로컬 변경을 USB에 반영 (\(updatable.count)곡)"),
                                 action: refreshReason == nil ? #selector(refreshUsbTracks) : nil, keyEquivalent: "")
        refresh.target = self
        refresh.toolTip = refreshReason
        menu.addItem(refresh)
        menu.addItem(.separator())
        let pending = NSMenuItem(title: String(ui: "USB 쓰기 대기 목록 보기"), action: #selector(showUsbPending), keyEquivalent: "")
        pending.target = self
        menu.addItem(pending)
        return true
    }

    func usbEditItem(_ title: String, _ action: Selector, _ edit: UsbLibraryEdit, edits: UsbEditActions, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let reason = edits.blockReason(edit, volumeKey: key) {
            item.action = nil
            item.toolTip = reason
        }
        return item
    }

    @objc func removeFromUsb() {
        guard case let .usb(target) = store.sidebar else { return }
        actions.removeFromUsb(usbMenuTargets(), target.volumeKey)
    }

    @objc func removeFromUsbPlaylist() {
        guard case let .usb(.playlist(key, playlist)) = store.sidebar else { return }
        actions.removeFromUsbPlaylist(usbMenuTargets(), key, playlist)
    }

    @objc func refreshUsbTracks() {
        guard case let .usb(target) = store.sidebar else { return }
        actions.refreshUsbTracks(usbMenuTargets(), target.volumeKey)
    }

    @objc func showUsbPending() {
        guard case let .usb(target) = store.sidebar else { return }
        store.sidebar = .usb(.pending(volumeKey: target.volumeKey))
    }
}
