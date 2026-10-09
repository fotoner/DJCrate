import DJCDomain
import Foundation

/// 라이브러리 읽기(유스케이스): 스냅샷 사본의 DB·분석 파일·초안·Music(iTunes) 목록을 읽어 곡 목록 한 값(`LoadedLibrary`)으로 만든다.
/// 어떤 사본을 열지(처음 열기·바뀐 라이브러리 다시 읽기), 읽기 전 초안 정리(저장 끝내기·손상 파일 옮기기), Music 결과의 채택·사본 저장 규칙과
/// iTunes 동기화 뒤 목록 사본 저장도 여기서 정한다. 화면 모델은 읽기 순번·화면 상태만 맡고 결과를 적용한다.
/// 읽기는 모두 메인 밖에서 한다(`read`·`readMusic`은 동기 함수라 부르는 쪽이 `background`로 감싼다).
public struct LoadLibrary: Sendable {
    let source: LibrarySource
    let music: MusicLibrarySource
    let drafts: DraftStore
    /// Music 결과 채택 순서(한 프로세스에 하나)
    let order: ITunesRefreshCoordinator
    /// 라이브 DB에서 읽기용 스냅샷 사본 뜨기
    let snapshots: SnapshotTaker
    /// 읽은 사본의 지문과 USB 작업 사본
    let usbSnapshots: UsbSyncSnapshots
    /// 읽은 사본의 USB 짝짓기 키(보존한 기기 재생 기록의 짝·쓴 표시 검증, #43). nil이면 읽지 않는다
    let localKeys: LocalLibraryKeysSource?

    public init(source: LibrarySource, music: MusicLibrarySource, drafts: DraftStore, order: ITunesRefreshCoordinator,
                snapshots: SnapshotTaker, usbSnapshots: UsbSyncSnapshots, localKeys: LocalLibraryKeysSource? = nil) {
        self.source = source
        self.music = music
        self.drafts = drafts
        self.order = order
        self.snapshots = snapshots
        self.usbSnapshots = usbSnapshots
        self.localKeys = localKeys
    }

    // MARK: - 어떤 사본을 읽을지

    /// 처음 열 때 읽을 사본
    public enum InitialRead: Sendable, Equatable {
        /// 명시한 사본(`--db PATH`·`DJC_DB`)
        case explicitCopy(URL)
        /// 스냅샷 폴더의 가장 최근 사본. `hasCurrentCatalog`: 사본 옆 목록이 지금 동기화 선택과 같아 Music을 바로 읽지 않아도 된다
        case latest(URL, refreshMusic: Bool, sourceDatabase: URL?, hasCurrentCatalog: Bool)
        /// 읽을 사본이 없다
        case none
    }

    public func initialRead(location: LibraryLocation, snapshotDirectory: URL) -> InitialRead {
        if let override = location.explicitCopy { return .explicitCopy(override) }
        guard let latest = try? source.latestSnapshot(snapshotDirectory) else { return .none }
        let mayCaptureMusic = location.mayCaptureMusic
        let sourceDatabase = snapshotDirectory.isSameDirectory(as: location.snapshotDirectory) ? location.liveDatabase : nil
        let cached = music.cached(latest)
        let sourceDirectory = (sourceDatabase ?? latest).deletingLastPathComponent()
        let hasCurrentCatalog = mayCaptureMusic && cached.status == .ready && cached.sourcePlaylists != nil
            && !music.selectionChanged(cached.syncData, sourceDirectory)
        return .latest(latest, refreshMusic: mayCaptureMusic && !hasCurrentCatalog, sourceDatabase: sourceDatabase,
                       hasCurrentCatalog: hasCurrentCatalog)
    }

    /// 창으로 돌아왔을 때 다시 읽을 것
    public enum Change: Sendable, Equatable {
        case none
        /// rekordbox의 iTunes 동기화 선택만 바뀌었다(같은 사본을 Music과 함께 다시 읽는다)
        case musicSelection
        /// 라이브러리가 바뀌었다(새 사본을 뜬다)
        case library
    }

    /// 지금 읽은 사본 뒤에 rekordbox가 라이브러리나 iTunes 동기화 선택을 바꿨는지
    /// - Parameter musicSyncData: 지금 보이는 목록의 동기화 원문
    /// - Parameter refreshingMusic: 이 읽기의 Music 최신화가 이미 돌고 있다
    public func change(since snapshot: URL, location: LibraryLocation, musicSyncData: Data?, refreshingMusic: Bool) -> Change {
        if source.changed(snapshot, location.liveDatabase) {
            source.log("rekordbox 라이브러리가 바뀌어 다시 읽습니다")
            return .library
        }
        guard location.mayCaptureMusic, !refreshingMusic,
              music.selectionChanged(musicSyncData, location.rekordboxDirectory) else { return .none }
        return .musicSelection
    }

    /// 사본을 라이브 rekordbox에서 뜬 것이면 그 원본 DB(Music 목록 사본·동기화 선택을 원본 폴더에서 본다). 명시한 사본은 nil
    public func sourceDatabase(of snapshot: URL, location: LibraryLocation) -> URL? {
        !location.opensExplicitCopy && snapshot.deletingLastPathComponent().isSameDirectory(as: location.snapshotDirectory)
            ? location.liveDatabase : nil
    }

    /// 새 사본을 뜨기 전에 붙들 지금 목록(같은 초에 사본 이름을 다시 써도 마지막 정상 iTunes 사본을 잃지 않게 먼저 읽는다)
    public func previousMusic(current snapshot: URL?, snapshotDirectory: URL, location: LibraryLocation,
                              refreshMusic: Bool) -> LoadedLibrary.ITunesFallback? {
        guard !location.opensExplicitCopy, let snapshot,
              snapshot.deletingLastPathComponent().isSameDirectory(as: snapshotDirectory) else { return nil }
        let sourceDatabase = snapshotDirectory.isSameDirectory(as: location.snapshotDirectory) ? location.liveDatabase : nil
        return LoadedLibrary.ITunesFallback(source: snapshot, contents: music.cached(snapshot), preferOverCurrent: !refreshMusic,
                                            sourceDatabase: sourceDatabase)
    }

    // MARK: - 사본

    /// 라이브 DB에서 읽기용 스냅샷 사본을 뜬다(메인 밖에서 부른다). `force`면 rekordbox가 켜져 있거나 WAL이 남아 있어도 뜬다
    public func takeSnapshot(force: Bool) throws -> URL { try snapshots.take(force) }

    /// rekordbox가 켜져 있는지(켜져 있으면 사본을 억지로 뜬다: 사본 안에서 WAL을 합친다)
    public func isRekordboxRunning() -> Bool { source.isRekordboxRunning() }

    /// 사본 지문(메인 밖에서 뜬다). 뜨지 못하면 nil
    public func usbStamp(of snapshot: URL) async -> UsbSyncSnapshotProvenance? {
        let usbSnapshots = usbSnapshots
        return try? await Self.background { try usbSnapshots.stamp(snapshot) }
    }

    /// 지문이 그대로인 사본에서 USB 작업 전용 사본을 빌린다(메인 밖에서). 사본이 바뀌었거나 뜨지 못하면 nil
    /// - Parameter directory: 빌린 사본을 둘 폴더(nil이면 실제 구현의 기본 폴더, 시험은 임시 폴더)
    public func leaseUsbSnapshot(_ provenance: UsbSyncSnapshotProvenance, directory: URL?) async -> UsbSyncSnapshotLease? {
        let usbSnapshots = usbSnapshots
        return try? await Self.background { try usbSnapshots.lease(provenance, directory) }
    }

    // MARK: - Music 채택 순서

    /// 이 사본들에 걸린 Music 결과 채택을 무른다(새 사본을 뜨기 전·뜬 뒤)
    public func invalidateMusic(_ snapshots: [URL]) { order.invalidateSnapshots(snapshots) }

    /// 메인 액터에서 정한 Music 결과 채택 순서(캡처가 끝날 때까지 유지한다)
    public func musicTicket(snapshot: URL, sourceDatabase: URL?) -> ITunesRefreshCoordinator.Ticket {
        order.begin(snapshot: snapshot, sourceDatabase: sourceDatabase)
    }

    /// 동기화 선택 창의 Music 전체 목록을 조회한다(걸린 시간을 남기지 않는다, 메인 밖에서)
    /// - Parameter capture: Music 조회(없으면 Music 포트). 시험이 바꿔 넣는다
    public func captureCatalog(_ capture: (@Sendable () -> ITunesLibrarySnapshot)? = nil) -> ITunesLibrarySnapshot {
        capture?() ?? music.capture()
    }

    // MARK: - 한 번 읽기(흐름)

    /// 한 번 읽은 결과
    public struct Opened: Sendable {
        public var loaded: LoadedLibrary
        /// 읽기 전에 옮긴 손상 초안 파일(`settled`로 이미 넘겼다. 화면이 메모리 입력을 다시 저장할 때 쓴다)
        public var moved: [DamagedDraftFile]
        /// 읽는 동안 사본이 그대로였으면 그 지문(USB 작업 사본의 출처). 바뀌었거나 뜨지 못하면 nil
        public var usbSnapshot: UsbSyncSnapshotProvenance?
        /// 읽는 동안 사본이 그대로였으면 그 사본의 USB 짝짓기 키. 바뀌었거나 읽지 못하면 nil
        public var localKeys: LocalLibraryKeys?
    }

    /// 사본 하나를 읽는 흐름: 걸린 초안 저장을 끝내고 손상된 초안 파일을 옮긴 뒤(빈 값으로 읽어 덮지 않게, #174) 화면에 옮긴 파일을 넘기고,
    /// 화면이 계속하라고 하면 사본 지문을 앞뒤로 떠서 그 사이에 읽는다(파일 교체가 읽기와 겹치면 USB 작업 사본의 출처로 쓰지 않는다).
    /// 저장 끝내기·읽기·지문은 메인 밖에서 한다.
    /// - Parameters:
    ///   - preservingDamaged: 읽지 못하는 초안 파일을 옮겨 보관할지(데이터 폴더를 정한 저장소만)
    ///   - settled: 옮긴 파일을 받아 알리고 계속 읽을지 답한다(새 읽기가 시작됐거나 취소됐으면 거짓). 거짓이면 읽지 않고 nil
    ///   - capture: Music 조회(없으면 Music 포트). 시험이 바꿔 넣는다
    public func open(_ request: Request, preservingDamaged: Bool,
                     settled: @escaping @MainActor @Sendable ([DamagedDraftFile]) -> Bool,
                     progress: @escaping @Sendable (LoadedLibrary.Stage) -> Void = { _ in },
                     capture: (@Sendable () -> ITunesLibrarySnapshot)? = nil) async throws -> Opened? {
        let loader = self
        let moved = try await Self.background { loader.settleDrafts(preservingDamaged: preservingDamaged) }
        guard await settled(moved) else { return nil }
        let before = await usbStamp(of: request.snapshot)
        let loaded = try await Self.background { try loader.read(request, progress: progress, capture: capture) }
        let keys: LocalLibraryKeys?
        if let localKeys { keys = try? await Self.background { try localKeys.load(request.snapshot) } } else { keys = nil }
        let after = await usbStamp(of: request.snapshot)
        // 파일 교체가 읽기와 겹치면 일반 화면은 유지하되, 그 사본의 지문·짝짓기 키는 채택하지 않는다
        let stable = before != nil && before == after
        return Opened(loaded: loaded, moved: moved, usbSnapshot: before == after ? before : nil, localKeys: stable ? keys : nil)
    }

    /// 읽은 뒤 맞춘 초안
    public struct Reconciled: Sendable {
        /// 고른 태그 초안과 base를 옮겨 저장한 초안·충돌 수
        public var tags: WatchDrafts.TagReload
        /// 저장을 기다리는 입력(디스크보다 최신이라 표시는 이것을 따른다)
        public var unsaved: UnsavedDrafts
        public var artworkDrafts: [String: ArtworkDraft]
        public var mergeDrafts: [DuplicateMergeDraft]
    }

    /// 읽은 결과를 화면에 넣기 전에 초안을 맞춘다: 태그 초안을 고르고(동기화면 충돌하지 않는 초안의 base를 새 rekordbox 값으로 옮겨 저장하고
    /// 저장을 끝낸다), 합치기 초안과 저장 대기 입력을 읽는다. 읽는 동안 그림 초안을 고쳤으면(저장은 바로 끝난다) 읽은 값 대신 지금 디스크를 쓴다.
    /// - Parameters:
    ///   - memoryTags: 화면의 태그 초안(읽는 동안 고쳤거나 저장에 실패한 입력은 디스크의 옛 값으로 덮지 않는다)
    ///   - failedTags: 이 화면이 저장을 맡겼다가 실패한 태그 초안 곡
    @MainActor
    public func reconcileDrafts(_ loaded: LoadedLibrary, memoryTags: [String: TagDraft], editedDuringRead: Bool, failedTags: Set<String>,
                                synchronizing: Bool, artworkChanged: Bool) -> Reconciled {
        // 지금 rekordbox 값은 읽은 곡 행에서 본다. 라이브러리에 없는 곡(추가 목록 곡, 넣은 뒤 연결이 끊긴 초안)은 비교할 값이 없어 충돌로 세지 않는다(#175).
        let current = Dictionary(loaded.rows.map { ($0.track.uuid, $0.tagFields) }, uniquingKeysWith: { first, _ in first })
        let tags = WatchDrafts.reloadedTags(loaded: loaded.tagDrafts, memory: memoryTags, editedDuringRead: editedDuringRead,
                                            failed: failedTags, synchronizing: synchronizing) { current[$0] }
        if !tags.rebased.isEmpty {
            drafts.saveTags(tags.rebased)
            drafts.flush()
        }
        return Reconciled(tags: tags, unsaved: drafts.unsaved(),
                          artworkDrafts: artworkChanged ? drafts.artworkDrafts() : loaded.artworkDrafts, mergeDrafts: drafts.mergeDrafts())
    }

    // MARK: - 읽기

    /// 초안 파일을 읽기 전: 걸린 저장을 끝내고, 손상된 초안 파일을 옮겨 보관한다(빈 값으로 읽어 덮지 않게, #174). 옮긴 파일을 돌려준다
    public func settleDrafts(preservingDamaged: Bool) -> [DamagedDraftFile] {
        drafts.flush()
        return preservingDamaged ? drafts.preserveDamaged() : []
    }

    /// 사본 하나를 읽는다(메인 밖에서)
    public struct Request: Sendable {
        public var snapshot: URL
        public var commentPreset: CommentPreset = .none
        /// Music을 지금 조회한다. 아니면 사본 옆 목록·이전 목록을 쓴다
        public var refreshMusic = false
        public var previousMusic: LoadedLibrary.ITunesFallback?
        /// 이전 스냅샷의 목록을 찾을 폴더(새 사본에 목록이 없을 때)
        public var fallbackDirectory: URL
        /// 메인 액터에서 정한 Music 채택 순서(없으면 여기서 받는다)
        public var ticket: ITunesRefreshCoordinator.Ticket?
        public var sourceDatabase: URL?
        /// 변속 흐름을 읽을 분석 파일 뿌리
        public var shareRoot: URL?

        public init(snapshot: URL, commentPreset: CommentPreset = .none, refreshMusic: Bool = false,
                    previousMusic: LoadedLibrary.ITunesFallback? = nil, fallbackDirectory: URL,
                    ticket: ITunesRefreshCoordinator.Ticket? = nil, sourceDatabase: URL? = nil, shareRoot: URL? = nil) {
            self.snapshot = snapshot
            self.commentPreset = commentPreset
            self.refreshMusic = refreshMusic
            self.previousMusic = previousMusic
            self.fallbackDirectory = fallbackDirectory
            self.ticket = ticket
            self.sourceDatabase = sourceDatabase
            self.shareRoot = shareRoot
        }
    }

    /// 사본의 DB·초안·Music 목록을 읽어 곡 목록 한 값으로 만든다(메인 밖에서 부른다)
    /// - Parameter capture: Music 조회(없으면 `music.capture`). 시험이 바꿔 넣는다
    public func read(_ request: Request, progress: @Sendable (LoadedLibrary.Stage) -> Void = { _ in },
                     capture: (@Sendable () -> ITunesLibrarySnapshot)? = nil) throws -> LoadedLibrary {
        let ticket = request.ticket ?? order.begin(snapshot: request.snapshot, sourceDatabase: request.sourceDatabase)
        let library = try LoadedLibrary.Stage.database.measure(progress: progress, log: source.log) {
            try source.library(request.snapshot)
        }
        let tracks = library.tracks
        let iTunes = readMusic(snapshot: request.snapshot, refreshMusic: request.refreshMusic, previous: request.previousMusic,
                               fallbackDirectory: request.fallbackDirectory, ticket: ticket, sourceDatabase: request.sourceDatabase,
                               progress: progress, capture: capture)
        progress(.tracks)
        let tracksStarted = ContinuousClock.now
        defer { LoadedLibrary.Stage.tracks.logElapsed(since: tracksStarted, log: source.log) }
        // 변속 흐름: 분석 파일의 그리드를 훑는다(실제 구현은 병렬, 7천 곡 약 0.2~0.7초).
        let tempo = source.tempoChanges(tracks, request.shareRoot)
        let rule = request.commentPreset.rule
        let listed = Set(library.playlists.filter { !$0.isFolder }.flatMap(\.trackIDs))
        let rows = tracks.enumerated().map { i, track in
            var row = TrackRow(track: track, cues: library.cues(for: track), playCount: library.playCounts[track.id, default: 0],
                               tempoChanges: i < tempo.count ? tempo[i] : [], autoGain: library.autoGains[track.id], commentRule: rule)
            row.inPlaylist = listed.contains(track.id)
            return row
        }
        var counts: [LibraryFilter: Int] = [:]
        for filter in LibraryFilter.visible(commentPreset: request.commentPreset) { counts[filter] = rows.lazy.filter(filter.includes).count }
        // 초안은 이 저장소의 초안 폴더에서만 읽는다(다른 폴더의 초안이 섞이지 않게)
        let draftIndex = WatchDrafts(drafts: drafts).load(autoCues: Dictionary(rows.map { ($0.track.uuid, $0.cues) }, uniquingKeysWith: { a, _ in a }))
        var draftCueCounts: [String: CueCounts] = [:]
        var draftPreviewCues: [String: [PreviewCueMark]] = [:]
        for (uuid, draft) in draftIndex.cueDrafts {
            draftCueCounts[uuid] = CueCounts(draft)
            if draft.hasChanges { draftPreviewCues[uuid] = draft.cues.map(PreviewCueMark.init) }
        }
        var loaded = LoadedLibrary(rows: rows, report: LibraryReport(library: library, commentRule: rule), filterCounts: counts,
                                   tagDrafts: draftIndex.tagDrafts, cueDraftUUIDs: draftIndex.cueDraftUUIDs,
                                   gridDraftUUIDs: draftIndex.gridDraftUUIDs, gainDraftUUIDs: draftIndex.gainDraftUUIDs,
                                   playlists: PlaylistLayout(rekordbox: library.playlists),
                                   playlistDraft: draftIndex.playlistDraft,
                                   histories: library.histories,
                                   draftCueCounts: draftCueCounts, draftPreviewCues: draftPreviewCues,
                                   duplicateGroups: LibraryRecords.duplicates(in: library).groups,
                                   iTunesLibrary: SyncedITunesLibrary(snapshot: iTunes, tracks: tracks), iTunesSnapshot: iTunes)
        loaded.artworkDrafts = draftIndex.artworkDrafts
        loaded.artworkFiles = library.artworkFiles
        loaded.colors = library.colors
        loaded.smartPlaylists = Dictionary(library.playlists.compactMap { playlist in playlist.smartSource.map { (playlist.id, $0) } },
                                           uniquingKeysWith: { first, _ in first })
        return loaded
    }

    /// DB를 다시 읽지 않고 Music 결과만 채택한다. 캡처 전 발급한 요청 순서로 늦은 결과를 거른다(메인 밖에서 부른다).
    /// - Parameter captured: 따로 끝낸 Music 조회 결과. 있으면 여기서 다시 조회하지 않는다.
    public func readMusic(snapshot: URL, refreshMusic: Bool = false, captured alreadyCaptured: ITunesLibrarySnapshot? = nil,
                          previous: LoadedLibrary.ITunesFallback? = nil, fallbackDirectory: URL,
                          ticket: ITunesRefreshCoordinator.Ticket? = nil, sourceDatabase: URL? = nil,
                          progress: @Sendable (LoadedLibrary.Stage) -> Void = { _ in },
                          capture: (@Sendable () -> ITunesLibrarySnapshot)? = nil) -> ITunesLibrarySnapshot {
        let ticket = ticket ?? order.begin(snapshot: snapshot, sourceDatabase: sourceDatabase)
        let capture = capture ?? music.capture
        let captured = refreshMusic ? alreadyCaptured ?? LoadedLibrary.Stage.music.measure(progress: progress, log: source.log, capture) : nil
        progress(.iTunes)
        let iTunesStarted = ContinuousClock.now
        let iTunes = order.commit(ticket, snapshot: snapshot, current: {
            let current = currentMusic(snapshot: snapshot, sourceDatabase: sourceDatabase)
            return recoverCurrentSelection(current, snapshot: snapshot, sourceDatabase: sourceDatabase, previous: previous)
        }) {
            let local = music.cached(snapshot)
            let rawCurrent = currentMusic(snapshot: snapshot, sourceDatabase: sourceDatabase)
            let current = captured == nil
                ? recoverCurrentSelection(rawCurrent, snapshot: snapshot, sourceDatabase: sourceDatabase, previous: previous) : rawCurrent
            var result: ITunesLibrarySnapshot
            if let captured {
                result = captured.status == .ready ? captured : staleMusic(current: current, snapshot: snapshot, previous: previous,
                                                                           fallbackDirectory: fallbackDirectory, sourceDatabase: sourceDatabase)
            } else {
                result = current
                // 쓰기 후 Music을 다시 읽지 않아도, 앞서 Music을 조회해 실패했으면 그 실패를 이어 간다(사본 파일은 미캡처로 남는다).
                // 조회한 적 없는 사본(`DJC_REKORDBOX_DIR`·`--db`)의 미캡처는 그대로 둔다: 읽는 중은 `.loading`이 따로 있어
                // 미캡처는 "캡처한 목록이 없다"만 뜻하고, 접근 권한 안내로 바꾸면 조회하지도 않은 Music 탓이 된다(#197).
                if result.status == .notCaptured, let previous, previous.preferOverCurrent,
                   sameSource(previous, snapshot: snapshot, sourceDatabase: sourceDatabase),
                   previous.contents.status == .unavailable {
                    result.status = .unavailable
                }
            }
            if let sync = syncFile(snapshot: snapshot, sourceDatabase: sourceDatabase), result.status == .ready {
                do { result = try music.applySelection(result, sync.get()) }
                catch { result.status = .stale }
            }
            let shouldSave = captured != nil || (sourceDatabase != nil && result.syncData != local.syncData)
            // 새 DB 사본에도 재사용한 목록을 남긴다. 같은 초에 교체되거나 정상 자료가 낡음 상태여도 보존한다.
            let reusedSnapshot = captured == nil && previous.map {
                sameSource($0, snapshot: snapshot, sourceDatabase: sourceDatabase)
            } == true && result != local && (result.status == .ready || result.status == .stale)
            if (result.status == .ready && shouldSave) || reusedSnapshot {
                do { try music.save(result, snapshot) }
                catch {
                    if captured != nil {
                        result = staleMusic(current: current, snapshot: snapshot, previous: previous,
                                            fallbackDirectory: fallbackDirectory, sourceDatabase: sourceDatabase)
                    }
                }
            }
            return result
        }
        LoadedLibrary.Stage.iTunes.logElapsed(since: iTunesStarted, log: source.log)
        return iTunes
    }

    /// Music 보관함만 조회한다(걸린 시간을 남긴다, 메인 밖에서 부른다). 채택은 `readMusic(captured:)`가 한다
    /// - Parameter capture: Music 조회(없으면 `music.capture`)
    public func captureMusic(_ capture: (@Sendable () -> ITunesLibrarySnapshot)? = nil) -> ITunesLibrarySnapshot {
        LoadedLibrary.Stage.music.measure(progress: { _ in }, log: source.log, capture ?? music.capture)
    }

    /// 동기화 선택 창에 바로 쓸 수 있는 목록인지: 전체 보관함이 있고 그 rekordbox 폴더의 동기화 선택이 그대로다
    public func isCurrentCatalog(_ value: ITunesLibrarySnapshot, directory: URL) -> Bool {
        value.status == .ready && value.sourcePlaylists != nil && !music.selectionChanged(value.syncData, directory)
    }

    /// 선택 창을 처음 열 때의 선택(동기화 원문에서 맨 위를 골랐는지 본다)
    public func initialSelection(of snapshot: ITunesLibrarySnapshot) -> ITunesSyncSelection {
        snapshot.initialSelection(rootSelected: snapshot.syncData.map(music.rootSelected) ?? false)
    }

    // MARK: - iTunes 동기화 뒤

    /// iTunes 동기화를 쓴 뒤 남길 목록 사본
    public struct SyncedSelection: Sendable {
        /// 쓴 동기화 선택을 적용한 목록(화면이 보일 값)
        public var selected: ITunesLibrarySnapshot
        /// 지금 보는 사본이 동기화한 라이브러리에서 뜬 것이라 화면 목록을 바꿔도 된다
        public var sameSource: Bool
        /// 목록 사본을 남기지 못한 곳이 있다
        public var saveFailed: Bool
    }

    /// 쓴 동기화 선택을 목록에 적용하고, 동기화한 DB(사본 실행이면 그 사본)와 지금 보는 사본 옆에 목록 사본을 남긴다.
    /// 다른 읽기가 낡은 목록을 채택하지 않게 같은 잠금 안에서 순서를 올린다.
    /// - Parameters:
    ///   - database: 동기화 창을 연 사본(쓰기를 요청한 곳)
    ///   - target: 실제로 쓴 rekordbox DB
    ///   - active: 지금 화면이 보는 사본
    public func publishSync(source: ITunesLibrarySnapshot, syncData: Data, database: URL, target: URL, active: URL?,
                            location: LibraryLocation) throws -> SyncedSelection {
        let selected = try music.applySelection(source, syncData)
        let sameSource = !location.opensExplicitCopy
            && active.map { $0.deletingLastPathComponent().isSameDirectory(as: location.snapshotDirectory) } == true
        let mayCacheDatabase = location.rekordboxDirectoryOverridden
            || !database.deletingLastPathComponent().isSameDirectory(as: location.rekordboxDirectory)
        let destinations = Set((mayCacheDatabase ? [database] : []) + (sameSource ? [active].compactMap { $0 } : []))
        let invalidated = Set(Array(destinations) + [target, database])
        var saveFailed = false
        order.publish(sources: Array(invalidated)) {
            for destination in destinations {
                do { try music.save(selected, destination) }
                catch { saveFailed = true }
            }
        }
        return SyncedSelection(selected: selected, sameSource: sameSource, saveFailed: saveFailed)
    }

    // MARK: - Music 사본 규칙

    private func currentMusic(snapshot: URL, sourceDatabase: URL?) -> ITunesLibrarySnapshot {
        let local = music.cached(snapshot)
        guard let sourceDatabase else { return applyingCurrentSelection(local, snapshot: snapshot, sourceDatabase: nil) }
        let sourceCopy = music.cached(sourceDatabase)
        let currentSync = syncData(snapshot: snapshot, sourceDatabase: sourceDatabase)
        let base: ITunesLibrarySnapshot
        if local.status == .ready, currentSync != nil, local.syncData == currentSync {
            base = local
        } else if sourceCopy.status == .ready {
            base = sourceCopy
        } else if local.status == .ready {
            base = local
        } else {
            base = sourceCopy.status == .stale ? sourceCopy : local
        }
        return applyingCurrentSelection(base, snapshot: snapshot, sourceDatabase: sourceDatabase)
    }

    private func recoverCurrentSelection(_ value: ITunesLibrarySnapshot, snapshot: URL, sourceDatabase: URL?,
                                         previous: LoadedLibrary.ITunesFallback?) -> ITunesLibrarySnapshot {
        let current = applyingCurrentSelection(value, snapshot: snapshot, sourceDatabase: sourceDatabase)
        guard let previous, sameSource(previous, snapshot: snapshot, sourceDatabase: sourceDatabase),
              previous.contents.status == .ready || previous.contents.status == .stale else { return current }
        let syncData = syncData(snapshot: snapshot, sourceDatabase: sourceDatabase)
        let previousMatchesSync = syncData != nil && previous.contents.syncData == syncData
        let diskMatchesSync = readySnapshotMatchesSync(snapshot: snapshot, sourceDatabase: sourceDatabase, syncData: syncData)
        // 현재 선택과 맞는 정상 사본이 있으면 이전 메모리 선택의 강제 우선권도 적용하지 않는다.
        if current.status == .ready && diskMatchesSync { return current }
        guard previous.preferOverCurrent || current.status != .ready
                || (previousMatchesSync && !diskMatchesSync) else { return current }
        return applyingCurrentSelection(previous.contents, snapshot: snapshot, sourceDatabase: sourceDatabase)
    }

    private func sameSource(_ previous: LoadedLibrary.ITunesFallback, snapshot: URL, sourceDatabase: URL?) -> Bool {
        guard previous.source.deletingLastPathComponent().isSameDirectory(as: snapshot.deletingLastPathComponent()) else { return false }
        guard let expected = previous.sourceDatabase else { return true }
        return sourceDatabase?.standardizedFileURL.path == expected.standardizedFileURL.path
    }

    /// 동기화 선택 원문(`playlists3.sync`, 원본 DB가 있으면 그 폴더). 파일이 없으면 nil
    private func syncFile(snapshot: URL, sourceDatabase: URL?) -> Result<Data, any Error>? {
        music.syncFile((sourceDatabase ?? snapshot).deletingLastPathComponent())
    }

    private func syncData(snapshot: URL, sourceDatabase: URL?) -> Data? {
        try? syncFile(snapshot: snapshot, sourceDatabase: sourceDatabase)?.get()
    }

    private func readySnapshotMatchesSync(snapshot: URL, sourceDatabase: URL?, syncData: Data?) -> Bool {
        guard let syncData else { return false }
        let local = music.cached(snapshot)
        let sourceCopy = sourceDatabase.map { music.cached($0) }
        return ([local, sourceCopy].compactMap { $0 }).contains { $0.status == .ready && $0.syncData == syncData }
    }

    private func applyingCurrentSelection(_ value: ITunesLibrarySnapshot, snapshot: URL,
                                          sourceDatabase: URL?) -> ITunesLibrarySnapshot {
        guard value.status == .ready, let sync = syncFile(snapshot: snapshot, sourceDatabase: sourceDatabase) else { return value }
        do { return try music.applySelection(value, sync.get()) }
        catch { var stale = value; stale.status = .stale; return stale }
    }

    private func staleMusic(current: ITunesLibrarySnapshot, snapshot: URL, previous: LoadedLibrary.ITunesFallback?,
                            fallbackDirectory: URL, sourceDatabase: URL?) -> ITunesLibrarySnapshot {
        var fallback = current
        let syncData = syncData(snapshot: snapshot, sourceDatabase: sourceDatabase)
        let hasCurrentReadySnapshot = current.status == .ready
            && readySnapshotMatchesSync(snapshot: snapshot, sourceDatabase: sourceDatabase, syncData: syncData)
        var usedPreferredPrevious = false
        if let previous, previous.preferOverCurrent, !hasCurrentReadySnapshot,
           sameSource(previous, snapshot: snapshot, sourceDatabase: sourceDatabase),
           previous.contents.status == .ready || previous.contents.status == .stale {
            fallback = previous.contents
            usedPreferredPrevious = true
        }
        if fallback.status != .ready && fallback.status != .stale {
            // 명시한 이전 사본은 같은 스냅샷 폴더일 때만 쓴다. 서로 다른 DB 출처를 섞지 않는다.
            if let previous, sameSource(previous, snapshot: snapshot, sourceDatabase: sourceDatabase),
               previous.contents.status == .ready || previous.contents.status == .stale {
                fallback = previous.contents
            }
            if fallback.status != .ready && fallback.status != .stale,
               snapshot.deletingLastPathComponent().isSameDirectory(as: fallbackDirectory) {
                let files = source.snapshots(fallbackDirectory)
                    .filter { $0.pathExtension == "db" && $0.lastPathComponent.hasPrefix("master-")
                        && $0.lastPathComponent < snapshot.lastPathComponent }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                fallback = files.lazy.map { music.cached($0) }
                    .first { $0.status == .ready || $0.status == .stale } ?? fallback
            }
        }
        guard fallback.status == .ready || fallback.status == .stale else { return ITunesLibrarySnapshot(status: .unavailable) }
        fallback.status = .stale
        // 새 DB 사본에만 낡음 표시를 저장한다. 기존 정상/손상 sidecar는 실패로 덮어쓰지 않는다.
        if current.status == .notCaptured || usedPreferredPrevious { try? music.save(fallback, snapshot) }
        return fallback
    }
}

extension LoadLibrary {
    /// 동기 읽기·복사를 메인 밖 스레드에서 돌린다. 기다리는 동안 협력 스레드 풀을 붙잡지 않는다(`BlockingWork`).
    public static func background<Value: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                                   _ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await BlockingWork.run(qos: qos, operation)
    }
}
