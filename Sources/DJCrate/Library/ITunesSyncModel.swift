import DJCDomain
import Foundation
import Observation

@MainActor @Observable
final class ITunesSyncModel {
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
    var canSync: Bool {
        !isLoading && !isSyncing && !isWaitingForMusic && source.status == .ready && source.syncData != nil && database != nil
    }
    static var waitingForMusicMessage: String {
        String(ui: "Music 보관함을 새로 읽는 중이니 목록이 최신으로 바뀐 뒤 동기화하세요.")
    }
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

    /// - Parameter captureITunes: Music 조회(주지 않으면 저장소 유스케이스의 Music 포트). 시험이 바꿔 넣는다
    func load(store: LibraryStore, forceRefresh: Bool = false,
              captureITunes: (@Sendable () -> ITunesLibrarySnapshot)? = nil) async {
        loadSequence += 1
        let sequence = loadSequence
        isWaitingForMusic = false
        let previousSource = source
        let previousSelection = selection
        let hadSource = previousSource.status == .ready || previousSource.status == .stale
        let selectionEdited = hadSource && previousSelection != store.iTunesInitialSelection(of: previousSource)
        isLoading = true
        error = nil
        let requestedDatabase = store.snapshotURL
        let requestedRevision = store.previewRevision
        database = requestedDatabase
        let captured = await store.iTunesSyncSource(forceRefresh: forceRefresh, captureITunes: captureITunes)
        guard sequence == loadSequence else { return }
        guard !Task.isCancelled, store.iTunesSync === self, store.showingITunesSync else {
            isLoading = false
            return
        }
        guard store.snapshotURL == requestedDatabase, store.previewRevision == requestedRevision else {
            database = nil
            isLoading = false
            error = String(ui: "라이브러리가 바뀌었거나 목록을 읽지 못했습니다. 동기화 창을 다시 여세요.")
            return
        }
        if captured.status != .ready, hadSource {
            source = previousSource
            source.status = .stale
            selection = previousSelection
        } else {
            source = captured
            if selectionEdited {
                let available = Set(source.selectionNodes.map(\.id)).union(["0"])
                selection = ITunesSyncSelection(selectedIDs: previousSelection.selectedIDs.intersection(available))
            } else {
                selection = store.iTunesInitialSelection(of: source)
            }
            if source.status == .ready, source.syncData == nil {
                error = String(ui: "rekordbox 동기화 파일 사본이 없습니다. rekordbox에서 한 번 동기화한 뒤 새로고침하세요.")
            }
        }
        isLoading = false
        // 최신화가 끝나기 전의 목록으로 쓰면 폴더 계층이 낡을 수 있다. 편집한 체크박스는 다시 열 때 남는다.
        guard let refresh = store.currentITunesRefresh(snapshot: requestedDatabase, revision: requestedRevision) else { return }
        isWaitingForMusic = true
        await refresh.value
        guard sequence == loadSequence else { return }
        isWaitingForMusic = false
        guard !Task.isCancelled, store.iTunesSync === self, store.showingITunesSync else { return }
        await load(store: store, captureITunes: captureITunes)
    }

    func startLoad(store: LibraryStore, forceRefresh: Bool = false, captureITunes: (@Sendable () -> ITunesLibrarySnapshot)? = nil) {
        task = Task { await load(store: store, forceRefresh: forceRefresh, captureITunes: captureITunes) }
    }

    /// 동기화를 마치면 `done`(시트 닫기)을 부른다. 쓰지 못했으면 시트를 남겨 이유를 보인다
    func startSync(store: LibraryStore, done: @escaping @MainActor () -> Void) {
        task = Task { if await sync(store: store) { done() } }
    }

    func sync(store: LibraryStore) async -> Bool {
        guard canSync, let database else { return false }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await store.syncITunesPlaylists(selection, source: source, database: database)
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
