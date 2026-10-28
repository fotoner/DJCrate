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
    /// 태그 인스펙터 화면 모델. 인스펙터를 닫았다 열어도 같은 모델을 쓴다(그림 칸 안내가 남는다).
    let tagInspector: TagInspectorModel
    /// 사이드바 재생 목록 칸 화면 모델(폴더 펼침·이름 바꾸기). 사이드바를 다시 그려도 같은 모델을 쓴다.
    let playlistSidebar: PlaylistSidebarModel
    /// 목록 아래 작업 막대 화면 모델(단추·막힘 이유, 파일 없음 확인의 결과·다시 확인)
    let listActionBar: ListActionBarModel
    /// 주 창 화면 모델(주 창이 띄우는 시트와 단추·메뉴 입구). 주 창을 다시 그려도 같은 모델을 쓴다.
    let libraryWindow: LibraryWindowModel
    /// 창 아래 상태 줄 화면 모델(#298): 활동 단추의 읽지 않은 수와 활동 팝오버. 알림의 [열기]도 이 모델로 팝오버를 연다
    let statusBar: StatusBarModel
    /// 창 아래 상태 줄의 rekordbox 쓰기 상태(#324): 칩·마지막 쓰기·상태 팝오버·Dock 배지. 저장소를 관찰해 스스로 고친다. 상태 줄(`StatusBar`)이 읽는다
    let writeStatus: ReflectionStatusModel
    /// 설정 › AI 에이전트 화면 모델(#262). 설정 창과 켤 때 알림이 함께 쓴다. 화면 시험의 조립(`init(store:deck:)`)은 nil이다
    /// (사용자 홈의 `~/.claude*`·`~/.agents`·`~/.local/bin`을 읽거나 쓰지 않게)
    let agentTools: AgentToolsSettingsModel?
    /// 켤 때 옛 설치본을 알릴지(자가 테스트·측정 실행은 알리지 않는다)
    private let agentNoticeEnabled: Bool
    /// 설정 › 업데이트와 앱 메뉴 "업데이트 확인…"의 화면 모델(#59)
    let updates: UpdateSettingsModel
    /// Sparkle 연결. 배포 앱 번들에서만 있다(개발 빌드·화면 시험은 nil)
    private let updater: AppUpdater?
    /// 창 아래 LINK 막대 화면 모델(#272). 실제 앱만 장치 알림을 받는다. 화면 시험·자가 테스트·측정 실행은 nil이다(네트워크 포트를 열지 않게)
    let link: LinkBarModel?
    /// rekordbox·rekordboxAgent 실행 감지 서비스(#323). 앱에 하나만 두고 `start()`가 돌린다. 화면 표시용이다(쓰기 판정은 관문이 한다)
    let rekordboxRun: RekordboxRunModel
    /// 덱 단축키(창이 처음 나타날 때 붙인다)
    let keys = KeyRouter()
    private var connected = false

    /// - Parameters:
    ///   - persistsActivityReadMark: 상태 줄의 읽음 기준을 설정에 남길지. 진단 실행(캡처·자가 테스트)은 사용자 설정을 바꾸지 않게 거짓이다
    ///   - dock: Dock 아이콘 배지. 실제 앱만 붙인다(화면 시험은 Dock을 건드리지 않는다)
    ///   - rekordboxRun: 실행 감지 서비스. 주지 않으면(화면 시험) 프로세스 목록을 읽지 않는 자리(`.none`)를 둔다
    init(settings: SettingsStore, store: LibraryStore, deck: DeckModel, windows: AppWindows, reflection: ReflectionCoordinator,
         agentTools: AgentToolsSettingsModel? = nil, agentNoticeEnabled: Bool = false, updater: AppUpdater? = nil, link: LinkBarModel? = nil,
         persistsActivityReadMark: Bool = true, dock: DockBadge = .none, rekordboxRun: RekordboxRunModel? = nil) {
        self.link = link
        self.rekordboxRun = rekordboxRun ?? RekordboxRunModel(source: .none)
        self.settings = settings
        self.updater = updater
        updates = UpdateSettingsModel(updater: updater, version: .of(.main))
        self.store = store
        self.deck = deck
        self.windows = windows
        self.reflection = reflection
        self.agentTools = agentTools
        self.agentNoticeEnabled = agentNoticeEnabled
        trackListActions = .live(store: store, reflection: reflection)
        tagInspector = TagInspectorModel(store: store)
        playlistSidebar = PlaylistSidebarModel(playlists: store.playlists)
        listActionBar = ListActionBarModel(store: store)
        libraryWindow = LibraryWindowModel(store: store)
        statusBar = StatusBarModel(log: store.activityLog, settings: persistsActivityReadMark ? settings : SettingsStore(persist: false))
        // 칩의 이유(켜짐·꺼짐)는 감지 서비스를 읽는 연결을 여기서 한다. 화면 시험의 조립(`.none`)은 늘 모름이라 칩이 바뀌지 않는다
        let run = self.rekordboxRun
        writeStatus = ReflectionStatusModel(store: store, window: libraryWindow, windows: windows, reflection: reflection, dock: dock,
                                            runState: { run.state })
        statusBar.write = writeStatus
        writeStatus.start()
        libraryWindow.agentTools = agentTools
        statusBar.showLog = { [weak window = libraryWindow] in window?.showActivityLog(selecting: $0) }
        libraryWindow.activityLogSeen = { [weak bar = statusBar] in bar?.markSeen() }
    }

    /// 이미 만든 저장소·덱으로 주 창을 띄울 때(화면 시험). 설정은 저장소의 것, 창은 새로 만들고 쓰기는 실제 관문으로 잇는다.
    /// - Parameter rekordboxRun: 감지 서비스. 주지 않으면 프로세스 목록을 읽지 않는다(늘 모름이라 상태 줄 칩이 바뀌지 않는다). 시험이 가짜 감시를 넣을 때 준다
    convenience init(store: LibraryStore, deck: DeckModel, rekordboxRun: RekordboxRunModel? = nil) {
        self.init(settings: store.settings, store: store, deck: deck, windows: AppWindows(), reflection: Self.reflection(store: store),
                  rekordboxRun: rekordboxRun)
    }

    /// 업데이트 설치 뒤 다시 켜려고 앱을 끄는 중인지(읽으면 표시를 지운다). 켜진 채 종료 시트(#326)가 이 종료는 묻지 않는다. 업데이트 도구가 없으면 거짓이다
    func consumeUpdateRelaunch() -> Bool { updater?.consumeRelaunchMark() ?? false }

    /// 옛 이름(anicue) 데이터·설정 옮기기. 앱이 시작할 때 목록·덱이 설정을 읽기 전에 한 번 부른다(`DJCrateApp`의 첫 속성)
    nonisolated static func migrateLegacyData() {
        #if DEBUG
        // 합성 사본 자가 테스트가 사용자 폴더·설정을 옮기지 않게 한다.
        if CommandLine.arguments.contains("--history-selftest") || CommandLine.arguments.contains(where: { $0.hasPrefix("--usb-snapshot-capture=") }) { return }
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
        var ports = LibraryPorts.live(location: location, drafts: drafts, batches: .live(url: places.reflection))
        // USB 기기 재생 기록 보존(#43)은 앱만 붙인다(시험 저장소·CLI는 보존하지 않는다)
        ports.usbHistories = UsbAppComposition.historyFiles()
        let store = LibraryStore(settings: settings, location: location, useCases: LibraryUseCases(ports: ports),
                                 activityLog: ActivityLog(url: places.activityLog, legacyResult: places.writeResult),
                                 launch: LibraryLaunchOptions(arguments: info.arguments, environment: info.environment))
        // 재생 기록 쓰기 관문(#43): 사본 재현으로 연 쓰기 경로. 닫혀 있으면 보존·보기만 하고 쓰기 대기에 올리지 않는다
        store.history.writesHistories = RekordboxWriter.writesHistories
        // 덱은 저장소와 같은 초안 저장소(같은 저장 큐)·설정을 쓴다(읽기는 메인 밖에서 실제 파일을 본다).
        let storage = DeckStorage(drafts: drafts, settings: settings)
        let deck = DeckModel(audio: DeckAudio(), storage: storage, assets: .live(drafts: drafts), analysis: deckAnalysis(), runsAnalysis: true)
        let notice = !info.arguments.contains { $0.contains("selftest") || $0.contains("capture") || $0.hasPrefix("--ui-perf") || $0.hasPrefix("--perf-")
            || $0 == "--autoplay" || $0 == "--scroll-perf" }
        // 앱 자동 업데이트(#59): 쓰는 동안 설치를 미루고 그 사실을 알림으로 보인다
        let updater = AppUpdater.make(activity: { [weak store] in store?.writeActivity ?? .idle },
                                      announce: { [weak store] in store?.showToast(.notice($0, nil)) })
        return AppComposition(settings: settings, store: store, deck: deck, windows: AppWindows(), reflection: reflection(store: store),
                              agentTools: agentTools(arguments: info.arguments, settings: settings), agentNoticeEnabled: notice,
                              updater: updater, link: DiagnosticRun.isActive(arguments: info.arguments) ? diagnosticLink(arguments: info.arguments, store: store)
                                  : linkBar(store: store, deck: deck),
                              persistsActivityReadMark: !DiagnosticRun.isActive(arguments: info.arguments), dock: .live,
                              rekordboxRun: RekordboxRunModel(source: .live(workspace: NSWorkspace.shared.notificationCenter)))
    }

    /// 자가 테스트·측정·캡처 실행의 LINK 막대: 장치 찾기를 붙이지 않는다(LNK-6). LINK 캡처만 포트 없는 가상 장치를 보인다
    static func diagnosticLink(arguments: [String], store: LibraryStore) -> LinkBarModel? {
        #if DEBUG
        LinkCapture.model(arguments: arguments, store: store)
        #else
        nil
        #endif
    }

    /// LINK 막대(#272·#273): 실제 알림 포트(받기만 한다)와 사용자가 켤 때만 띄우는 Link Export 서버.
    /// 내어 줄 라이브러리는 저장소가 읽은 rekordbox 컬렉션·재생 목록이고, 분석 파일은 저장소의 share 뿌리에서 읽기만 한다.
    /// 포트 실패는 표준 오류에만 남기고, 연결·싣기 실패는 알림으로 보인다
    static func linkBar(store: LibraryStore, deck: DeckModel) -> LinkBarModel {
        // LINK 재생 기록의 세션 열쇠: 앱 실행마다 새 앞부분 + 연결 차례 + 서버가 연 기록 번호
        // (보존본은 다시 켠 뒤에도 남아 앞 실행의 차례와 섞이지 않게, CDJ가 기록을 지우고 새로 열면 새 기록이 되게)
        let launch = UUID().uuidString
        // CDJ가 저장·삭제한 큐(#280)는 큐 초안에 하나씩 얹는다(앱이 맡은 초안 저장을 먼저 끝낸다)
        let cueDrafts = LinkCueDrafts(edits: store.useCases.draftEdits, flush: { [watch = store.useCases.watch] in watch.flush() })
        return LinkBarModel(
            discovery: LinkDiscovery(source: .live, log: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }),
            // CDJ가 못 읽는 FLAC·ALAC은 끌어 놓거나 CDJ에서 고를 때 WAV로 바꿔 ~/Music/DJCrate/LINK에 둔다(#277). 저장 공간 설정·`djc cache`가
            // 같은 자리를 보인다(#287). 음악 폴더 밖 곡만 내어 줘 이 폴더가 NFS 밖이면 서버가 원본 이름으로 내어 준다
            session: LinkSession(source: .live(), converter: .live(cache: DJCCachePaths.current.linkAudio),
                                 played: { [weak store] play in
                Task { @MainActor in store?.history.recordLinkPlay(play, session: "\(launch)-\(play.session)-\(play.history)") }
            }, cueEdited: { [weak store] edit in
                Task { @MainActor in store?.enqueueLinkCueEdit(edit, drafts: cueDrafts) }
            }, backgroundConversion: { [weak store] event in
                // CDJ에서 고른 FLAC·ALAC은 그 싣기가 실패한 뒤에 WAV로 바꾼다. 다 바꾸면 다시 실으라고 알린다
                let finished = if case .finished = event { true } else { false }
                Task { @MainActor in
                    store?.showToast(.notice(LinkText.backgroundConversion(event), nil, kind: finished ? .success : .warning))
                }
            }),
            library: { [weak store] in
                guard let store, case .loaded = store.phase else { return nil }
                // iTunes 목록은 다 읽었을 때만 넣는다(USB 동기화와 같은 조건). 읽는 중이면 다 읽은 뒤 연결 중인 서버에 더한다
                let music = store.music.library
                let iTunes = music.status == .ready || music.status == .stale ? music.tree : nil
                return LinkBarModel.LibraryInput(rows: store.rows, playlists: store.playlists.playlistProjection.layout, iTunes: iTunes,
                                                 draftCues: store.linkDraftCues(), shareRoot: store.shareRoot.path)
            },
            notify: { [weak store] text, kind in store?.showToast(.notice(text, nil, kind: kind)) },
            sessionEnded: { [weak store] in store?.history.closeLinkSessions() },
            // CDJ가 덱의 곡을 실으면 라이브러리가 덱 곡 ID와 함께 내린다(다시 읽을 때 그 곡을 되올리지 않게)
            cdjTracks: { [weak deck, weak store] loaded in
                if deck?.applyCDJTracks(loaded: loaded) == true { store?.unloadDeckForCDJ() }
            })
    }

    /// AI 에이전트 설치(#262): 재료는 이 앱 번들 안(`Contents/Resources/skills/djcrate`·`Contents/Helpers/djc`), 설치 자리의 뿌리는 사용자 홈.
    /// 디버그 빌드는 `--agent-home=<폴더>`로 홈을 바꾼다(자가 테스트·캡처가 사용자 홈과 휴지통에 쓰지 않게 휴지통도 그 안으로 둔다)
    static func agentTools(arguments: [String], settings: SettingsStore?,
                           confirm: @escaping @MainActor (ReflectionPrompt) -> Bool = { AlertPrompter().show($0) }) -> AgentToolsSettingsModel {
        var home = FileManager.default.homeDirectoryForCurrentUser
        var trash: URL?
        #if DEBUG
        if let value = arguments.first(where: { $0.hasPrefix("--agent-home=") })?.dropFirst("--agent-home=".count), !value.isEmpty {
            home = URL(filePath: String(value), directoryHint: .isDirectory)
            trash = home.appending(path: ".djc-test-trash")
        }
        #endif
        let tools = AgentTools(files: .live(layout: agentLayout(), trash: trash), home: home)
        return AgentToolsSettingsModel(tools: tools, settings: settings, confirm: confirm)
    }

    /// 앱 번들이면 번들 안 재료, 디버그 실행 파일이면 저장소의 `skills/djcrate`와 실행 파일 옆 djc(`swift build`가 함께 만든다)
    static func agentLayout(bundle: Bundle = .main) -> AgentBundleLayout {
        if bundle.bundleURL.pathExtension == "app" { return .appBundle(bundle.bundleURL, info: bundle.infoDictionary ?? [:]) }
        #if DEBUG
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let command = bundle.executableURL?.deletingLastPathComponent().appending(path: "djc")
        return AgentBundleLayout(skillSource: repository.appending(path: "skills/djcrate"),
                                 command: command.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil },
                                 version: AgentPayloadVersion(version: "dev", build: "0"))
        #else
        return AgentBundleLayout(skillSource: nil, command: nil, version: AgentPayloadVersion(version: "dev", build: "0"))
        #endif
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
                                        savePlaylistDraft: { [weak store] in store?.playlists.ensurePlaylistDraftSaved() ?? true },
                                        recordHistories: { [weak store] in await store?.history.recordWrittenHistories($0) })
        // Mac을 끄는 중·종료를 기다리는 중에는 세션도 새 쓰기를 시작하지 않는다(바쁨으로 답한다, #300)
        let lock = WriteLock(isLocked: { [weak store] in store.map { $0.libraryBusy || $0.writeRefusal != nil } ?? false },
                             set: { [weak store] locked, deck in store?.setWriteLock(locked, deck: deck) },
                             stage: { [weak store] in store?.writeStage = $0 })
        // 반영 세션은 라이브러리와 같은 초안 저장 큐·스냅샷 뜨기·연결 기록을 쓴다(라이브러리 유스케이스 묶음에서 받는다).
        let ports = ReflectionPorts(gate: gate, backups: backups, sharing: store.useCases, audio: audio, library: library,
                                    reload: LibraryReloader { [weak store] written, edits in
                                        await store?.reloadAfterWrite(written: written, playlistEdits: edits) ?? false
                                    },
                                    lock: lock,
                                    // 확인 창이 떠 있는 동안은 아직 아무것도 쓰지 않았다: 종료 판정이 이 때를 가른다(#300)
                                    confirmation: UserConfirmation(
                                        confirm: { [weak store] prompt in store?.whileAwaitingConfirmation { prompter.show(prompt) } ?? prompter.show(prompt) },
                                        choose: { [weak store] prompt in store?.whileAwaitingConfirmation { prompter.choose(prompt) } ?? prompter.choose(prompt) }),
                                    results: ReflectionResults { presenter.publish($0) }, runningApps: runningApps)
        let session = ReflectionSession(location: store.location, ports: ports, options: options)
        store.music.write = { try await session.syncITunes($0) }
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
        let staging = StagingStore(tracks: { [weak store] in store?.staging.staged ?? [] },
                                   save: { [weak store] tracks in
                                       guard let store else { throw CancellationError() }
                                       try store.staging.saveStaged(tracks)
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
        // 덱이 비어 있으면 덱 위 알림이 보이지 않으므로 창 아래 알림으로 까닭을 알린다(#278)
        store.deckRefuses = { [weak deck, weak store] row in
            guard let reason = deck?.cdjRefusal(row) else { return false }
            store?.showToast(.notice(reason, nil, kind: .warning))
            return true
        }
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
        deck.onStagedGridChange = { [weak store] uuid, bpm in store?.staging.stagedGridChanged(uuid: uuid, bpm: bpm) }
        deck.onCueDraftChange = { [weak store] draft in store?.cueDraftChanged(draft) }
        deck.onReanalyze = { [weak store] uuid in store?.tags.restoreKeySuggestion(uuid: uuid) }
        store.onWriteLock = { [weak deck] locked in deck?.editsFrozen = locked }
        store.onRekordboxWritten = { [weak deck, weak store] uuids in
            // 처음부터 다시 불러오지 않고 초안·그리드·게인만 새 rekordbox 값으로 맞춘다(소리·파형은 그대로).
            guard let deck, let uuid = deck.row?.track.uuid, uuids.contains(uuid) else { return }
            deck.refreshAfterWrite(store?.rowsByUUID[uuid])
        }
        keys.install(deck: deck, store: store, windows: windows)
        let editLinks = EditWindowLinks(deck: deck, store: store, reflection: reflection, writer: Self.renderEdit(store: store),
                                        makeAudio: { EditAudioPlayer() },
                                        showStaged: { [weak store] staged, hasGrid in store?.staging.showStagedEdit(staged, hasGrid: hasGrid) })
        windows.trackEdit.attach(editLinks)
        windows.flip.attach(editLinks)
        #if DEBUG
        DevSelfTests.runIfRequested(store: store, deck: deck, windows: windows, reflection: reflection, playlistSidebar: playlistSidebar,
                                    libraryWindow: libraryWindow, statusBar: statusBar, rekordboxRun: rekordboxRun)
        DevSelfTests.runAsyncGuidanceCaptureIfRequested(store: store, deck: deck)
        UsbMigrateCapture.runIfRequested(store: store)
        UsbSnapshotCapture.runIfRequested(store: store)
        AgentToolsCapture.runIfRequested()
        LinkCapture.runIfRequested(link: link, store: store)
        DevSelfTests.runKeyRoutingSelfTestIfRequested(store: store, deck: deck, windows: windows)
        #endif
        deck.onDraftChange = { [weak store] uuid, kind, exists in
            store?.draftChanged(trackUUID: uuid, kind: kind, exists: exists)
        }
        // DJCrate에서 고친 큐를 LINK로 내어 주는 큐에 옮긴다(#281)
        if let link {
            store.isLinkServing = { [weak link] in link?.isServing ?? false }
            store.onLinkCuesChanged = { [weak link] contentID, cues in link?.updateCues(contentID: contentID, cues: cues) }
            // 재생 목록 초안도 얹어 내어 준다. 추가 대기 곡은 rekordbox 분석 파일이 없어 빼므로 목록에서도 빠진다
            store.playlists.onProjectionChanged = { [weak link] in link?.updatePlaylists() }
        }
    }

    /// 창을 띄운 뒤: rekordbox 실행 감지를 돌리고, 사이드바 USB 절을 붙이고, 읽을 때마다 도는 캐시 정리를 붙이고, 라이브러리를 처음 읽는다.
    func start() async {
        updater?.start()
        rekordboxRun.start()
        UsbAppSetup.attach(to: store)
        // CLI가 앱의 시점 스냅샷 보관 일수를 따르게 공유 파일에 맞춘다
        settings.syncShared()
        // 프로세스 전체의 캐시·임시 파일 정리는 앱만 한다(화면 모델·시험 저장소가 공용 음량 캐시를 자기 곡으로 잘라내지 않게).
        store.onLibraryLoaded = { paths in Self.maintainCaches(keeping: paths) }
        // 옛 AI 에이전트 설치본 알림(#262)은 읽기를 기다리지 않는다. 다른 알림을 덮지 않는다
        if agentNoticeEnabled, let agentTools {
            Task { [store] in
                _ = await agentTools.launchNotice { toast in
                    guard store.toast == nil else { return false }
                    store.showToast(toast)
                    return true
                }
            }
        }
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
                                    linkServing: { [weak store] in store?.isLinkServing() ?? false },
                                    // 변환본을 비우는 동안 LINK 켜기를 기다리게 한다(LINK 막대가 없는 실행은 막을 것이 없다)
                                    beginLinkAudioClear: { [weak link = self.link] in
                                        guard let link else { return {} }
                                        return link.beginCacheClear()
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

    /// 주 창이 떠 있는 동안 자동 시점 스냅샷을 돌린다(창이 사라지면 `.task`가 취소한다)
    func runAutoPointSnapshots() async { await autoPointSnapshots().loop() }

    /// 주 창이 떠 있는 동안 CLI·다른 앱이 바꾼 초안 파일을 다시 읽는다(창이 사라지면 `.task`가 취소해 멈춘다).
    func watchExternalDrafts(every interval: Duration = .seconds(1)) async {
        while !Task.isCancelled {
            // 끄는 중인 큐·그리드는 손을 놓아 저장한 뒤에 다시 읽는다.
            if !deck.hasUncommittedCueEdits, deck.cueDragBase == nil, deck.gridDragBase == nil { await store.refreshExternalDrafts() }
            do { try await Task.sleep(for: interval) } catch { break }
        }
    }

    /// 라이브러리를 읽을 때마다: 라이브러리에 없는 곡의 음량 항목(#217, 추가한 곡의 경로는 남긴다)과 캐시 용량 상한(최근 사용 순)을
    /// 뒤에서 조용히 정리한다. 비정상 종료 뒤 남은 임시 파일·폴더(#219)는 처음 한 번만 치운다.
    static func maintainCaches(keeping libraryPaths: Set<String>) {
        Task(priority: .background) {
            let removed = await LoudnessCache.shared.prune(keeping: libraryPaths)
            if removed > 0 { FileHandle.standardError.write(Data("음량 캐시 정리 \(removed)개\n".utf8)) }
        }
        // 파일을 지우는 동기 입출력이라 협력 풀이 아닌 GCD에서 돌린다(기다리지 않는다)
        DispatchQueue.global(qos: .background).async {
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

extension DockBadge {
    /// 실제 Dock 아이콘 배지(조립 지점만 고른다, UI-7)
    static var live: DockBadge { DockBadge { NSApplication.shared.dockTile.badgeLabel = $0 } }
}
