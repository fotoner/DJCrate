import DJCApplication
import DJCDomain
import SwiftUI
import UniformTypeIdentifiers

/// 사이드바 USB 재생 목록 줄
struct UsbPlaylistNode: Identifiable, Hashable {
    var id: Int
    var name: String
    var isFolder: Bool
    var isSmart: Bool
    /// 보일 항목 수(폴더는 0)
    var count: Int
    /// 두 형식을 함께 쓴 USB에서 한 형식에만 있는 목록("OneLibrary만"·"Device Library만")
    var marker: String?
    /// 두 형식의 항목(곡·순서)이 다르다
    var entriesDiffer: Bool
    /// 폴더면 하위 목록(비어 있어도 배열), 목록이면 nil
    var children: [UsbPlaylistNode]?
}

/// 합친 USB 라이브러리의 재생 목록 → 사이드바 트리
enum UsbPlaylistTree {
    static var mismatchHelp: String { String(ui: "두 형식의 재생 목록 내용이 다릅니다") }

    static func build(_ library: UsbLibrary) -> [UsbPlaylistNode] {
        let bothFormats = library.formats.isSuperset(of: UsbFormat.defaultSet)
        let byParent = Dictionary(grouping: library.playlists, by: \.parentID)
        var visited: Set<Int> = []
        func order(_ playlist: UsbPlaylist) -> Int { playlist.sortOrder[.oneLibrary] ?? playlist.sortOrder[.deviceLibrary] ?? .max }
        func nodes(under parent: Int) -> [UsbPlaylistNode] {
            (byParent[parent] ?? []).sorted { (order($0), $0.id) < (order($1), $1.id) }.compactMap { playlist in
                // 부모가 자기 자신을 가리키는 깨진 트리에서 끝없이 돌지 않게
                guard visited.insert(playlist.id).inserted else { return nil }
                let isFolder = playlist.attribute == 1
                var marker: String?
                if bothFormats, playlist.presentIn.count == 1 {
                    marker = playlist.presentIn.contains(.oneLibrary) ? String(ui: "OneLibrary만") : String(ui: "Device Library만")
                }
                let differ = bothFormats && !isFolder && playlist.presentIn.isSuperset(of: UsbFormat.defaultSet)
                    && playlist.entries[.oneLibrary] ?? [] != playlist.entries[.deviceLibrary] ?? []
                return UsbPlaylistNode(id: playlist.id, name: playlist.name, isFolder: isFolder, isSmart: playlist.attribute == 4,
                                       count: isFolder ? 0 : UsbLibraryRows.entries(of: playlist).count, marker: marker,
                                       entriesDiffer: differ, children: isFolder ? nodes(under: playlist.id) : nil)
            }
        }
        return nodes(under: 0)
    }
}

/// 사이드바 USB 절의 볼륨 하나(순수 모델, 화면은 이것만 그린다)
struct UsbSidebarVolume: Identifiable, Equatable {
    /// 볼륨키
    var id: String
    var name: String
    var symbol: String
    var isWarning: Bool
    /// 이름 아래 짧은 안내(읽는 중·막힌 이유 등)
    var status: String?
    var help: String
    /// "USB로 내보내기…"(빈 FAT32)
    var showsExport: Bool
    /// 내보내기를 누를 수 있는지(쓰는 중이 아닐 때)
    var canExport: Bool
    var collection: UsbSidebarTarget?
    var collectionCount: Int
    var playlists: [UsbPlaylistNode]
    /// 두 형식의 재생 목록이 다를 때의 경고
    var mismatchHelp: String?
    var canEject: Bool
    /// USB 쓰기 대기(초안을 받는 볼륨만)
    var pending: UsbSidebarTarget? = nil
    /// 초안 편집 수
    var pendingCount = 0
    var showsMigration = false
    var canMigrate = false
    var migrationHelp: String?
    var showsMigrationRestore = false
    var showsSync = false
    var canSync = false
}

@MainActor
enum UsbSidebarModel {
    static func volumes(_ store: UsbStore) -> [UsbSidebarVolume] {
        store.volumes.map { volume in
            let key = volume.usbKey
            let idle = !store.busyVolumes.contains(key) && store.activeWrite == nil
            var row = UsbSidebarVolume(id: key, name: volume.name, symbol: "externaldrive", isWarning: false, status: nil, help: volume.name,
                                       showsExport: false, canExport: false, collection: nil, collectionCount: 0, playlists: [], mismatchHelp: nil,
                                       canEject: !store.busyVolumes.contains(key) && !store.ejecting.contains(key))
            row.showsMigrationRestore = store.migrationBackups[key] != nil
            if store.acceptsEdits(key) {
                row.pending = .pending(volumeKey: key)
                row.pendingCount = store.draftCounts[key] ?? 0
            }
            switch store.shapes[key] {
            case .emptyExportable:
                row.showsSync = true
                row.canSync = idle && !store.ejecting.contains(key)
                row.showsExport = true
                row.canExport = idle
                row.help = String(ui: "rekordbox 라이브러리가 없는 USB입니다")
            case let .rekordbox(formats):
                row.showsSync = true
                row.canSync = idle && !store.ejecting.contains(key)
                row.symbol = "externaldrive.fill"
                row.help = UsbFormat.allCases.filter(formats.contains).map(\.displayName).joined(separator: " · ")
                if formats == [.deviceLibrary] {
                    row.showsMigration = true
                    row.help = String(ui: "Device Library만 있습니다. OneLibrary를 더하려면 ‘OneLibrary 더하기…’를 누르세요")
                    let reason = store.migrationBlockReasons[key] ?? store.physicalWriteBlock(volume)
                    row.canMigrate = idle && reason == nil
                    row.migrationHelp = reason ?? String(ui: "Device Library를 읽어 OneLibrary를 더합니다. 확인 창에서 CDJ에서 확인하지 않은 항목을 확인하세요")
                }
                if let library = store.libraries[key] {
                    row.collection = .collection(volumeKey: key)
                    row.collectionCount = library.tracks.count
                    // 곡 수는 목록 줄과 같게 초안을 얹은 항목으로 센다
                    row.playlists = UsbPlaylistTree.build(UsbDraftProjection.library(library, edits: store.draftEdits[key] ?? []))
                }
                if (store.infos[key]?.consistency.playlistMismatches ?? 0) > 0 { row.mismatchHelp = UsbPlaylistTree.mismatchHelp }
            case let .unsupported(reason):
                row.isWarning = true
                row.symbol = "exclamationmark.triangle"
                row.help = reason
                row.status = reason
            case let .failed(message):
                row.isWarning = true
                row.symbol = "exclamationmark.triangle"
                row.help = message
                row.status = message
            case .reading, nil:
                row.status = String(ui: "읽는 중…")
                // 다시 읽는 중에는 앞서 읽은 목록을 그대로 둔다(고른 목록이 사라지지 않게)
                if let library = store.libraries[key] {
                    row.symbol = "externaldrive.fill"
                    row.collection = .collection(volumeKey: key)
                    row.collectionCount = library.tracks.count
                    row.playlists = UsbPlaylistTree.build(library)
                }
            }
            return row
        } + absent(store)
    }

    /// 초안이 남은 채 빠진 볼륨: 이름·연결 안 됨·쓰기 대기만
    private static func absent(_ store: UsbStore) -> [UsbSidebarVolume] {
        store.absentDrafts.values.sorted { $0.volume.name.localizedStandardCompare($1.volume.name) == .orderedAscending }.compactMap { absent in
            let key = absent.volume.usbKey
            guard store.acceptsEdits(key) else { return nil }
            return UsbSidebarVolume(id: key, name: absent.volume.name, symbol: "externaldrive.badge.xmark", isWarning: false,
                                    status: String(ui: "연결 안 됨"), help: String(ui: "USB를 연결하면 쓰기 대기의 초안을 쓸 수 있습니다"),
                                    showsExport: false, canExport: false, collection: nil, collectionCount: 0, playlists: [], mismatchHelp: nil,
                                    canEject: false, pending: .pending(volumeKey: key), pendingCount: store.draftCounts[key] ?? 0)
        }
    }
}

/// 사이드바 "USB" 절: 볼륨마다 모양·꺼내기, 빈 FAT32는 내보내기, rekordbox USB는 컬렉션·재생 목록과 쓰기 대기.
/// 로컬 곡을 컬렉션·일반 재생 목록에 끌어다 놓으면 곡 더하기 초안이 된다(USB에는 "USB에 쓰기…" 때 쓴다)
struct UsbSidebarSection: View {
    let store: LibraryStore
    let usb: UsbStore
    @State private var isExpanded = true
    @State private var collapsed: Set<String> = []

    var body: some View {
        Section(isExpanded: $isExpanded) {
            let volumes = UsbSidebarModel.volumes(usb)
            if volumes.isEmpty {
                Text(.ui("연결된 USB가 없습니다")).foregroundStyle(.secondary)
            }
            ForEach(volumes) { volume in
                DisclosureGroup(isExpanded: expanded(volume.id)) {
                    contents(of: volume)
                } label: {
                    header(of: volume)
                }
            }
            if let ejectMessage = usb.ejectMessage {
                Text(ejectMessage).font(.caption).foregroundStyle(UIColors.warning.color).lineLimit(3)
            }
        } header: {
            HStack {
                Text(verbatim: "USB")
                Spacer(minLength: 0)
                Button {
                    usb.refreshTapped()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(.ui("USB 다시 읽기"))
                .accessibilityLabel(.ui("USB 다시 읽기"))
            }
        }
    }

    private func expanded(_ key: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(key) }, set: { open in
            if open { collapsed.remove(key) } else { collapsed.insert(key) }
        })
    }

    private func header(of volume: UsbSidebarVolume) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Label {
                    Text(verbatim: volume.name).lineLimit(1)
                } icon: {
                    Image(systemName: volume.symbol)
                        .foregroundStyle(volume.isWarning ? UIColors.warning.color : Color.secondary)
                }
                if let status = volume.status {
                    Text(verbatim: status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if volume.showsSync {
                Button {
                    usb.presentSync(volume.id)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .disabled(!volume.canSync || store.isLoading || store.isWritingRekordbox || store.snapshotURL == nil)
                .help(.ui("USB 동기화 설정…"))
                .accessibilityLabel(.ui("\(volume.name) 동기화…"))
                .accessibilityIdentifier("usb-sync-\(volume.id)")
            }
            if usb.volume(volume.id) != nil {
                Button {
                    usb.ejectTapped(volume.id)
                } label: {
                    Image(systemName: "eject")
                }
                .buttonStyle(.borderless)
                .disabled(!volume.canEject)
                .help(.ui("꺼내기"))
                .accessibilityLabel(.ui("\(volume.name) 꺼내기"))
            }
        }
        .help(volume.help)
        .contextMenu {
            migrationButtons(volume)
        }
    }

    @ViewBuilder private func migrationButtons(_ volume: UsbSidebarVolume) -> some View {
        if volume.showsMigration {
            Button {
                store.usbCoordinator?.startMigrate(volumeKey: volume.id)
            } label: {
                Label(.ui("OneLibrary 더하기…"), systemImage: "plus.rectangle.on.folder")
            }
            .buttonStyle(.plain)
            .disabled(!volume.canMigrate)
            .help(volume.migrationHelp ?? volume.help)
        }
        if volume.showsMigrationRestore {
            Button(.ui("쓰기 전으로 되돌리기…")) {
                store.usbCoordinator?.startRestoreMigration(volumeKey: volume.id)
            }
            .buttonStyle(.plain)
            .disabled(usb.activeWrite != nil)
            .help(.ui("이번에 OneLibrary를 더하기 전에 만든 백업으로 USB를 되돌립니다"))
        }
    }

    @ViewBuilder private func contents(of volume: UsbSidebarVolume) -> some View {
        if volume.showsExport {
            Button {
                if let info = usb.volume(volume.id) { usb.exportSheet = UsbExportSheetRequest(volume: info) }
            } label: {
                Label(.ui("USB로 내보내기…"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(!volume.canExport)
            .help(.ui("로컬 재생 목록·곡을 이 USB에 OneLibrary·Device Library로 내보냅니다"))
        }
        migrationButtons(volume)
        if let collection = volume.collection {
            UsbDropRow(store: store, target: collection) {
                Label(.ui("컬렉션"), systemImage: "music.note.list")
            }
            .badge(volume.collectionCount)
            .tag(SidebarItem.usb(collection))
        }
        if let pending = volume.pending {
            Label(.ui("USB 쓰기 대기"), systemImage: "square.and.arrow.up.on.square")
                .badge(volume.pendingCount)
                .tag(SidebarItem.usb(pending))
                .help(.ui("이 USB에 쓸 초안(곡 더하기·빼기·갱신, 재생 목록 편집)을 모아 봅니다"))
        }
        if volume.collection != nil {
            if let help = volume.mismatchHelp {
                Label(.ui("재생 목록이 형식마다 다릅니다"), systemImage: WarningMark.symbol)
                    .font(.caption)
                    .foregroundStyle(UIColors.warning.color)
                    .help(help)
            }
            OutlineGroup(volume.playlists, children: \.children) { node in
                UsbDropRow(store: store, target: .playlist(volumeKey: volume.id, id: node.id)) {
                    UsbPlaylistRow(node: node)
                }
                .badge(node.isFolder ? 0 : node.count)
                .tag(SidebarItem.usb(.playlist(volumeKey: volume.id, id: node.id)))
            }
        }
    }
}

/// 곡을 놓을 수 있는 USB 줄. 로컬 곡은 컬렉션·일반 재생 목록에 놓아 곡 더하기, USB 곡은 같은 USB의 일반 재생 목록에 놓아 넣기 초안이 된다(#240)
private struct UsbDropRow<Content: View>: View {
    let store: LibraryStore
    let target: UsbSidebarTarget
    @ViewBuilder var content: Content
    @State private var highlight = DropHighlight()

    var body: some View {
        content
            .onDrop(of: [PlaylistDragType.tracks, PlaylistDragType.usbTracks], delegate: UsbDropDelegate(store: store, target: target, highlight: $highlight))
            .background(highlight.isTargeted ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// 끄는 곡의 종류(로컬·USB)와 끄는 USB를 보고 받을 줄만 강조한다
private struct UsbDropDelegate: DropDelegate {
    let store: LibraryStore
    let target: UsbSidebarTarget
    @Binding var highlight: DropHighlight

    func validateDrop(info: DropInfo) -> Bool {
        UsbDrop.accepts(local: info.hasItemsConforming(to: [PlaylistDragType.tracks]), usb: info.hasItemsConforming(to: [PlaylistDragType.usbTracks]),
                        on: target, store: store)
    }

    func dropEntered(info: DropInfo) { highlight.enter(accepted: validateDrop(info: info)) }
    func dropExited(info: DropInfo) { highlight.exit() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let accepted = validateDrop(info: info)
        highlight.update(accepted: accepted)
        return DropProposal(operation: accepted ? .copy : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        highlight.drop()
        guard validateDrop(info: info) else { return false }
        return UsbDrop.perform(info.itemProviders(for: [PlaylistDragType.usbTracks, PlaylistDragType.tracks]), on: target, store: store)
    }
}

/// 사이드바 USB 줄에 놓은 곡
@MainActor
enum UsbDrop {
    /// 놓을 수 있는지: 로컬 곡은 컬렉션·일반 재생 목록, USB 곡은 끄는 USB와 같은 USB의 일반 재생 목록
    static func accepts(local: Bool, usb: Bool, on target: UsbSidebarTarget, store: LibraryStore) -> Bool {
        guard store.writeLockPolicy.allowsLibraryInteraction, let actions = store.usbEdits else { return false }
        if usb { return actions.acceptsUsbDrop(from: store.usbDragVolume, on: target) }
        return local && actions.acceptsDrop(on: target)
    }

    static func perform(_ providers: [NSItemProvider], on target: UsbSidebarTarget, store: LibraryStore) -> Bool {
        guard store.writeLockPolicy.allowsLibraryInteraction, let actions = store.usbEdits else { return false }
        let usbTracks = providers.filter { $0.hasItemConformingToTypeIdentifier(PlaylistDragType.usbTracks.identifier) }
        if !usbTracks.isEmpty {
            guard actions.acceptsUsbDrop(from: store.usbDragVolume, on: target) else { return false }
            PlaylistDrop.loadStrings(usbTracks, type: PlaylistDragType.usbTracks) { strings in
                actions.startDropUsbTracks(strings.compactMap(UsbTrackDrag.init(pasteboardString:)), on: target)
            }
            return true
        }
        guard actions.acceptsDrop(on: target) else { return false }
        let tracks = providers.filter { $0.hasItemConformingToTypeIdentifier(PlaylistDragType.tracks.identifier) }
        guard !tracks.isEmpty else { return false }
        PlaylistDrop.loadStrings(tracks, type: PlaylistDragType.tracks) { ids in
            actions.startDrop(ids, on: target, rows: store.rowsByID)
        }
        return true
    }
}

/// 사이드바 USB 줄의 오른쪽 클릭 메뉴(초안): 새 목록·폴더, 이름 바꾸기, 순서, 지우기, 로컬 변경 반영, 쓰기 대기.
/// 막힐 편집은 누를 수 없게 하고 이유를 도움말로 단다
struct UsbSidebarMenu: View {
    let store: LibraryStore
    let actions: UsbEditActions
    let target: UsbSidebarTarget

    private var key: String { target.volumeKey }

    var body: some View {
        if actions.usb.acceptsEdits(key) {
            switch target {
            case .collection:
                createButtons(parent: nil)
                Divider()
                refreshButton
                pendingButton
            case let .playlist(_, id):
                if let playlist = actions.usb.editLibrary(key)?.playlists.first(where: { $0.id == id }) {
                    createButtons(parent: playlist.attribute == 1 ? id : (playlist.parentID == 0 ? nil : playlist.parentID))
                    Divider()
                    edit(String(ui: "이름 바꾸기…"), .playlist(edit: .rename(playlist: .id(String(id)), name: playlist.name)),
                         .renamePlaylist(id, volumeKey: key))
                    moveButton(String(ui: "위로 옮기기"), id: id, step: -1)
                    moveButton(String(ui: "아래로 옮기기"), id: id, step: 1)
                    Divider()
                    edit(playlist.attribute == 1 ? String(ui: "폴더 지우기") : String(ui: "재생 목록 지우기"),
                         .playlist(edit: .delete(playlist: .id(String(id)))), .deletePlaylist(id, volumeKey: key))
                    Divider()
                    pendingButton
                }
            case .pending:
                Button(.ui("USB에 쓰기…")) {
                    store.usbCoordinator?.startWriteDraft(volumeKey: key, database: store.snapshotURL, share: store.shareRoot)
                }
                .disabled(actions.usb.volume(key) == nil || (actions.usb.draftCounts[key] ?? 0) == 0)
                Button(.ui("초안 버리기"), role: .destructive) { actions.start(.discardDraft(volumeKey: key)) }
                    .disabled((actions.usb.draftCounts[key] ?? 0) == 0)
            }
        }
    }

    @ViewBuilder private func createButtons(parent: Int?) -> some View {
        let parentRef: PlaylistRef = parent.map { .id(String($0)) } ?? .root
        edit(String(ui: "새 재생 목록…"), .playlist(edit: .create(key: "menu", name: "menu", isFolder: false, parent: parentRef)),
             .createPlaylist(isFolder: false, parent: parent, volumeKey: key))
        edit(String(ui: "새 폴더…"), .playlist(edit: .create(key: "menu", name: "menu", isFolder: true, parent: parentRef)),
             .createPlaylist(isFolder: true, parent: parent, volumeKey: key))
    }

    private var refreshButton: some View {
        let count = actions.updatableTracks(volumeKey: key).count
        let reason = count == 0 ? nil : actions.refreshBlockReason(volumeKey: key)
        return Button(.ui("로컬 변경을 USB에 반영 (\(count)곡)")) { actions.start(.refreshLocalChanges(volumeKey: key)) }
            .disabled(count == 0 || reason != nil)
            .help(reason ?? String(ui: "로컬에서 더 고친 곡(갱신 가능)을 USB 쓰기 대기에 더합니다. USB는 ‘USB에 쓰기…’를 누를 때 바뀝니다."))
    }

    /// 같은 부모 안에서 한 칸 옮기기: 초안을 적용한 자리에서 옮길 곳이 없거나 막히면 누를 수 없고, 막힌 이유를 도움말로
    private func moveButton(_ title: String, id: Int, step: Int) -> some View {
        let reason = actions.moveBlockReason(id, by: step, volumeKey: key)
        return Button(title) { actions.start(.movePlaylist(id, by: step, volumeKey: key)) }
            .disabled(!actions.canMovePlaylist(id, by: step, volumeKey: key) || reason != nil)
            .help(reason ?? title)
    }

    private var pendingButton: some View {
        Button(.ui("USB 쓰기 대기 목록 보기")) { store.sidebar = .usb(.pending(volumeKey: key)) }
    }

    /// 막힐 편집이면 누를 수 없게 하고 이유를 도움말로. 누르면 그 편집 동작을 시작한다(뷰는 기다리지 않는다)
    private func edit(_ title: String, _ edit: UsbLibraryEdit, _ intent: UsbEditActions.Intent) -> some View {
        let reason = actions.blockReason(edit, volumeKey: key)
        return Button(title) { actions.start(intent) }
            .disabled(reason != nil)
            .help(reason ?? title)
    }
}

private struct UsbPlaylistRow: View {
    let node: UsbPlaylistNode

    var body: some View {
        HStack(spacing: 4) {
            Label {
                Text(verbatim: node.name).lineLimit(1)
            } icon: {
                Image(systemName: node.isFolder ? "folder" : node.isSmart ? "gearshape" : "music.note.list")
            }
            if let marker = node.marker {
                Text(verbatim: marker)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            if node.entriesDiffer {
                Image(systemName: WarningMark.symbol)
                    .foregroundStyle(UIColors.warning.color)
                    .help(UsbPlaylistTree.mismatchHelp)
                    .accessibilityLabel(UsbPlaylistTree.mismatchHelp)
            }
        }
        .help(node.name)
    }
}
