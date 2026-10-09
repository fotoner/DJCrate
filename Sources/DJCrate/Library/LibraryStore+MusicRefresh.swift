import DJCApplication
import DJCDomain
import Foundation

/// Music(iTunes) 목록 최신화: DB·곡 행을 읽은 뒤 Music 결과만 따로 결합한다(채택 규칙은 유스케이스 `LoadLibrary.readMusic`).
/// 오래된 요청은 읽기 세대(`reads`)와 `ITunesRefreshCoordinator`의 순서표로 거른다.
extension LibraryStore {
    /// iTunes 버튼은 명시한 DB를 벗어나지 않는다. 사본 모드에서는 현재 DB 옆 목록만 다시 읽는다.
    func refreshITunesPlaylists() async {
        guard !isLoading, !isWritingRekordbox else { return }
        if location.opensExplicitCopy {
            guard let snapshotURL else { return }
            await load(snapshot: snapshotURL)
        } else {
            await takeSnapshot(force: useCases.load.isRekordboxRunning())
        }
    }

    /// DB/행은 이미 읽은 뒤 Music 결과만 결합한다. 오래된 요청은 sidecar와 화면 모두 순서표로 거른다.
    /// - Parameter capture: 버려진 최신화가 하던 Music 조회. 주면 Music을 다시 조회하지 않고 그 결과를 기다린다.
    @discardableResult
    func startITunesRefresh(snapshot: URL, quiet: Bool,
                                    previousITunesSnapshot: LoadedLibrary.ITunesFallback?, fallbackDirectory: URL,
                                    sourceDatabase: URL?, captureITunes: (@Sendable () -> ITunesLibrarySnapshot)?,
                                    continuing capture: Task<ITunesLibrarySnapshot, Never>? = nil) -> Task<Void, Never> {
        let generation = reads.generation
        let loader = useCases.load
        let refreshTicket = loader.musicTicket(snapshot: snapshot, sourceDatabase: sourceDatabase)
        if !quiet { phase = .loading(LoadedLibrary.Stage.music.message) }
        // 조용히 읽는 동안에도 사이드바가 보이므로, 캡처한 목록이 없다는 안내를 읽는 중 안내로 바꾼다.
        if iTunesLibrary.status == .notCaptured { iTunesLibrary.status = .loading }
        let capture = capture ?? Task {
            (try? await LoadLibrary.background {
                loader.captureMusic(captureITunes)
            }) ?? ITunesLibrarySnapshot(status: .unavailable)
        }
        let id = UUID()
        let task = Task { [self] in
            defer {
                if endITunesRefresh(id: id) {
                    // 결과를 채택하지 못하고 끝났을 때만(취소·옛 요청) 되돌린다. 채택한 결과는 건드리지 않는다.
                    if iTunesLibrary.status == .loading { iTunesLibrary.status = .notCaptured }
                    if Task.isCancelled, reads.isCurrent(generation), !quiet, isLoading { phase = .loaded }
                }
            }
            let captured = await capture.value
            guard reads.isCurrent(generation), snapshotURL == snapshot, !Task.isCancelled else { return }
            let result = try? await LoadLibrary.background {
                loader.readMusic(snapshot: snapshot, refreshMusic: true, captured: captured, previous: previousITunesSnapshot,
                                 fallbackDirectory: fallbackDirectory, ticket: refreshTicket, sourceDatabase: sourceDatabase)
            }
            guard reads.isCurrent(generation), snapshotURL == snapshot, !Task.isCancelled else { return }
            if let result {
                iTunesSnapshot = result
                iTunesLibrary = SyncedITunesLibrary(snapshot: result, tracks: rows.map(\.track))
                if case let .itunesPlaylist(id) = sidebar, iTunesLibrary.index[id] == nil { sidebar = .filter(.all) }
                refreshBase()
                pruneMissingSelection()
            }
            if !quiet { phase = .loaded }
        }
        beginITunesRefresh(ITunesRefresh(id: id, generation: generation, capture: capture, task: task))
        return task
    }

    #if DEBUG
    /// 자가 테스트용: 사본 모드는 Music을 읽지 않으므로 멈춘 Music 최신화를 흉내 내 선택 창이 기다리는지 본다.
    func startSimulatedITunesRefresh(quiet: Bool = true, capture: @escaping @Sendable () -> ITunesLibrarySnapshot) -> Task<Void, Never>? {
        guard let snapshotURL else { return nil }
        return startITunesRefresh(snapshot: snapshotURL, quiet: quiet, previousITunesSnapshot: nil,
                                  fallbackDirectory: snapshotURL.deletingLastPathComponent(),
                                  sourceDatabase: nil, captureITunes: capture)
    }
    #endif

    /// 사본을 뜨는 동안 동기화 선택을 저장했다면, 뜨기 전에 붙든 이전 선택보다 현재 화면을 우선한다.
    func latestITunesFallback(_ previous: LoadedLibrary.ITunesFallback?) -> LoadedLibrary.ITunesFallback? {
        guard let previous, snapshotURL == previous.source else { return previous }
        let hasUsableDiskCache = previous.contents.status == .ready || previous.contents.status == .stale
        guard iTunesSnapshot.status == .ready || iTunesSnapshot.status == .stale
                || (iTunesSnapshot.status == .unavailable && !hasUsableDiskCache) else { return previous }
        return .init(source: previous.source, contents: iTunesSnapshot,
                     preferOverCurrent: previous.preferOverCurrent || previous.contents.syncData != iTunesSnapshot.syncData,
                     sourceDatabase: previous.sourceDatabase)
    }

    /// 이 사본에 곧 결과를 채택할 Music 최신화. 끝나기 전에는 선택 창이 낡은 목록으로 쓰지 않는다.
    func currentITunesRefresh(snapshot: URL?, revision: Int) -> Task<Void, Never>? {
        guard let snapshot, snapshotURL == snapshot, previewRevision == revision,
              let iTunesRefresh, iTunesRefresh.generation == reads.generation else { return nil }
        return iTunesRefresh.task
    }
}
