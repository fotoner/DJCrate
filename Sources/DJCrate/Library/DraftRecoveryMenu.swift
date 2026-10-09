import AppKit
import DJCApplication
import DJCDomain

/// 선택으로 목록을 움직이지 않고, 곡·종류를 명시해 그 줄만 든 복구 시트를 연다(#232).
@MainActor
final class DraftRecoveryMenu: NSObject, NSMenuItemValidation {
    struct Target {
        let row: TrackRow
        let kind: DraftRecoveryKind
    }

    let store: LibraryStore
    /// 고른 곡·종류의 복구 시트를 연다(앱은 반영 화면 쪽 `ReflectionCoordinator.startRecovery`)
    let recover: @MainActor (TrackRow, DraftRecoveryKind) -> Void

    init(store: LibraryStore, recover: @escaping @MainActor (TrackRow, DraftRecoveryKind) -> Void) {
        self.store = store
        self.recover = recover
    }

    func append(to menu: NSMenu, rows targets: [TrackRow]) {
        let rows = store.uniqueTracks(targets).filter { !store.recoveryKinds(for: $0).isEmpty }
        let deckRow = store.deckTrackID.flatMap { store.rowsByID[$0] }
        let otherDeckRow = deckRow.flatMap { row in
            !rows.contains(where: { $0.track.uuid == row.track.uuid }) && !store.recoveryKinds(for: row).isEmpty ? row : nil
        }
        guard !rows.isEmpty || otherDeckRow != nil else { return }
        menu.addItem(.separator())
        if rows.count == 1, let row = rows.first {
            for kind in store.recoveryKinds(for: row) { menu.addItem(item(row: row, kind: kind)) }
        } else if !rows.isEmpty {
            let group = NSMenuItem(title: String(ui: "선택한 곡 현재값 가져오기…"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for row in rows {
                let track = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
                track.submenu = kindsMenu(row)
                submenu.addItem(track)
            }
            group.submenu = submenu
            menu.addItem(group)
        }
        if let row = otherDeckRow {
            let deck = NSMenuItem(title: String(ui: "덱 곡 현재값 가져오기…"), action: nil, keyEquivalent: "")
            deck.submenu = kindsMenu(row)
            menu.addItem(deck)
        }
    }

    private func kindsMenu(_ row: TrackRow) -> NSMenu {
        let menu = NSMenu()
        for kind in store.recoveryKinds(for: row) { menu.addItem(item(row: row, kind: kind)) }
        return menu
    }

    private func item(row: TrackRow, kind: DraftRecoveryKind) -> NSMenuItem {
        let item = NSMenuItem(title: kind.recoveryButtonTitle, action: #selector(recoverDraft(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Target(row: row, kind: kind)
        item.isEnabled = validateMenuItem(item)
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let target = item.representedObject as? Target else { return false }
        return !store.isRecoveringDraft && !store.isWritingRekordbox && (store.allowsLibrarySync?() ?? true)
            && store.recoveryKinds(for: target.row).contains(target.kind)
    }

    @objc private func recoverDraft(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let target = sender.representedObject as? Target else { return }
        recover(target.row, target.kind)
    }
}
