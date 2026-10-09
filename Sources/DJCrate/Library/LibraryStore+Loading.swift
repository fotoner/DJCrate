import DJCApplication
import DJCDomain
import Foundation

/// 라이브러리 읽기: 스냅샷 사본 뜨기 → DB·초안 읽기(메인 밖, 유스케이스 `LoadLibrary`) → 결과를 한 번에 적용, 뒤따른 Music 최신화.
/// 어떤 사본을 읽을지, 읽기 순서(초안 저장 끝내기·손상 파일 옮기기 → 사본 지문 → 읽기), 읽은 뒤 초안 맞추기(태그 base 옮겨 저장·합치기·그림 초안),
/// Music 결과 채택은 유스케이스가 정한다. 여기서는 읽기 순번(`reads`, `LibraryReadSequence`)과 돌려받은 값을 화면 상태에 적용하는 일만 맡는다.
extension LibraryStore {
    /// 스냅샷을 뜨지 않은 이유(`LibraryLocation.allowsSnapshot`이 거짓일 때)
    static var snapshotRefusedMessage: String { ReflectionSession.snapshotRefusedMessage }

    /// 명시한 사본(`--db PATH`·`DJC_DB`)이 있으면 그 사본을, 없으면 최신 스냅샷을 연다.
    /// - Parameter snapshotDirectory: 최신 스냅샷을 찾을 폴더(주지 않으면 위치 값의 스냅샷 폴더)
    /// - Parameter captureITunes: Music 조회(주지 않으면 유스케이스의 Music 포트). 시험이 바꿔 넣는다
    func loadInitial(snapshotDirectory: URL? = nil, captureITunes: (@Sendable () -> ITunesLibrarySnapshot)? = nil) async {
        guard !isLoading, rows.isEmpty else { return }
        let snapshotDirectory = snapshotDirectory ?? location.snapshotDirectory
        switch useCases.load.initialRead(location: location, snapshotDirectory: snapshotDirectory) {
        case let .explicitCopy(override):
            await load(snapshot: override, captureITunes: captureITunes)
        case let .latest(latest, refreshMusic, sourceDatabase, hasCurrentCatalog):
            let expectedGeneration = reads.generation + 1
            await load(snapshot: latest, refreshITunes: refreshMusic, captureITunes: captureITunes)
            // 켠 순간의 창 활성화는 읽는 도중이라 건너뛰므로, 읽은 뒤 한 번 더 본다
            let loadedRevision = previewRevision
            await refreshIfRekordboxChanged()
            guard hasCurrentCatalog, snapshotURL == latest, reads.isCurrent(expectedGeneration),
                  previewRevision == loadedRevision, lastError == nil else { return }
            startITunesRefresh(snapshot: latest, quiet: true,
                previousITunesSnapshot: nil, fallbackDirectory: snapshotDirectory,
                sourceDatabase: sourceDatabase, captureITunes: captureITunes)
        case .none:
            phase = .idle
        }
    }

    /// 창으로 돌아올 때: 지금 읽은 스냅샷 뒤에 rekordbox가 라이브러리를 바꿨으면 뒤에서 조용히 새로 읽는다.
    /// rekordbox가 켜져 있어도 읽기용 사본(WAL까지 사본 안에서 합침)으로 뜬다. 원본은 읽기만 한다.
    func refreshIfRekordboxChanged() async {
        guard case .loaded = phase, !isLoading, !isWritingRekordbox, let snapshotURL, !location.opensExplicitCopy,
              snapshotURL.deletingLastPathComponent().isSameDirectory(as: location.snapshotDirectory) else { return }
        switch useCases.load.change(since: snapshotURL, location: location, musicSyncData: iTunesSnapshot.syncData,
                                    refreshingMusic: iTunesRefresh?.generation == reads.generation) {
        case .none: return
        case .musicSelection: await load(snapshot: snapshotURL, quiet: true, refreshITunes: true)
        case .library:
            await takeSnapshot(force: true, quiet: true)
        }
    }

    /// 명시적 동기화만 비충돌 태그 기준을 맞춘다. 사본 모드에서는 지정한 DB를 다시 읽는다.
    func synchronizeLibrary() async {
        guard canSynchronizeLibrary else { return }
        await whileSynchronizingLibrary {
            useCases.watch.flush()
            retryFailedTagSaves()
            if location.opensExplicitCopy {
                guard let snapshotURL else { return }
                await load(snapshot: snapshotURL, quiet: true, synchronizingDrafts: true)
            } else {
                await takeSnapshot(force: useCases.load.isRekordboxRunning(), synchronizingDrafts: true)
            }
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
        guard !synchronizingDrafts || !isWritingRekordbox else { return }
        guard location.allowsSnapshot else {
            let message = Self.snapshotRefusedMessage
            if rows.isEmpty { phase = .failed(message) } else { reportLibraryError(message) }
            return
        }
        let snapshotDirectory = snapshotDirectory ?? location.snapshotDirectory
        let loader = useCases.load
        let snapshotCopy = snapshotCopy ?? { try loader.takeSnapshot(force: $0) }
        guard !isLoading || snapshotRequests.isRunning || !refreshITunes else { return }
        await snapshotRequests.runWithFollowUp(force: force, quiet: quiet, refreshITunes: refreshITunes, synchronizingDrafts: synchronizingDrafts) { [self] force, quiet in
            await takeSnapshotOnce(force: force, quiet: quiet, refreshITunes: refreshITunes, synchronizingDrafts: synchronizingDrafts, snapshotDirectory: snapshotDirectory,
                                   snapshotCopy: snapshotCopy, captureITunes: captureITunes)
        }
    }

    private func takeSnapshotOnce(force: Bool, quiet: Bool, refreshITunes: Bool, synchronizingDrafts: Bool, snapshotDirectory: URL,
                                  snapshotCopy: @escaping @Sendable (Bool) throws -> URL,
                                  captureITunes: (@Sendable () -> ITunesLibrarySnapshot)?) async -> Task<Void, Never>? {
        // 이 다시 읽기가 버리는 Music 최신화는 새 사본에서 이어받는다. 지난 세션 목록이 세션 내내 남지 않게.
        let interrupted = iTunesRefresh.flatMap { $0.generation == reads.generation ? $0 : nil }
        let (generation, readRequest) = beginSnapshotRead()
        if let snapshotURL { useCases.load.invalidateMusic([snapshotURL]) }
        let hadRows = !rows.isEmpty
        defer {
            if reads.isCurrent(generation), Task.isCancelled, isLoading { phase = hadRows ? .loaded : .idle }
        }
        let refreshITunes = refreshITunes && location.mayCaptureMusic
        // 같은 초에 DB 파일 이름을 재사용해도 마지막 정상 iTunes 사본을 잃지 않게 먼저 읽는다.
        let sourceDatabase = snapshotDirectory.isSameDirectory(as: location.snapshotDirectory) ? location.liveDatabase : nil
        let previousITunesSnapshot = useCases.load.previousMusic(current: snapshotURL, snapshotDirectory: snapshotDirectory,
                                                                 location: location, refreshMusic: refreshITunes)
        var isLoaded: Bool { if case .loaded = phase { true } else { false } }
        let quiet = quiet && hadRows && isLoaded
        if !quiet { phase = .loading(String(ui: "rekordbox DB 스냅샷을 뜨는 중…")) }
        do {
            let url = try await LoadLibrary.background { try snapshotCopy(force) }
            guard reads.isCurrentRequest(readRequest), !Task.isCancelled else { return nil }
            useCases.load.invalidateMusic([url])
            let fallback = latestITunesFallback(previousITunesSnapshot)
            let expectedGeneration = reads.generation + 1
            await load(snapshot: url, quiet: quiet, refreshITunes: false, synchronizingDrafts: synchronizingDrafts,
                       previousITunesSnapshot: fallback, captureITunes: captureITunes)
            guard reads.isCurrent(expectedGeneration), snapshotURL == url, lastError == nil else { return nil }
            guard refreshITunes else {
                // 쓰기는 Music을 기다리지 않게 후속 작업으로 돌려주지 않는다.
                if let interrupted {
                    startITunesRefresh(snapshot: url, quiet: true, previousITunesSnapshot: fallback,
                                       fallbackDirectory: snapshotDirectory, sourceDatabase: sourceDatabase,
                                       captureITunes: captureITunes, continuing: interrupted.capture)
                }
                return nil
            }
            return startITunesRefresh(snapshot: url, quiet: quiet, previousITunesSnapshot: fallback,
                                      fallbackDirectory: snapshotDirectory, sourceDatabase: sourceDatabase,
                                      captureITunes: captureITunes)
        } catch {
            guard reads.isCurrentRequest(readRequest), !Task.isCancelled, !(error is CancellationError) else {
                if reads.isCurrent(generation) { phase = hadRows ? .loaded : .idle }
                return nil
            }
            // 이미 라이브러리가 있으면 그대로 두고 오류만 알린다.
            AppErrorMessage.log(error)
            reportReadFailure(LibraryReadFailure(stage: .snapshotCreation, keepsPreviousLibrary: hadRows))
            return nil
        }
    }

    func load(snapshot: URL, quiet: Bool = false, refreshITunes: Bool = false, synchronizingDrafts: Bool = false,
              previousITunesSnapshot: LoadedLibrary.ITunesFallback? = nil,
              captureITunes: (@Sendable () -> ITunesLibrarySnapshot)? = nil) async {
        guard !synchronizingDrafts || !isWritingRekordbox else { return }
        let initialTagRevision = tagRevision
        previewWarmTask?.cancel()
        let generation = beginLoad()
        let started = ContinuousClock.now
        // 읽기와 한 번에 Music을 조회하는 경로(`refreshITunes`)도 `startITunesRefresh`처럼, 사이드바가 보이는 동안 캡처한 목록이 없다는 안내를
        // 읽는 중 안내로 바꾼다(#197). 결과를 채택하면 그 결과로 바뀌고, 채택하지 못하고 끝났을 때(실패·취소·옛 읽기)만 되돌린다.
        var markedITunesLoading = false
        if refreshITunes, iTunesLibrary.status == .notCaptured {
            iTunesLibrary.status = .loading
            markedITunesLoading = true
        }
        defer {
            if reads.isCurrent(generation), Task.isCancelled, isLoading { phase = rows.isEmpty ? .idle : .loaded }
            // 따로 도는 Music 최신화가 있으면 그 쪽이 읽는 중 표시를 되돌린다.
            if markedITunesLoading, iTunesLibrary.status == .loading, iTunesRefresh == nil { iTunesLibrary.status = .notCaptured }
        }
        if !quiet { phase = .loading(LoadedLibrary.Stage.database.message) }
        do {
            let preset = commentPreset
            let loader = useCases.load
            let sourceDatabase = loader.sourceDatabase(of: snapshot, location: location)
            // 메인 액터에서 정한 요청 순서를 캡처가 끝날 때까지 유지한다.
            let refreshTicket = loader.musicTicket(snapshot: snapshot, sourceDatabase: sourceDatabase)
            let artworkChanges = artworkChangeCount
            let request = LoadLibrary.Request(snapshot: snapshot, commentPreset: preset, refreshMusic: refreshITunes,
                                              previousMusic: previousITunesSnapshot, fallbackDirectory: location.snapshotDirectory,
                                              ticket: refreshTicket, sourceDatabase: sourceDatabase, shareRoot: rekordboxShareRoot)
            // 초안 저장 끝내기·손상 파일 옮기기(#174) → 사본 지문 → 읽기 → 사본 지문은 유스케이스가 차례로 한다. 옮긴 파일은 읽기 전에 알리고,
            // 그사이 새 읽기가 시작됐으면 읽지 않는다.
            let opened = try await loader.open(request, preservingDamaged: location.movesDamagedDrafts, settled: { [self] moved in
                guard reads.isCurrent(generation), !Task.isCancelled else { return false }
                reportDamagedDrafts(moved)
                return true
            }, progress: { stage in
                Task { @MainActor in
                    // 늦게 도착한 진행 표시가 끝난 읽기나 새 요청을 덮지 않는다.
                    guard self.reads.isCurrent(generation), self.isLoading else { return }
                    self.phase = .loading(stage.message)
                }
            }, capture: captureITunes)
            // 더 나중에 시작한 로드가 있으면 이 결과는 버린다.
            guard let opened, reads.isCurrent(generation), !Task.isCancelled else { return }
            let loaded = opened.loaded
            // 기다리는 동안 시작한 쓰기·복원의 초안과 동기화 결과를 섞지 않는다.
            guard !synchronizingDrafts || !isWritingRekordbox else {
                if !quiet { phase = rows.isEmpty ? .idle : .loaded }
                return
            }
            undoManager?.removeAllActions(withTarget: self)
            applyLoadedRows(from: loaded)
            let previousTags = tagDrafts, previousPlaylist = playlistDraft
            // 읽는 동안 사용자가 편집했거나 저장에 실패한 입력은 디스크의 오래된 값으로 덮지 않는다. 동기화면 충돌하지 않는 초안의 base를
            // 새 rekordbox 값으로 옮겨 저장한다(유스케이스). 연결 안 된 초안은 쓰기 대기 목록에서 따로 다룬다(#175).
            let reconciled = loader.reconcileDrafts(loaded, memoryTags: tagDrafts, editedDuringRead: tagRevision != initialTagRevision,
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
            rekordboxPlaylists = loaded.playlists
            smartPlaylistSources = loaded.smartPlaylists
            // 저장하지 못한 재생 목록 초안은 디스크의 옛 초안으로 덮지 않는다(#174).
            if !playlistDraftUnsaved { playlistDraft = loaded.playlistDraft }
            iTunesLibrary = loaded.iTunesLibrary
            iTunesSnapshot = loaded.iTunesSnapshot
            if case let .itunesPlaylist(id) = sidebar, iTunesLibrary.index[id] == nil { sidebar = .filter(.all) }
            mergeDrafts = reconciled.mergeDrafts
            refreshPlaylists(refreshList: false)
            applyMovedDrafts(opened.moved, previousTags: previousTags, previousPlaylist: previousPlaylist, reporting: false)
            restoreAwaitingPlaylistEdits()
            setHistories(loaded.histories, localKeys: opened.localKeys)
            adoptSnapshot(snapshot, usb: opened.usbSnapshot, generation: generation)
            // 스냅샷을 채택한 뒤에야 쓰기 대기를 고른다(쓴 기록이 rekordbox에 있는지 그 전에는 모른다). 처음 한 번 가장 최근 연·월을 펼친다
            refreshHistoryTree()
            seedHistoryFolders()
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
        } catch {
            guard reads.isCurrent(generation) else { return }
            guard !Task.isCancelled, !(error is CancellationError) else {
                phase = rows.isEmpty ? .idle : .loaded
                return
            }
            AppErrorMessage.log(error)
            let stage: LibraryReadFailure.Stage
            if case DJCError.databaseOpenFailed = error { stage = .opening }
            else if case DJCError.keyDerivationFailed = error { stage = .opening }
            else { stage = .contents }
            reportReadFailure(LibraryReadFailure(stage: stage, keepsPreviousLibrary: !rows.isEmpty))
        }
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
