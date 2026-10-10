import DJCApplication
import DJCDomain
import Foundation

/// 라이브러리 읽기: 스냅샷 사본 뜨기 → DB·초안 읽기(메인 밖, 유스케이스 `LoadLibrary`) → 결과를 한 번에 적용, 뒤따른 Music 최신화.
/// 읽기 순서(처음 열기·바뀜 확인·사본 뜨기 요청 합치기·읽기 순번·Music 최신화 이음)는 유스케이스 `LibraryReadFlow`가, 어떤 사본을 읽을지와
/// 읽기 순서(초안 저장 끝내기·손상 파일 옮기기 → 사본 지문 → 읽기), 읽은 뒤 초안 맞추기, Music 결과 채택은 `LoadLibrary`가 정한다.
/// 여기서는 흐름이 보는 화면(`readScreen`)과, 돌려받은 값을 화면 상태에 적용하는 일만 맡는다.
extension LibraryStore {
    /// 스냅샷을 뜨지 않은 이유(`LibraryLocation.allowsSnapshot`이 거짓일 때)
    static var snapshotRefusedMessage: String { ReflectionSession.snapshotRefusedMessage }

    /// 명시한 사본(`--db PATH`·`DJC_DB`)이 있으면 그 사본을, 없으면 최신 스냅샷을 연다.
    /// - Parameter snapshotDirectory: 최신 스냅샷을 찾을 폴더(주지 않으면 위치 값의 스냅샷 폴더)
    /// - Parameter captureITunes: Music 조회(주지 않으면 유스케이스의 Music 포트). 시험이 바꿔 넣는다
    func loadInitial(snapshotDirectory: URL? = nil, captureITunes: (@Sendable () -> ITunesLibrarySnapshot)? = nil) async {
        await readFlow.loadInitial(snapshotDirectory: snapshotDirectory, capture: captureITunes)
    }

    /// 창으로 돌아올 때: 지금 읽은 스냅샷 뒤에 rekordbox가 라이브러리를 바꿨으면 뒤에서 조용히 새로 읽는다.
    func refreshIfRekordboxChanged() async {
        await readFlow.refreshIfChanged()
    }

    /// 명시적 동기화만 비충돌 태그 기준을 맞춘다. 사본 모드에서는 지정한 DB를 다시 읽는다.
    func synchronizeLibrary() async {
        guard canSynchronizeLibrary else { return }
        await whileSynchronizingLibrary {
            useCases.watch.flush()
            retryFailedTagSaves()
            await readFlow.rereadSynchronizingDrafts()
        }
    }

    /// - Parameter quiet: 화면을 로딩으로 바꾸지 않고 뒤에서 다시 읽는다(rekordbox에 쓴 뒤 등).
    /// - Parameter refreshITunes: 쓰기 뒤에는 기존 목록을 재사용해 Music 응답을 기다리지 않는다.
    /// - Parameter snapshotDirectory: 사본을 뜨는 폴더(주지 않으면 위치 값의 스냅샷 폴더)
    /// - Parameter snapshotCopy: 사본 뜨기(주지 않으면 유스케이스의 사본 뜨기)
    func takeSnapshot(force: Bool = false, quiet: Bool = false, refreshITunes: Bool = true, synchronizingDrafts: Bool = false,
                      snapshotDirectory: URL? = nil,
                      snapshotCopy: (@Sendable (Bool) throws -> URL)? = nil,
                      captureITunes: (@Sendable () -> ITunesLibrarySnapshot)? = nil) async {
        await readFlow.takeSnapshot(force: force, quiet: quiet, refreshMusic: refreshITunes, synchronizingDrafts: synchronizingDrafts,
                                    snapshotDirectory: snapshotDirectory, copy: snapshotCopy, capture: captureITunes)
    }

    func load(snapshot: URL, quiet: Bool = false, refreshITunes: Bool = false, synchronizingDrafts: Bool = false,
              previousITunesSnapshot: LoadedLibrary.ITunesFallback? = nil,
              captureITunes: (@Sendable () -> ITunesLibrarySnapshot)? = nil) async {
        await readFlow.load(snapshot: snapshot, quiet: quiet, refreshMusic: refreshITunes, synchronizingDrafts: synchronizingDrafts,
                            previousMusic: previousITunesSnapshot, capture: captureITunes)
    }

    // MARK: - 읽기 흐름이 보는 화면

    /// 읽기 흐름(`readFlow`)이 보는 화면. 흐름이 저장소를 붙들지 않게 약하게 잇는다
    var readScreen: LibraryReadScreen {
        LibraryReadScreen(state: { [weak self] in self?.readState ?? LibraryReadState() },
                          apply: { [weak self] in self?.applyRead($0) },
                          beginRead: { [weak self] in self?.beginRead() ?? LibraryReadStart(commentPreset: .none) { _ in } })
    }

    private var readState: LibraryReadState {
        let readPhase: LibraryReadPhase = switch phase {
        case .idle: .idle
        case let .loading(message): .loading(message)
        case .loaded: .loaded
        case let .failed(message): .failed(message)
        }
        return LibraryReadState(phase: readPhase, snapshot: snapshotURL, revision: previewRevision, hasRows: !rows.isEmpty,
                                hasError: lastError != nil, isWriting: isWritingRekordbox, music: music.snapshot,
                                musicStatus: music.library.status)
    }

    private func applyRead(_ change: LibraryReadChange) {
        switch change {
        case let .phase(phase):
            switch phase {
            case .idle: self.phase = .idle
            case let .loading(message): self.phase = .loading(message)
            case .loaded: self.phase = .loaded
            case let .failed(message): self.phase = .failed(message)
            }
        case let .readSequence(sequence):
            setReads(sequence)
        case let .error(message):
            reportLibraryError(message)
        case let .musicStatus(status):
            music.library.status = status
        case let .music(result):
            music.snapshot = result
            music.library = SyncedITunesLibrary(snapshot: result, tracks: rows.map(\.track))
            if case let .itunesPlaylist(id) = sidebar, music.library.index[id] == nil { sidebar = .filter(.all) }
            refreshBase()
            pruneMissingSelection()
        case let .damagedDrafts(moved):
            reportDamagedDrafts(moved)
        case let .readFailed(failure, error):
            AppErrorMessage.log(error)
            reportReadFailure(failure)
        }
    }

    /// 읽기를 시작한다: 읽는 동안 사용자가 고친 입력을 가려낼 값(태그 편집 순번·그림 초안 변경 수·설정)을 붙든다
    private func beginRead() -> LibraryReadStart {
        let initialTagRevision = tagRevision
        previewWarmTask?.cancel()
        let started = ContinuousClock.now
        let preset = commentPreset
        let artworkChanges = artworkChangeCount
        return LibraryReadStart(commentPreset: preset) { [self] read in
            adoptRead(read, initialTagRevision: initialTagRevision, artworkChanges: artworkChanges, preset: preset, started: started)
        }
    }

    /// 읽은 결과를 화면 상태에 한 번에 넣는다
    private func adoptRead(_ read: LibraryReadResult, initialTagRevision: Int, artworkChanges: Int, preset: CommentPreset,
                           started: ContinuousClock.Instant) {
        let opened = read.opened, loaded = read.opened.loaded
        let snapshot = read.snapshot, generation = read.generation, synchronizingDrafts = read.synchronizingDrafts
        undoManager?.removeAllActions(withTarget: self)
        applyLoadedRows(from: loaded)
        let previousTags = tagDrafts, previousPlaylist = playlists.playlistDraft
        // 읽는 동안 사용자가 편집했거나 저장에 실패한 입력은 디스크의 오래된 값으로 덮지 않는다. 동기화면 충돌하지 않는 초안의 base를
        // 새 rekordbox 값으로 옮겨 저장한다(유스케이스). 연결 안 된 초안은 쓰기 대기 목록에서 따로 다룬다(#175).
        let reconciled = useCases.load.reconcileDrafts(loaded, memoryTags: tagDrafts, editedDuringRead: tagRevision != initialTagRevision,
                                                       failedTags: failedTagSaves(), synchronizing: synchronizingDrafts,
                                                       artworkChanged: artworkChanges != artworkChangeCount)
        let conflicts = reconciled.tags.conflicts
        tagDrafts = reconciled.tags.tags
        rememberTagSaves(reconciled.tags.rebased)
        tagRevision += 1
        setDraftMarks(cue: loaded.cueDraftUUIDs, grid: loaded.gridDraftUUIDs, gain: loaded.gainDraftUUIDs)
        draftCueCounts = loaded.draftCueCounts
        draftPreviewCues = loaded.draftPreviewCues
        // 실패한 저장의 입력이 디스크보다 최신이므로 다시 읽어도 복구 진입점을 남긴다.
        applyUnsavedDraftIndicators(reconciled.unsaved)
        // 읽는 동안 그림 초안을 고쳤으면(저장은 바로 끝난다) 유스케이스가 읽은 값 대신 지금 디스크를 준다.
        artworkDrafts = reconciled.artworkDrafts
        artworkFileRows = loaded.artworkFiles
        trackColors = loaded.colors.isEmpty ? TrackColor.rekordboxDefaults : loaded.colors
        recountEdited()
        playlists.rekordboxPlaylists = loaded.playlists
        playlists.smartPlaylistSources = loaded.smartPlaylists
        // 저장하지 못한 재생 목록 초안은 디스크의 옛 초안으로 덮지 않는다(#174).
        if !playlists.playlistDraftUnsaved { playlists.playlistDraft = loaded.playlistDraft }
        music.library = loaded.iTunesLibrary
        music.snapshot = loaded.iTunesSnapshot
        if case let .itunesPlaylist(id) = sidebar, music.library.index[id] == nil { sidebar = .filter(.all) }
        mergeDrafts = reconciled.mergeDrafts
        playlists.refreshPlaylists(refreshList: false)
        applyMovedDrafts(opened.moved, previousTags: previousTags, previousPlaylist: previousPlaylist, reporting: false)
        playlists.restoreAwaitingPlaylistEdits()
        history.setHistories(loaded.histories, localKeys: opened.localKeys)
        adoptSnapshot(snapshot, usb: opened.usbSnapshot, generation: generation)
        // 스냅샷을 채택한 뒤에야 쓰기 대기를 고른다(쓴 기록이 rekordbox에 있는지 그 전에는 모른다). 처음 한 번 가장 최근 연·월을 펼친다
        history.refreshHistoryTree()
        history.seedHistoryFolders()
        loadStaged()
        // 기다리는 동안 설정이 바뀌었으면 최신 프리셋으로 맞춘다.
        if preset != commentPreset { refreshCommentRule() }
        // rekordbox에서 지운 곡은 선택에서도 뺀다
        refreshBase()
        pruneMissingSelection()
        verifyReflection()
        refreshBase()
        markLoadSucceeded()
        refreshUnlinkedDrafts()
        warmPreviewWaveforms(loaded.rows)
        if failedTagSaves().isEmpty { clearLibraryError() } else { reportLibraryError(DraftSaveFailure.tagSaveMessage) }
        if synchronizingDrafts {
            toast = conflicts == 0
                ? AppToast(title: String(ui: "현재 rekordbox 내용을 불러왔습니다"))
                : AppToast(kind: .warning, title: String(ui: "태그 충돌을 확인하세요"),
                           detail: String(ui: "같은 칸이 바뀐 \(conflicts)곡의 초안을 보존했습니다. 곡 정보에서 현재 값과 초안을 확인하세요."))
        }
        useCases.log("라이브러리 로드 \(ContinuousClock.now - started) · \(rows.count)곡")
        // 동기화 중 시작한 드래그는 메모리에만 있을 수 있어 덱을 덮지 않는다.
        if !synchronizingDrafts || (allowsLibrarySync?() ?? true) {
            refreshDeckTrack()
            if synchronizingDrafts, let deckTrackID, let row = rowsByID[deckTrackID] {
                onRekordboxWritten?([row.track.uuid])
            }
            deliverWrittenAfterReload()
        }
        checkMissingFiles()
        applyLaunchSelection()
        runLaunchStagingTest()
        // 라이브러리에 없는 곡의 음량 항목·캐시 정리는 조립 지점이 맡는다(#217, `AppComposition.start`). 추가한 곡의 경로는 남긴다.
        onLibraryLoaded?(Set((rows + stagedRows).filter { !$0.track.isStreaming }.map(\.track.folderPath) + staged.map(\.path)))
    }

    /// 개발용: `--select <ContentID>` 곡을 골라 덱에 올린다(처음 읽을 때 한 번).
    private func applyLaunchSelection() {
        guard deckTrackID == nil, let id = launch.selectTrackID, let row = rowsByID[id] else { return }
        if case let .filter(filter) = sidebar, !filter.includes(row) { sidebar = .filter(.all) }
        selection = [row.id]
        loadToDeck(row)
    }

    /// 목록 미리 보기 파형을 뒤에서 채운다(라이브러리를 읽은 뒤, 설정 › 저장 공간에서 비운 뒤).
    func warmPreviewWaveforms(_ rows: [TrackRow]? = nil) {
        let shareRoot = shareRoot, rows = rows ?? self.rows, previews = useCases.previews
        previewWarmTask?.cancel()
        previewWarmTask = Task(priority: .background) { await previews.warm(rows, shareRoot: shareRoot) }
    }
}
