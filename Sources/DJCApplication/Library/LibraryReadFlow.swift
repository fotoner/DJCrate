import DJCDomain
import Foundation

/// 라이브러리 읽기 순서(유스케이스): 처음 열기·창으로 돌아올 때 바뀜 확인·사본 뜨기·사본 한 번 읽기와 뒤따르는 Music(iTunes) 최신화,
/// iTunes 동기화 창의 목록 열기와 쓰기 전 확인(`LibraryReadFlow+Music`).
/// 늦게 끝난 옛 결과는 읽기 순번(`reads`)으로 버리고, 사본을 뜨는 동안 온 요청은 하나로 합친다(`SnapshotRequestQueue`).
/// 어떤 사본을 읽을지·Music 결과를 어떻게 채택할지는 `LoadLibrary`가, 무엇을 보일지는 화면(`screen`)이 정한다.
/// 화면 상태(Observation)는 두지 않는다. 앱은 라이브러리 화면 모델이 하나를 만들어 화면을 붙인다.
@MainActor
public final class LibraryReadFlow {
    /// Music 조회(주지 않으면 Music 포트). 시험이 바꿔 넣는다
    public typealias MusicCapture = @Sendable () -> ITunesLibrarySnapshot

    /// 뒤에서 도는 Music 최신화. 쓰기 뒤 다시 읽기가 버리면 새 사본이 같은 조회를 이어받는다.
    public struct MusicRefresh: Sendable {
        public let id: UInt64
        /// 시작할 때의 읽기 세대(새 읽기가 시작되면 결과를 넣지 않는다)
        public let generation: Int
        public let capture: Task<ITunesLibrarySnapshot, Never>
        public let task: Task<Void, Never>
    }

    let loader: LoadLibrary
    let location: LibraryLocation
    /// 흐름이 보는 화면. 화면 모델이 만들 때 붙인다(붙이지 않으면 읽은 결과를 버린다)
    public var screen: LibraryReadScreen = .none
    /// 읽기 세대·요청 순번. 늦게 끝난 읽기·Music 최신화·파일 확인·USB 사본 출처를 이것으로 가른다
    public internal(set) var reads = LibraryReadSequence()
    /// 사본 뜨기 요청 합치기(DB 복사·읽기만 차례로 돌린다)
    let requests = SnapshotRequestQueue()
    public internal(set) var musicRefresh: MusicRefresh?
    /// iTunes 동기화 창 목록 캐시·진행 중인 조회와, 화면의 Music 목록이 바뀔 때마다 오르는 순번(`+Music`)
    var catalogCache: CatalogCache?
    var catalogCapture: CatalogCapture?
    var catalogEpoch: UInt64 = 0
    /// Music 최신화·목록 조회를 가르는 순번(늦게 끝난 것이 새 기록을 지우지 않게)
    private var serial: UInt64 = 0

    public init(loader: LoadLibrary, location: LibraryLocation) {
        self.loader = loader
        self.location = location
    }

    /// 기다리는 사본 뜨기 요청 수(합친 것 포함)
    public var waitingSnapshotRequests: Int { requests.waitingCount }

    /// 기다리던 읽기 결과를 버린다
    public func invalidate() { reads.invalidate() }

    func nextID() -> UInt64 {
        serial &+= 1
        return serial
    }

    // MARK: - 처음 열기·바뀜 확인

    /// 처음 열 때: 명시한 사본(`--db PATH`·`DJC_DB`)이 있으면 그 사본을, 없으면 최신 스냅샷을 읽는다.
    /// 사본 옆 목록이 지금 동기화 선택과 같으면 Music을 기다리지 않고 먼저 보인 뒤 뒤에서 최신화한다.
    /// - Parameter snapshotDirectory: 최신 스냅샷을 찾을 폴더(주지 않으면 위치 값의 스냅샷 폴더)
    public func loadInitial(snapshotDirectory: URL? = nil, capture: MusicCapture? = nil) async {
        let state = screen.state()
        guard !state.isLoading, !state.hasRows else { return }
        let snapshotDirectory = snapshotDirectory ?? location.snapshotDirectory
        switch loader.initialRead(location: location, snapshotDirectory: snapshotDirectory) {
        case let .explicitCopy(override):
            await load(snapshot: override, capture: capture)
        case let .latest(latest, refreshMusic, sourceDatabase, hasCurrentCatalog):
            let expectedGeneration = reads.generation + 1
            await load(snapshot: latest, refreshMusic: refreshMusic, capture: capture)
            // 켠 순간의 창 활성화는 읽는 도중이라 건너뛰므로, 읽은 뒤 한 번 더 본다
            let loadedRevision = screen.state().revision
            await refreshIfChanged()
            let now = screen.state()
            guard hasCurrentCatalog, now.snapshot == latest, reads.isCurrent(expectedGeneration),
                  now.revision == loadedRevision, !now.hasError else { return }
            startMusicRefresh(snapshot: latest, quiet: true, previous: nil, fallbackDirectory: snapshotDirectory,
                              sourceDatabase: sourceDatabase, capture: capture)
        case .none:
            screen.apply(.phase(.idle))
        }
    }

    /// 창으로 돌아올 때: 지금 읽은 스냅샷 뒤에 rekordbox가 라이브러리를 바꿨으면 뒤에서 조용히 새로 읽는다.
    /// rekordbox가 켜져 있어도 읽기용 사본(WAL까지 사본 안에서 합침)으로 뜬다. 원본은 읽기만 한다.
    public func refreshIfChanged() async {
        let state = screen.state()
        guard state.isLoaded, !state.isWriting, let snapshot = state.snapshot, !location.opensExplicitCopy,
              snapshot.deletingLastPathComponent().isSameDirectory(as: location.snapshotDirectory) else { return }
        switch loader.change(since: snapshot, location: location, musicSyncData: state.music.syncData,
                             refreshingMusic: musicRefresh?.generation == reads.generation) {
        case .none: return
        case .musicSelection: await load(snapshot: snapshot, quiet: true, refreshMusic: true)
        case .library: await takeSnapshot(force: true, quiet: true)
        }
    }

    /// 명시적 동기화의 다시 읽기(비충돌 태그 기준을 맞춘다). 사본 모드에서는 지정한 DB를 다시 읽는다.
    public func rereadSynchronizingDrafts() async {
        if location.opensExplicitCopy {
            guard let snapshot = screen.state().snapshot else { return }
            await load(snapshot: snapshot, quiet: true, synchronizingDrafts: true)
        } else {
            await takeSnapshot(force: loader.isRekordboxRunning(), synchronizingDrafts: true)
        }
    }

    /// iTunes 단추: 명시한 DB를 벗어나지 않는다. 사본 모드에서는 지금 DB 옆 목록만 다시 읽는다.
    public func refreshMusicPlaylists() async {
        let state = screen.state()
        guard !state.isLoading, !state.isWriting else { return }
        if location.opensExplicitCopy {
            guard let snapshot = state.snapshot else { return }
            await load(snapshot: snapshot)
        } else {
            await takeSnapshot(force: loader.isRekordboxRunning())
        }
    }

    // MARK: - 사본 뜨기

    /// 사본을 떠서 읽는다. 사본을 뜨는 동안 온 요청은 하나로 합친다(하나라도 억지로 뜨라면 억지로, 모두 조용하면 조용히).
    /// - Parameter quiet: 화면을 로딩으로 바꾸지 않고 뒤에서 다시 읽는다(rekordbox에 쓴 뒤 등).
    /// - Parameter refreshMusic: 읽은 뒤 Music을 최신화하고 그 끝까지 기다린다. 쓰기 뒤에는 기존 목록을 재사용해 Music 응답을 기다리지 않는다.
    /// - Parameter snapshotDirectory: 사본을 뜨는 폴더(주지 않으면 위치 값의 스냅샷 폴더)
    /// - Parameter copy: 사본 뜨기(주지 않으면 `LoadLibrary.takeSnapshot`). 시험이 바꿔 넣는다
    public func takeSnapshot(force: Bool = false, quiet: Bool = false, refreshMusic: Bool = true, synchronizingDrafts: Bool = false,
                             snapshotDirectory: URL? = nil, copy: (@Sendable (Bool) throws -> URL)? = nil,
                             capture: MusicCapture? = nil) async {
        let state = screen.state()
        guard !synchronizingDrafts || !state.isWriting else { return }
        guard location.allowsSnapshot else {
            let message = ReflectionSession.snapshotRefusedMessage
            screen.apply(state.hasRows ? .error(message) : .phase(.failed(message)))
            return
        }
        let snapshotDirectory = snapshotDirectory ?? location.snapshotDirectory
        let loader = loader
        let copy = copy ?? { try loader.takeSnapshot(force: $0) }
        guard !state.isLoading || requests.isRunning || !refreshMusic else { return }
        await requests.runWithFollowUp(force: force, quiet: quiet, refreshITunes: refreshMusic,
                                       synchronizingDrafts: synchronizingDrafts) { [self] force, quiet in
            await takeSnapshotOnce(force: force, quiet: quiet, refreshMusic: refreshMusic, synchronizingDrafts: synchronizingDrafts,
                                   snapshotDirectory: snapshotDirectory, copy: copy, capture: capture)
        }
    }

    /// 사본을 한 번 떠서 읽는다. 돌려주는 작업(뒤따르는 Music 최신화)은 합친 요청이 모두 기다린다
    private func takeSnapshotOnce(force: Bool, quiet: Bool, refreshMusic: Bool, synchronizingDrafts: Bool, snapshotDirectory: URL,
                                  copy: @escaping @Sendable (Bool) throws -> URL,
                                  capture: MusicCapture?) async -> Task<Void, Never>? {
        // 이 다시 읽기가 버리는 Music 최신화는 새 사본에서 이어받는다. 지난 세션 목록이 세션 내내 남지 않게.
        let interrupted = musicRefresh.flatMap { $0.generation == reads.generation ? $0 : nil }
        let (generation, readRequest) = reads.beginSnapshot()
        let state = screen.state()
        if let current = state.snapshot { loader.invalidateMusic([current]) }
        let hadRows = state.hasRows
        defer {
            if reads.isCurrent(generation), Task.isCancelled, screen.state().isLoading { screen.apply(.phase(hadRows ? .loaded : .idle)) }
        }
        let refreshMusic = refreshMusic && location.mayCaptureMusic
        // 같은 초에 DB 파일 이름을 재사용해도 마지막 정상 iTunes 사본을 잃지 않게 먼저 읽는다.
        let sourceDatabase = snapshotDirectory.isSameDirectory(as: location.snapshotDirectory) ? location.liveDatabase : nil
        let previousMusic = loader.previousMusic(current: state.snapshot, snapshotDirectory: snapshotDirectory,
                                                 location: location, refreshMusic: refreshMusic)
        let quiet = quiet && hadRows && state.isLoaded
        if !quiet { screen.apply(.phase(.loading(String(ui: "rekordbox DB 스냅샷을 뜨는 중…")))) }
        do {
            let url = try await LoadLibrary.background { try copy(force) }
            guard reads.isCurrentRequest(readRequest), !Task.isCancelled else { return nil }
            loader.invalidateMusic([url])
            let fallback = latestMusicFallback(previousMusic)
            let expectedGeneration = reads.generation + 1
            await load(snapshot: url, quiet: quiet, refreshMusic: false, synchronizingDrafts: synchronizingDrafts,
                       previousMusic: fallback, capture: capture)
            let now = screen.state()
            guard reads.isCurrent(expectedGeneration), now.snapshot == url, !now.hasError else { return nil }
            guard refreshMusic else {
                // 쓰기는 Music을 기다리지 않게 후속 작업으로 돌려주지 않는다.
                if let interrupted {
                    startMusicRefresh(snapshot: url, quiet: true, previous: fallback, fallbackDirectory: snapshotDirectory,
                                      sourceDatabase: sourceDatabase, capture: capture, continuing: interrupted.capture)
                }
                return nil
            }
            return startMusicRefresh(snapshot: url, quiet: quiet, previous: fallback, fallbackDirectory: snapshotDirectory,
                                     sourceDatabase: sourceDatabase, capture: capture)
        } catch {
            guard reads.isCurrentRequest(readRequest), !Task.isCancelled, !(error is CancellationError) else {
                if reads.isCurrent(generation) { screen.apply(.phase(hadRows ? .loaded : .idle)) }
                return nil
            }
            // 이미 라이브러리가 있으면 그대로 두고 오류만 알린다.
            screen.apply(.readFailed(LibraryReadFailure(stage: .snapshotCreation, keepsPreviousLibrary: hadRows), error))
            return nil
        }
    }

    /// 사본을 뜨는 동안 동기화 선택을 저장했다면, 뜨기 전에 붙든 이전 선택보다 지금 화면의 목록을 우선한다.
    public func latestMusicFallback(_ previous: LoadedLibrary.ITunesFallback?) -> LoadedLibrary.ITunesFallback? {
        let state = screen.state()
        guard let previous, state.snapshot == previous.source else { return previous }
        let music = state.music
        let hasUsableDiskCache = previous.contents.status == .ready || previous.contents.status == .stale
        guard music.status == .ready || music.status == .stale
                || (music.status == .unavailable && !hasUsableDiskCache) else { return previous }
        return .init(source: previous.source, contents: music,
                     preferOverCurrent: previous.preferOverCurrent || previous.contents.syncData != music.syncData,
                     sourceDatabase: previous.sourceDatabase)
    }

    // MARK: - 한 번 읽기

    /// 사본 하나를 읽어 화면에 넣는다. 더 나중에 시작한 읽기가 있으면 이 결과는 버린다.
    /// 읽기 순서(초안 저장 끝내기·손상 파일 옮기기 → 사본 지문 → 읽기)는 `LoadLibrary.open`이 정한다.
    /// - Parameter quiet: 화면을 로딩으로 바꾸지 않고 뒤에서 다시 읽는다.
    /// - Parameter refreshMusic: 읽기와 함께 Music을 조회한다.
    /// - Parameter synchronizingDrafts: 명시적 동기화(기다리는 동안 쓰기·복원이 시작되면 결과를 섞지 않는다)
    /// - Parameter previousMusic: 새 사본에 목록이 없을 때 이어 쓸 지금 목록
    public func load(snapshot: URL, quiet: Bool = false, refreshMusic: Bool = false, synchronizingDrafts: Bool = false,
                     previousMusic: LoadedLibrary.ITunesFallback? = nil, capture: MusicCapture? = nil) async {
        guard !synchronizingDrafts || !screen.state().isWriting else { return }
        let start = screen.beginRead()
        let generation = reads.beginLoad()
        // 읽기와 한 번에 Music을 조회하는 경로도 `startMusicRefresh`처럼, 사이드바가 보이는 동안 캡처한 목록이 없다는 안내를
        // 읽는 중 안내로 바꾼다(#197). 결과를 채택하면 그 결과로 바뀌고, 채택하지 못하고 끝났을 때(실패·취소·옛 읽기)만 되돌린다.
        var markedMusicLoading = false
        if refreshMusic, screen.state().musicStatus == .notCaptured {
            screen.apply(.musicStatus(.loading))
            markedMusicLoading = true
        }
        defer {
            let state = screen.state()
            if reads.isCurrent(generation), Task.isCancelled, state.isLoading { screen.apply(.phase(state.settledPhase)) }
            // 따로 도는 Music 최신화가 있으면 그 쪽이 읽는 중 표시를 되돌린다.
            if markedMusicLoading, screen.state().musicStatus == .loading, musicRefresh == nil { screen.apply(.musicStatus(.notCaptured)) }
        }
        if !quiet { screen.apply(.phase(.loading(LoadedLibrary.Stage.database.message))) }
        do {
            let loader = loader, screen = screen
            let sourceDatabase = loader.sourceDatabase(of: snapshot, location: location)
            // 메인 액터에서 정한 요청 순서를 캡처가 끝날 때까지 유지한다.
            let ticket = loader.musicTicket(snapshot: snapshot, sourceDatabase: sourceDatabase)
            let request = LoadLibrary.Request(snapshot: snapshot, commentPreset: start.commentPreset, refreshMusic: refreshMusic,
                                              previousMusic: previousMusic, fallbackDirectory: location.snapshotDirectory,
                                              ticket: ticket, sourceDatabase: sourceDatabase, shareRoot: location.shareRoot)
            // 옮긴 손상 파일은 읽기 전에 알리고, 그사이 새 읽기가 시작됐으면 읽지 않는다.
            let opened = try await loader.open(request, preservingDamaged: location.movesDamagedDrafts, settled: { [self] moved in
                guard reads.isCurrent(generation), !Task.isCancelled else { return false }
                screen.apply(.damagedDrafts(moved))
                return true
            }, progress: { stage in
                Task { @MainActor [weak self] in
                    // 늦게 도착한 진행 표시가 끝난 읽기나 새 요청을 덮지 않는다.
                    guard let self, self.reads.isCurrent(generation), screen.state().isLoading else { return }
                    screen.apply(.phase(.loading(stage.message)))
                }
            }, capture: capture)
            // 더 나중에 시작한 읽기가 있으면 이 결과는 버린다.
            guard let opened, reads.isCurrent(generation), !Task.isCancelled else { return }
            // 기다리는 동안 시작한 쓰기·복원의 초안과 동기화 결과를 섞지 않는다.
            guard !synchronizingDrafts || !screen.state().isWriting else {
                if !quiet { screen.apply(.phase(screen.state().settledPhase)) }
                return
            }
            start.adopt(LibraryReadResult(opened: opened, snapshot: snapshot, generation: generation, synchronizingDrafts: synchronizingDrafts))
        } catch {
            guard reads.isCurrent(generation) else { return }
            let state = screen.state()
            guard !Task.isCancelled, !(error is CancellationError) else {
                screen.apply(.phase(state.settledPhase))
                return
            }
            let stage: LibraryReadFailure.Stage
            if case DJCError.databaseOpenFailed = error { stage = .opening }
            else if case DJCError.keyDerivationFailed = error { stage = .opening }
            else { stage = .contents }
            screen.apply(.readFailed(LibraryReadFailure(stage: stage, keepsPreviousLibrary: state.hasRows), error))
        }
    }
}
