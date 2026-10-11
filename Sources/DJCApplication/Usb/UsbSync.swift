import DJCDomain
import Foundation

/// 확인 취소 뒤에도 초안은 디스크에 남으므로 계획의 모든 입력이 같을 때만 이어 쓴다.
public struct UsbSyncPlanInputs: Sendable, Equatable {
    public var database: URL
    public var share: URL
    public var catalogRevision: Int
    public var source: UsbSyncSource
    public var volume: UsbVolumeInfo
    public var library: UsbLibrary
    public var usbBase: UsbFingerprint
    public var localDBID: Int64
    public var matches: [Int: String]
    public var badges: [Int: UsbSyncStatus]
    public var bindings: [String: UsbSyncPlaylistBinding]
    public var selection: ITunesSyncSelection
    public var syncPlaylists: Bool
    public var nativeBaseFiles: [UsbFormat: Data]
    public var nativeFingerprint: String?
    public var nativePlaylistIDs: [String: Int]
    public var nativeCanWrite: Bool
    public var nativeIssues: [String]
    public var readEpoch: Int = 0
    public var snapshotProvenance: UsbSyncSnapshotProvenance? = nil
    public var nativeRemovedPlaylistIDs: Set<Int> = []

    public init(database: URL, share: URL, catalogRevision: Int, source: UsbSyncSource, volume: UsbVolumeInfo, library: UsbLibrary,
                usbBase: UsbFingerprint, localDBID: Int64, matches: [Int: String], badges: [Int: UsbSyncStatus],
                bindings: [String: UsbSyncPlaylistBinding], selection: ITunesSyncSelection, syncPlaylists: Bool, nativeBaseFiles: [UsbFormat: Data],
                nativeFingerprint: String?, nativePlaylistIDs: [String: Int], nativeCanWrite: Bool, nativeIssues: [String], readEpoch: Int = 0,
                snapshotProvenance: UsbSyncSnapshotProvenance? = nil, nativeRemovedPlaylistIDs: Set<Int> = []) {
        self.database = database
        self.share = share
        self.catalogRevision = catalogRevision
        self.source = source
        self.volume = volume
        self.library = library
        self.usbBase = usbBase
        self.localDBID = localDBID
        self.matches = matches
        self.badges = badges
        self.bindings = bindings
        self.selection = selection
        self.syncPlaylists = syncPlaylists
        self.nativeBaseFiles = nativeBaseFiles
        self.nativeFingerprint = nativeFingerprint
        self.nativePlaylistIDs = nativePlaylistIDs
        self.nativeCanWrite = nativeCanWrite
        self.nativeIssues = nativeIssues
        self.readEpoch = readEpoch
        self.snapshotProvenance = snapshotProvenance
        self.nativeRemovedPlaylistIDs = nativeRemovedPlaylistIDs
    }
}

/// 초안에 넣은 동기화 계획과 그 입력(확인 취소 뒤 같은 입력이면 이어 쓴다)
public struct UsbSyncQueuedPlan: Sendable {
    public var edits: [UsbLibraryEdit]
    public var inputs: UsbSyncPlanInputs

    public init(edits: [UsbLibraryEdit], inputs: UsbSyncPlanInputs) {
        self.edits = edits
        self.inputs = inputs
    }

    public func canReuse(edits: [UsbLibraryEdit], inputs: UsbSyncPlanInputs) -> Bool {
        self.edits == edits && self.inputs == inputs
    }
}

/// 동기화 창의 흐름 상태와 그 판정(SYNC·가져오기·체크를 바꿀 수 있는지, 동기화 뒤 USB 목록 계획). 유스케이스 `UsbSync`가 바꾸고
/// 바뀔 때마다 화면에 내보낸다(`UsbSyncOutput.changed`). 무엇을 어떻게 보일지(트리·표시 고르기·오류 칸)는 앱 화면 모델이 정한다.
public struct UsbSyncState: Sendable {
    public internal(set) var selection = ITunesSyncSelection()
    /// "장치와 플레이리스트 동기화"
    public internal(set) var syncPlaylists = true
    /// 지금 USB에 있는 선택(선택 파일, 없으면 창을 열 때의 선택). 닫을 때 이 선택과 다르면 동기화할지 묻는다.
    public internal(set) var usbSelection = ITunesSyncSelection()
    public internal(set) var isLoading = true
    public internal(set) var isSyncing = false
    public internal(set) var isImporting = false
    /// 동기화 원본(rekordbox·iTunes 목록을 합친 트리)과 따로 본 두 트리, 목록별로 동기화할 수 없는 이유
    public internal(set) var source = PlaylistLayout()
    public internal(set) var rekordboxSource = PlaylistLayout()
    public internal(set) var iTunesSource = PlaylistLayout()
    public internal(set) var sourceBlockReasons: [String: String] = [:]
    /// 읽은 USB 라이브러리(없으면 아직 읽지 못했거나 빈 USB)
    public internal(set) var library: UsbLibrary?
    /// 내보낼 수 있는 빈 USB
    public internal(set) var emptyVolume = false
    /// USB 선택 파일을 풀며 찾은 문제(있으면 SYNC를 막는다)
    public internal(set) var nativeSelectionIssues: [String] = []
    var database: URL?
    var localDBID: Int64?
    var matches: [Int: String] = [:]
    var badges: [Int: UsbSyncStatus] = [:]
    var bindings: [String: UsbSyncPlaylistBinding] = [:]
    var nativeBaseFiles: [UsbFormat: Data] = [:]
    var nativePlaylistIDs: [String: Int] = [:]
    /// 로컬에서 지운 원본의 선택 파일 행이 가리키던 USB 목록. SYNC 때 지운다(rekordbox와 같다).
    var nativeRemovedPlaylistIDs: Set<Int> = []
    var nativeSelectionCanWrite = true
    /// USB 선택 파일의 AutomaticSync(두 형식이 같을 때만). 닫을 때 바뀌었으면 이 칸만 쓴다.
    var nativeEnabled: Bool?

    init(library: UsbLibrary?) {
        self.library = library
    }

    public var nodes: [ITunesSyncSelection.Node] { UsbSyncPlan.nodes(source) }
    /// 체크한 원본 목록만 남긴 트리
    public var selectedLayout: PlaylistLayout { UsbSyncPlan.selectedLayout(source, selection: selection) }
    /// 동기화 뒤 USB 목록 계획(쓰기 계획과 같은 규칙). 라이브러리가 없거나 계획할 수 없으면 nil
    public var afterSyncPlan: UsbSyncPlaylistPlan? {
        guard let library else { return nil }
        var counter = 0
        return try? UsbSyncPlan.playlistPlan(desired: selectedLayout, library: library, bindings: bindings,
                                             linkedPlaylistIDs: nativePlaylistIDs, removedPlaylistIDs: nativeRemovedPlaylistIDs,
                                             newKey: { counter += 1; return "preview-\(counter)" })
    }
    /// 지금 USB의 목록 트리
    public var usbLayout: PlaylistLayout { library.map(UsbSyncPlan.usbLayout) ?? PlaylistLayout() }
    /// 선택한 원본에 이어지지 않아 동기화가 건드리지 않는 USB 목록(rekordbox처럼 흐리게 보인다)
    public var unlinkedUsbIDs: Set<String> {
        guard syncPlaylists else { return [] }
        let linked = Set(selectedLayout.outline.compactMap { item in nativePlaylistIDs[item.id] ?? bindings[item.id]?.usbID }.map(String.init))
        return Set(usbLayout.outline.map(\.id)).subtracting(linked)
    }
    /// 체크한 목록 수(곡을 담는 목록만)
    public var playlistCount: Int { selectedLayout.outline.filter(\.holdsTracks).count }
    /// 체크한 목록의 곡 수(같은 곡은 한 번)
    public var trackCount: Int { Set(selectedLayout.outline.filter(\.holdsTracks).flatMap(\.trackIDs)).count }
    /// rekordbox처럼 "장치와 플레이리스트 동기화"가 꺼져 있으면 SYNC를 누를 수 없다.
    public var canSync: Bool {
        !isLoading && !isSyncing && !isImporting && database != nil && localDBID != nil && syncPlaylists
            && nativeSelectionCanWrite && nativeSelectionIssues.isEmpty
            && (library != nil || (emptyVolume && syncPlaylists && playlistCount > 0 && trackCount > 0))
    }
    public var canImport: Bool { !isLoading && !isSyncing && !isImporting && library != nil && database != nil && !matches.isEmpty }

    /// rekordbox는 "장치와 플레이리스트 동기화"가 꺼져 있으면 체크를 바꿀 수 없게 막았다(2026-10-08 실험 G5b).
    public var canEditSelection: Bool { syncPlaylists }

    /// 닫을 때 USB에 쓸 것이 있는지: "장치와 플레이리스트 동기화"를 USB 파일과 다르게 바꿨을 때만.
    /// 선택 파일이 없는 USB는 꺼짐으로 본다. rekordbox처럼 켜면 행 없는 선택 파일을 만들고, 꺼진 채면 쓰지 않는다.
    /// 라이브러리가 없는 빈 USB는 켜짐만 쓰지 않는다(rekordbox는 이때 빈 DB도 만들지만 DJCrate는 SYNC 때 함께 만든다).
    public var enabledChanged: Bool {
        UsbSyncPreferenceChoice.enabledChanged(hasNativeFiles: !nativeBaseFiles.isEmpty, nativeEnabled: nativeEnabled,
                                               hasLibrary: localDBID != nil && library != nil && !emptyVolume, syncPlaylists: syncPlaylists)
    }

    /// USB의 선택과 다르게 체크했는지. 폴더 자체 체크와 하위를 모두 체크한 것은 선택 파일에서 다르다(폴더 행 1과 2).
    public var selectionDiffersFromUsb: Bool { UsbSyncPreferenceChoice.selectionDiffers(selection, from: usbSelection, nodes: nodes) }
}

/// 동기화 창 유스케이스가 화면에 알리는 것. 화면 모델이 오류 칸(problem)·안내 칸(info)에 보인다.
public enum UsbSyncNotice: Equatable, Sendable {
    /// 막힘·실패 이유(무엇을 하면 되는지까지)
    case problem(String)
    /// 결과·안내
    case info(String)
    /// 새로 시작한 동작이 지난 오류·안내를 지운다
    case clearProblem, clearInfo
}

/// 닫기를 누른 결과
public enum UsbSyncCloseResult: Equatable, Sendable {
    /// 창을 닫는다
    case close
    /// 창을 남긴다(까닭은 알림으로 보냈다)
    case stay
    /// 동기화하지 못해 창을 남긴다. 한 번 더 닫으면 USB에 쓰지 않고 닫는다(화면이 그렇게 알린다)
    case stayUntilNextClose
}

/// 동기화 창 유스케이스가 화면으로 내보내는 출력 포트. 앱 화면 모델이 자기 관찰 상태와 오류·안내 칸으로 옮긴다.
@MainActor
public struct UsbSyncOutput {
    /// 흐름 상태가 바뀔 때마다
    public var changed: @MainActor (UsbSyncState) -> Void
    public var notice: @MainActor (UsbSyncNotice) -> Void

    public init(changed: @escaping @MainActor (UsbSyncState) -> Void, notice: @escaping @MainActor (UsbSyncNotice) -> Void) {
        self.changed = changed
        self.notice = notice
    }
}

/// USB 동기화 창의 유스케이스(rekordbox의 "장치와 플레이리스트 동기화"): 열 때 로컬 원본·USB 선택 파일·설정을 읽고(`load`),
/// 체크를 바꾸면 설정에 저장하고, SYNC면 계획을 초안으로 만들어 다른 USB 쓰기와 같은 흐름으로 쓰고(`sync`), 닫을 때 바꾼 것이
/// 있으면 묻는다(`close`). 순서·판정·뒤처리는 모두 여기 있다. 화면 상태는 들지 않는다: 흐름 상태(`state`)와 알림을 출력 포트로
/// 내보내고, 앱 화면 모델(`UsbSyncModel`)이 관찰 상태·표시 트리·오류 칸으로 옮겨 보인다.
/// 읽는 동안·쓰는 동안 라이브러리·USB가 바뀌면 옛 입력으로 쓰지 않는다(바뀐 것을 다시 볼 때마다 지금 값을 포트로 읽는다).
@MainActor
public final class UsbSync {
    public let volumeKey: String
    /// 흐름 상태. 바뀔 때마다 `output.changed`로 내보낸다
    public private(set) var state: UsbSyncState { didSet { output?.changed(state) } }
    /// 화면 쪽 출력(화면 모델이 만든 뒤 붙인다)
    public var output: UsbSyncOutput?
    public var selection: ITunesSyncSelection {
        get { state.selection }
        set { state.selection = newValue; selectionChanged() }
    }
    public var syncPlaylists: Bool {
        get { state.syncPlaylists }
        set { state.syncPlaylists = newValue; selectionChanged() }
    }
    private var loadedSources: UsbSyncSource?
    private var loadedVolume: UsbVolumeInfo?
    private var usbBase: UsbFingerprint?
    private var catalogRevision: Int?
    private var readEpoch: Int?
    private var snapshotProvenance: UsbSyncSnapshotProvenance?
    private var snapshotLease: UsbSyncSnapshotLease?
    private var nativeSelectionFingerprint: String?
    /// masterPlaylists6.xml의 NODE. 선택 파일의 Timestamp를 옮긴다.
    private var masterNodes: [MasterPlaylistNode] = []
    /// 닫으며 쓰지 못한 뒤 다시 닫으면 그대로 닫는다(초안은 쓰기 대기에 남는다).
    private var closeDeclined = false
    /// 닫기가 확인 창·쓰기를 기다리는 중. 그 사이 다시 닫으면 들어가지 않는다.
    private var isClosing = false
    /// 계획한 동기화가 USB를 비우지 않으려고 빼지 않은 곡 수(쓴 뒤 알린다)
    private var keptOrphanCount = 0
    /// 마지막으로 연 때의 포트(체크를 바꿀 때 설정을 저장한다)
    private var ports: UsbSyncPorts?
    private var saveChain: Task<Bool, Never>?
    private var queuedPlan: UsbSyncQueuedPlan?

    public init(volumeKey: String, library: UsbLibrary? = nil) {
        self.volumeKey = volumeKey
        state = UsbSyncState(library: library)
    }

    private func notify(_ notice: UsbSyncNotice) { output?.notice(notice) }

    // MARK: - 체크

    public func selectAll() { guard state.canEditSelection else { return }; selection = ITunesSyncSelection(selectedIDs: ["0"]) }
    public func clearSelection() { guard state.canEditSelection else { return }; selection = ITunesSyncSelection() }
    public func selectAllRekordbox() { setSelected(true, id: UsbSyncSource.rekordboxSelectionID) }
    public func clearRekordboxSelection() { setSelected(false, id: UsbSyncSource.rekordboxSelectionID) }
    public func selectAllITunes() { setSelected(true, id: UsbSyncSource.iTunesSelectionID) }
    public func clearITunesSelection() { setSelected(false, id: UsbSyncSource.iTunesSelectionID) }
    public func toggle(_ id: String) { setSelected(selection.state(of: id, in: state.nodes) != .on, id: id) }
    private func setSelected(_ selected: Bool, id: String) {
        guard state.canEditSelection else { return }
        selection.setSelected(selected, id: id, in: state.nodes)
    }

    // MARK: - 열기

    public func load(_ ports: UsbSyncPorts) async {
        guard !state.isSyncing, !state.isImporting else { return }
        self.ports = ports
        // 새로 읽은 상태를 옛 디스크 초안의 계획 입력으로 삼지 않는다. 초안 자체는 대기 목록에 보존한다.
        queuedPlan = nil
        loadedSources = nil
        loadedVolume = nil
        usbBase = nil
        state.source = PlaylistLayout()
        state.rekordboxSource = PlaylistLayout()
        state.iTunesSource = PlaylistLayout()
        state.sourceBlockReasons = [:]
        state.matches = [:]
        state.badges = [:]
        state.bindings = [:]
        state.isLoading = true
        state.database = nil
        state.localDBID = nil
        catalogRevision = nil
        readEpoch = nil
        snapshotProvenance = nil
        snapshotLease = nil
        notify(.clearProblem)
        notify(.clearInfo)
        state.nativeSelectionIssues = []
        nativeSelectionFingerprint = nil
        state.nativeBaseFiles = [:]
        state.nativePlaylistIDs = [:]
        state.nativeRemovedPlaylistIDs = []
        state.nativeSelectionCanWrite = true
        state.nativeEnabled = nil
        masterNodes = []
        closeDeclined = false
        state.usbSelection = ITunesSyncSelection()
        // USB 내용은 로컬 목록과 설정을 읽기 전에도 보여 준다.
        let opened = ports.volume()
        state.library = opened.library
        state.emptyVolume = opened.isEmptyExportable
        guard let snapshot = ports.library().snapshot, let volume = opened.volume else {
            notify(.problem(String(ui: "로컬 라이브러리와 USB를 다시 읽은 뒤 동기화 창을 여세요")))
            state.isLoading = false
            return
        }
        let sources = ports.sources()
        let source = sources.layout
        state.source = source
        state.rekordboxSource = sources.rekordbox
        state.iTunesSource = sources.iTunes
        state.sourceBlockReasons = sources.notices
        let before = ports.library()
        let revision = before.revision
        let epoch = before.readEpoch
        guard let lease = await ports.leaseSnapshot(), ports.library().readEpoch == epoch,
              ports.library().snapshot == snapshot, ports.library().revision == revision, ports.sources() == sources,
              ports.volume().volume == volume else {
            notify(.problem(String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")))
            state.isLoading = false
            return
        }
        let library = ports.volume().library
        let preferencesFiles = ports.preferences
        let key = volumeKey
        let formats = library?.formats ?? UsbFormat.defaultSet
        let service = ports.service
        let files = ports.files, keys = ports.localKeys
        let wasEmpty = state.emptyVolume
        // 라이브 폴더가 아니라 스냅샷을 뜰 때 함께 복사한 사본을 읽는다. 없으면(옛 스냅샷) 체크한 목록을 쓸 때 막힌다.
        let result = await BlockingWork.run {
            () -> Result<(LocalLibraryKeys, Result<UsbSyncPreferences?, any Error>, UsbSyncNativeSelection, UsbFingerprint, [MasterPlaylistNode]), any Error> in
            Result {
                guard let files, let keys else { throw UsbSyncUnavailable() }
                let local = try keys.load(lease.database)
                let current = try service.currentVolume(volume)
                let native = try files.selection(URL(filePath: current.mountPoint), formats)
                let prefs = Result { try preferencesFiles.map { try $0.load(key) } ?? nil }
                let master = files.masterNodes(snapshot)
                return (local, prefs, native, try service.draftBase(current), master)
            }
        }
        defer { state.isLoading = false }
        let after = ports.library(), now = ports.volume()
        guard !Task.isCancelled, after.readEpoch == epoch, after.provenance == lease.provenance,
              after.snapshot == snapshot, after.revision == revision, now.volume == volume,
              ports.sources() == sources, now.library == library,
              now.isEmptyExportable == wasEmpty else {
            notify(.problem(String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")))
            return
        }
        switch result {
        case .failure:
            // 원본 선택 파일에는 개인 식별값이 있으므로 파서 오류의 원문을 로그에 싣지 않는다.
            notify(.problem(String(ui: "USB 동기화 선택이나 로컬 라이브러리를 읽지 못했습니다. USB와 라이브러리를 새로고침한 뒤 다시 시도하세요")))
        case let .success((local, preferences, native, base, master)):
            state.library = library
            masterNodes = master
            loadedSources = sources
            loadedVolume = volume
            usbBase = base
            state.database = snapshot
            catalogRevision = revision
            readEpoch = epoch
            snapshotProvenance = lease.provenance
            snapshotLease = lease
            state.localDBID = local.localDBID
            state.emptyVolume = now.isEmptyExportable
            nativeSelectionFingerprint = native.semanticFingerprint
            state.nativeBaseFiles = native.baseFiles
            let resolved = native.resolve(sources.nativeNodes, local.localDBID, library, Self.masterNodeIDs(master))
            state.nativePlaylistIDs = resolved.playlistIDs
            state.nativeRemovedPlaylistIDs = resolved.removedSourcePlaylistIDs
            state.nativeEnabled = native.baseFiles.isEmpty ? nil : resolved.enabled
            state.nativeSelectionCanWrite = resolved.canWrite
            state.nativeSelectionIssues = resolved.issues.map(\.message)
            let prefs: UsbSyncPreferences?
            switch preferences {
            case let .success(saved): prefs = saved
            case .failure:
                prefs = nil
                notify(.problem(String(ui: "USB 동기화 설정을 읽지 못했습니다. 데이터 폴더의 usb-sync-selections 파일을 확인한 뒤 다시 시도하세요")))
            }
            let choice = UsbSyncPreferenceChoice.resolve(preferences: prefs, localDBID: local.localDBID,
                                                        hasNativeFiles: !native.baseFiles.isEmpty, fingerprint: native.semanticFingerprint,
                                                        nativeSelection: resolved.selection, nativeEnabled: resolved.enabled,
                                                        fallbackSelection: library.map { UsbSyncPlan.initialSelection(source: source, library: $0) } ?? ITunesSyncSelection(),
                                                        currentEnabled: syncPlaylists)
            selection = choice.selection
            state.usbSelection = choice.selection
            syncPlaylists = choice.enabled
            state.bindings = choice.usesSavedPreferences ? prefs?.bindings ?? [:] : [:]
            // 원본 ID를 USB 현재 폴더에 직접 잇는다. 이름 변경도 같은 목록으로 따라간다.
            for (sourceID, usbID) in state.nativePlaylistIDs {
                guard let item = state.source.item(sourceID), let usbItem = state.usbLayout.item(String(usbID)),
                      item.isFolder == usbItem.isFolder else { continue }
                state.bindings[sourceID] = UsbSyncPlaylistBinding(usbID: usbID, path: UsbSyncPlan.path(usbItem, in: state.usbLayout),
                                                           isFolder: item.isFolder)
            }
            let availableIDs = Set(state.nodes.map(\.id)).union(["0"])
            if !selection.selectedIDs.isSubset(of: availableIDs) {
                state.nativeSelectionIssues.append(String(ui: "USB에서 선택했던 원본 목록을 찾지 못했습니다. iTunes와 rekordbox 목록을 다시 읽거나 rekordbox에서 USB 동기화 선택을 확인하세요"))
            }
            if let library {
                let evaluated = UsbSyncBadges.evaluate(library: library, local: local)
                state.matches = evaluated.matches
                state.badges = evaluated.badges
            } else {
                state.matches = [:]
                state.badges = [:]
            }
        }
    }

    private func sourcesAreCurrent(_ ports: UsbSyncPorts) -> Bool {
        let current = ports.library()
        return loadedSources == ports.sources() && readEpoch == current.readEpoch
            && snapshotProvenance != nil && snapshotProvenance == current.provenance
    }

    private func planInputs(_ ports: UsbSyncPorts, volume: UsbVolumeInfo) -> UsbSyncPlanInputs? {
        guard let database = state.database, let catalogRevision, let readEpoch, let loadedSources, let library = state.library, let usbBase,
              let localDBID = state.localDBID else { return nil }
        return UsbSyncPlanInputs(database: database, share: ports.library().share,
                                 catalogRevision: catalogRevision, source: loadedSources, volume: volume,
                                 library: library, usbBase: usbBase, localDBID: localDBID, matches: state.matches, badges: state.badges,
                                 bindings: state.bindings, selection: selection, syncPlaylists: syncPlaylists,
                                 nativeBaseFiles: state.nativeBaseFiles, nativeFingerprint: nativeSelectionFingerprint,
                                 nativePlaylistIDs: state.nativePlaylistIDs, nativeCanWrite: state.nativeSelectionCanWrite,
                                 nativeIssues: state.nativeSelectionIssues, readEpoch: readEpoch, snapshotProvenance: snapshotProvenance,
                                 nativeRemovedPlaylistIDs: state.nativeRemovedPlaylistIDs)
    }

    private func inputsAreCurrent(_ inputs: UsbSyncPlanInputs, _ ports: UsbSyncPorts) -> Bool {
        let current = ports.library(), usb = ports.volume()
        return state.database == current.snapshot && catalogRevision == current.revision && sourcesAreCurrent(ports)
            && usb.volume == inputs.volume && state.library == usb.library
            && state.emptyVolume == usb.isEmptyExportable
            && planInputs(ports, volume: inputs.volume) == inputs
            && !current.isLoading && !current.isWriting && !usb.isEjecting
            && queuedPlan?.canReuse(edits: usb.draftEdits, inputs: inputs) == true
    }

    /// USB를 다시 읽고 처음부터 다시 연다(바꾼 체크는 먼저 저장한다)
    public func refresh(_ ports: UsbSyncPorts) async {
        guard !state.isLoading, !state.isSyncing, !state.isImporting, !ports.volume().isWriting else { return }
        state.isLoading = true
        queuedPlan = nil
        snapshotLease = nil
        defer { state.isLoading = false }
        if state.localDBID != nil, !(await savePreferences(ports)) { return }
        await ports.refreshUsb()
        await load(ports)
    }

    private func selectionChanged() {
        guard !state.isLoading else { return }
        queuedPlan = nil
        snapshotLease = nil
        notify(.clearInfo)
        if let ports { Task { await savePreferences(ports) } }
    }

    /// 연속으로 고른 선택도 누른 차례로 저장해 이전 선택이 나중에 남지 않게 한다.
    @discardableResult
    private func savePreferences(_ ports: UsbSyncPorts) async -> Bool {
        guard let localDBID = state.localDBID else { return false }
        guard let files = ports.preferences else { return true }
        let prefs = UsbSyncPreferences(volumeKey: volumeKey, localDBID: localDBID, selection: selection,
                                       syncPlaylists: syncPlaylists, bindings: state.bindings,
                                       nativeSelectionFingerprint: nativeSelectionFingerprint)
        let previous = saveChain
        let log = ports.log
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            let result = await BlockingWork.run(qos: .utility) { Result { try files.save(prefs) } }
            if case let .failure(failure) = result {
                log(failure)
                self?.notify(.problem(String(ui: "USB 동기화 설정을 저장하지 못했습니다. 데이터 폴더의 usb-sync-selections 파일을 확인한 뒤 다시 시도하세요")))
                return false
            }
            return true
        }
        saveChain = task
        return await task.value
    }

    // MARK: - SYNC

    private func changedError() {
        notify(.problem(String(ui: "라이브러리가 바뀌었습니다. 동기화 목록을 새로고침한 뒤 다시 시도하세요")))
    }

    /// 계획 → 초안 → USB 쓰기(다른 USB 쓰기와 같은 미리 보기·확인 창). 쓰고 다시 읽었으면 true
    public func sync(_ ports: UsbSyncPorts) async -> Bool {
        defer { snapshotLease = nil }
        let opened = ports.library(), usbNow = ports.volume()
        guard state.canSync, !opened.isLoading, !opened.isWriting, opened.allowsInteraction,
              !usbNow.isWriting, !usbNow.isEjecting, let volume = usbNow.volume else { return false }
        notify(.clearProblem)
        notify(.clearInfo)
        guard state.database == opened.snapshot, catalogRevision == opened.revision,
              sourcesAreCurrent(ports), state.library == usbNow.library, loadedVolume == volume,
              state.emptyVolume == usbNow.isEmptyExportable else {
            changedError()
            return false
        }
        if let reason = loadedSources?.blockReason(selection: selection) {
            notify(.problem(reason))
            return false
        }
        state.isSyncing = true
        // 실행 중에는 아래 지역 소유자가 유지하고, 저장한 native 초안은 USB 화면이 창을 닫은 뒤에도 이어 소유한다.
        defer { state.isSyncing = false }
        let running = await BlockingWork.run(qos: .utility) { [service = ports.service] in service.isRekordboxRunning() }
        guard !running else {
            notify(.problem(String(ui: "rekordbox와 rekordboxAgent를 종료한 뒤 USB와 동기화하세요")))
            return false
        }
        guard await nativeFilesAreCurrent(ports, volume: volume) else { return false }
        if let block = ports.service.syncGate.gateBlock(state.nativeBaseFiles, state.library?.formats ?? UsbFormat.defaultSet) {
            notify(.problem(block.message))
            return false
        }
        if UsbSyncSource.lacksMasterNode(UsbSyncSource.nativeNodes(state.source, master: masterNodes), selection: selection) {
            notify(.problem(String(ui: "masterPlaylists6.xml에서 동기화할 목록을 찾지 못했습니다. rekordbox를 한 번 켰다가 종료하고 새 스냅샷을 읽은 뒤 동기화하세요")))
            return false
        }
        guard await savePreferences(ports), ports.volume().volume == volume else { return false }
        let saved = ports.library(), usbSaved = ports.volume()
        guard state.database == saved.snapshot, catalogRevision == saved.revision,
              sourcesAreCurrent(ports),
              state.library == usbSaved.library, loadedVolume == volume,
              state.emptyVolume == usbSaved.isEmptyExportable,
              !saved.isLoading, !saved.isWriting else {
            changedError()
            return false
        }
        if let reason = loadedSources?.blockReason(selection: selection) {
            notify(.problem(reason))
            return false
        }
        if snapshotLease == nil { snapshotLease = await ports.leaseSnapshot() }
        guard let lease = snapshotLease, sourcesAreCurrent(ports), ports.volume().volume == volume,
              lease.provenance == snapshotProvenance, let readEpoch else {
            changedError()
            return false
        }
        // rekordbox처럼 USB에 넣을 수 없는 곡(잇지 못한 iTunes 곡·스트리밍 곡 등)은 빼고 동기화하고, 넣지 못한 곡으로 알린다
        let localSkips = skippedLocalTracks(ports.localSkip)
        let skippedTracks = skippedTrackBlocks(localSkips: localSkips)
        if state.emptyVolume {
            guard syncPlaylists, let writer = ports.writer,
                  let localDBID = state.localDBID, let loadedSources, let catalogRevision else { return false }
            let topIDs = state.selectedLayout.childIDs(of: PlaylistLayout.root)
            let job = UsbExportJob(database: lease.database, share: ports.library().share,
                                   volume: volume, selection: .playlists(topIDs), formats: UsbFormat.defaultSet, snapshotTime: lease.provenance.snapshotTime,
                                   playlistLayout: UsbSyncPlan.removing(Set(localSkips.keys), from: state.selectedLayout),
                                   syncSelection: UsbSyncSelectionDraft(localDBID: localDBID, sourceNodes: UsbSyncSource.nativeNodes(state.source, master: masterNodes),
                                                                        selection: selection, enabled: syncPlaylists,
                                                                        playlistRefs: [:], baseFiles: state.nativeBaseFiles,
                                                                        skippedTracks: skippedTracks),
                                   syncSourceContext: UsbExportSyncSourceContext(source: loadedSources, catalogRevision: catalogRevision,
                                                                                 readEpoch: readEpoch, snapshot: lease.reference),
                                   snapshotLease: lease)
            guard await writer.export(job) else {
                notify(writer.lastNoticeDetail().map(UsbSyncNotice.info) ?? .clearInfo)
                return false
            }
            if let written = ports.volume().library {
                state.bindings = UsbSyncPlan.bindings(source: state.source, target: state.selectedLayout, library: written)
                state.usbSelection = selection
                guard await adoptWrittenNativeFiles(ports) else { return false }
                _ = await savePreferences(ports)
                return true
            }
            notify(writer.lastNoticeDetail().map(UsbSyncNotice.info) ?? .clearInfo)
            return false
        }
        guard let localDBID = state.localDBID, let drafts = ports.drafts, let writer = ports.writer,
              let inputs = planInputs(ports, volume: volume) else { return false }
        let draft = ports.volume().draftEdits
        if !draft.isEmpty {
            guard queuedPlan?.canReuse(edits: draft, inputs: inputs) == true else {
                notify(.problem(String(ui: "이 USB에 쓰기 대기 중인 초안이 있습니다. 쓰기 대기 목록에서 쓰거나 버린 뒤 동기화하세요")))
                return false
            }
        } else {
            do {
                var edits: [UsbLibraryEdit] = []
                keptOrphanCount = 0
                var refs = state.nativePlaylistIDs.mapValues { PlaylistRef.id(String($0)) }
                for (sourceID, binding) in state.bindings where refs[sourceID] == nil {
                    refs[sourceID] = .id(String(binding.usbID))
                }
                if syncPlaylists {
                    let plan = try UsbSyncPlan.build(source: inputs.source, selection: selection, library: inputs.library, matches: state.matches,
                                                     badges: state.badges, bindings: state.bindings, linkedPlaylistIDs: inputs.nativePlaylistIDs,
                                                     removedPlaylistIDs: inputs.nativeRemovedPlaylistIDs, excluding: Set(localSkips.keys),
                                                     newKey: ports.newPlaylistKey)
                    edits = plan.edits
                    refs.merge(plan.playlistRefs) { _, planned in planned }
                    keptOrphanCount = plan.keptOrphanTrackIDs.count
                    // rekordbox처럼 어느 목록에도 남지 않는 USB 곡은 확인을 받고 뺀다. 음원 파일은 곡 빼기 규칙을 따른다.
                    if !plan.orphanTrackIDs.isEmpty {
                        guard ports.confirmation.confirm(Self.orphanPrompt(count: plan.orphanTrackIDs.count)) else {
                            notify(.info(String(ui: "동기화를 취소했습니다. USB는 그대로입니다.")))
                            return false
                        }
                        edits.append(.removeTracks(usbContentIDs: plan.orphanTrackIDs))
                    }
                }
                // 목록 내용이 같아도 선택·상위 부분 체크와 동기화 켜짐은 USB 파일에 따로 써야 한다.
                edits.append(.syncSelection(draft: UsbSyncSelectionDraft(localDBID: localDBID,
                                                                         sourceNodes: UsbSyncSource.nativeNodes(state.source, master: masterNodes),
                                                                         selection: selection, enabled: syncPlaylists,
                                                                         playlistRefs: refs, baseFiles: state.nativeBaseFiles,
                                                                         skippedTracks: syncPlaylists ? skippedTracks : [])))
                if let reason = drafts.blockReason(edits) {
                    notify(.problem(reason))
                    return false
                }
                guard await drafts.append(edits, String(ui: "재생 목록 동기화")) else {
                    notify(.problem(String(ui: "USB 동기화 초안을 저장하지 못했습니다. 데이터 폴더를 확인한 뒤 다시 시도하세요")))
                    return false
                }
                queuedPlan = UsbSyncQueuedPlan(edits: edits, inputs: inputs)
            } catch let failure as PlaylistLayout.Blocked {
                notify(.problem(failure.reason))
                return false
            } catch {
                ports.log(error)
                notify(.problem(String(ui: "USB 동기화를 준비하지 못했습니다. 목록을 새로고침한 뒤 다시 시도하세요")))
                return false
            }
        }
        guard inputsAreCurrent(inputs, ports) else {
            queuedPlan = nil
            changedError()
            return false
        }
        guard await nativeFilesAreCurrent(ports, volume: volume) else { queuedPlan = nil; return false }
        guard inputsAreCurrent(inputs, ports) else {
            queuedPlan = nil
            changedError()
            return false
        }
        // 계획 뒤 곡 상태가 바뀌었으면(빼는 곡이 달라짐) 계획한 초안을 쓰지 않는다
        guard skippedLocalTracks(ports.localSkip) == localSkips else {
            queuedPlan = nil
            changedError()
            return false
        }
        let job = UsbEditJob(database: lease.database, share: inputs.share, volume: inputs.volume,
                             snapshotTime: lease.provenance.snapshotTime,
                             syncSourceContext: .init(source: inputs.source, catalogRevision: inputs.catalogRevision,
                                                      readEpoch: inputs.readEpoch, snapshot: lease.reference))
        guard await writer.writeSyncDraft(job, ports.volume().draftEdits) else {
            notify(writer.lastNoticeDetail().map(UsbSyncNotice.info) ?? .clearInfo)
            return false
        }
        guard ports.volume().draftEdits.isEmpty, let written = ports.volume().library else {
            notify(.info(String(ui: "동기화 초안은 USB 쓰기 대기에 남았습니다. 쓰기 대기 목록에서 결과와 막힌 이유를 확인하세요")))
            return false
        }
        queuedPlan = nil
        state.bindings = UsbSyncPlan.bindings(source: state.source, target: state.selectedLayout, library: written)
        state.usbSelection = selection
        guard await adoptWrittenNativeFiles(ports) else { return false }
        _ = await savePreferences(ports)
        if keptOrphanCount > 0 { notify(.info(Self.keptOrphansNotice(count: keptOrphanCount))) }
        return true
    }

    /// 곡 빼기를 생략했을 때 알림. rekordbox는 확인 창 뒤 곡을 뺐지만 DJCrate는 곡 0개 라이브러리를 쓰지 않는다(모양 미확인)
    public nonisolated static func keptOrphansNotice(count: Int) -> String {
        String(ui: "USB에 곡이 하나도 남지 않게 되어 어느 재생 목록에도 없는 곡 \(count)개는 빼지 않았습니다. 곡까지 지우려면 USB를 비운 뒤 새로 내보내세요")
    }

    /// 선택한 목록 중 USB에 넣을 수 없는 로컬 곡(스트리밍·추가 대기·찾지 못한 곡). 동기화는 이 곡만 빼고 쓴다
    /// - Parameter kind: 로컬 곡을 USB에 넣을 수 없는 까닭(`UsbSyncPorts.localSkip`)
    public func skippedLocalTracks(_ kind: (String) -> UsbSyncSource.LocalSkip?) -> [String: UsbBlock] {
        guard syncPlaylists else { return [:] }
        return UsbSyncSource.skippedLocalTracks(state.selectedLayout, kind: kind)
    }

    /// 동기화 계획이 USB에 넣지 않고 건너뛸 곡(잇지 못한 iTunes 곡 + 넣을 수 없는 로컬 곡, 목록 순서대로)
    private func skippedTrackBlocks(localSkips: [String: UsbBlock]) -> [UsbBlock] {
        guard syncPlaylists else { return [] }
        var seen = Set<String>()
        let local = state.selectedLayout.outline.filter(\.holdsTracks).flatMap(\.trackIDs).compactMap { id in
            seen.insert(id).inserted ? localSkips[id] : nil
        }
        return (loadedSources?.skippedITunesTracks(selection: selection) ?? []) + local
    }

    /// SYNC 전에 알릴 것: 동기화가 USB에 넣지 않고 건너뛸 곡(잇지 못한 iTunes 곡 + 넣을 수 없는 로컬 곡, 목록 순서대로).
    /// 음원·분석 파일 문제는 쓰기 확인 창에서 더 알린다
    public func skippedTracks(_ kind: (String) -> UsbSyncSource.LocalSkip?) -> [UsbBlock] {
        skippedTrackBlocks(localSkips: skippedLocalTracks(kind))
    }

    /// masterPlaylists6.xml의 rekordbox NODE Id. 못 읽었으면 nil(지운 원본을 판정하지 않고 막는다)
    public nonisolated static func masterNodeIDs(_ nodes: [MasterPlaylistNode]) -> Set<String>? {
        let ids = nodes.filter { $0.libType == 0 }.map(\.id)
        return ids.isEmpty ? nil : Set(ids)
    }

    /// rekordbox의 내보내기 확인 창과 같은 문구(OK/취소). 취소하면 동기화 전체를 하지 않는다.
    public nonisolated static func orphanPrompt(count: Int) -> ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "플레이리스트에 더 이상 존재하지 않는 트랙은 삭제될 것입니다."),
                         text: String(ui: "USB의 어느 재생 목록에도 남지 않는 곡 \(count)개를 USB에서 뺍니다. 음원 파일은 다른 곡이 쓰지 않을 때만 지웁니다."),
                         confirm: String(ui: "확인"), destructive: true)
    }

    // MARK: - 닫기

    /// rekordbox의 닫기 확인과 같은 문구(예/아니오)
    public nonisolated static var unsyncedClosePrompt: ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "변경 사항이 동기화되지 않았습니다."),
                         text: String(ui: "변경한 내용을 지금 바로 동기화합니까?"),
                         confirm: String(ui: "예"), cancel: String(ui: "아니오"))
    }

    /// 동기화하지 않고 닫을 때 바꾼 체크를 버린다. rekordbox도 "아니오"로 닫으면 체크 변경을 버렸다(2026-10-08 실험 G2a).
    public func discardUnsyncedSelection() {
        guard selection != state.usbSelection else { return }
        selection = state.usbSelection
    }

    /// 닫기를 시작한다. 이미 닫는 중이면 false(확인 창·쓰기를 기다리는 사이 다시 불린 닫기)
    public func beginClosing() -> Bool {
        guard !isClosing else { return false }
        isClosing = true
        return true
    }

    public func endClosing() { isClosing = false }

    /// rekordbox처럼 동기화가 켜진 채 바뀐 것이 있으면 지금 동기화할지 묻고, "예"면 SYNC와 같은 흐름으로 쓴다.
    /// "아니오"나 꺼진 채 닫으면 바꾼 체크는 버리고, 동기화 켜짐을 바꿨으면 두 선택 파일의 AutomaticSync만 쓴다
    /// (다른 칸·선택은 그대로, G5c에서 켜고 "아니오"로 닫아도 이 칸만 바뀌었다). 다른 USB 쓰기와 같은 미리 보기·확인 창을 거친다.
    public func close(_ ports: UsbSyncPorts) async -> UsbSyncCloseResult {
        guard !state.isLoading, !state.isSyncing, !state.isImporting else { return .close }
        // 가드 바로 뒤에 표시한다. 아래 확인 창·저장·쓰기를 기다리는 동안 다시 닫으면 같은 쓰기를 두 번 시작했다.
        // 첫 닫기가 결과를 정하므로 두 번째는 창을 남긴다.
        guard beginClosing() else { return .stay }
        defer { endClosing() }
        if !closeDeclined, UsbSyncPreferenceChoice.asksToSyncOnClose(syncPlaylists: syncPlaylists, canSync: state.canSync,
                                                                      selectionDiffers: state.selectionDiffersFromUsb, enabledChanged: state.enabledChanged) {
            if ports.confirmation.confirm(Self.unsyncedClosePrompt) {
                if await sync(ports) { return .close }
                // 동기화하지 못했으면 이유(sync가 알렸다)를 보이고 창을 남긴다. 한 번 더 닫으면 묻지 않고 닫는다.
                closeDeclined = true
                return .stayUntilNextClose
            }
        }
        discardUnsyncedSelection()
        if state.localDBID != nil { _ = await savePreferences(ports) }
        guard state.enabledChanged, !closeDeclined else { return .close }
        notify(.clearProblem)
        notify(.clearInfo)
        func decline(_ reason: String) -> UsbSyncCloseResult {
            closeDeclined = true
            notify(.problem(reason))
            return .stayUntilNextClose
        }
        let current = ports.library(), usb = ports.volume()
        guard let volume = usb.volume, !usb.isWriting, !usb.isEjecting,
              !current.isLoading, !current.isWriting, current.allowsInteraction,
              let localDBID = state.localDBID, let drafts = ports.drafts, let writer = ports.writer,
              state.database == current.snapshot, catalogRevision == current.revision, sourcesAreCurrent(ports),
              state.library == usb.library, loadedVolume == volume else {
            return decline(String(ui: "라이브러리가 바뀌어 USB 동기화 켜짐을 저장하지 못했습니다. 새로고침한 뒤 다시 바꾸세요"))
        }
        if let block = ports.service.syncGate.gateBlock(state.nativeBaseFiles, state.library?.formats ?? UsbFormat.defaultSet) {
            return decline(block.message)
        }
        guard usb.draftEdits.isEmpty else {
            return decline(String(ui: "이 USB에 쓰기 대기 중인 초안이 있어 동기화 켜짐을 저장하지 못했습니다. 쓰기 대기 목록에서 쓰거나 버린 뒤 다시 바꾸세요"))
        }
        state.isSyncing = true
        defer { state.isSyncing = false; snapshotLease = nil }
        let running = await BlockingWork.run(qos: .utility) { [service = ports.service] in service.isRekordboxRunning() }
        guard !running else { return decline(String(ui: "rekordbox와 rekordboxAgent를 종료한 뒤 USB와 동기화하세요")) }
        guard await nativeFilesAreCurrent(ports, volume: volume) else { closeDeclined = true; return .stay }
        guard await savePreferences(ports) else { closeDeclined = true; return .stay }
        if snapshotLease == nil { snapshotLease = await ports.leaseSnapshot() }
        guard let lease = snapshotLease, lease.provenance == snapshotProvenance, sourcesAreCurrent(ports),
              ports.volume().volume == volume, let inputs = planInputs(ports, volume: volume) else {
            return decline(String(ui: "라이브러리가 바뀌어 USB 동기화 켜짐을 저장하지 못했습니다. 새로고침한 뒤 다시 바꾸세요"))
        }
        let edits: [UsbLibraryEdit] = [.syncSelection(draft: .enabledOnly(localDBID: localDBID, enabled: syncPlaylists,
                                                                          baseFiles: state.nativeBaseFiles))]
        if let reason = drafts.blockReason(edits) { return decline(reason) }
        guard await drafts.append(edits, String(ui: "USB 동기화 켜짐 저장")) else {
            return decline(String(ui: "USB 동기화 초안을 저장하지 못했습니다. 데이터 폴더를 확인한 뒤 다시 시도하세요"))
        }
        queuedPlan = UsbSyncQueuedPlan(edits: edits, inputs: inputs)
        guard inputsAreCurrent(inputs, ports) else {
            queuedPlan = nil
            return decline(String(ui: "라이브러리가 바뀌어 USB 동기화 켜짐을 저장하지 못했습니다. 새로고침한 뒤 다시 바꾸세요"))
        }
        let job = UsbEditJob(database: lease.database, share: inputs.share, volume: inputs.volume,
                             snapshotTime: lease.provenance.snapshotTime,
                             syncSourceContext: .init(source: inputs.source, catalogRevision: inputs.catalogRevision,
                                                      readEpoch: inputs.readEpoch, snapshot: lease.reference))
        guard await writer.writeSyncDraft(job, ports.volume().draftEdits),
              ports.volume().draftEdits.isEmpty else {
            closeDeclined = true
            notify(.info(String(ui: "동기화 켜짐 초안은 USB 쓰기 대기에 남았습니다. 쓰기 대기 목록에서 결과와 막힌 이유를 확인하세요")))
            return .stay
        }
        queuedPlan = nil
        _ = await adoptWrittenNativeFiles(ports)
        _ = await savePreferences(ports)
        return .close
    }

    // MARK: - 선택 파일 다시 읽기

    /// 다른 앱이 선택 파일을 바꾼 뒤에는 화면에 없던 선택을 덮지 않고 다시 읽도록 한다.
    private func nativeFilesAreCurrent(_ ports: UsbSyncPorts, volume: UsbVolumeInfo) async -> Bool {
        let formats = state.library?.formats ?? UsbFormat.defaultSet
        let service = ports.service, files = ports.files
        let result = await BlockingWork.run {
            Result {
                guard let files else { throw UsbSyncUnavailable() }
                let current = try service.currentVolume(volume)
                let native = try files.selection(URL(filePath: current.mountPoint), formats)
                return (native, try service.draftBase(current))
            }
        }
        guard ports.volume().volume == volume else {
            notify(.problem(String(ui: "USB가 바뀌었습니다. USB를 다시 읽은 뒤 동기화하세요")))
            return false
        }
        switch result {
        case let .success((native, base)) where native.baseFiles == state.nativeBaseFiles
            && native.semanticFingerprint == nativeSelectionFingerprint && usbBase?.sameContent(as: base) == true:
            return true
        case let .success((native, _)) where native.baseFiles == state.nativeBaseFiles:
            notify(.problem(String(ui: "USB가 바뀌었습니다. USB를 다시 읽은 뒤 동기화하세요")))
        case .success:
            notify(.problem(String(ui: "USB 동기화 선택이 다른 앱에서 바뀌었습니다. 새로고침해 바뀐 선택을 확인한 뒤 동기화하세요")))
        case .failure:
            notify(.problem(String(ui: "USB 동기화 선택 파일을 다시 읽지 못했습니다. USB를 새로고침한 뒤 동기화하세요")))
        }
        return false
    }

    /// 성공한 쓰기의 새 원본에 지문을 맞춰 두면 다음 창에서도 편집 중 선택과 원본을 혼동하지 않는다.
    private func adoptWrittenNativeFiles(_ ports: UsbSyncPorts) async -> Bool {
        let opened = ports.volume()
        guard let volume = opened.volume, let localDBID = state.localDBID else { return false }
        let formats = opened.library?.formats ?? UsbFormat.defaultSet
        let service = ports.service, files = ports.files
        let result = await BlockingWork.run {
            Result {
                guard let files else { throw UsbSyncUnavailable() }
                let current = try service.currentVolume(volume)
                return try files.selection(URL(filePath: current.mountPoint), formats)
            }
        }
        let now = ports.volume()
        guard now.volume == volume else { return false }
        switch result {
        case let .success(native):
            state.nativeBaseFiles = native.baseFiles
            nativeSelectionFingerprint = native.semanticFingerprint
            let resolved = native.resolve(UsbSyncSource.nativeNodes(state.source), localDBID, now.library, Self.masterNodeIDs(masterNodes))
            state.nativePlaylistIDs = resolved.playlistIDs
            state.nativeRemovedPlaylistIDs = resolved.removedSourcePlaylistIDs
            state.nativeEnabled = native.baseFiles.isEmpty ? nil : resolved.enabled
            state.nativeSelectionCanWrite = resolved.canWrite
            state.nativeSelectionIssues = resolved.issues.map(\.message)
            return resolved.canWrite
        case .failure:
            notify(.problem(String(ui: "쓴 USB 동기화 선택 파일을 읽지 못했습니다. USB를 새로고침해 결과를 확인하세요")))
            return false
        }
    }

    // MARK: - 큐·그리드 가져오기

    /// rekordbox의 "← CUE GRID INFO" 확인(2026-10-08 실험 G5b)을 DJCrate에 맞게 고친 문구. rekordbox는 바로 바꾸지만
    /// DJCrate는 초안만 만든다. rekordbox 창은 곡 정보(색상·레이팅·코멘트)도 적지만 실제로는 바꾸지 않아(실험 X1) 적지 않는다.
    public nonisolated static var cueGridImportPrompt: ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "USB에 있는 모든 곡의 다음 정보로 로컬 곡 정보를 바꾸는 초안을 만듭니다."),
                         text: String(ui: "- 큐 포인트와 루프 포인트\n- 핫 큐\n- 비트 그리드\n\nrekordbox의 곡이 더 최근에 바뀌었어도 USB 값으로 바꿉니다. 레이팅·색상·코멘트는 rekordbox처럼 가져오지 않습니다. 초안이 이미 있는 곡은 건너뜁니다. 가져온 초안을 확인한 뒤 rekordbox에 쓰기로 반영하세요.\n\n계속하시겠습니까?"),
                         confirm: String(ui: "가져오기"))
    }

    /// 묻고 USB의 큐·그리드를 로컬 초안으로 가져온다
    public func importCueGrid(_ ports: UsbSyncPorts) async {
        let current = ports.library()
        guard state.canImport, !ports.volume().isWriting, !current.isLoading, !current.isWriting else { return }
        guard ports.confirmation.confirm(Self.cueGridImportPrompt) else { return }
        notify(.clearProblem)
        state.isImporting = true
        defer { state.isImporting = false }
        let result = await ports.importCueGrid()
        let remaining = result.details.dropFirst()
        notify(.info(result.message + (remaining.isEmpty ? "" : "\n" + remaining.joined(separator: "\n"))))
    }
}

/// 동기화가 읽을 파일·짝짓기 키 포트가 붙지 않았다(읽지 못한 것으로 알린다)
struct UsbSyncUnavailable: Error {}
