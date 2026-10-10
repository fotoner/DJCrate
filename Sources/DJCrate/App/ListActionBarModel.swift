import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 목록 아래 작업 막대(`ListActionBar`)의 화면 모델(#252): 사이드바 항목마다 보일 단추의 대상·막힘 이유와 단추가 부르는 일,
/// 파일이 없는 곡 확인(#126)의 진행과 결과. 상태는 공유 핵심(`LibraryStore`: 사이드바·선택·목록·쓰기 잠금)과 기능 조각
/// (추가 목록·재생 목록·재생 기록·Music)에 있다. 본문이 읽는 관찰 속성은 옛 막대와 같다(다시 계산 횟수가 같다).
/// 조립 지점(`AppComposition`)이 한 번 만든다. 핵심이 읽은 뒤·디스크를 연결하거나 뺄 때 파일 확인을 이 모델에 맡긴다(`onCheckMissingFiles`, 핵심 하나에 모델 하나).
@MainActor
@Observable
final class ListActionBarModel {
    /// 편집을 받는 USB의 막대 값
    struct UsbEditing: Equatable {
        /// 로컬에서 더 고쳐 USB 쓰기 대기에 더할 수 있는 곡 수
        var updatable: Int
        /// 막힐 반영이면(실물 USB 등) 그 이유(도움말)
        var blockReason: String?
        /// 이 USB의 쓰기 대기 수
        var draftCount: Int
    }

    /// 공유 핵심. 막대의 단추는 핵심과 기능 조각의 값을 읽어 계산한다. '폴더에서 찾기…' 단추에도 넘긴다
    @ObservationIgnored let store: LibraryStore
    private var staging: TrackStagingStore { store.staging }

    /// 마지막 파일 확인 결과(#126). 연결되지 않은 외장 디스크는 막대에 알린다.
    private(set) var missingFiles = MissingFiles()
    private(set) var isCheckingFiles = false
    /// 마지막으로 시작한 파일 확인. 시험은 이것을 기다린다
    @ObservationIgnored private(set) var missingFileTask: Task<Void, Never>?

    init(store: LibraryStore) {
        self.store = store
        store.onCheckMissingFiles = { [weak self] in self?.checkMissingFiles() }
    }

    var sidebar: SidebarItem { store.sidebar }
    var isWritingRekordbox: Bool { store.isWritingRekordbox }

    // MARK: - 추가한 곡

    /// '바로 넣기' 대상: 고른 추가한 곡(없으면 추가 목록 전체)
    var stagedAddTargets: [TrackRow] {
        let selectedStaged = ReflectionTargets.add(store.selectedRows)
        return selectedStaged.isEmpty ? staging.stagedRows : selectedStaged
    }

    func isAddBlocked(_ targets: [TrackRow]) -> Bool { targets.isEmpty || store.isWritingRekordbox || store.writesBlockedBySheet }

    var addHelp: String {
        store.writesBlockedBySheet ? LibraryStore.writesBlockedBySheetReason
            : String(ui: "고른 곡(없으면 추가 목록 전체)을 확인한 뒤 rekordbox 컬렉션에 넣습니다.")
    }

    var canRemoveStaged: Bool { store.selection.contains { $0.hasPrefix("djc-") } }
    var canExportStaged: Bool { !staging.staged.isEmpty }
    /// rekordbox에 들어간 것이 확인된 곡이 있는지('가져온 곡 정리')
    var hasImportedStaged: Bool { staging.staged.contains(where: { $0.importCheck != nil && $0.importCheck?.result != .pending }) }

    func chooseFiles() { StagingPanels.chooseFiles(store: store) }
    func removeSelectedStaged() { staging.removeStaged(store.selection) }
    func exportStagedXML() { StagingPanels.exportXML(store: store) }
    func removeImportedStaged() { staging.removeImportedStaged() }

    // MARK: - rekordbox 쓰기 대기

    /// 쓸 곡: 고른 곡(없으면 목록 전체)
    var pendingTargets: [TrackRow] { store.selection.isEmpty ? store.displayRows : store.selectedRows }
    var pendingPlaylistEdits: Int { store.playlists.playlistDraft.steps.count }
    /// 쓰기 대기에 오른 USB 재생 기록(#43)
    var pendingHistories: [ArchivedHistory] { store.history.pendingHistories }

    func isWriteBlocked(targets: [TrackRow], playlistEdits: Int, histories: Int) -> Bool {
        (targets.isEmpty && playlistEdits == 0 && histories == 0) || store.isWritingRekordbox || store.writesBlockedBySheet
    }

    var writeHelp: String {
        store.writesBlockedBySheet ? LibraryStore.writesBlockedBySheetReason
            : String(ui: "고른 곡(없으면 목록 전체)과 재생 목록 초안·USB 재생 기록을 rekordbox에 씁니다.")
    }

    func showHistory(_ id: String) { store.sidebar = .history(id) }
    /// 쓰기 대기 재생 기록을 모두 뺀다(실행 취소로 되돌린다)
    func excludePendingHistories() { store.history.setHistoriesExcluded(store.history.pendingHistories.map(\.id), excluded: true) }
    func discardPlaylistDrafts() { PlaylistPanels.discardAll(store: store) }
    func exportPendingXML(_ rows: [TrackRow]) { ReflectionPanels.export(store: store, rows: rows) }

    var isRestoreBlocked: Bool { store.isWritingRekordbox || !store.hasWriteBackup || store.writesBlockedBySheet }

    var restoreHelp: String {
        store.writesBlockedBySheet ? LibraryStore.writesBlockedBySheetReason
            : store.hasWriteBackup
            ? String(ui: "라이브러리 전체를 마지막 쓰기 전 백업으로 복원합니다.")
            : String(ui: "복원할 백업이 없습니다. rekordbox에 쓰면 쓰기 전 백업이 생깁니다.")
    }

    // MARK: - Music·재생 목록

    /// Music 목록에서 rekordbox 곡과 잇지 못한 곡 수(0이면 알리지 않는다)
    func unavailableMusicTracks(_ id: String) -> Int { store.music.library.index[id]?.unavailableTrackCount ?? 0 }

    /// 실험실에서 보는 인텔리전트 목록의 계산 결과(#68)
    var smartPlaylistResult: SmartPlaylistResult? { store.playlists.selectedSmartPlaylistResult }
    var streamingHiddenInView: Int { store.streamingHiddenInView }

    /// 숨긴 스트리밍 곡 때문에 끌어 옮길 수 없는 목록인지(`canReorderDisplayedTracks`).
    /// 줄이 하나도 안 남았으면 목록 가운데 안내(`EmptyLibraryOverlay`)가 같은 말을 한다.
    func showsHiddenStreamingNote(_ id: String) -> Bool {
        store.streamingHiddenInView > 0 && store.playlists.editablePlaylistID == id && !store.displayRows.isEmpty
    }

    func playlistNode(_ id: String) -> PlaylistOutlineNode? { store.playlists.playlistIndex[id] }
    var isPlaylistRecoveryBlocked: Bool { store.isWritingRekordbox || store.isRecoveringDraft || store.writeTask != nil }
    func discardPlaylistDraft(_ id: String) { store.playlists.discardPlaylistDraft(id) }

    // MARK: - USB

    /// 편집을 받는 USB면 막대 값(읽기만 하는 USB면 nil)
    func usbEditing(volumeKey key: String) -> UsbEditing? {
        guard let actions = store.usbEdits, actions.usb.acceptsEdits(key) else { return nil }
        let updatable = actions.updatableTracks(volumeKey: key).count
        // 막힐 반영이면(실물 USB 등) 누를 수 없게 하고 이유를 도움말로
        let reason = updatable == 0 ? nil : actions.refreshBlockReason(volumeKey: key)
        return UsbEditing(updatable: updatable, blockReason: reason, draftCount: actions.usb.draftCounts[key] ?? 0)
    }

    func hasUsbPlaylistMismatch(volumeKey key: String) -> Bool {
        store.usb?.infos[key].map({ $0.consistency.playlistMismatches > 0 }) == true
    }

    /// '로컬 변경을 USB에 반영'. USB 초안 편집 흐름의 입구로 시작한다(기다리지 않는다)
    func startRefreshUsbLocalChanges(volumeKey key: String) { store.usbEdits?.start(.refreshLocalChanges(volumeKey: key)) }
    func showUsbPending(volumeKey key: String) { store.sidebar = .usb(.pending(volumeKey: key)) }

    // MARK: - BPM 없는 곡

    var displayedCount: Int { store.displayRows.count }
    var isGridEstimateBlocked: Bool { store.displayRows.isEmpty || staging.gridJob != nil }
    func estimateGridsForDisplayedRows() { staging.estimateGridsForDisplayedRows() }

    // MARK: - 파일 없음(#126)

    /// 음원 파일이 있는지 뒤에서 확인해 행·'파일 없음' 개수에 반영한다. 읽은 뒤·디스크를 연결하거나 뺄 때(핵심 `checkMissingFiles`)·다시 확인 단추에서 부른다.
    /// 큰 라이브러리의 확인(곡마다 파일 시스템 조회)이 메인 스레드를 막지 않게 한다.
    func checkMissingFiles() {
        missingFileTask?.cancel()
        let generation = store.reads.generation
        let tracks = store.rows.map(\.track), useCases = store.useCases
        isCheckingFiles = true
        missingFileTask = Task { [weak self] in
            let result = await useCases.missingFiles(tracks)
            guard let self, !Task.isCancelled else { return }
            // 그사이 다시 읽기 시작했으면 버린다(새로 읽은 뒤 다시 확인한다).
            guard store.reads.isCurrent(generation) else {
                isCheckingFiles = false
                return
            }
            isCheckingFiles = false
            missingFiles = result
            store.applyMissingFiles(result)
        }
    }
}
