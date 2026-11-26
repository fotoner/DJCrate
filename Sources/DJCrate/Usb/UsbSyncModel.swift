import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 동기화 창 오른쪽에 보일 USB 목록
enum UsbSyncTargetDisplay: CaseIterable, Hashable, Sendable {
    case currentUsb, afterSync

    var title: String {
        switch self {
        case .currentUsb: String(ui: "현재 USB")
        case .afterSync: String(ui: "동기화 후")
        }
    }
}

extension UsbSyncPreviewMark {
    /// 동기화 후 미리 보기의 칸 표시. 연결 없는 목록(흐린 줄)은 글 대신 툴팁(`hint`)으로 뜻을 말한다
    var note: String? {
        switch self {
        case .created: String(ui: "새로 만듦")
        case .moved: String(ui: "옮김")
        case .deleted: String(ui: "지움")
        case .unlinked: nil
        }
    }

    /// 흐린 줄·지울 줄에 마우스를 올리면 나오는 뜻. 새로 만듦·옮김은 줄 옆 글이 뜻이라 없다
    var hint: String? {
        switch self {
        case .unlinked: String(ui: "동기화에 이어지지 않아 USB에 그대로 남습니다")
        case .deleted: String(ui: "동기화하면 USB에서 지웁니다")
        case .created, .moved: nil
        }
    }
}

/// USB 동기화 목록 줄마다 붙는 표시: 흐림, 줄 옆 글(새로 만듦·옮김·지움·하위 N건 변경), 흐린 줄의 뜻(툴팁)
struct UsbSyncTargetRowStyle {
    let display: UsbSyncTargetDisplay
    let dimmed: Set<String>
    let marks: [String: UsbSyncPreviewMark]

    func isDimmed(_ node: PlaylistOutlineNode) -> Bool { dimmed.contains(node.id) }
    func note(of node: PlaylistOutlineNode) -> String? { UsbSyncModel.note(of: node, marks: marks) }
    func hint(of node: PlaylistOutlineNode) -> String? {
        UsbSyncModel.hint(display: display, isDimmed: isDimmed(node), mark: marks[node.id])
    }
}

/// USB 동기화 창의 화면 모델: 동기화 유스케이스(`UsbSync`)에 라이브러리 화면·USB 화면의 지금 상태와 쓰기 흐름·확인 창을 포트로 붙여 부르고,
/// 유스케이스가 내보낸 흐름 상태(`UsbSyncState`)와 알림을 관찰 상태·오류 칸·안내 칸으로 옮긴다. 표시 트리·표시 고르기·안내 문구 잇기도 여기서 한다.
/// 순서·판정은 유스케이스에 있다(판정 값은 `state`의 같은 이름으로 넘긴다).
@MainActor @Observable @dynamicMemberLookup
final class UsbSyncModel {
    @ObservationIgnored let session: UsbSync
    /// 유스케이스가 마지막으로 내보낸 흐름 상태
    private(set) var state: UsbSyncState
    var targetDisplay = UsbSyncTargetDisplay.currentUsb
    /// 오류 칸(막힘·실패 이유)
    private(set) var error: String?
    /// 안내 칸(결과)
    private(set) var message: String?

    init(volumeKey: String, library: UsbLibrary? = nil) {
        let session = UsbSync(volumeKey: volumeKey, library: library)
        self.session = session
        state = session.state
        session.output = UsbSyncOutput(changed: { [weak self] in self?.apply($0) }, notice: { [weak self] in self?.show($0) })
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<UsbSyncState, Value>) -> Value { state[keyPath: keyPath] }

    var selection: ITunesSyncSelection {
        get { state.selection }
        set { session.selection = newValue }
    }
    var syncPlaylists: Bool {
        get { state.syncPlaylists }
        set { session.syncPlaylists = newValue }
    }

    private func apply(_ new: UsbSyncState) {
        state = new
        // 동기화가 꺼지면 동기화 후 목록은 보일 것이 없다
        if !new.syncPlaylists, targetDisplay != .currentUsb { targetDisplay = .currentUsb }
    }

    /// 유스케이스의 알림을 오류·안내 칸에 놓는다
    func show(_ notice: UsbSyncNotice) {
        switch notice {
        case let .problem(text): error = text
        case let .info(text): message = text
        case .clearProblem: error = nil
        case .clearInfo: message = nil
        }
    }

    /// 닫기 결과를 창에 보이고 창을 닫을지 돌려준다. 다음 닫기까지 남기면 보이던 이유 뒤에 그 안내를 붙인다
    func finishClose(_ result: UsbSyncCloseResult) -> Bool {
        switch result {
        case .close: return true
        case .stay: return false
        case .stayUntilNextClose:
            let hint = String(ui: "한 번 더 닫으면 USB에 쓰지 않고 닫습니다.")
            if let error { self.error = error + "\n" + hint } else { message = (message.map { $0 + "\n" } ?? "") + hint }
            return false
        }
    }

    static var unsyncedClosePrompt: ReflectionPrompt { UsbSync.unsyncedClosePrompt }
    static var cueGridImportPrompt: ReflectionPrompt { UsbSync.cueGridImportPrompt }

    // MARK: - 보이는 것

    var tree: [PlaylistOutlineNode] { PlaylistOutlineNode.tree(state.source, blocked: state.sourceBlockReasons) }
    var rekordboxTree: [PlaylistOutlineNode] { PlaylistOutlineNode.tree(state.rekordboxSource) }
    var iTunesTree: [PlaylistOutlineNode] { PlaylistOutlineNode.tree(state.iTunesSource, blocked: state.sourceBlockReasons) }
    /// 동기화 후 트리: 새로 만들 목록과 옮길 목록, 지울 목록(원래 자리에 `지움` 표시)이 한 트리에 있다
    var previewTree: [PlaylistOutlineNode] {
        state.afterSyncPlan.map { PlaylistOutlineNode.tree($0.previewLayout) } ?? PlaylistOutlineNode.tree(state.selectedLayout)
    }
    /// 흐리게 보일 USB 목록: 현재 USB는 선택에 잇지 않은 목록, 동기화 후는 연결 없이 남는 목록과 지울 목록
    var dimmedTargetIDs: Set<String> {
        switch targetDisplay {
        case .currentUsb: state.unlinkedUsbIDs
        case .afterSync: Set((state.afterSyncPlan?.marks ?? [:]).filter { $0.value == .unlinked || $0.value == .deleted }.keys)
        }
    }
    /// 동기화 후 미리 보기의 칸 표시(새로 만듦·옮김·지움·연결 없음). 현재 USB 보기에서는 비어 있다
    var targetMarks: [String: UsbSyncPreviewMark] {
        targetDisplay == .afterSync ? state.afterSyncPlan?.marks ?? [:] : [:]
    }

    // MARK: - 줄 옆 표시와 툴팁

    /// 줄 옆에 붙일 글: 자기 표시(새로 만듦·옮김·지움)와, 폴더 줄이면 안쪽의 바뀌는 목록 수(접힌 폴더 안은 보이지 않아서 펼침과 상관없이 붙는다).
    /// 지울 폴더는 안쪽이 모두 지움이라 건수를 더하지 않는다. 새로 만든 폴더는 안쪽의 새 목록은 세지 않고, 옮겨 들어온 목록처럼 다른 변경만 센다.
    /// 연결 없는 목록은 바뀌지 않으므로 세지 않는다.
    nonisolated static func note(of node: PlaylistOutlineNode, marks: [String: UsbSyncPreviewMark]) -> String? {
        let own = marks[node.id]
        func counts(_ mark: UsbSyncPreviewMark) -> Bool { mark != .unlinked && !(own == .created && mark == .created) }
        func changes(_ node: PlaylistOutlineNode) -> Int {
            (node.children ?? []).reduce(0) { total, child in
                total + (marks[child.id].map { counts($0) ? 1 : 0 } ?? 0) + changes(child)
            }
        }
        let inner = node.isFolder && own != .deleted ? changes(node) : 0
        let rollup = inner > 0 ? String(ui: "하위 \(inner)건 변경") : nil
        let parts = [own?.note, rollup].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 현재 USB 보기에서 흐린 줄의 뜻
    nonisolated static var currentUsbDimmedHint: String { String(ui: "선택한 원본에 이어지지 않은 목록입니다") }
    /// 흐린 줄에 마우스를 올리면 나오는 뜻. 현재 USB 보기는 흐린 줄 모두 같은 뜻이고, 동기화 후 보기는 표시가 뜻을 정한다
    nonisolated static func hint(display: UsbSyncTargetDisplay, isDimmed: Bool, mark: UsbSyncPreviewMark?) -> String? {
        switch display {
        case .currentUsb: isDimmed ? currentUsbDimmedHint : nil
        case .afterSync: mark?.hint
        }
    }
    /// USB 동기화 목록의 줄마다 붙는 표시를 한 번에 계산해 둔다(줄마다 동기화 계획을 다시 만들지 않게 본문이 한 번 부른다)
    var targetRowStyle: UsbSyncTargetRowStyle {
        UsbSyncTargetRowStyle(display: targetDisplay, dimmed: dimmedTargetIDs, marks: targetMarks)
    }

    /// 동기화가 꺼져 선택 목록·표시 고르기를 쓸 수 없을 때 마우스를 올리면 나오는 이유(원인과 할 일)
    nonisolated static var selectionLockedHint: String {
        String(ui: "동기화가 꺼져 있어 ‘장치와 플레이리스트 동기화’를 켜야 쓸 수 있습니다")
    }
    /// 선택 목록이 잠긴 이유. 로딩·쓰기 중처럼 잠깐 막힌 때는 없다
    var selectionLockedReason: String? { state.canEditSelection ? nil : Self.selectionLockedHint }
    var usbTree: [PlaylistOutlineNode] { PlaylistOutlineNode.tree(state.usbLayout) }
    var usbPlaylistCount: Int { state.usbLayout.outline.filter { !$0.isFolder }.count }
    var targetTree: [PlaylistOutlineNode] { targetDisplay == .currentUsb ? usbTree : previewTree }
    var targetPlaylistCount: Int { targetDisplay == .currentUsb ? usbPlaylistCount : state.playlistCount }
    var targetEmptyMessage: String {
        switch targetDisplay {
        case .currentUsb:
            state.library != nil || state.emptyVolume
                ? String(ui: "USB에 재생 목록이 없습니다")
                : String(ui: "USB 재생 목록을 아직 읽지 못했습니다. 새로고침하세요")
        case .afterSync:
            String(ui: "동기화할 목록을 선택하세요")
        }
    }

    // MARK: - 체크

    func selectAll() { session.selectAll() }
    func clearSelection() { session.clearSelection() }
    func selectAllRekordbox() { session.selectAllRekordbox() }
    func clearRekordboxSelection() { session.clearRekordboxSelection() }
    func selectAllITunes() { session.selectAllITunes() }
    func clearITunesSelection() { session.clearITunesSelection() }
    func toggle(_ id: String) { session.toggle(id) }
    func discardUnsyncedSelection() { session.discardUnsyncedSelection() }
    func beginClosing() -> Bool { session.beginClosing() }
    func endClosing() { session.endClosing() }

    // MARK: - 의도

    func load(store: LibraryStore, usb: UsbStore) async { await session.load(ports(store: store, usb: usb)) }
    func refresh(store: LibraryStore, usb: UsbStore) async { await session.refresh(ports(store: store, usb: usb)) }
    func sync(store: LibraryStore, usb: UsbStore) async -> Bool { await session.sync(ports(store: store, usb: usb)) }
    func close(store: LibraryStore, usb: UsbStore) async -> Bool { finishClose(await session.close(ports(store: store, usb: usb))) }
    func importCueGrid(store: LibraryStore, usb: UsbStore) async { await session.importCueGrid(ports(store: store, usb: usb)) }

    // MARK: - 단추(뷰는 작업을 시작하지 않고 이 의도를 부른다)

    func refreshTapped(store: LibraryStore, usb: UsbStore) { Task { await refresh(store: store, usb: usb) } }
    /// 쓰고 다시 읽었으면 창을 닫는다
    func syncTapped(store: LibraryStore, usb: UsbStore, dismiss: @escaping @MainActor () -> Void) {
        Task { if await sync(store: store, usb: usb) { dismiss() } }
    }
    /// 닫아도 되면 창을 닫는다
    func closeTapped(store: LibraryStore, usb: UsbStore, dismiss: @escaping @MainActor () -> Void) {
        Task { if await close(store: store, usb: usb) { dismiss() } }
    }
    func importTapped(store: LibraryStore, usb: UsbStore) { Task { await importCueGrid(store: store, usb: usb) } }

    /// SYNC 전에 보이는 알림: USB에 넣지 못할 곡 수(이유별)
    func skippedSummary(store: LibraryStore) -> String? {
        let blocks = session.skippedTracks(Self.localSkip(store))
        return blocks.isEmpty ? nil : Self.skippedSummary(blocks)
    }

    /// "USB에 넣지 못할 곡 N개" + 이유별 수(처음 나온 순서). 같은 곡은 한 번 센다
    nonisolated static func skippedSummary(_ blocks: [UsbBlock]) -> String {
        var order: [String] = [], targets: [String: Set<UsbBlock.Scope>] = [:]
        for block in blocks {
            if targets[block.message] == nil { order.append(block.message) }
            targets[block.message, default: []].insert(block.scope)
        }
        let count = Set(blocks.map(\.scope)).count
        return ([String(ui: "USB에 넣지 못할 곡 \(count)개:")] + order.map { "• \($0) (\(targets[$0]?.count ?? 0))" })
            .joined(separator: "\n")
    }

    // MARK: - 포트

    /// 앱이 아는 로컬 곡 상태로 USB에 넣을 수 없는 까닭(음원 없음·분석 파일 없음은 USB 쓰기 계획이 곡마다 알린다)
    private static func localSkip(_ store: LibraryStore) -> (String) -> UsbSyncSource.LocalSkip? {
        { id in
            guard let row = store.rowsByID[id] else { return .missing }
            if row.isStaged { return .staged }
            if row.isUsb { return .usb }
            return row.track.isStreaming ? .streaming : nil
        }
    }

    /// 라이브러리 화면·USB 화면의 지금 상태와 쓰기 흐름·확인 창. 포트는 부를 때마다 지금 값을 읽는다
    private func ports(store: LibraryStore, usb: UsbStore) -> UsbSyncPorts {
        let key = session.volumeKey
        let actions = store.usbEdits, coordinator = store.usbCoordinator
        let prompter = actions?.prompter ?? AlertPrompter()
        let skip = Self.localSkip(store)
        return UsbSyncPorts(
            library: {
                UsbSyncLibraryState(snapshot: store.snapshotURL, revision: store.previewRevision, readEpoch: store.snapshotReadEpoch,
                                    provenance: store.snapshotForUsbSync, share: store.shareRoot, isLoading: store.isLoading,
                                    isWriting: store.libraryBusy, allowsInteraction: !store.libraryBusy)
            },
            sources: { UsbSyncSource.make(rekordbox: store.playlists.rekordboxPlaylists, iTunes: store.music.library) },
            leaseSnapshot: { await store.leaseUsbSyncSnapshot() },
            localSkip: { skip($0) },
            volume: {
                UsbSyncVolumeState(volume: usb.volume(key), library: usb.libraries[key], isEmptyExportable: usb.shapes[key] == .emptyExportable,
                                   isWriting: usb.activeWrite != nil, isEjecting: usb.ejecting.contains(key), draftEdits: usb.draftEdits[key] ?? [])
            },
            refreshUsb: { await usb.refresh() },
            service: usb.writeService,
            files: usb.syncFiles,
            localKeys: usb.localKeys,
            preferences: usb.syncSelectionDirectory.flatMap { usb.syncFiles?.preferences($0) },
            confirmation: prompter.confirmation,
            drafts: actions.map { actions in
                UsbSyncDrafts(blockReason: { actions.blockReason($0, volumeKey: key) },
                              append: { await actions.append($0, to: key, detail: $1) })
            },
            writer: coordinator.map { coordinator in
                UsbSyncWriter(export: { await coordinator.export($0) }, writeSyncDraft: { await coordinator.writeSyncDraft($0, edits: $1) },
                              lastNoticeDetail: { store.toast?.detail })
            },
            importCueGrid: { await store.importUsbCueGrid(volumeKey: key) },
            newPlaylistKey: { "sync-" + UUID().uuidString.lowercased() },
            log: { AppErrorMessage.log($0) })
    }
}
