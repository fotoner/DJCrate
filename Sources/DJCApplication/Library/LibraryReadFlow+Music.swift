import DJCDomain
import Foundation

/// iTunes 동기화 창이 지금 보이는 목록과 선택
public struct ITunesSyncShown: Sendable {
    public var source: ITunesLibrarySnapshot
    public var selection: ITunesSyncSelection

    public init(source: ITunesLibrarySnapshot, selection: ITunesSyncSelection) {
        self.source = source
        self.selection = selection
    }
}

/// iTunes 동기화 창을 연 결과
public enum ITunesSyncOpening: Sendable {
    /// 여는 사이 라이브러리가 바뀌었다(창을 다시 열어야 한다)
    case superseded
    case opened(ITunesSyncOpened)
}

/// 동기화 창에 보일 목록과 선택
public struct ITunesSyncOpened: Sendable {
    public var source: ITunesLibrarySnapshot
    public var selection: ITunesSyncSelection
    /// 창에 보일 막힘 이유(동기화 원문이 없을 때)
    public var error: String?
    /// 뒤에서 도는 Music 최신화. 끝날 때까지는 쓰지 않고, 끝나면 그 결과로 다시 연다
    public var refresh: Task<Void, Never>?

    public init(source: ITunesLibrarySnapshot, selection: ITunesSyncSelection, error: String? = nil, refresh: Task<Void, Never>? = nil) {
        self.source = source
        self.selection = selection
        self.error = error
        self.refresh = refresh
    }
}

/// Music(iTunes) 최신화와 iTunes 동기화 창: DB·곡 행을 읽은 뒤 Music 결과만 따로 결합한다(채택 규칙은 `LoadLibrary.readMusic`).
/// 오래된 요청은 읽기 세대(`reads`)와 `ITunesRefreshCoordinator`의 순서표로 거른다.
extension LibraryReadFlow {
    struct CatalogCache {
        let snapshot: URL
        let revision: Int
        let epoch: UInt64
        let sourceDirectory: URL
        let contents: ITunesLibrarySnapshot
    }

    struct CatalogCapture {
        let id: UInt64
        let snapshot: URL
        let revision: Int
        let epoch: UInt64
        let sourceDirectory: URL
        let task: Task<ITunesLibrarySnapshot, Never>
    }

    public static var waitingForMusicMessage: String {
        String(ui: "Music 보관함을 새로 읽는 중이니 목록이 최신으로 바뀐 뒤 동기화하세요.")
    }

    public static var libraryChangedMessage: String {
        String(ui: "라이브러리가 바뀌었거나 목록을 읽지 못했습니다. 동기화 창을 다시 여세요.")
    }

    static var missingSyncFileMessage: String {
        String(ui: "rekordbox 동기화 파일 사본이 없습니다. rekordbox에서 한 번 동기화한 뒤 새로고침하세요.")
    }

    // MARK: - Music 최신화

    /// DB·곡 행은 이미 읽은 뒤 Music 결과만 결합한다. 오래된 요청은 Music 목록 사본과 화면 모두 순서표로 거른다.
    /// - Parameter continuing: 버려진 최신화가 하던 Music 조회. 주면 Music을 다시 조회하지 않고 그 결과를 기다린다.
    @discardableResult
    public func startMusicRefresh(snapshot: URL, quiet: Bool, previous: LoadedLibrary.ITunesFallback?, fallbackDirectory: URL,
                                  sourceDatabase: URL?, capture: MusicCapture?,
                                  continuing: Task<ITunesLibrarySnapshot, Never>? = nil) -> Task<Void, Never> {
        let generation = reads.generation
        let loader = loader, screen = screen
        let ticket = loader.musicTicket(snapshot: snapshot, sourceDatabase: sourceDatabase)
        if !quiet { screen.apply(.phase(.loading(LoadedLibrary.Stage.music.message))) }
        // 조용히 읽는 동안에도 사이드바가 보이므로, 캡처한 목록이 없다는 안내를 읽는 중 안내로 바꾼다.
        if screen.state().musicStatus == .notCaptured { screen.apply(.musicStatus(.loading)) }
        let musicCapture = continuing ?? Task {
            (try? await LoadLibrary.background { loader.captureMusic(capture) }) ?? ITunesLibrarySnapshot(status: .unavailable)
        }
        let id = nextID()
        let task = Task { [self] in
            defer {
                if endMusicRefresh(id: id) {
                    // 결과를 채택하지 못하고 끝났을 때만(취소·옛 요청) 되돌린다. 채택한 결과는 건드리지 않는다.
                    if screen.state().musicStatus == .loading { screen.apply(.musicStatus(.notCaptured)) }
                    if Task.isCancelled, reads.isCurrent(generation), !quiet, screen.state().isLoading { screen.apply(.phase(.loaded)) }
                }
            }
            let captured = await musicCapture.value
            guard reads.isCurrent(generation), screen.state().snapshot == snapshot, !Task.isCancelled else { return }
            let result = try? await LoadLibrary.background {
                loader.readMusic(snapshot: snapshot, refreshMusic: true, captured: captured, previous: previous,
                                 fallbackDirectory: fallbackDirectory, ticket: ticket, sourceDatabase: sourceDatabase)
            }
            guard reads.isCurrent(generation), screen.state().snapshot == snapshot, !Task.isCancelled else { return }
            if let result { screen.apply(.music(result)) }
            if !quiet { screen.apply(.phase(.loaded)) }
        }
        musicRefresh = MusicRefresh(id: id, generation: generation, capture: musicCapture, task: task)
        return task
    }

    /// 이 Music 최신화가 아직 마지막 것이면 지우고 참
    private func endMusicRefresh(id: UInt64) -> Bool {
        guard musicRefresh?.id == id else { return false }
        musicRefresh = nil
        return true
    }

    /// 이 사본에 곧 결과를 채택할 Music 최신화. 끝나기 전에는 동기화 창이 낡은 목록으로 쓰지 않는다.
    public func currentMusicRefresh(snapshot: URL?, revision: Int) -> Task<Void, Never>? {
        let state = screen.state()
        guard let snapshot, state.snapshot == snapshot, state.revision == revision,
              let musicRefresh, musicRefresh.generation == reads.generation else { return nil }
        return musicRefresh.task
    }

    // MARK: - iTunes 동기화 창

    /// 화면의 Music 목록이 바뀌었다(동기화 창 목록 캐시를 버린다)
    public func musicChanged() {
        catalogEpoch &+= 1
        catalogCache = nil
    }

    /// 동기화 선택 창의 Music 전체 목록. 지금 동기화 선택과 맞는 목록이 있으면 Music을 기다리지 않는다.
    /// 뒤에서 도는 최신화나 진행 중인 조회가 있으면 그 결과를 함께 쓴다. 사본 실행에서는 Music에 접근하지 않고 함께 캡처한 목록만 쓴다.
    public func syncCatalog(forceRefresh: Bool = false, capture: MusicCapture? = nil) async -> ITunesLibrarySnapshot {
        if location.opensExplicitCopy || !location.mayCaptureMusic {
            return screen.state().music
        }
        let state = screen.state()
        guard let snapshot = state.snapshot else { return ITunesLibrarySnapshot(status: .unavailable) }
        let revision = state.revision
        let epoch = catalogEpoch
        let sourceDirectory = snapshot.deletingLastPathComponent().isSameDirectory(as: location.snapshotDirectory)
            ? location.rekordboxDirectory : snapshot.deletingLastPathComponent()
        let loader = loader

        if !forceRefresh {
            if let cached = catalogCache, cached.snapshot == snapshot, cached.revision == revision,
               cached.epoch == epoch,
               cached.sourceDirectory == sourceDirectory,
               loader.isCurrentCatalog(cached.contents, directory: sourceDirectory) {
                return cached.contents
            }
            if loader.isCurrentCatalog(state.music, directory: sourceDirectory) {
                return state.music
            }
        }

        // 뒤에서 도는 최신화가 같은 DB의 Music 전체 목록을 이미 읽는 중이면 그 결과를 함께 쓴다.
        if let refresh = currentMusicRefresh(snapshot: snapshot, revision: revision) {
            await refresh.value
            let now = screen.state()
            guard now.snapshot == snapshot, now.revision == revision else {
                return ITunesLibrarySnapshot(status: .unavailable)
            }
            return now.music
        }

        // 쓸 수 있는 캐시가 없을 때만 진행 중인 Music 읽기를 함께 기다린다.
        if let pending = catalogCapture, pending.snapshot == snapshot, pending.revision == revision,
           pending.epoch == epoch, pending.sourceDirectory == sourceDirectory {
            let captured = await pending.task.value
            return currentCatalogIfSuperseded(snapshot: snapshot, revision: revision,
                                              epoch: epoch, directory: sourceDirectory) ?? captured
        }

        let id = nextID()
        let task = Task(priority: .userInitiated) {
            (try? await LoadLibrary.background { loader.captureCatalog(capture) }) ?? ITunesLibrarySnapshot(status: .unavailable)
        }
        catalogCapture = CatalogCapture(id: id, snapshot: snapshot, revision: revision, epoch: epoch,
                                        sourceDirectory: sourceDirectory, task: task)
        let captured = await task.value
        if catalogCapture?.id == id { catalogCapture = nil }
        if let current = currentCatalogIfSuperseded(snapshot: snapshot, revision: revision,
                                                    epoch: epoch, directory: sourceDirectory) {
            return current
        }
        let now = screen.state()
        if now.snapshot == snapshot, now.revision == revision, catalogEpoch == epoch,
           loader.isCurrentCatalog(captured, directory: sourceDirectory) {
            catalogCache = CatalogCache(snapshot: snapshot, revision: revision, epoch: epoch,
                                        sourceDirectory: sourceDirectory, contents: captured)
        }
        return captured
    }

    private func currentCatalogIfSuperseded(snapshot: URL, revision: Int, epoch: UInt64,
                                            directory: URL) -> ITunesLibrarySnapshot? {
        let state = screen.state()
        guard state.snapshot != snapshot || state.revision != revision || catalogEpoch != epoch else { return nil }
        guard state.snapshot == snapshot, state.revision == revision,
              loader.isCurrentCatalog(state.music, directory: directory) else {
            return ITunesLibrarySnapshot(status: .unavailable)
        }
        return state.music
    }

    /// 동기화 창에 보일 목록과 선택을 연다. 여는 사이 라이브러리가 바뀌었으면 버린다(창을 다시 열게 한다).
    /// 새 목록을 읽지 못했으면 지금 보이는 목록·선택을 낡음으로 남긴다. 편집한 선택은 새 목록에 있는 것만 남긴다.
    /// 뒤에서 Music 최신화가 돌면 그 작업을 함께 돌려준다: 창은 끝날 때까지 쓰지 않고, 끝나면 그 결과로 다시 연다.
    /// - Parameter shown: 창이 지금 보이는 목록과 선택
    public func openSyncWindow(shown: ITunesSyncShown, forceRefresh: Bool = false, capture: MusicCapture? = nil) async -> ITunesSyncOpening {
        let hadSource = shown.source.status == .ready || shown.source.status == .stale
        let selectionEdited = hadSource && shown.selection != loader.initialSelection(of: shown.source)
        let requested = screen.state()
        let captured = await syncCatalog(forceRefresh: forceRefresh, capture: capture)
        let now = screen.state()
        guard now.snapshot == requested.snapshot, now.revision == requested.revision else { return .superseded }
        var opened: ITunesSyncOpened
        if captured.status != .ready, hadSource {
            var source = shown.source
            source.status = .stale
            opened = ITunesSyncOpened(source: source, selection: shown.selection)
        } else {
            let selection: ITunesSyncSelection
            if selectionEdited {
                let available = Set(captured.selectionNodes.map(\.id)).union(["0"])
                selection = ITunesSyncSelection(selectedIDs: shown.selection.selectedIDs.intersection(available))
            } else {
                selection = loader.initialSelection(of: captured)
            }
            opened = ITunesSyncOpened(source: captured, selection: selection)
            if captured.status == .ready, captured.syncData == nil { opened.error = Self.missingSyncFileMessage }
        }
        // 최신화가 끝나기 전의 목록으로 쓰면 폴더 계층이 낡을 수 있다. 편집한 체크박스는 다시 열 때 남는다.
        opened.refresh = currentMusicRefresh(snapshot: requested.snapshot, revision: requested.revision)
        return .opened(opened)
    }

    /// 동기화 선택을 rekordbox에 쓴다. 라이브러리가 바뀌었거나, Music 최신화가 끝나기 전이거나, 동기화 원문이 없거나,
    /// 연 사본(`--db`)의 원문이 쓰기 대상과 다르면 쓰지 않는다. 쓰는 동안 기다리던 읽기를 버리고, 쓴 선택을 목록 사본에 남긴 뒤
    /// `published`로 화면에 넘긴다(목록 사본 규칙은 `LoadLibrary.publishSync`).
    /// - Parameter database: 동기화 창을 연 사본
    /// - Parameter write: 반영 세션의 iTunes 동기화 쓰기(쓰기 대상·관문은 세션이 정한다). 없으면 쓰지 않는다
    public func syncMusic(_ selection: ITunesSyncSelection, source: ITunesLibrarySnapshot, database: URL,
                          write: ((ITunesSyncWrite) async throws -> (target: URL, syncData: Data))?,
                          published: @MainActor (LoadLibrary.SyncedSelection) -> Void) async throws {
        let state = screen.state()
        guard !state.isLoading, !state.isWriting, state.snapshot == database, source.status == .ready else {
            throw DJCError.writeRefused(Self.libraryChangedMessage)
        }
        // 최신화가 끝나기 전의 목록으로 쓰면 폴더 계층이 낡을 수 있다.
        guard currentMusicRefresh(snapshot: database, revision: state.revision) == nil else {
            throw DJCError.writeRefused(Self.waitingForMusicMessage)
        }
        guard let base = source.syncData else { throw DJCError.writeRefused(Self.missingSyncFileMessage) }
        // 다른 폴더의 `--db` 사본은 새로고침해도 쓰기 대상과 원문이 맞춰지지 않는다. 쓰기 관문의 "새로고침" 안내 대신 다시 여는 길을 알린다
        if loader.syncDiffersFromTarget(base, opened: database, location: location) {
            throw DJCError.writeRefused(String(ui: "지금 연 사본(--db)의 동기화 선택이 rekordbox와 다르니 --db 없이 다시 열어 동기화하세요."))
        }
        guard let write else { throw DJCError.writeRefused(Self.libraryChangedMessage) }
        reads.invalidate()
        defer { reads.invalidate() }
        let written = try await write(ITunesSyncWrite(base: base, source: source.selectionNodes, selection: selection))
        // 쓴 선택을 목록에 적용하고 동기화 창을 연 사본·지금 보는 사본 옆에 목록 사본을 남긴다.
        let synced = try loader.publishSync(source: source, syncData: written.syncData, database: database, target: written.target,
                                            active: screen.state().snapshot, location: location)
        published(synced)
    }
}
