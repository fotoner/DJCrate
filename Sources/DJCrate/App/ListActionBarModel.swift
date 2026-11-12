import DJCApplication
import DJCDomain
import Foundation
import Observation

/// 머리 줄 오른쪽(`ListHeaderActionsView`)의 화면 모델(#252·#340): 사이드바 항목마다 주 단추 하나 · `…` 메뉴 · 상태 표시 하나를
/// 값(`ListHeaderActions`)으로 계산하고, 단추·메뉴가 부르는 일을 맡는다. 단추 이름(고른·전체·개수)과 막힘 이유도 이 값에 있다.
/// 상태는 공유 핵심(`LibraryStore`: 사이드바·선택·목록·쓰기 잠금·파일 없음 확인)과 기능 조각(추가 목록·재생 목록·재생 기록·Music)에 있다.
/// 구성을 읽는 곳은 잎 뷰 하나라, 선택·개수가 바뀌어도 `ContentView`·`LibraryDetail`·`ListHeaderBar` 본문은 다시 계산하지 않는다(#340).
/// 사이드바 항목에 필요한 값만 읽는다: 일반 목록은 아무것도 읽지 않고, 추가 목록 조각은 추가한 곡을 볼 때만 읽는다.
/// 조립 지점(`AppComposition`)이 한 번 만든다.
/// 파일이 없는 곡 확인(#126)은 곡 행을 바꾸는 라이브러리 전체의 일이라 핵심이 한다(#254). 이 모델은 결과·진행을 읽고 다시 확인 단추만 부른다.
@MainActor
@Observable
final class ListActionBarModel {
    /// 편집을 받는 USB의 머리 줄 값
    struct UsbEditing: Equatable {
        /// 로컬에서 더 고쳐 USB 쓰기 대기에 더할 수 있는 곡 수
        var updatable: Int
        /// 막힐 반영이면(실물 USB 등) 그 이유(도움말)
        var blockReason: String?
        /// 이 USB의 쓰기 대기 수
        var draftCount: Int
    }

    /// 공유 핵심. 단추는 핵심과 기능 조각의 값을 읽어 계산한다. '폴더에서 찾기…' 단추에도 넘긴다
    @ObservationIgnored let store: LibraryStore
    private var staging: TrackStagingStore { store.staging }

    init(store: LibraryStore) {
        self.store = store
    }

    var sidebar: SidebarItem { store.sidebar }
    var libraryBusy: Bool { store.libraryBusy }
    var editsFrozen: Bool { store.editsFrozen }

    // MARK: - 추가한 곡

    /// 고른 추가한 곡. 있으면 '바로 넣기'는 이것만 넣는다
    private var selectedStaged: [TrackRow] { ReflectionTargets.add(store.selectedRows) }

    /// '바로 넣기' 대상: 고른 추가한 곡(없으면 추가 목록 전체)
    var stagedAddTargets: [TrackRow] {
        let selected = selectedStaged
        return selected.isEmpty ? staging.stagedRows : selected
    }

    var canRemoveStaged: Bool { store.selection.contains { $0.hasPrefix("djc-") } }
    var canExportStaged: Bool { !staging.staged.isEmpty }
    /// rekordbox에 들어간 것이 확인된 곡 수('가져온 곡 정리' 단추 이름에 붙는다)
    var importedStagedCount: Int { staging.staged.filter { $0.importCheck != nil && $0.importCheck?.result != .pending }.count }

    func chooseFiles() { StagingPanels.chooseFiles(store: store) }
    func removeSelectedStaged() { staging.removeStaged(store.selection) }
    func exportStagedXML() { StagingPanels.exportXML(store: store) }
    func removeImportedStaged() { staging.removeImportedStaged() }

    // MARK: - rekordbox 쓰기 대기

    /// 쓸 곡: 고른 곡(없으면 목록 전체). 보이지 않는 곡의 선택(다른 목록에서 고른 곡, 방금 쓴 곡)은 고른 것으로 치지 않는다
    var pendingTargets: [TrackRow] {
        let selected = store.selectedRows
        return selected.isEmpty ? store.displayRows : selected
    }
    var pendingPlaylistEdits: Int { store.playlists.playlistDraft.steps.count }
    /// 쓰기 대기에 오른 재생 기록(USB 기기 기록 #43, LINK 기록)
    var pendingHistories: [ArchivedHistory] { store.history.pendingHistories }
    /// 쓰기 대기 기록의 이름(rekordbox에 쓰일 이름)
    func displayName(_ history: ArchivedHistory) -> String { store.history.displayName(history) }

    func showHistory(_ id: String) { store.sidebar = .history(id) }
    /// 쓰기 대기 재생 기록을 모두 뺀다(실행 취소로 되돌린다)
    func excludePendingHistories() { store.history.setHistoriesExcluded(store.history.pendingHistories.map(\.id), excluded: true) }
    func discardPlaylistDrafts() { PlaylistPanels.discardAll(store: store) }
    func exportPendingXML(_ rows: [TrackRow]) { ReflectionPanels.export(store: store, rows: rows) }

    var restoreHelp: String {
        store.writesBlockedBySheet ? LibraryStore.writesBlockedBySheetReason
            : store.hasWriteBackup
            ? String(ui: "라이브러리 전체를 마지막 저장 전 백업으로 복원합니다.")
            : String(ui: "복원할 백업이 없습니다. rekordbox에 저장하면 저장 전 백업이 생깁니다.")
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
    var isPlaylistRecoveryBlocked: Bool { store.libraryBusy || store.isRecoveringDraft || store.writeTask != nil }
    func discardPlaylistDraft(_ id: String) { store.playlists.discardPlaylistDraft(id) }

    // MARK: - USB

    /// 편집을 받는 USB면 머리 줄 값(읽기만 하는 USB면 nil)
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

    /// 마지막 파일 확인 결과(핵심이 확인한다). 연결되지 않은 외장 디스크는 머리 줄 상태 표시가 알린다.
    var missingFiles: MissingFiles { store.missingFiles }
    var isCheckingFiles: Bool { store.isCheckingFiles }
    /// '다시 확인' 단추
    func checkMissingFiles() { store.checkMissingFiles() }

    // MARK: - 머리 줄 오른쪽 구성(#340)

    private var locks: ListHeaderActions.Locks {
        .init(busy: store.libraryBusy, sheetBlocked: store.writesBlockedBySheet, editsFrozen: store.editsFrozen)
    }

    /// 지금 사이드바 항목의 머리 줄 오른쪽 구성. 항목에 필요한 값만 읽는다
    var actions: ListHeaderActions {
        switch store.sidebar {
        case .staged:
            return .staged(selected: !selectedStaged.isEmpty, count: stagedAddTargets.count, canRemove: canRemoveStaged,
                           canExportXML: canExportStaged, importedCount: importedStagedCount, locks: locks)
        case .pending:
            // 검색·필터로 목록을 좁혔는지(보이는 곡이 그 목록의 곡보다 적다)
            return .pending(selected: !store.selectedRows.isEmpty, narrowed: store.displayRows.count < store.sortedBase.count,
                            tracks: pendingTargets.count, playlistEdits: pendingPlaylistEdits,
                            histories: pendingHistories.map { .init(id: $0.id, name: displayName($0)) },
                            unlinkedDrafts: store.unlinkedDraftUUIDs.count,
                            restore: .init(isEnabled: store.hasWriteBackup, help: restoreHelp), locks: locks)
        case let .itunesPlaylist(id):
            return .music(unavailable: unavailableMusicTracks(id))
        case let .playlist(id):
            // 실험실에서 보는 인텔리전트 목록은 읽기 전용이고 곡은 DJCrate가 조건으로 계산한 것이다(#68)
            if let result = smartPlaylistResult { return .smartPlaylist(unsupported: result.unsupportedSummary != nil) }
            let node = playlistNode(id)
            return .playlist(id: id, isDraft: node?.isDraft == true, blockedReason: node?.blockedReason,
                             hiddenStreaming: showsHiddenStreamingNote(id) ? streamingHiddenInView : nil,
                             canCompare: !isPlaylistRecoveryBlocked, locks: locks)
        case .usb(.pending):
            // 쓰기 대기 목록은 자기 머리에 단추를 둔다
            return .none
        case let .usb(target):
            let editing = usbEditing(volumeKey: target.volumeKey).map {
                (updatable: $0.updatable, blockReason: $0.blockReason, draftCount: $0.draftCount)
            }
            return .usb(volumeKey: target.volumeKey, editing: editing, playlistMismatch: hasUsbPlaylistMismatch(volumeKey: target.volumeKey))
        case .filter(.missingFile):
            return .missingFiles(volumes: missingFiles.unmountedVolumes.map { .init(name: $0.name, trackCount: $0.trackCount) },
                                 checking: isCheckingFiles, hasMissing: !missingFiles.trackIDs.isEmpty, canFindInFolder: store.snapshotURL != nil)
        case .filter(.noBPM):
            return .gridEstimate(count: displayedCount, blocked: isGridEstimateBlocked)
        default:
            return .none
        }
    }

    /// 단추·메뉴 항목이 부르는 일. 반영 입구(`reflection`)와 주 창 모델(`window`)은 뷰가 환경에서 받아 넘긴다.
    /// 쓰는 곡은 누른 순간의 대상(`stagedAddTargets`·`pendingTargets`)이고, 단추 이름이 말한 곡과 같은 계산이다
    func perform(_ action: ListHeaderActions.Action, reflection: ReflectionCoordinator?, window: LibraryWindowModel?) {
        switch action {
        case .addStaged: reflection?.startAddTracks(rows: stagedAddTargets)
        case .chooseFiles: chooseFiles()
        case .removeSelectedStaged: removeSelectedStaged()
        case .exportStagedXML: exportStagedXML()
        case .removeImportedStaged: removeImportedStaged()
        case .writePending: reflection?.startWrite(rows: pendingTargets)
        case .exportPendingXML: exportPendingXML(pendingTargets)
        case .restoreLatest: reflection?.startRestoreLatest()
        case .discardPlaylistDrafts: discardPlaylistDrafts()
        case let .showHistory(id): showHistory(id)
        case .excludePendingHistories: excludePendingHistories()
        case let .discardPlaylistDraft(id): discardPlaylistDraft(id)
        case let .comparePlaylist(id): reflection?.startPlaylistRecovery(playlist: id)
        case let .refreshUsbLocalChanges(key): startRefreshUsbLocalChanges(volumeKey: key)
        case let .showUsbPending(key): showUsbPending(volumeKey: key)
        case .recheckFiles: checkMissingFiles()
        // 폴더를 고르고 시트를 띄우는 단추 뷰(`RelocateEntryButton`)가 직접 한다
        case .findInFolder: break
        case .estimateGrids: estimateGridsForDisplayedRows()
        case .showStreaming: store.showHiddenStreaming()
        case .openUnlinkedDrafts: window?.openUnlinkedDrafts()
        }
    }
}
