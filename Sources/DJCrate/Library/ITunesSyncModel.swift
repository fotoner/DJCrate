import DJCApplication
import DJCDomain
import Foundation
import Observation

/// iTunes 동기화 창의 화면 모델. 띄울 때 Music 조각(`MusicLibraryStore.presentSyncWindow`)이 만들고, 라이브러리 저장소 대신 좁은 포트만 본다.
@MainActor @Observable
final class ITunesSyncModel {
    /// 동기화 창이 보는 바깥(앱: Music 조각). 부를 때마다 지금 값을 읽는다
    struct Ports {
        /// 지금 목록을 읽은 사본(동기화 대상)
        var database: @MainActor () -> URL?
        /// 창에 보일 목록과 선택을 연다(`LibraryReadFlow.openSyncWindow`)
        var open: @MainActor (_ shown: ITunesSyncShown, _ forceRefresh: Bool, _ capture: LibraryReadFlow.MusicCapture?) async -> ITunesSyncOpening
        /// 이 모델이 아직 떠 있는 창의 모델인지(닫았거나 새 창을 띄웠으면 결과를 넣지 않는다)
        var isShowing: @MainActor (ITunesSyncModel) -> Bool
        /// 라이브러리를 읽거나 rekordbox에 쓰는 중(새로고침·동기화 단추를 막는다)
        var isLibraryBusy: @MainActor () -> Bool
        /// 선택을 rekordbox에 쓰고 화면 목록에 넣는다(목록, 동기화 창을 연 사본)
        var sync: @MainActor (ITunesSyncSelection, ITunesLibrarySnapshot, URL) async throws -> Void

        /// 띄우지 않은 창: 열거나 쓰지 않는다
        static var closed: Self {
            Self(database: { nil }, open: { _, _, _ in .superseded }, isShowing: { _ in false }, isLibraryBusy: { false },
                 sync: { _, _, _ in throw DJCError.writeRefused(LibraryReadFlow.libraryChangedMessage) })
        }
    }

    /// 목록을 읽기 전에는 미캡처가 아니라 읽는 중이다.
    var source = ITunesLibrarySnapshot(status: .loading)
    var selection = ITunesSyncSelection()
    var database: URL?
    var isLoading = true
    var isSyncing = false
    /// 뒤에서 Music 최신화가 도는 동안은 캐시를 보여 주되 쓰지 않는다. 끝나면 그 결과로 다시 연다.
    var isWaitingForMusic = false
    var error: String?
    @ObservationIgnored private var loadSequence = 0
    /// 새로고침·동기화 단추가 마지막으로 시작한 일. 시트를 닫아도 끝까지 간다. 시험은 이것을 기다린다
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private let ports: Ports
    var canSync: Bool {
        !isLoading && !isSyncing && !isWaitingForMusic && source.status == .ready && source.syncData != nil && database != nil
    }
    /// 라이브러리를 읽거나 rekordbox에 쓰는 중(창의 새로고침·동기화 단추를 막는다)
    var isLibraryBusy: Bool { ports.isLibraryBusy() }
    static var waitingForMusicMessage: String { LibraryReadFlow.waitingForMusicMessage }
    var nodes: [ITunesSyncSelection.Node] { source.selectionNodes }
    var tree: [ITunesSyncOutline.Node] {
        guard let snapshot = try? source.applying(.init(selectedIDs: ["0"])) else { return [] }
        return ITunesSyncOutline(playlists: snapshot.playlists).tree
    }
    var preview: ITunesSyncOutline {
        guard source.status == .ready || source.status == .stale,
              let snapshot = try? source.applying(selection) else { return ITunesSyncOutline() }
        return ITunesSyncOutline(playlists: snapshot.playlists)
    }

    init(ports: Ports) {
        self.ports = ports
    }

    /// 어떤 목록·선택을 보일지, 여는 사이 라이브러리가 바뀌었는지, Music 최신화를 기다릴지는 유스케이스(`LibraryReadFlow.openSyncWindow`)가 정한다.
    /// 여기서는 마지막으로 연 요청인지와 창이 열려 있는지만 보고 결과를 표시한다.
    /// - Parameter captureITunes: Music 조회(주지 않으면 유스케이스의 Music 포트). 시험이 바꿔 넣는다
    func load(forceRefresh: Bool = false, captureITunes: LibraryReadFlow.MusicCapture? = nil) async {
        loadSequence += 1
        let sequence = loadSequence
        isWaitingForMusic = false
        let shown = ITunesSyncShown(source: source, selection: selection)
        isLoading = true
        error = nil
        database = ports.database()
        let opening = await ports.open(shown, forceRefresh, captureITunes)
        guard sequence == loadSequence else { return }
        guard !Task.isCancelled, ports.isShowing(self) else {
            isLoading = false
            return
        }
        guard case let .opened(opened) = opening else {
            database = nil
            isLoading = false
            error = LibraryReadFlow.libraryChangedMessage
            return
        }
        source = opened.source
        selection = opened.selection
        if let reason = opened.error { error = reason }
        isLoading = false
        // 최신화가 끝나기 전의 목록으로 쓰지 않는다. 끝나면 그 결과로 다시 연다(편집한 체크박스는 남는다).
        guard let refresh = opened.refresh else { return }
        isWaitingForMusic = true
        await refresh.value
        guard sequence == loadSequence else { return }
        isWaitingForMusic = false
        guard !Task.isCancelled, ports.isShowing(self) else { return }
        await load(captureITunes: captureITunes)
    }

    func startLoad(forceRefresh: Bool = false, captureITunes: LibraryReadFlow.MusicCapture? = nil) {
        task = Task { await load(forceRefresh: forceRefresh, captureITunes: captureITunes) }
    }

    /// 동기화를 마치면 `done`(시트 닫기)을 부른다. 쓰지 못했으면 시트를 남겨 이유를 보인다
    func startSync(done: @escaping @MainActor () -> Void) {
        task = Task { if await sync() { done() } }
    }

    func sync() async -> Bool {
        guard canSync, let database else { return false }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await ports.sync(selection, source, database)
            return true
        } catch {
            self.error = DJCError.reason(of: error)
            return false
        }
    }
}

/// 선택 창은 목록 이름과 계층만 쓰므로 곡 경로를 연결하지 않는다.
struct ITunesSyncOutline {
    struct Node: Identifiable {
        let id: String
        let name: String
        let children: [Node]?
        var isFolder: Bool { children != nil }
    }

    var tree: [Node] = []
    var playlistCount = 0

    init() {}

    init(playlists: [ITunesLibrarySnapshot.Playlist]) {
        let byParent = Dictionary(grouping: playlists, by: { $0.parentID ?? "0" })
        func build(_ parent: String) -> [Node] {
            (byParent[parent] ?? []).map { playlist in
                if playlist.isFolder {
                    return Node(id: "itunes:\(playlist.id)", name: playlist.name,
                                children: build(playlist.id))
                }
                playlistCount += 1
                return Node(id: "itunes:\(playlist.id)", name: playlist.name, children: nil)
            }
        }
        tree = build("0")
    }
}
