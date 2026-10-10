import DJCApplication
import DJCDomain
import AppKit
import SwiftUI

extension TrackListCoordinator {
    // MARK: - 오른쪽 클릭 메뉴

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// 오른쪽 클릭한 줄이 선택 밖이면 그 줄만, 아니면 선택 전체가 대상이다(Finder와 같다).
    func menuTargets() -> [TrackRow] {
        guard let table else { return [] }
        let clicked = table.clickedRow
        let indexes = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : table.selectedRowIndexes
        return store.uniqueTracks(indexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil })
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier?.rawValue == "columns" { fillColumnMenu(menu); return }
        menu.removeAllItems()
        if store.isUsbSelection || menuTargetsIncludeUsb {
            addReadOnlyItems(to: menu)
            return
        }
        let targets = menuTargets()
        // 누른 줄(없으면 고른 첫 줄)을 덱에 올린다(#93). ⌘→는 고른 첫 곡을 올린다.
        menu.addItem(LoadToDeckCommand.menuItem(action: loadMenuRowIndex == nil ? nil : #selector(loadMenuRow), target: self))
        recoveryMenu.append(to: menu, rows: targets)
        // 쓰기·넣기·빼기 대상은 반영 세션과 같은 규칙(`ReflectionTargets`)으로 고른다(누르면 "쓸 곡이 없습니다"가 뜨지 않게, adv2 N9).
        let pending = store.writeTargets(targets)
        if !pending.isEmpty {
            menu.addItem(.separator())
            let reflect = NSMenuItem(title: String(ui: "선택한 곡 rekordbox에 쓰기 (\(pending.count)곡)"),
                                     action: #selector(reflectSelected), keyEquivalent: "")
            reflect.target = self
            menu.addItem(reflect)
            let xml = NSMenuItem(title: String(ui: "선택한 곡 XML 만들기 (\(pending.count)곡)"), action: #selector(exportReflectionXML), keyEquivalent: "")
            xml.target = self
            menu.addItem(xml)
        }
        addPlaylistItems(to: menu, targets: targets)
        addUsbItems(to: menu, targets: targets)
        let staged = ReflectionTargets.add(targets)
        if !staged.isEmpty {
            menu.addItem(.separator())
            let add = NSMenuItem(title: String(ui: "rekordbox에 바로 넣기 (\(staged.count)곡)"), action: #selector(addToRekordbox), keyEquivalent: "")
            add.target = self
            menu.addItem(add)
            let export = NSMenuItem(title: String(ui: "추가한 곡 XML 만들기 (\(staged.count)곡)"), action: #selector(exportStaged), keyEquivalent: "")
            export.target = self
            menu.addItem(export)
        }
        menu.addItem(.separator())
        let pendingList = NSMenuItem(title: String(ui: "rekordbox 쓰기 대기 목록 보기"), action: #selector(showPending), keyEquivalent: "")
        pendingList.target = self
        menu.addItem(pendingList)
        let removable = store.deleteTargets(targets)
        if !removable.isEmpty {
            menu.addItem(.separator())
            // 재생 목록에서 빼기(⌫, 초안)와 헷갈리지 않게 컬렉션에서 지운다는 것을 적는다.
            let remove = NSMenuItem(title: String(ui: "rekordbox 컬렉션에서 빼기 (\(removable.count)곡)…"), action: #selector(deleteFromRekordbox), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }
    }

    /// 오른쪽 클릭한 줄·고른 줄에 USB 곡이 있는지(USB 곡은 편집·쓰기 메뉴를 달지 않는다)
    var menuTargetsIncludeUsb: Bool {
        guard let table else { return false }
        let clicked = table.clickedRow
        let indexes = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : table.selectedRowIndexes
        return indexes.contains { rows.indices.contains($0) && rows[$0].isUsb }
    }

    /// USB 곡은 직접 고치지 않는다: 고치기는 USB 초안 항목으로만 한다. 덱에는 짝인 로컬 곡을 올리고, 짝이 없으면 누른 뒤 이유를 알린다(#255)
    func addReadOnlyItems(to menu: NSMenu) {
        menu.addItem(LoadToDeckCommand.menuItem(action: loadMenuRowIndex == nil ? nil : #selector(loadMenuRow), target: self))
        guard !addUsbEditItems(to: menu) else { return }
        let note = NSMenuItem(title: String(ui: "USB 곡은 읽기만 합니다"), action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
    }

    /// 메뉴의 '덱에 불러오기'가 올릴 줄: 오른쪽 클릭한 줄, 없으면 고른 첫 줄.
    var loadMenuRowIndex: Int? {
        guard let table else { return nil }
        let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRowIndexes.first ?? -1
        return rows.indices.contains(index) ? index : nil
    }

    @objc func loadMenuRow() {
        if let index = loadMenuRowIndex { loadRow(at: index) }
    }

    @objc func addToRekordbox() {
        actions.addToRekordbox(menuTargets())
    }

    @objc func deleteFromRekordbox() {
        actions.deleteFromRekordbox(menuTargets())
    }

    @objc func reflectSelected() {
        // 고른 곡의 초안만 쓴다(재생 목록 초안은 ⇧⌘E·반영 대기 목록에서).
        actions.writeDrafts(menuTargets())
    }

    @objc func exportReflectionXML() {
        actions.exportDraftsXML(menuTargets())
    }

    @objc func exportStaged() {
        store.selection = Set(menuTargets().filter(\.isStaged).map(\.id))
        actions.exportStagedXML()
    }

    @objc func showPending() {
        store.sidebar = .pending
    }

    // MARK: - 데이터 소스

    // MARK: - 칸 보이기·숨기기

    func makeColumnMenu(_ table: NSTableView) -> NSMenu {
        let menu = NSMenu(title: String(ui: "칸"))
        menu.delegate = self
        menu.identifier = NSUserInterfaceItemIdentifier("columns")
        return menu
    }

    func fillColumnMenu(_ menu: NSMenu) {
        guard let table else { return }
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: String(ui: "보일 칸")))
        for spec in TrackColumn.all {
            if spec.id == "class", commentPreset?.rule == nil { continue }
            // 갱신 상태 칸은 USB 목록이 정한다. 다른 칸은 USB 목록에서도 같은 배치라 여기서 고른다(#256)
            if spec.id == TrackColumn.usbSyncID { continue }
            guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == spec.id }) else { continue }
            let title = spec.title.isEmpty ? String(ui: "앨범아트") : spec.id == "edited" ? String(ui: "초안 표시") : spec.title == "#" ? String(ui: "# 번호") : spec.title
            let item = NSMenuItem(title: title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.state = column.isHidden ? .off : .on
            item.representedObject = spec.id
            // 제목 칸은 숨기지 않는다.
            item.isEnabled = spec.id != "title"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reset = NSMenuItem(title: String(ui: "모든 칸 보이기"), action: #selector(showAllColumns), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let column = table?.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
        guard id != "class" || commentPreset?.rule != nil, id != TrackColumn.usbSyncID else { return }
        finishEditing(commit: true, restoreFocus: true)
        column.isHidden.toggle()
        if id == "class" { store.settings.set(SettingKeys.commentClassColumnHidden, column.isHidden) }
    }

    @objc func showAllColumns() {
        finishEditing(commit: true, restoreFocus: true)
        table?.tableColumns.forEach {
            let id = $0.identifier.rawValue
            // 갱신 상태 칸은 USB 목록에서만 보인다
            $0.isHidden = (id == "class" && commentPreset?.rule == nil) || (id == TrackColumn.usbSyncID && usbMode != true)
        }
        if commentPreset?.rule != nil { store.settings.set(SettingKeys.commentClassColumnHidden, false) }
    }
}
