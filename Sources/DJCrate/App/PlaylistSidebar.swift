import AppKit
import DJCDomain
import SwiftUI
import UniformTypeIdentifiers

/// 끌어다 놓기 형식: 곡 목록의 곡(ContentID)과 사이드바의 재생 목록(ID). 앱 안에서만 쓴다.
/// 곡 형식은 표(AppKit)가 싣고 사이드바(SwiftUI)가 받으므로 Info.plist에 선언한다(선언이 없으면 SwiftUI가 받지 못한다, #240).
enum PlaylistDragType {
    static let tracks = UTType(exportedAs: "com.djcrate.track-ids", conformingTo: .data)
    static let playlist = UTType(exportedAs: "com.djcrate.playlist-id", conformingTo: .data)
    static let pasteboardTracks = NSPasteboard.PasteboardType(tracks.identifier)
    /// USB 곡(`UsbTrackDrag`). 로컬 곡 형식과 따로 두어 로컬 재생 목록·덱·앱 밖에는 놓이지 않는다
    static let usbTracks = UTType(exportedAs: "com.djcrate.usb-track-ids", conformingTo: .data)
    static let pasteboardUsbTracks = NSPasteboard.PasteboardType(usbTracks.identifier)

    static func provider(for node: PlaylistOutlineNode) -> NSItemProvider {
        let provider = NSItemProvider()
        // 인텔리전트 목록은 옮기지 않는다(규칙 미확인).
        guard !node.isSmart else { return provider }
        let data = Data(node.id.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: playlist.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

/// 사이드바 재생 목록(#40): 초안을 얹은 트리, 만들기·이름 바꾸기·지우기·옮기기, 곡을 끌어다 놓기(#39).
/// 바꾼 것은 모두 초안이고 반영(⇧⌘E) 때 rekordbox에 쓴다.
struct PlaylistSection: View {
    @Bindable var store: LibraryStore
    /// 펼침 설정은 사이드바 본문이 아니라 여기서 든다(`@AppStorage`를 든 뷰는 부모가 다시 계산될 때마다 본문이 새로 계산된다, #141).
    @AppStorage(SettingKeys.sidebarPlaylistsExpanded.name) private var isExpanded = SettingKeys.sidebarPlaylistsExpanded.defaultValue

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(store.playlistTree) { node in
                PlaylistTreeRow(store: store, node: node)
            }
        } header: {
            HStack(spacing: 4) {
                Text(.ui("rekordbox 플레이리스트 (\(store.playlistCount))"))
                if store.hasPlaylistDrafts {
                    Image(systemName: DraftMark.symbol)
                        .foregroundStyle(UIColors.draft.color)
                        .help(.ui("아직 쓰지 않은 재생 목록 초안 \(store.playlistDraft.steps.count)건"))
                        .accessibilityLabel(.ui("재생 목록 초안 \(store.playlistDraft.steps.count)건"))
                }
                Spacer(minLength: 0)
                Menu {
                    PlaylistCreateButtons(store: store, parent: PlaylistLayout.root)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(.ui("새 재생 목록·폴더(맨 위)"))
                .accessibilityLabel(.ui("새 재생 목록·폴더"))
            }
            .sidebarSectionHeader()
            // 제목 줄에 놓으면 맨 위의 맨 끝으로 옮긴다.
            .onDrop(of: [PlaylistDragType.playlist], isTargeted: nil) { providers in
                PlaylistDrop.movePlaylist(providers) { store.movePlaylist($0, into: PlaylistLayout.root) }
            }
        }
        .onChange(of: store.renamingPlaylistID) { _, id in
            if id != nil { isExpanded = true }
        }
    }
}

/// 펼침 상태를 직접 묶어야 접힌 폴더에 만든 항목의 이름 편집도 보인다.
struct PlaylistTreeRow: View {
    @Bindable var store: LibraryStore
    let node: PlaylistOutlineNode

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(
                get: { store.expandedPlaylistIDs.contains(node.id) },
                set: { expanded in
                    if expanded { store.expandedPlaylistIDs.insert(node.id) }
                    else { store.expandedPlaylistIDs.remove(node.id) }
                }
            )) {
                ForEach(children) { child in
                    PlaylistTreeRow(store: store, node: child)
                }
            } label: {
                PlaylistRow(store: store, node: node)
            }
            .tag(SidebarItem.playlist(node.id))
        } else {
            PlaylistRow(store: store, node: node)
                .tag(SidebarItem.playlist(node.id))
        }
    }
}

/// 새 목록·폴더 버튼(맨 위 메뉴·오른쪽 클릭 메뉴)
struct PlaylistCreateButtons: View {
    let store: LibraryStore
    let parent: String

    var body: some View {
        Button(.ui("새 재생 목록")) { store.createPlaylist(isFolder: false, in: parent) }
        Button(.ui("새 폴더")) { store.createPlaylist(isFolder: true, in: parent) }
        let tracks = store.selectedRows.filter { !$0.isStaged }
        Button(.ui("고른 곡으로 새 재생 목록 (\(tracks.count)곡)")) { store.createPlaylist(isFolder: false, in: parent, tracks: tracks) }
            .disabled(tracks.isEmpty)
    }
}

struct PlaylistRow: View {
    let store: LibraryStore
    let node: PlaylistOutlineNode
    @State private var isTargeted = false
    @State private var name = ""
    @FocusState private var isEditing: Bool

    private var title: String { node.name.isEmpty ? String(ui: "(이름 없음)") : node.name }
    private var icon: String { node.isSmart ? "gearshape" : node.isFolder ? "folder" : "music.note.list" }
    /// 실험실 '인텔리전트 재생 목록 보기'를 켰을 때 이 목록의 계산 결과(아니면 nil)
    private var smartResult: SmartPlaylistResult? { node.isSmart && store.showSmartPlaylists ? store.smartPlaylistResults[node.id] : nil }
    /// 계산하지 못한 인텔리전트 목록의 이유 한 줄
    private var smartUnsupported: String? { smartResult?.unsupportedSummary }
    private var smartHelp: String? {
        guard node.isSmart, store.showSmartPlaylists else { return nil }
        return smartUnsupported.map { String(ui: "DJCrate가 이 목록의 조건을 계산하지 못했습니다: \($0)") } ?? SmartPlaylistSource.readOnlyReason
    }

    var body: some View {
        content
            .badge(store.count(playlist: node))
            .lineLimit(1)
            .help(node.blockedReason.map { String(ui: "이 목록의 초안 일부를 쓸 수 없습니다: \($0)") } ?? smartHelp ?? title)
            .onDrag { PlaylistDragType.provider(for: node) }
            .onDrop(of: [PlaylistDragType.tracks, PlaylistDragType.playlist, .fileURL], isTargeted: $isTargeted) { providers in
                PlaylistDrop.perform(providers, on: node, store: store)
            }
            .background(isTargeted ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder private var content: some View {
        if store.renamingPlaylistID == node.id {
            TextField(text: $name, prompt: Text(verbatim: title)) { Text(.ui("재생 목록 이름")) }
                .textFieldStyle(.plain)
                .focused($isEditing)
                .onSubmit { store.renamePlaylist(node.id, to: name) }
                .onExitCommand { store.renamingPlaylistID = nil }
                .onAppear {
                    name = node.name
                    isEditing = true
                }
                .onChange(of: isEditing) { _, editing in
                    // 다른 곳을 누르면 고친 이름으로 끝낸다(Finder와 같다).
                    if !editing, store.renamingPlaylistID == node.id { store.renamePlaylist(node.id, to: name) }
                }
        } else {
            Label {
                HStack(spacing: 4) {
                    Text(verbatim: title)
                    if node.isDraft {
                        Image(systemName: DraftMark.symbol)
                            .foregroundStyle(UIColors.draft.color)
                            .accessibilityLabel(Text(verbatim: DraftMark.spoken))
                    }
                    if node.blockedReason != nil {
                        Image(systemName: WarningMark.symbol)
                            .foregroundStyle(UIColors.warning.color)
                            .accessibilityLabel(.ui("쓸 수 없는 초안"))
                    }
                    if smartUnsupported != nil {
                        Image(systemName: WarningMark.symbol)
                            .foregroundStyle(UIColors.warning.color)
                            .accessibilityLabel(.ui("계산하지 못한 조건"))
                    }
                }
            } icon: {
                Image(systemName: icon)
            }
        }
    }
}

/// 사이드바 목록 전체의 오른쪽 클릭·두 번 누르기(Return). 재생 목록이면 메뉴, 빈 곳이면 새 목록·폴더.
/// 두 번 누르기·Return은 이름 바꾸기(Finder·rekordbox와 같다). 한 번 누르기는 그대로 고르기다.
struct PlaylistSidebarMenu: ViewModifier {
    let store: LibraryStore

    func body(content: Content) -> some View {
        content.contextMenu(forSelectionType: SidebarItem.self) { items in
            if items.isEmpty {
                PlaylistCreateButtons(store: store, parent: PlaylistLayout.root)
            } else if items.count == 1, case let .playlist(id)? = items.first, let node = store.playlistIndex[id] {
                PlaylistContextMenu(store: store, node: node)
            } else if items.count == 1, case let .history(id)? = items.first {
                Button(.ui("재생 목록으로 만들기")) { store.createPlaylist(fromHistory: id) }
                    .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
            } else if items.count == 1, case let .usb(target)? = items.first, let actions = store.usbEdits {
                UsbSidebarMenu(store: store, actions: actions, target: target)
            }
        } primaryAction: { items in
            guard items.count == 1, case let .playlist(id)? = items.first, let node = store.playlistIndex[id] else { return }
            // 실험실에서 인텔리전트 목록을 보는 중이면 이름을 바꿀 수 없는 이유를 알린다(끄면 지금처럼 조용히 넘어간다).
            if node.isSmart {
                store.blockSmartPlaylistEdit(id)
                return
            }
            guard store.writeLockPolicy.allowsLibraryInteraction else { return }
            store.renamingPlaylistID = id
        }
        // ⌫: 고른 목록·폴더를 지운다(초안, ⌘Z로 되돌림)
        .onDeleteCommand {
            guard case let .playlist(id) = store.sidebar else { return }
            if store.blockSmartPlaylistEdit(id) { return }
            guard store.playlistIndex[id]?.isSmart == false,
                  store.renamingPlaylistID == nil, store.writeLockPolicy.allowsLibraryInteraction else { return }
            PlaylistPanels.delete(store: store, id: id)
        }
    }
}

/// 사이드바 재생 목록 오른쪽 클릭 메뉴
struct PlaylistContextMenu: View {
    let store: LibraryStore
    let node: PlaylistOutlineNode

    var body: some View {
        let parent = node.isFolder ? node.id : store.playlistItem(node.id)?.parentID ?? PlaylistLayout.root
        if !node.isSmart {
            PlaylistCreateButtons(store: store, parent: parent)
            Divider()
            Button(.ui("이름 바꾸기")) { store.renamingPlaylistID = node.id }
            Menu(.ui("옮기기")) {
                Button(.ui("맨 위")) { store.movePlaylist(node.id, into: PlaylistLayout.root) }
                    .disabled(store.playlistItem(node.id)?.parentID == PlaylistLayout.root)
                PlaylistFolderMenu(store: store, nodes: store.playlistTree, moving: node.id)
            }
            Button(.ui("위로 옮기기")) { move(by: -1) }.disabled(!canMove(by: -1))
            Button(.ui("아래로 옮기기")) { move(by: 1) }.disabled(!canMove(by: 1))
            Divider()
            Button(node.isFolder ? LocalizedStringResource.ui("폴더 지우기") : .ui("재생 목록 지우기"), role: .destructive) {
                PlaylistPanels.delete(store: store, id: node.id)
            }
        }
        if node.isSmart, store.showSmartPlaylists {
            // 실험실에서 보는 인텔리전트 목록은 읽기 전용이다. 이름·옮기기·지우기 대신 이유를 보인다.
            Button(SmartPlaylistSource.readOnlyReason) {}
                .disabled(true)
        }
        if node.isDraft || node.blockedReason != nil {
            Divider()
            Button(.ui("이 목록의 초안 버리기")) { store.discardPlaylistDraft(node.id) }
        }
    }

    private var siblings: [String] {
        let parent = store.playlistItem(node.id)?.parentID ?? PlaylistLayout.root
        return store.playlistProjection.layout.childIDs(of: parent)
    }

    private func canMove(by step: Int) -> Bool {
        guard let index = siblings.firstIndex(of: node.id) else { return false }
        return siblings.indices.contains(index + step)
    }

    /// 같은 부모 안에서 한 칸 올리거나 내린다(끌어 놓기로는 폴더 앞에 놓을 수 없어서 메뉴로도 둔다).
    private func move(by step: Int) {
        let siblings = siblings
        guard let index = siblings.firstIndex(of: node.id), siblings.indices.contains(index + step),
              let parent = store.playlistItem(node.id)?.parentID else { return }
        let before = step < 0 ? siblings[index - 1] : siblings.indices.contains(index + 2) ? siblings[index + 2] : nil
        store.movePlaylist(node.id, into: parent, before: before)
    }
}

/// '옮기기 ▸'의 폴더 트리(옮기는 폴더 자신과 그 아래는 뺀다)
struct PlaylistFolderMenu: View {
    let store: LibraryStore
    let nodes: [PlaylistOutlineNode]
    let moving: String

    var body: some View {
        ForEach(nodes.filter { $0.isFolder && !$0.isSmart && $0.id != moving }) { folder in
            let children = (folder.children ?? []).filter { $0.isFolder && !$0.isSmart && $0.id != moving }
            if children.isEmpty {
                Button(folder.name) { store.movePlaylist(moving, into: folder.id) }
            } else {
                Menu(folder.name) {
                    Button(.ui("이 폴더에")) { store.movePlaylist(moving, into: folder.id) }
                    Divider()
                    PlaylistFolderMenu(store: store, nodes: children, moving: moving)
                }
            }
        }
    }
}

/// 사이드바에 놓은 곡·재생 목록
@MainActor
enum PlaylistDrop {
    /// 곡을 목록에 놓으면 넣고, 재생 목록을 폴더에 놓으면 그 안(맨 끝)으로, 목록에 놓으면 그 앞으로 옮긴다.
    static func perform(_ providers: [NSItemProvider], on node: PlaylistOutlineNode, store: LibraryStore) -> Bool {
        guard store.writeLockPolicy.allowsLibraryInteraction else { return false }
        let tracks = providers.filter { $0.hasItemConformingToTypeIdentifier(PlaylistDragType.tracks.identifier) }
        if !tracks.isEmpty {
            guard store.canEditTracks(of: node.id) else {
                store.blockSmartPlaylistEdit(node.id)
                return false
            }
            loadStrings(tracks, type: PlaylistDragType.tracks) { ids in
                store.addTracks(ids.compactMap { store.rowsByID[$0] }, toPlaylist: node.id)
            }
            return true
        }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            guard store.canEditTracks(of: node.id) else {
                store.blockSmartPlaylistEdit(node.id)
                return false
            }
            loadStrings(files, type: .fileURL) { strings in
                let urls = strings.compactMap(URL.init(string:)).filter(\.isFileURL)
                Task { await store.addFiles(urls, toPlaylist: node.id) }
            }
            return true
        }
        guard !node.isSmart else {
            store.blockSmartPlaylistEdit(node.id)
            return false
        }
        return movePlaylist(providers) { id in
            if node.isFolder {
                store.movePlaylist(id, into: node.id)
            } else if let parent = store.playlistItem(node.id)?.parentID {
                store.movePlaylist(id, into: parent, before: node.id)
            }
        }
    }

    static func movePlaylist(_ providers: [NSItemProvider], _ move: @escaping @MainActor (String) -> Void) -> Bool {
        let playlists = providers.filter { $0.hasItemConformingToTypeIdentifier(PlaylistDragType.playlist.identifier) }
        guard !playlists.isEmpty else { return false }
        loadStrings(playlists, type: PlaylistDragType.playlist) { ids in ids.first.map(move) }
        return true
    }

    /// 여러 항목의 글자를 모두 읽은 뒤(순서 그대로) 메인 스레드에서 넘긴다(USB 줄에 놓은 곡도 같다).
    static func loadStrings(_ providers: [NSItemProvider], type: UTType, _ done: @escaping @MainActor ([String]) -> Void) {
        let group = DispatchGroup()
        let box = StringBox(count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                box.set(index, data.flatMap { String(data: $0, encoding: .utf8) })
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let strings = box.values.compactMap { $0 }.flatMap { $0.split(separator: "\n").map(String.init) }
            MainActor.assumeIsolated { done(strings) }
        }
    }
}

/// 끌어다 놓은 항목을 다른 스레드에서 읽는 동안 모아 둔다.
private final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?]
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: String?) { lock.lock(); storage[index] = value; lock.unlock() }
    var values: [String?] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// 재생 목록 지우기·초안 버리기. 초안 편집이라 묻지 않고 ⌘Z로 되돌린다(#212). rekordbox에는 쓸 때 한 번 확인한다.
@MainActor
enum PlaylistPanels {
    static func delete(store: LibraryStore, id: String) {
        store.deletePlaylist(id)
    }

    static func discardAll(store: LibraryStore) {
        guard !store.playlistDraft.steps.isEmpty else { return }
        store.discardPlaylistDraft()
    }
}
