import DJCApplication
import DJCDomain
import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    enum Phase {
        case idle
        case loading(String)
        case loaded
        case failed(String)
    }

    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet { if oldValue !== undoManager { oldValue?.removeAllActions(withTarget: self) } }
    }
    /// rekordbox 라이브러리 위치(읽기 출처·쓰기 대상·스냅샷·백업·초안 폴더). 조립 지점이 실행 인자·환경을 한 번 풀어 준다.
    @ObservationIgnored let location: LibraryLocation
    /// 라이브러리 유스케이스(읽기·초안 지켜보기 …). 조립 지점이 포트로 만들어 준다. 이 화면 모델은 포트를 직접 부르지 않고 유스케이스만 부른다
    /// (초안 저장 큐·스냅샷·파일은 모두 유스케이스 뒤에 있다).
    @ObservationIgnored let useCases: LibraryUseCases
    /// 곡 목록 미리 보기 파형 그림(목록 칸이 나눠 쓴다). 원자료는 유스케이스(`useCases.previews`)로 읽는다
    @ObservationIgnored let previewImages: PreviewWaveformCache
    /// 곡 목록·중복 후보의 앨범아트 썸네일(목록 칸이 나눠 쓴다). 그림은 유스케이스(`useCases.artwork`)로 읽는다
    @ObservationIgnored let thumbnails: Thumbnails
    /// rekordbox 환경설정에 한 번 지정하는 연동 XML 파일("XML 만들기"가 늘 이 파일에 쓴다)
    var linkedXMLFile: URL { useCases.linkedXML }
    /// 이번 실행에서 저장을 맡긴 태그 초안 곡(저장 실패를 이 저장소 것만 본다, `LibraryStore+DraftIndex`)
    @ObservationIgnored private(set) var tagSaveAttempts: Set<String> = []
    var mergeDrafts: [DuplicateMergeDraft] = []
    var playlistImports = PlaylistImports()
    var playlistImportsLoadFailed = false
    var backupDirectory: URL { location.backupDirectory }
    /// 쓰기·복원 대상 rekordbox DB와 분석 파일 뿌리(사본이면 그 share). 앱은 라이브 라이브러리, 시험은 합성 사본을 준다.
    /// 복원은 늘 이 DB로 되돌린다(#182: 대상 없이 되돌려 시험이 실제 라이브러리를 덮었다).
    var rekordboxDatabase: URL { location.database }
    var rekordboxShareRoot: URL? { location.shareRoot }
    /// 분석 파일·그림을 찾을 share 뿌리(쓰기 대상과 같은 곳). 정하지 않았으면 위치 값의 rekordbox 폴더
    var shareRoot: URL { rekordboxShareRoot ?? location.liveShare }
    private(set) var hasWriteBackup = false

    func refreshWriteBackups() {
        hasWriteBackup = useCases.hasWriteBackup(in: backupDirectory)
    }

    let resultHistory: WriteResultHistory
    @ObservationIgnored var feedback: AppFeedback
    var showingWriteResult = false
    @ObservationIgnored var writeTask: Task<Void, Never>?
    @ObservationIgnored var previewWarmTask: Task<Void, Never>?

    func cancelWritePreparation() {
        guard writeStage?.cancellable == true else { return }
        writeTask?.cancel()
    }

    @ObservationIgnored let settings: SettingsStore
    var commentPreset: CommentPreset {
        didSet {
            guard commentPreset != oldValue else { return }
            settings.commentPreset = commentPreset
            refreshCommentRule()
        }
    }
    var commentRuleEnabled: Bool { commentPreset.rule != nil }
    /// 설정 '스트리밍 곡 숨기기'. 곡 목록·곡 수에 보이는 것만 바꾼다. 라이브러리에서 읽은 곡(`rows`)·초안·재생 목록 편집·쓰기 내용은 그대로다.
    var hideStreaming: Bool {
        didSet {
            guard hideStreaming != oldValue else { return }
            settings.set(SettingKeys.hideStreaming, hideStreaming)
            applyStreamingVisibility()
        }
    }
    /// 실험실 '인텔리전트 재생 목록 보기'(#68). 켜면 인텔리전트 목록의 조건을 계산해 읽기 전용으로 보인다. 끄면(기본) 계산하지 않고,
    /// 사이드바·곡 목록·편집은 이 기능이 없던 때와 같다. 켜고 끄면 다시 읽지 않고 사이드바를 바로 바꾼다(`LibraryStore+SmartPlaylists`).
    var showSmartPlaylists: Bool {
        didSet {
            guard showSmartPlaylists != oldValue else { return }
            settings.set(SettingKeys.labSmartPlaylists, showSmartPlaylists)
            refreshPlaylists()
        }
    }
    /// 목록 ID → 읽은 조건 칸(스냅샷을 읽을 때 채운다)
    var smartPlaylistSources: [String: SmartPlaylistSource] = [:]
    /// 켜 있을 때 목록 ID → 계산 결과(계산하지 못한 조건이 있으면 곡 없이 이유만)
    var smartPlaylistResults: [String: SmartPlaylistResult] = [:]
    /// 지금 보는 목록에서 '스트리밍 곡 숨기기' 때문에 뺀 줄 수. 0이 아니면 보이는 줄 번호가 목록 순서와 다르니 끌어 옮기지 않는다.
    /// (고치는 곳: `LibraryStore+List`)
    private(set) var streamingHiddenInView = 0
    /// 지금 보는 목록에서 숨긴 줄의 ID(재생 기록의 반복 행처럼 곡 ID와 다른 줄 ID도 선택에서 뺀다)
    @ObservationIgnored private(set) var hiddenStreamingRowIDs: Set<TrackRow.ID> = []

    /// 실제 구현(초안 파일·스냅샷·위치)은 조립 지점(`AppComposition.live`)이 고른다. 시험은 `LibraryStore.test(…)`로 만든다.
    /// rekordbox 쓰기는 이 저장소가 하지 않는다: 조립 지점이 만든 반영 세션(`ReflectionSession`)이 이 저장소의 상태를 읽고 결과를 알린다.
    /// - Parameter launch: 개발용 실행 인자(`--select`·`--add-files`)
    init(settings: SettingsStore, location: LibraryLocation, useCases: LibraryUseCases, resultHistory: WriteResultHistory,
         feedback: AppFeedback = AppFeedback(), launch: LibraryLaunchOptions = LibraryLaunchOptions()) {
        self.settings = settings
        self.dismissedKeySuggestions = settings.strings(SettingKeys.dismissedKeySuggestions)
        self.commentPreset = settings.commentPreset
        self.hideStreaming = settings.value(SettingKeys.hideStreaming)
        self.showSmartPlaylists = settings.value(SettingKeys.labSmartPlaylists)
        self.location = location
        self.useCases = useCases
        previewImages = PreviewWaveformCache(previews: useCases.previews)
        thumbnails = Thumbnails(artwork: useCases.artwork)
        self.resultHistory = resultHistory
        self.feedback = feedback
        self.launch = launch
        readFlow = LibraryReadFlow(loader: useCases.load, location: location)
        music = MusicLibraryStore(readFlow: readFlow)
        readFlow.screen = readScreen
        music.host = musicHost
        refreshWriteBackups()
        loadRecentPlaylists()
        loadPlaylistImports()
    }

    var phase: Phase = .idle
    private(set) var rows: [TrackRow] = []
    private(set) var report: LibraryReport?
    private(set) var snapshotURL: URL?
    private(set) var previewRevision = 0
    /// 표에 보이는 줄. 필터·검색·정렬이 바뀔 때만 다시 계산한다(그릴 때마다 계산하지 않는다).
    private(set) var displayRows: [TrackRow] = []
    private(set) var duplicateGroups: [LibraryRecords.DuplicateGroup] = []
    private(set) var displayDuplicateGroups: [LibraryRecords.DuplicateGroup] = []
    private(set) var filterCounts: [LibraryFilter: Int] = [:]
    /// 마지막 파일 확인 결과(#126). 연결되지 않은 외장 디스크는 목록 위 작업 줄에 알린다.
    private(set) var missingFiles = MissingFiles()
    private(set) var isCheckingFiles = false
    @ObservationIgnored var missingFileTask: Task<Void, Never>?
    /// 지난 확인에서 없던 경로. 다시 읽은 직후 확인이 끝날 때까지 이것으로 표시해 개수가 0으로 깜빡이지 않게 한다.
    @ObservationIgnored private var missingPathCache: Set<String> = []
    var playlistCounts: [String: Int] = [:]
    var isLoading: Bool { if case .loading = phase { true } else { false } }

    var sidebar: SidebarItem = .filter(.all) {
        didSet {
            guard sidebar != oldValue else { return }
            // 고른 재생 기록이 접힌 연·월 안에 있으면 펼친다
            if case let .history(id) = sidebar { revealHistory(id) }
            // 플레이리스트는 rekordbox 순서가 기본, 필터는 임포트 최신순이 기본.
            suppressRefresh = true
            switch sidebar {
            case .playlist, .itunesPlaylist, .history, .duplicates, .staged, .pending, .usb: sortOrder = []
            case .filter:
                if case .filter = oldValue {} else { sortOrder = [KeyPathComparator(\TrackRow.importedOn, order: .reverse)] }
            }
            suppressRefresh = false
            refreshBase()
        }
    }
    /// 사이드바 재생 목록 트리(rekordbox 상태에 재생 목록 초안을 얹은 모양, LibraryStore+Playlists)
    var playlistTree: [PlaylistOutlineNode] = []
    /// Music(iTunes) 표시 상태와 동기화 창(기능 조각, `MusicLibraryStore`). `let`이라 관찰하지 않는다: 화면은 조각의 값을 읽는다
    let music: MusicLibraryStore
    var isITunesSelection: Bool { if case .itunesPlaylist = sidebar { true } else { false } }
    /// USB 목록을 보는 중(읽기 전용: 편집·쓰기·끌기·덱 불러오기를 막는다)
    var isUsbSelection: Bool { if case .usb = sidebar { true } else { false } }
    /// 사이드바 USB 절(앱이 붙인다. 시험·캡처에서는 없다)
    var usb: UsbStore? {
        didSet {
            usb?.onChange = { [weak self] in self?.usbChanged() }
            // 붙이거나 뗄 때 USB 쓰기·초안 편집 흐름을 한 번 만든다. 흐름은 이 스토어를 약하게 잡는다(스토어가 흐름을 들고 있으므로)
            let host = WeakUsbWriteHost(self)
            usbCoordinator = usb.map { UsbWriteCoordinator(usb: $0, host: host, service: $0.writeService) }
            usbEdits = usb.map { UsbEditActions(usb: $0, host: host, undoManager: { [weak self] in self?.undoManager }) }
        }
    }
    /// USB 쓰기·초안 편집 흐름. `usb`를 붙이거나 뗄 때만 바뀐다
    private(set) var usbCoordinator: UsbWriteCoordinator?
    private(set) var usbEdits: UsbEditActions?
    /// 곡 목록에서 USB 곡을 끄는 동안 그 볼륨키(#240). 사이드바 USB 줄이 같은 USB의 목록만 받으려고 본다(놓기 판정은 끈 내용을 미리 읽지 못한다)
    @ObservationIgnored var usbDragVolume: String?
    /// 새 항목의 부모만 펼치고 다른 폴더의 펼침 상태는 유지한다.
    var expandedPlaylistIDs: Set<String> = []
    var playlistIndex: [String: PlaylistOutlineNode] = [:] { didSet { playlistCount = playlistIndex.values.filter { !$0.isFolder }.count } }
    /// 폴더를 뺀 rekordbox 플레이리스트 수(사이드바 제목)
    private(set) var playlistCount = 0
    /// 스냅샷에서 읽은 rekordbox 재생 목록(초안을 얹기 전)
    var rekordboxPlaylists = PlaylistLayout()
    /// 재생 목록 초안(반영 때 쓴다). 바꿀 때는 `setPlaylistDraft`로(저장·화면·되돌리기).
    var playlistDraft = PlaylistDraft()
    /// 초안을 얹은 모양과 편집마다 막힌 이유
    var playlistProjection = PlaylistDraft().project(onto: PlaylistLayout())
    /// 목록마다 초안으로 넣은 곡(ContentID). 목록을 볼 때 초안 표식을 붙인다.
    var playlistAddedTracks: [String: Set<String>] = [:]
    /// 최근에 곡을 넣은 목록(최근 것부터). 오른쪽 클릭 메뉴 맨 위·'마지막에 쓴 목록에 넣기'.
    var recentPlaylistIDs: [String] = []
    /// 사이드바에서 이름을 고치는 중인 목록
    var renamingPlaylistID: String?
    /// 재생 목록 편집 결과 안내(넣은 곡 수·이미 든 곡·막힌 이유)
    var playlistMessage: AppMessage? {
        didSet { if let playlistMessage { feedback.announce(playlistMessage) } }
    }
    /// 재생 목록 초안 저장에 실패해 메모리 초안이 디스크보다 최신이다(쓰기 전에 다시 저장한다, #174).
    var playlistDraftUnsaved = false
    /// 읽지 못해 옮겨 보관한 초안 파일 안내(#174). 닫을 때까지 남는다.
    var draftFileMessage: AppMessage? {
        didSet { if let draftFileMessage { feedback.announce(draftFileMessage) } }
    }
    @ObservationIgnored var damagedDraftCount = 0
    @ObservationIgnored var damagedStagedList = false
    /// 스냅샷 곡·추가한 곡 어디에도 이어지지 않는 초안이 있는 곡(#175). 쓰기 대기 목록에서 보여 주고 고른 것만 버린다.
    var unlinkedDraftUUIDs: Set<String> = []
    /// 연결되지 않은 초안 시트의 화면 모델(띄울 때 만든다, `openUnlinkedDrafts`)
    var unlinkedDraftsSheet: UnlinkedDraftsModel?
    /// 개발용 실행 인자(처음 읽은 뒤 한 번 곡을 고르거나 곡을 추가한다)
    @ObservationIgnored let launch: LibraryLaunchOptions
    /// '재생 목록에 넣기…' 창과 넣을 곡(연 때 고른 곡)
    var showingPlaylistPicker = false
    var playlistPickerTracks: [TrackRow] = [] {
        // 열 때마다 새 화면 모델(찾는 말·고른 줄을 처음부터). 시트 본문이 다시 그려져도 같은 모델을 쓴다
        didSet { playlistPicker = PlaylistPickerModel(store: self, tracks: playlistPickerTracks) }
    }
    @ObservationIgnored private(set) var playlistPicker: PlaylistPickerModel?
    var histories: [RekordboxHistory] = [] {
        didSet {
            guard histories != oldValue else { return }
            historyIndex = Dictionary(histories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            refreshHistoryTree()
        }
    }
    private(set) var historyIndex: [String: RekordboxHistory] = [:]
    /// USB에서 가져와 DJCrate에 보존한 기기 재생 기록(#43, `LibraryStore+Histories`). rekordbox 라이브러리에는 없다
    var archivedHistories: [ArchivedHistory] = [] {
        didSet {
            guard archivedHistories != oldValue else { return }
            archivedHistoryIndex = Dictionary(archivedHistories.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            refreshHistoryTree()
        }
    }
    private(set) var archivedHistoryIndex: [String: ArchivedHistory] = [:]
    /// USB 기록 보존(유스케이스). nil이면 USB 기록을 보존·가져오지 않는다(시험 기본: 사용자 폴더를 건드리지 않게, 조립 지점만 붙인다)
    @ObservationIgnored var usbHistories: ArchiveUsbHistories?
    /// 현재 채택한 스냅샷의 키. USB 분리 뒤에도 보존본의 짝·쓴 표시를 검증한다.
    @ObservationIgnored var historyLocalKeys: LocalLibraryKeys?
    /// 읽지 못해 그 자리에 남은 보존 파일. 해소될 때까지 새 ID 보존을 막아 중복을 만들지 않는다.
    @ObservationIgnored var unreadableHistoryFiles: [String] = []
    /// 사이드바 재생 기록 트리(연 › 월 › 기록). 두 기록 중 하나가 바뀔 때만 다시 만들어, 사이드바 구역 본문은 이 값만 읽는다(#141)
    private(set) var historyTree = HistoryTree()
    /// rekordbox도 가져온 같은 USB 기록이라 트리에서 숨긴 보존 기록(파일은 그대로)
    private(set) var shadowedArchiveIDs: Set<String> = []
    /// 펼친 재생 기록 연·월 폴더(`HistoryTree.yearID`·`monthID`)
    var expandedHistoryFolders: Set<String> = []
    /// 가장 최근 연·월을 한 번 펼쳤는지(그 뒤 접고 펼친 것은 사용자 몫)
    @ObservationIgnored var historyFoldersSeeded = false
    /// USB 기록 보존·보존본 저장(쓰기 대기에서 빼기·rekordbox에 쓴 표시)을 한 줄로 세운다
    /// (USB 읽기와 로컬 짝 다시 계산이 겹쳐도 같은 기록을 두 번 보존하지 않고, 파일 쓰기가 서로 겹치지 않게)
    @ObservationIgnored var historyImports: Task<Void, Never>?
    /// rekordbox 쓰기 대기에 오른 보존 기록(#43, `HistoryWriteQueue.pending`, 가져온 차례). 라이브러리를 읽은 뒤에만 고르고
    /// (rekordbox에 이미 쓴 기록인지 모르는 동안 올리지 않게), 기록·보존본이 바뀔 때만 다시 계산한다(#141).
    /// 사이드바 배지·기록 줄 표시·쓰기 대기 바·rekordbox에 쓰기(⇧⌘E)가 이것을 쓴다
    private(set) var pendingHistories: [ArchivedHistory] = []
    /// 쓰기 대기 기록 ID(사이드바 기록 줄이 대기 표시를 고른다)
    private(set) var pendingHistoryIDs: Set<String> = []
    /// rekordbox에 썼지만 아직 새 스냅샷으로 읽지 못한 기록의 rekordbox ID. 다시 읽을 때까지 rekordbox에 있는 것으로 본다
    /// (쓴 뒤 다시 읽지 못해도 같은 기록을 또 쓰지 않게). 라이브러리를 새로 읽으면 비운다
    @ObservationIgnored var historyIDsAwaitingReload: Set<String> = []
    /// rekordbox 재생 기록 쓰기 관문. 조립 지점이 사본 재현으로 확인한 `RekordboxWriter.writesHistories`를 넣고 시험은 따로 바꾼다.
    /// 닫혀 있으면 보존·보기만 하고 쓰기 대기에 올리지 않는다(다른 초안을 쓸 때마다 막힘을 묻지 않게)
    @ObservationIgnored var writesHistories = false {
        didSet { if writesHistories != oldValue { refreshHistoryTree() } }
    }

    /// 트리·숨김·쓰기 대기를 다시 정한다(`UsbHistoryRules.view`). 같으면 건드리지 않는다(사이드바·배지가 다시 계산되지 않게)
    func refreshHistoryTree() {
        let rows = rowsByID
        let view = UsbHistoryRules.view(histories: histories, archived: archivedHistories, local: historyLocalKeys,
                                        inCollection: { rows[$0] != nil }, queueOpen: snapshotURL != nil && writesHistories,
                                        awaitingReload: historyIDsAwaitingReload, calendar: .current)
        if view.shadowed != shadowedArchiveIDs { shadowedArchiveIDs = view.shadowed }
        if view.tree != historyTree { historyTree = view.tree }
        guard view.pending != pendingHistories else { return }
        pendingHistories = view.pending
        pendingHistoryIDs = Set(view.pending.map(\.id))
    }

    var search = "" { didSet { if search != oldValue { refreshFiltered() } } }
    var sortOrder = [KeyPathComparator(\TrackRow.importedOn, order: .reverse)] {
        didSet { if !suppressRefresh { refreshBase() } }
    }
    /// 목록에서 고른 곡(포커스). 덱은 따라가지 않는다: 덱에 올리기는 불러오기 명령(`loadToDeck`)으로만 한다(#93).
    var selection: Set<TrackRow.ID> = []
    /// 덱에 곡을 올리거나(nil이면 내리기) 새로 읽은 값으로 맞춘다. 덱과 잇는 곳은 여기 하나다.
    var onLoadToDeck: ((TrackRow?) -> Void)?
    /// 덱의 곡을 다른 곡으로 바꿔도 되는지(Flip 기록을 버리기 전에 묻는다). false면 올리지 않는다.
    @ObservationIgnored var confirmDeckReplacement: ((TrackRow) -> Bool)?
    /// 스냅샷을 새로 읽었을 때(USB 갱신 상태의 로컬 짝짓기 키를 다시 읽는다)
    @ObservationIgnored var onSnapshotLoaded: ((URL) -> Void)?
    var allowsLibrarySync: (() -> Bool)?
    private(set) var isSynchronizingLibrary = false
    var canSynchronizeLibrary: Bool { !isLoading && !isSynchronizingLibrary && !isWritingRekordbox && (allowsLibrarySync?() ?? true) }
    /// 덱에 올린 곡(ContentID, 추가한 곡은 djc- ID). 목록의 덱 표시와 새로 읽을 때 덱을 맞추는 데 쓴다.
    private(set) var deckTrackID: String?

    /// 초안 상태(메모리). 표의 ✎ 표시는 디스크를 다시 읽지 않고 이것으로 계산한다.
    var tagDrafts: [String: TagDraft] = [:]
    /// 무시한 키 제안(곡 UUID). 게인·그리드 제안처럼 곡마다 기억하고, 덱 제안 줄에 바로 반영한다.
    var dismissedKeySuggestions: Set<String> = []
    /// 그림 초안(곡 UUID별, 그림 바이트 없이). 그림 사본은 `ArtworkDraftStore`에 있다(#66).
    var artworkDrafts: [String: ArtworkDraft] = [:]
    /// 곡의 살아 있는 그림 파일 행(ContentID별). 그림 초안의 base로 쓴다(스냅샷에서 읽음).
    @ObservationIgnored var artworkFileRows: [String: [ArtworkFileRow]] = [:]
    /// 그림 초안 안내(읽지 못한 그림·쓸 수 없는 곡)
    var artworkMessage: AppMessage?
    /// rekordbox 곡 색 목록(이름·순서, #65). 라이브러리에서 읽지 못하면 rekordbox 기본 여덟 색이다.
    var trackColors: [TrackColor] = TrackColor.rekordboxDefaults
    /// 목록 거르기: 평점 이 별 수 이상(0이면 끔)과 곡 색(nil이면 끔). rekordbox 값(초안 전)으로 거른다(정렬과 같다).
    var minimumRating = 0 { didSet { if minimumRating != oldValue { refreshFiltered() } } }
    var colorFilter: String? { didSet { if colorFilter != oldValue { refreshFiltered() } } }
    var isAttributeFiltered: Bool { minimumRating > 0 || colorFilter != nil }
    /// 그림 초안을 고친 횟수. 백그라운드 읽기 사이에 고쳤으면 읽은 초안 대신 디스크를 다시 읽는다.
    @ObservationIgnored var artworkChangeCount = 0
    @ObservationIgnored var recoveryMemoryInput: ((String, DraftRecoveryKind) -> RecoveryDraft?)?
    @ObservationIgnored var onDraftRecovered: ((RecoveryDraft, TrackRow?, BeatGrid?) -> Void)?
    var isRecoveringDraft = false
    /// 열려 있는 막힌 초안 복구 시트(#232). 메인 창(`ContentView`)과 곡 편집 창이 `anchor`에 맞는 쪽에서 띄운다.
    var recoverySheet: RecoverySheetModel?
    /// 복구가 rekordbox 사본을 읽은 횟수(시험이 시트 하나가 줄마다 사본을 뜨지 않는지 센다)
    @ObservationIgnored var recoverySnapshotReads = 0
    private(set) var cueDraftUUIDs: Set<String> = []
    private(set) var gridDraftUUIDs: Set<String> = []
    private(set) var gainDraftUUIDs: Set<String> = []
    private(set) var editedUUIDs: Set<String> = []

    var rowsByID: [TrackRow.ID: TrackRow] = [:]
    var rowsByUUID: [String: TrackRow] = [:]

    // 추가한 곡(LibraryStore+Staging.swift)
    var staged: [StagedTrack] = []
    var stagedRows: [TrackRow] = []
    /// 백그라운드 그리드 추정 진행(끝나면 nil)
    var gridJob: GridJob? {
        didSet { if (oldValue == nil) != (gridJob == nil) { hasGridJob = gridJob != nil } }
    }
    /// 추정이 도는 중인지. 진행(`done`)이 오를 때마다가 아니라 시작·끝에만 바뀌어, 사이드바 본문은 이것만 읽고 진행 줄을 넣고 뺀다(#141).
    private(set) var hasGridJob = false
    var gridQueue: [GridJobItem] = []
    var gridTask: Task<Void, Never>?
    /// 라이브러리 XML 내보내기 진행(끝나면 nil, `LibraryStore+XMLExport.swift`). 그리드 추정처럼 줄은 시작·끝에만 넣고 뺀다.
    var xmlExportJob: LibraryXMLExportJob? {
        didSet { if (oldValue == nil) != (xmlExportJob == nil) { hasXMLExportJob = xmlExportJob != nil } }
    }
    private(set) var hasXMLExportJob = false
    @ObservationIgnored var xmlExportTask: Task<Void, Never>?
    /// rekordbox XML 가져오기(읽는 중·미리 보기 시트·초안 결과, `XMLImportModel`). 메뉴가 읽는 중인지 보므로 시트를 닫아도 남는다
    @ObservationIgnored private(set) lazy var xmlImport = XMLImportModel(store: self)
    /// 덱에 올린 곡과 그 그리드 초안을 덱에서 바꿨는지(가져오기가 덱 곡의 그리드 초안을 덱에 넘길지 정한다)
    @ObservationIgnored var deckGridDraftState: (() -> (uuid: String, hasChanges: Bool)?)?
    /// 가져온 그리드 초안을 덱이 받아 저장한다. 받지 못하면(덱에서 고쳤거나 다른 곡) false.
    @ObservationIgnored var adoptImportedGridDraft: ((GridDraft) -> Bool)?
    /// 곡 추가·내보내기 결과 안내
    var stagingMessage: AppMessage? {
        didSet { if let stagingMessage { feedback.announce(stagingMessage) } }
    }
    /// rekordbox 반영 내보내기·검증 결과 안내
    var reflectionMessage: AppMessage? {
        didSet { if let reflectionMessage { feedback.announce(reflectionMessage) } }
    }
    /// 마지막으로 내보낸 반영 묶음(가져온 뒤 검증 대기). 앱을 다시 켜면 유스케이스가 남긴 묶음을 읽는다(`ExportXML.verifyReflection`)
    var reflectionBatch: ReflectionXMLBatch?
    /// 이번 실행에서 rekordbox에 쓴 마지막 백업(토스트·툴바의 되돌리기)
    var lastWriteBackup: URL?
    /// detail 아래쪽에 뜨는 알림(rekordbox 반영 완료 등)
    var toast: AppToast? {
        didSet {
            if let toast { feedback.announce(AppMessage(kind: toast.kind, text: [toast.title, toast.detail].compactMap { $0 }.joined(separator: "\n"))) }
        }
    }
    /// rekordbox 쓰기 단계 안내(있으면 창 전체를 덮어 조작을 막는다. 확인 창이 떠 있는 동안은 nil)
    var writeStage: WriteStage?
    /// rekordbox에 쓰는 중(미리 보기 포함)
    /// rekordbox 쓰기를 시작한 횟수(자동 시점 스냅샷이 뜨는 동안 쓰기가 끼어들었는지 본다, #228)
    @ObservationIgnored private(set) var rekordboxWriteCount = 0
    var isWritingRekordbox = false {
        didSet {
            if isWritingRekordbox, !oldValue { rekordboxWriteCount += 1 }
            if isWritingRekordbox { undoManager?.removeAllActions(withTarget: self) }
            // 쓰기·되돌리기 실패 때도 백업이 남거나 정리될 수 있다.
            if oldValue && !isWritingRekordbox { refreshWriteBackups() }
        }
    }
    /// 쓰는 동안 덱 큐 편집을 잠근다
    var onWriteLock: ((Bool) -> Void)?
    /// rekordbox에 쓰거나 되돌린 곡(UUID). 덱이 그 곡이면 다시 읽는다. 새 스냅샷을 읽은 뒤에만 부른다(#175).
    var onRekordboxWritten: ((Set<String>) -> Void)?
    /// 성공한 라이브러리 읽기 수(쓰기 뒤 다시 읽기가 실제로 끝났는지 본다)
    @ObservationIgnored private(set) var completedLoadCount = 0
    /// 라이브러리를 읽을 때마다(성공) 라이브러리 곡·추가한 곡의 음원 경로를 받는다. 앱은 조립 지점이 캐시 정리를 붙인다(시험은 없다).
    @ObservationIgnored var onLibraryLoaded: ((Set<String>) -> Void)?
    /// rekordbox에 쓰거나 되돌렸지만 아직 새 스냅샷으로 다시 읽지 못한 곡. 다음 읽기가 성공하면 덱에 알린다.
    @ObservationIgnored var writtenAwaitingReload: Set<String> = []
    /// 복원한 뒤 다시 읽지 못해 아직 쌓지 못한 재생 목록 편집(옛 목록 상태에 쌓지 않게 다음 읽기 뒤에 쌓는다)
    @ObservationIgnored var playlistEditsAwaitingReload: [PlaylistEdit] = []
    /// 마지막 쓰기·복원은 끝났지만 뒤따른 일(초안 정리·다시 읽기·복원 충돌)에 남은 경고. 쓰기 결과와 나눠 알린다.
    @ObservationIgnored var writeFollowUp: [String] = []

    /// 큐 초안이 있는 곡의 (핫큐, 메모리 큐) 개수. 목록 숫자는 반영 전에도 초안 기준으로 보여 준다.
    var draftCueCounts: [String: CueCounts] = [:]
    var draftPreviewCues: [String: [PreviewCueMark]] = [:]

    /// 큐·그리드·게인·태그 초안이 있는 곡(태그도 반영하면 rekordbox 곡 정보에 쓴다).
    /// 부를 때마다 합집합을 새로 만든다. 곡마다 거를 때는 한 번 받아 두고 쓴다(#129: 초안 600곡이면 곡을 고를 때마다 수백 ms였다).
    var pendingUUIDs: Set<String> { cueDraftUUIDs.union(gridDraftUUIDs).union(gainDraftUUIDs).union(tagDrafts.keys)
        .union(artworkDrafts.keys).union(mergeDrafts.flatMap { $0.members.map(\.trackUUID) }) }
    /// 반영 대기 중인 rekordbox 곡 수(추가한 곡 제외)
    var pendingLibraryCount: Int { pendingUUIDs.filter { rowsByUUID[$0].map { !$0.isStaged } ?? false }.count }
    /// 사이드바 'rekordbox 쓰기 대기' 배지: 쓸 곡 수 + 쓰기 대기 재생 기록 수(#43). 재생 목록 초안은 목록 구역 머리에 따로 알린다
    var pendingWriteCount: Int { pendingLibraryCount + pendingHistories.count }
    /// 백그라운드 추정이 초안을 저장했을 때(덱이 같은 곡을 보고 있으면 다시 읽게)
    var onGridDraftSaved: ((String) -> Void)?
    var onCueDraftsReloaded: (([String: CueDraft]) -> Void)?
    /// 마지막으로 읽은 초안 파일 수정 시각(바깥 변경 확인이 같으면 다시 읽지 않는다)
    @ObservationIgnored private(set) var draftFileStamps: [String: Date]?
    /// 바깥 초안 확인 순번(늦게 끝난 확인이 새 확인을 덮지 않게)과 초안 표시를 메모리에서 고친 횟수
    @ObservationIgnored var externalDraftRefreshCount = 0
    @ObservationIgnored var draftMarkRevision = 0

    /// 필터·플레이리스트·정렬까지 적용한 줄(검색 전). 검색은 이 순서를 그대로 걸러 쓴다.
    private(set) var sortedBase: [TrackRow] = []
    private var suppressRefresh = false
    /// 읽기 순서(유스케이스): 처음 열기·바뀜 확인·사본 뜨기 요청 합치기·Music 최신화·동기화 창 목록. 화면은 `readScreen`으로 붙인다
    @ObservationIgnored let readFlow: LibraryReadFlow
    /// 읽기 세대·요청 순번(`readFlow`가 세어 알린다). 늦게 끝난 읽기·Music 최신화·파일 확인·USB 사본 출처를 이것으로 가른다.
    /// 뷰가 쓰기 판정 단추(`usbSyncSourceIsCurrent`)에서 읽으므로 관찰하는 값으로 둔다.
    private(set) var reads = LibraryReadSequence()
    /// 결과 채택 전에도 조용한 다시 읽기 시작을 native USB 작업에서 구분한다.
    var snapshotReadEpoch: Int { reads.generation }
    /// 읽은 목록의 사본 지문과 그 읽기 세대(USB 작업 사본의 출처, `Usb/LibraryStore+UsbSnapshot`)
    @ObservationIgnored private(set) var usbSnapshotStamp: UsbSyncSnapshotProvenance?
    @ObservationIgnored private(set) var usbSnapshotEpoch: Int?

    private(set) var lastError: String? {
        didSet { lastErrorDismissed = false }
    }
    /// 목록 위 오류 줄을 닫았는지. 오류 상태(`lastError`)는 그대로 두고 줄만 숨긴다(#230). 새로 알리면 다시 보인다.
    private var lastErrorDismissed = false
    /// 목록 위에 보일 오류 줄
    var visibleLastError: String? { lastErrorDismissed ? nil : lastError }
    func dismissLastError() { lastErrorDismissed = true }
    private(set) var lastReadFailure: LibraryReadFailure?
    var unreadableDraftKinds: [String: Set<WritePart>] = [:]

    // 태그 시트 되돌리기(LibraryStore+Tags). 편집이 반영될 때마다 tagRevision이 올라 시트가 보이는 줄을 다시 그린다.
    var canFillDownTags = false
    var tagRevision = 0

    // MARK: - 상태 바꾸기
    // 읽은 곡·목록 줄·초안 표시·오류는 이 파일에서만 바꾼다(읽기 순번은 `readFlow`가 바꾼다). 확장(+Loading·+List·+DraftIndex …)도 아래 메서드로 고쳐,
    // 저장소를 받는 다른 코드(USB 화면 등)가 쓰기 판정의 근거(`snapshotURL`·`previewRevision` …)를 실수로 바꾸지 못하게 한다.

    func invalidatePendingLoads() { readFlow.invalidate() }
    /// 읽기 순번이 바뀌었다(`readFlow`가 알린다)
    func setReads(_ sequence: LibraryReadSequence) { reads = sequence }

    /// 읽은 곡 행을 넣는다. 지난 확인에서 없던 파일은 새 확인이 끝날 때까지 '파일 없음'으로 둔다.
    /// 초안 파일 시각도 잊어 다음 바깥 확인이 다시 읽게 한다.
    func applyLoadedRows(from loaded: LoadedLibrary) {
        let loadedRows = loaded.rows.map { row in
            var row = row
            row.fileMissing = missingPathCache.contains(row.track.folderPath)
            return row
        }
        rows = loadedRows
        rowsByID = Dictionary(loadedRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rowsByUUID = Dictionary(loadedRows.map { ($0.track.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        report = loaded.report
        filterCounts = loaded.filterCounts
        filterCounts[.missingFile] = rows.lazy.filter(LibraryFilter.missingFile.includes).count
        // 읽는 동안(백그라운드) 숨기기 설정을 알 수 없었으니, 숨기는 중이면 곡 수를 다시 센다.
        if hideStreaming { recountFilters() }
        duplicateGroups = loaded.duplicateGroups
        draftFileStamps = nil
    }

    /// 읽은 사본을 이 목록의 출처로 정한다. USB 작업 사본의 출처(`usb`)는 이 읽기 세대의 것이다.
    func adoptSnapshot(_ snapshot: URL, usb: UsbSyncSnapshotProvenance?, generation: Int) {
        snapshotURL = snapshot
        usbSnapshotStamp = usb
        usbSnapshotEpoch = generation
        onSnapshotLoaded?(snapshot)
        previewRevision += 1
    }

    /// 새 스냅샷의 rekordbox 기록과 짝짓기 키를 채택한다. 새 스냅샷이 rekordbox 기록의 원본이라 쓴 뒤 기다리던 기록 ID를 비우고
    /// 쓰기 대기를 다시 고른다(복원으로 사라진 기록은 다시 대기, #43)
    func setHistories(_ histories: [RekordboxHistory], localKeys: LocalLibraryKeys?) {
        historyLocalKeys = localKeys
        self.histories = histories
        historyIDsAwaitingReload = []
        rematchArchivedHistories()
        refreshHistoryTree()
    }

    /// 읽기가 끝났다(쓰기 뒤 다시 읽기가 실제로 끝났는지 `completedLoadCount`로 본다)
    func markLoadSucceeded() {
        phase = .loaded
        lastReadFailure = nil
        completedLoadCount += 1
    }

    /// 읽기 실패: 이미 라이브러리가 있으면 그대로 두고 오류만, 없으면 실패 화면으로 알린다.
    /// 목록 위 경고는 초안 저장 오류와 같은 자리이므로 무엇이 실패했는지 문구 앞에 적는다.
    func reportReadFailure(_ failure: LibraryReadFailure) {
        lastReadFailure = failure
        if failure.keepsPreviousLibrary {
            phase = .loaded
            lastError = failure.message
        } else {
            phase = .failed(failure.message)
        }
    }

    func reportLibraryError(_ message: String) { lastError = message }
    func clearLibraryError() { lastError = nil }

    func whileSynchronizingLibrary(_ body: () async -> Void) async {
        isSynchronizingLibrary = true
        defer { isSynchronizingLibrary = false }
        await body()
    }

    /// 덱의 곡을 정하고 덱에 알린다(nil이면 내리기)
    func setDeckTrack(_ row: TrackRow?) {
        deckTrackID = row?.track.id
        onLoadToDeck?(row)
    }

    /// 덱의 곡이 다른 ID로 바뀌었다(추가한 곡을 rekordbox에 넣음). 다음 `refreshDeckTrack`에서 새 곡으로 올린다.
    func moveDeckTrack(to id: String) { deckTrackID = id }

    // 목록 줄(`LibraryStore+List`)

    /// 숨기기까지 적용한 줄을 정렬해 둔다(검색 전 순서)
    func applyListBase(_ visible: TrackListProjection.Visible) {
        if streamingHiddenInView != visible.hiddenCount { streamingHiddenInView = visible.hiddenCount }
        hiddenStreamingRowIDs = visible.hiddenIDs
        sortedBase = sortOrder.isEmpty ? visible.rows : visible.rows.sorted(using: sortOrder)
    }

    /// 표에 보일 줄(검색·거르기 뒤)과 중복 후보 묶음
    func showRows(_ rows: [TrackRow], duplicateGroups: [LibraryRecords.DuplicateGroup] = []) {
        displayDuplicateGroups = duplicateGroups
        displayRows = rows
    }

    /// 정렬을 고치는 동안은 목록을 다시 만들지 않는다
    func withoutListRefresh(_ change: () -> Void) {
        suppressRefresh = true
        change()
        suppressRefresh = false
    }

    /// 필터별 곡 수. 숨기는 곡은 세지 않는다.
    func recountFilters() {
        let filters = LibraryFilter.visible(commentPreset: commentPreset, hidingStreaming: hideStreaming)
        filterCounts = StreamingVisibility.filterCounts(rows, filters: filters, hidingStreaming: hideStreaming,
                                                        track: { $0.track }, includes: { $0.includes($1) })
    }

    /// 코멘트 규칙을 곡 행·추가한 곡 행·보고서에 다시 적용한다
    func applyCommentRuleToRows(_ rule: (any CommentRule)?) {
        for index in rows.indices { rows[index].applyCommentRule(rule) }
        for index in stagedRows.indices { stagedRows[index].applyCommentRule(rule) }
        for row in rows + stagedRows { rowsByID[row.id] = row; rowsByUUID[row.track.uuid] = row }
        report?.applyCommentRule(rule, comments: rows.map(\.comment))
    }

    /// 곡 행 하나를 같은 UUID의 새 값으로 바꾼다
    func replaceRow(_ row: TrackRow) {
        rows = rows.map { $0.track.uuid == row.track.uuid ? row : $0 }
        rowsByUUID[row.track.uuid] = row
        rowsByID[row.track.id] = row
    }

    func setCheckingFiles(_ checking: Bool) { isCheckingFiles = checking }

    /// 파일 확인 결과를 행·'파일 없음' 개수에 넣는다(#126)
    func applyMissingFiles(_ result: MissingFiles) {
        isCheckingFiles = false
        missingFiles = result
        // 사본을 고쳐 한 번에 넣는다(곡마다 고치면 관찰 알림이 곡 수만큼 나간다).
        var updated = rows, byID = rowsByID, byUUID = rowsByUUID
        var changed = false
        for index in updated.indices {
            let missing = result.trackIDs.contains(updated[index].track.id)
            guard updated[index].fileMissing != missing else { continue }
            updated[index].fileMissing = missing
            byID[updated[index].id] = updated[index]
            byUUID[updated[index].track.uuid] = updated[index]
            changed = true
        }
        missingPathCache = Set(updated.lazy.filter(\.fileMissing).map(\.track.folderPath))
        filterCounts[.missingFile] = updated.lazy.filter(LibraryFilter.missingFile.includes).count
        guard changed else { return }
        rows = updated
        rowsByID = byID
        rowsByUUID = byUUID
        refreshBase()
    }

    // 초안 표시(`LibraryStore+DraftIndex`)

    func persistTagDrafts(_ tags: [TagDraft]) {
        rememberTagSaves(tags)
        useCases.watch.saveTags(tags)
    }

    /// 저장을 맡긴 태그 초안 곡을 기억한다(저장 실패를 이 저장소 것만 본다). 유스케이스·반영 세션이 저장한 초안도 여기에 센다
    func rememberTagSaves(_ tags: [TagDraft]) { tagSaveAttempts.formUnion(tags.map(\.trackUUID)) }

    func rememberDraftFileStamps(_ stamps: [String: Date]?) { draftFileStamps = stamps }

    /// 큐·그리드·게인 초안이 있는 곡. nil인 종류는 그대로 둔다.
    func setDraftMarks(cue: Set<String>? = nil, grid: Set<String>? = nil, gain: Set<String>? = nil) {
        if let cue { cueDraftUUIDs = cue }
        if let grid { gridDraftUUIDs = grid }
        if let gain { gainDraftUUIDs = gain }
    }

    func setDraftMark(_ kind: DeckModel.DraftKind, trackUUID: String, exists: Bool) {
        switch kind {
        case .cue: if exists { cueDraftUUIDs.insert(trackUUID) } else { cueDraftUUIDs.remove(trackUUID) }
        case .grid: if exists { gridDraftUUIDs.insert(trackUUID) } else { gridDraftUUIDs.remove(trackUUID) }
        case .gain: if exists { gainDraftUUIDs.insert(trackUUID) } else { gainDraftUUIDs.remove(trackUUID) }
        }
    }

    /// 초안이 하나라도 있는 곡을 모두 다시 센다
    func recountEdited() {
        editedUUIDs = cueDraftUUIDs.union(gridDraftUUIDs).union(gainDraftUUIDs).union(tagDrafts.keys).union(artworkDrafts.keys)
    }

    func updateEdited(_ uuid: String) {
        let edited = cueDraftUUIDs.contains(uuid) || gridDraftUUIDs.contains(uuid) || gainDraftUUIDs.contains(uuid) || tagDrafts[uuid] != nil
            || artworkDrafts[uuid] != nil
        // 바뀔 때만 건드려서 표의 ✎ 칸이 불필요하게 다시 그려지지 않게 한다.
        if edited, !editedUUIDs.contains(uuid) { editedUUIDs.insert(uuid) }
        if !edited, editedUUIDs.contains(uuid) { editedUUIDs.remove(uuid) }
    }
}
