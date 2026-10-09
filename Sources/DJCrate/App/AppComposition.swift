import DJCAdapters
import DJCAnalysis
import DJCApplication
import DJCDomain
import DJCEnvironment
import DJCStorage
import Foundation
import RekordboxKit
import SwiftUI

/// 비정상 종료 뒤 남은 임시 파일·폴더(#219)는 프로세스당 한 번만 치운다(전역 지연 초기화라 한 번만 실행된다).
private let tempCleanupOnce: Void = DJCTempCleanup.runAndLog()

/// 앱 조립 지점: 실행 인자·환경을 한 번 풀어 라이브러리 위치(rekordbox 쓰기 대상·읽기 출처·초안 폴더)를 정하고,
/// 설정·초안 저장 큐·쓰기 관문·스냅샷 뜨기를 한 곳에서 만들어 라이브러리 저장소·덱·창에 넘기고 서로 잇는다.
/// 포트의 실제 구현(`.live`)은 여기서만 고른다. 시험은 저장소·덱을 직접 만들어 가짜를 넣는다(`LibraryStore.test`).
@MainActor
final class AppComposition {
    /// 저장소·덱·설정 창이 함께 쓰는 설정 하나
    let settings: SettingsStore
    let store: LibraryStore
    let deck: DeckModel
    let windows: AppWindows
    /// rekordbox 쓰기의 화면 쪽(반영 세션을 부르고 결과를 보인다). 메뉴·목록·사이드바·창이 함께 쓴다.
    let reflection: ReflectionCoordinator
    /// 곡 목록 오른쪽 클릭 메뉴가 시작하는 흐름(쓰기·XML·USB 초안)
    let trackListActions: TrackListActions
    /// 덱 단축키(창이 처음 나타날 때 붙인다)
    let keys = KeyRouter()
    private var connected = false

    init(settings: SettingsStore, store: LibraryStore, deck: DeckModel, windows: AppWindows, reflection: ReflectionCoordinator) {
        self.settings = settings
        self.store = store
        self.deck = deck
        self.windows = windows
        self.reflection = reflection
        trackListActions = .live(store: store, reflection: reflection)
    }

    /// 이미 만든 저장소·덱으로 주 창을 띄울 때(화면 시험). 설정은 저장소의 것, 창은 새로 만들고 쓰기는 실제 관문으로 잇는다.
    convenience init(store: LibraryStore, deck: DeckModel) {
        self.init(settings: store.settings, store: store, deck: deck, windows: AppWindows(), reflection: Self.reflection(store: store))
    }

    /// 옛 이름(anicue) 데이터·설정 옮기기. 앱이 시작할 때 목록·덱이 설정을 읽기 전에 한 번 부른다(`DJCrateApp`의 첫 속성)
    nonisolated static func migrateLegacyData() {
        #if DEBUG
        // 합성 사본 자가 테스트가 사용자 폴더·설정을 옮기지 않게 한다.
        if CommandLine.arguments.contains("--history-selftest") { return }
        #endif
        LegacyMigration.run()
    }

    /// 실제 앱. 위치는 실행 인자·환경에서 한 번 푼다(`LibraryLocation.resolve`): 초안은 데이터 폴더(`DJC_HOME`을 따른다),
    /// 쓰기·복원 대상은 rekordbox 라이브러리(`DJC_REKORDBOX_DIR`을 따른다)의 master.db와 그 옆 share다(#182: 대상은 이 한 곳에서 정한다).
    static func live() -> AppComposition {
        let info = ProcessInfo.processInfo
        // CLI와 함께 따르는 설정(시점 스냅샷 보관 일수)은 데이터 폴더의 공유 파일에도 적는다
        let settings = SettingsStore(sharedFile: .live)
        let location = LibraryLocation.resolve(arguments: info.arguments, environment: info.environment)
        // 초안 저장 큐는 하나다: 저장소·덱·반영·복구·그리드 추정이 모두 같은 큐로 쓴다(게인 초안은 모든 곡이 파일 하나라 순서가 지켜져야 한다).
        let drafts = DraftStore.live(writer: DraftWriter(), home: location.draftHome)
        let places = DraftLocations(home: location.draftHome)
        let ports = LibraryPorts.live(location: location, drafts: drafts, batches: .live(url: places.reflection))
        let store = LibraryStore(settings: settings, location: location, useCases: LibraryUseCases(ports: ports),
                                 resultHistory: WriteResultHistory(url: places.writeResult),
                                 launch: LibraryLaunchOptions(arguments: info.arguments))
        // 재생 기록 쓰기 관문(#43): 사본 재현으로 연 쓰기 경로. 닫혀 있으면 보존·보기만 하고 쓰기 대기에 올리지 않는다
        store.writesHistories = RekordboxWriter.writesHistories
        // 덱은 저장소와 같은 초안 저장소(같은 저장 큐)·설정을 쓴다(읽기는 메인 밖에서 실제 파일을 본다).
        let storage = DeckStorage(drafts: drafts, settings: settings)
        let deck = DeckModel(audio: DeckAudio(), storage: storage, assets: .live(drafts: drafts), analysis: deckAnalysis(), runsAnalysis: true)
        return AppComposition(settings: settings, store: store, deck: deck, windows: AppWindows(), reflection: reflection(store: store))
    }

    /// rekordbox 쓰기를 잇는다: 반영 세션(DJCApplication)의 포트에 실제 구현(관문·백업 폴더·음원·실행 중인 앱, DJCAdapters)과
    /// 이 저장소의 상태·잠금·다시 읽기, 확인 창(`prompter`), 결과 보이기(`ReflectionPresenter`)를 붙이고 화면 쪽 조정자를 만든다.
    /// 시험은 관문·백업 폴더 쓰기·확인 창·실행 중인 앱을 바꿔 넣는다.
    static func reflection(store: LibraryStore, gate: RekordboxWriteGate = .live(), backups: RekordboxBackups = .live(),
                           audio: TrackAudioReader = .live(loudness: { await AppComposition.loudness(of: $0) }),
                           prompter: any ReflectionPrompter = AlertPrompter(), runningApps: RunningApps = .live,
                           options: ReflectionSession.Options = .liveApp) -> ReflectionCoordinator {
        let presenter = ReflectionPresenter(store: store, prompter: prompter)
        let library = ReflectionLibrary(state: { [weak store] in store?.reflectionState() ?? ReflectionLibraryState() },
                                        apply: { [weak store] in store?.applyReflection($0) },
                                        retryTagSaves: { [weak store] in store?.retryFailedTagSaves() },
                                        preserveDamagedDrafts: { [weak store] in store?.preserveDamagedDraftFiles() ?? [] },
                                        savePlaylistDraft: { [weak store] in store?.ensurePlaylistDraftSaved() ?? true },
                                        recordHistories: { [weak store] in await store?.recordWrittenHistories($0) })
        let lock = WriteLock(isLocked: { [weak store] in store?.isWritingRekordbox ?? false },
                             set: { [weak store] locked, deck in store?.setWriteLock(locked, deck: deck) },
                             stage: { [weak store] in store?.writeStage = $0 })
        // 반영 세션은 라이브러리와 같은 초안 저장 큐·스냅샷 뜨기·연결 기록을 쓴다(라이브러리 유스케이스 묶음에서 받는다).
        let ports = ReflectionPorts(gate: gate, backups: backups, sharing: store.useCases, audio: audio, library: library,
                                    reload: LibraryReloader { [weak store] written, edits in
                                        await store?.reloadAfterWrite(written: written, playlistEdits: edits) ?? false
                                    },
                                    lock: lock,
                                    confirmation: UserConfirmation(confirm: { prompter.show($0) }, choose: { prompter.choose($0) }),
                                    results: ReflectionResults { presenter.publish($0) }, runningApps: runningApps)
        let session = ReflectionSession(location: store.location, ports: ports, options: options)
        store.syncITunesWrite = { change, database in try await session.syncITunes(change, opened: database) }
        return ReflectionCoordinator(session: session, store: store, prompter: prompter)
    }

    /// 전에 잰 음량, 없으면 재서 캐시에 남긴다(재지 못하면 nil). 분석 붙이기와 곡 넣기가 같이 쓴다.
    static func loudness(of url: URL) async -> Loudness? {
        if let cached = LoudnessCache.shared.value(for: url) { return cached }
        let measured = try? await Task.detached(priority: .userInitiated) { try Loudness.measure(fileAt: url) }.value
        if let measured { LoudnessCache.shared.store(measured, for: url) }
        return measured
    }

    /// 덱 분석: DJCAnalysis 분석기와 이 프로세스의 캐시 폴더(`DJC_HOME`을 따른다). 음량 캐시는 목록과 함께 쓰는 하나다.
    static func deckAnalysis() -> AnalyzeDeckTrack {
        let cache = AnalysisStore.live(paths: .current, loudness: { LoudnessCache.shared.value(for: $0) },
                                       storeLoudness: { LoudnessCache.shared.store($0, for: $1) })
        return AnalyzeDeckTrack(analyzer: .live(paths: .current), cache: cache)
    }

    /// 편집본 쓰기: 편집본은 음악 폴더의 DJCrate 편집본(`DJC_HOME`을 주면 그 아래 edits), 추가한 곡·초안은 저장소의 초안 폴더(덱·목록과 같은 곳).
    /// 추가 목록은 저장소가 든 목록과 디스크를 한 길로 고친다(넣기와 목록 저장이 겹쳐 편집본 줄을 잃지 않게, adv2 N8).
    static func renderEdit(store: LibraryStore) -> RenderEdit {
        let staging = StagingStore(tracks: { [weak store] in store?.staged ?? [] },
                                   save: { [weak store] tracks in
                                       guard let store else { throw CancellationError() }
                                       try store.saveStaged(tracks)
                                   })
        return RenderEdit(files: .live(output: { DJCPaths.editOutput }),
                          stager: StageEdit(staging: staging, files: .live(home: store.draftFolder), now: { Date() }))
    }

    /// 주 창이 처음 나타날 때 한 번: 저장소와 덱, 단축키, 편집 창을 잇는다.
    func connect() {
        guard !connected else { return }
        connected = true
        let store = store, deck = deck, windows = windows
        deck.feedback = store.feedback
        store.recoveryMemoryInput = { [weak deck] uuid, kind in deck?.inputForDraftRecovery(uuid: uuid, kind: kind) }
        store.onDraftRecovered = { [weak deck, weak windows] draft, row, grid in
            deck?.applyDraftRecovery(draft, currentRow: row, currentGrid: grid)
            windows?.trackEdit.draftRecovered(draft.uuid)
        }
        // 목록 선택은 덱을 바꾸지 않는다. 더블클릭·⌘→·오른쪽 클릭·끌어다 놓기로만 덱에 올린다(#93).
        store.onLoadToDeck = { [weak deck] row in deck?.load(row) }
        // 덱이 분석 파일·그림을 읽는 곳을 쓰기 대상 라이브러리와 맞춘다.
        deck.shareRoot = { [weak store] in store?.shareRoot }
        store.confirmDeckReplacement = { [weak deck] _ in deck?.confirmDiscardingFlip() ?? true }
        store.allowsLibrarySync = { [weak deck] in
            guard let deck else { return true }
            return !deck.hasUncommittedCueEdits && deck.cueDragBase == nil && deck.gridDragBase == nil
        }
        store.onCueDraftsReloaded = { [weak deck] drafts in
            guard let deck, let uuid = deck.row?.track.uuid else { return }
            deck.reloadExternalCueDraft(drafts[uuid])
        }
        store.onGridDraftSaved = { [weak deck] uuid in deck?.gridDraftSavedExternally(uuid) }
        store.deckGridDraftState = { [weak deck] in
            guard let deck, let uuid = deck.row?.track.uuid else { return nil }
            return (uuid, deck.gridDraft?.hasChanges == true || deck.gridDragBase != nil)
        }
        store.adoptImportedGridDraft = { [weak deck] draft in deck?.adoptImportedGridDraft(draft) ?? false }
        deck.onStagedGridChange = { [weak store] uuid, bpm in store?.stagedGridChanged(uuid: uuid, bpm: bpm) }
        deck.onCueDraftChange = { [weak store] draft in store?.cueDraftChanged(draft) }
        deck.onReanalyze = { [weak store] uuid in store?.restoreKeySuggestion(uuid: uuid) }
        store.onWriteLock = { [weak deck] locked in deck?.isWriteLocked = locked }
        store.onRekordboxWritten = { [weak deck, weak store] uuids in
            // 처음부터 다시 불러오지 않고 초안·그리드·게인만 새 rekordbox 값으로 맞춘다(소리·파형은 그대로).
            guard let deck, let uuid = deck.row?.track.uuid, uuids.contains(uuid) else { return }
            deck.refreshAfterWrite(store?.rowsByUUID[uuid])
        }
        keys.install(deck: deck, store: store, windows: windows)
        let editLinks = EditWindowLinks(deck: deck, store: store, reflection: reflection, writer: Self.renderEdit(store: store),
                                        makeAudio: { EditAudioPlayer() },
                                        showStaged: { [weak store] staged, hasGrid in store?.showStagedEdit(staged, hasGrid: hasGrid) })
        windows.trackEdit.attach(editLinks)
        windows.flip.attach(editLinks)
        #if DEBUG
        DevSelfTests.runIfRequested(store: store, deck: deck, windows: windows, reflection: reflection)
        DevSelfTests.runAsyncGuidanceCaptureIfRequested(store: store, deck: deck)
        UsbMigrateCapture.runIfRequested(store: store)
        DevSelfTests.runKeyRoutingSelfTestIfRequested(store: store, deck: deck, windows: windows)
        #endif
        deck.onDraftChange = { [weak store] uuid, kind, exists in
            store?.draftChanged(trackUUID: uuid, kind: kind, exists: exists)
        }
    }

    /// 창을 띄운 뒤: 사이드바 USB 절을 붙이고, 읽을 때마다 도는 캐시 정리를 붙이고, 라이브러리를 처음 읽는다.
    func start() async {
        UsbAppSetup.attach(to: store)
        // CLI가 앱의 시점 스냅샷 보관 일수를 따르게 공유 파일에 맞춘다
        settings.syncShared()
        // 프로세스 전체의 캐시·임시 파일 정리는 앱만 한다(화면 모델·시험 저장소가 공용 음량 캐시를 자기 곡으로 잘라내지 않게).
        store.onLibraryLoaded = { paths in Self.maintainCaches(keeping: paths) }
        await store.loadInitial()
    }

    /// 시점 스냅샷 창의 유스케이스: 대상은 반영과 같은 곳(저장소의 rekordbox DB·share), 스냅샷은 데이터 폴더, 백업은 저장소의 백업 폴더
    static func pointSnapshots(store: LibraryStore) -> PointSnapshots {
        PointSnapshots(database: store.rekordboxDatabase, shareRoot: store.rekordboxShareRoot, directory: DJCPaths.pointSnapshots,
                       backupDirectory: store.backupDirectory, files: .live(), backups: .live())
    }

    /// 설정 › 저장 공간 화면 모델: 이 프로세스의 캐시 자리(`DJC_HOME`을 따른다)와 캐시 폴더. 앱이 연 사본은 남기고 rekordbox·USB 쓰기 중에는 막으며,
    /// 비울 때 앱 메모리의 음량·미리 보기 파형 캐시도 비우고(옛 값을 다시 저장하지 않게) 목록의 미리 보기 파형을 다시 채운다
    func storageSettings() -> StorageSettingsModel {
        let store = store
        let rekordbox = store.rekordboxDatabase.deletingLastPathComponent(), snapshots = DJCPaths.pointSnapshots
        let previews = store.useCases.previews
        return StorageSettingsModel(paths: .current, files: .live, settings: store.settings,
                                    openSnapshot: { [weak store] in store?.snapshotURL },
                                    busyReason: { [weak store] in
                                        guard let store else { return nil }
                                        return StorageSettingsModel.busyReason(store: store)
                                    },
                                    canClone: { RekordboxPointSnapshot.canClone(from: rekordbox, to: snapshots) },
                                    clearMemory: { [weak store] kinds in
                                        if kinds.contains(.loudness) { LoudnessCache.shared.clear() }
                                        if kinds.contains(.previewWaveforms) {
                                            store?.previewWarmTask?.cancel()
                                            await previews.clear()
                                        }
                                    },
                                    rebuild: { [weak store] kinds in
                                        if kinds.contains(.previewWaveforms) { store?.warmPreviewWaveforms() }
                                    })
    }

    /// 하루 한 번 자동 시점 스냅샷(#228): 대상은 반영과 같은 곳, 스냅샷은 데이터 폴더, 파일은 이 Mac의 가드로 본다
    func autoPointSnapshots() -> AutoPointSnapshotRunner {
        AutoPointSnapshotRunner(store: store, snapshots: DJCPaths.pointSnapshots, files: .live())
    }

    /// 라이브러리를 읽을 때마다: 라이브러리에 없는 곡의 음량 항목(#217, 추가한 곡의 경로는 남긴다)과 캐시 용량 상한(최근 사용 순)을
    /// 뒤에서 조용히 정리한다. 비정상 종료 뒤 남은 임시 파일·폴더(#219)는 처음 한 번만 치운다.
    static func maintainCaches(keeping libraryPaths: Set<String>) {
        Task(priority: .background) {
            let removed = await LoudnessCache.shared.prune(keeping: libraryPaths)
            if removed > 0 { FileHandle.standardError.write(Data("음량 캐시 정리 \(removed)개\n".utf8)) }
        }
        Task.detached(priority: .background) {
            CacheMaintenance.prune()
            _ = tempCleanupOnce
        }
    }
}

/// 앱에 하나씩 있는 보조 창. 조립 지점이 만들어 들고, 화면은 환경 값 `appWindows`로, 메뉴는 `AppCommandContext`로 받는다.
@MainActor
final class AppWindows {
    let trackEdit = TrackEditWindow()
    let flip = FlipWindow()
    let pointSnapshots = PointSnapshotWindow(points: AppComposition.pointSnapshots(store:))
    let appleMusicImport = AppleMusicImportWindow()
}

extension EnvironmentValues {
    /// 주 창 아래 화면이 여는 보조 창(곡 편집·Flip). 조립 지점이 붙이지 않은 화면(시험·미리 보기)에서는 nil이다.
    @Entry var appWindows: AppWindows? = nil
}
