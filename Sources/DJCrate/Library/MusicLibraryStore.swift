import DJCApplication
import DJCDomain
import Foundation
import Observation

/// Music(iTunes) 표시 상태(기능 조각, #253): 사이드바 iTunes 동기화 목록, 지금 보이는 Music 목록, iTunes 동기화 창.
/// 언제 읽고 어떤 결과를 버릴지는 유스케이스 `LibraryReadFlow`(읽기 세대·`ITunesRefreshCoordinator` 순서표)가, 채택 규칙은 `LoadLibrary.readMusic`이 정한다.
/// 라이브러리 핵심(`LibraryStore`)이 `let music`으로 든다. 읽거나 쓴 결과를 곡 목록·사이드바 선택에 맞추는 일은 핵심이 한다(`host`).
@MainActor @Observable
final class MusicLibraryStore {
    /// 사이드바 iTunes 동기화 목록(곡 행에 이은 모양)
    var library = SyncedITunesLibrary()
    /// 지금 보이는 Music 목록(동기화 선택을 얹은 사본). 바뀌면 동기화 창 목록 캐시를 버린다
    var snapshot = ITunesLibrarySnapshot(status: .notCaptured) {
        didSet { readFlow.musicChanged() }
    }
    var showingSyncWindow = false
    /// 띄운 동기화 창의 화면 모델. 띄울 때 한 번 만든다(`presentSyncWindow`)
    private(set) var syncWindow = ITunesSyncModel(ports: .closed)
    /// iTunes 동기화 선택을 rekordbox에 쓴다(반영 세션 `syncITunes`, 조립 지점이 붙인다. 없으면 쓰지 않는다)
    @ObservationIgnored var write: ((ITunesSyncWrite) async throws -> (target: URL, syncData: Data))?
    /// 이 조각이 보는 라이브러리 핵심(핵심이 다 만든 뒤 붙인다)
    @ObservationIgnored var host = MusicLibraryHost.none
    @ObservationIgnored private let readFlow: LibraryReadFlow

    init(readFlow: LibraryReadFlow) {
        self.readFlow = readFlow
    }

    // MARK: - Music 최신화

    /// 뒤에서 도는 Music 최신화(`readFlow`가 든다). 쓰기 뒤 다시 읽기가 버리면 새 사본이 같은 조회를 이어받는다.
    var refresh: LibraryReadFlow.MusicRefresh? { readFlow.musicRefresh }

    /// iTunes 버튼은 명시한 DB를 벗어나지 않는다. 사본 모드에서는 현재 DB 옆 목록만 다시 읽는다.
    func refreshPlaylists() async {
        await readFlow.refreshMusicPlaylists()
    }

    /// 사이드바 메뉴의 새로고침 입구(MVVM-4). 시작만 하고 기다리지 않는다. 돌려주는 손잡이는 시험이 기다린다
    @discardableResult
    func startRefreshPlaylists() -> Task<Void, Never> { Task { await refreshPlaylists() } }

    #if DEBUG
    /// 자가 테스트용: 사본 모드는 Music을 읽지 않으므로 멈춘 Music 최신화를 흉내 내 선택 창이 기다리는지 본다.
    func startSimulatedRefresh(quiet: Bool = true, capture: @escaping @Sendable () -> ITunesLibrarySnapshot) -> Task<Void, Never>? {
        guard let snapshotURL = host.snapshot() else { return nil }
        return readFlow.startMusicRefresh(snapshot: snapshotURL, quiet: quiet, previous: nil,
                                          fallbackDirectory: snapshotURL.deletingLastPathComponent(),
                                          sourceDatabase: nil, capture: capture)
    }
    #endif

    /// 사본을 뜨는 동안 동기화 선택을 저장했다면, 뜨기 전에 붙든 이전 선택보다 현재 화면을 우선한다.
    func latestFallback(_ previous: LoadedLibrary.ITunesFallback?) -> LoadedLibrary.ITunesFallback? {
        readFlow.latestMusicFallback(previous)
    }

    /// 이 사본에 곧 결과를 채택할 Music 최신화. 끝나기 전에는 선택 창이 낡은 목록으로 쓰지 않는다.
    func currentRefresh(snapshot: URL?, revision: Int) -> Task<Void, Never>? {
        readFlow.currentMusicRefresh(snapshot: snapshot, revision: revision)
    }

    // MARK: - iTunes 동기화 창
    // 목록 열기(캐시·진행 중인 조회 함께 쓰기)와 쓰기 전 확인·쓴 뒤 목록 사본은 유스케이스(`LibraryReadFlow`·`LoadLibrary`)가 한다.

    func presentSyncWindow() {
        syncWindow = ITunesSyncModel(ports: syncWindowPorts)
        showingSyncWindow = true
    }

    /// 사본 실행에서는 Music에 접근하지 않고 함께 캡처한 전체 목록만 쓴다.
    /// - Parameter captureITunes: Music 조회(주지 않으면 유스케이스의 Music 포트). 시험이 바꿔 넣는다
    func syncSource(forceRefresh: Bool = false,
                    captureITunes: (@Sendable () -> ITunesLibrarySnapshot)? = nil) async -> ITunesLibrarySnapshot {
        await readFlow.syncCatalog(forceRefresh: forceRefresh, capture: captureITunes)
    }

    func syncPlaylists(_ selection: ITunesSyncSelection, source: ITunesLibrarySnapshot, database: URL) async throws {
        // 쓰기는 반영 세션이 한다: 반영·복원과 같은 쓰기 대상에(명시한 사본 `--db`는 읽기 출처만 바꾼다), 덱은 잠그지 않는다.
        try await readFlow.syncMusic(selection, source: source, database: database, write: write) { [self] synced in
            host.adoptSynced(synced, database)
        }
    }

    /// 동기화 창이 보는 바깥. 창 모델이 이 조각을 붙들지 않게 약하게 잇는다(조각이 창 모델을 든다)
    private var syncWindowPorts: ITunesSyncModel.Ports {
        let readFlow = readFlow
        return ITunesSyncModel.Ports(
            database: { [weak self] in self?.host.snapshot() },
            open: { await readFlow.openSyncWindow(shown: $0, forceRefresh: $1, capture: $2) },
            isShowing: { [weak self] model in self.map { $0.syncWindow === model && $0.showingSyncWindow } ?? false },
            isLibraryBusy: { [weak self] in self?.host.isBusy() ?? true },
            sync: { [weak self] selection, source, database in
                guard let self else { throw DJCError.writeRefused(LibraryReadFlow.libraryChangedMessage) }
                try await syncPlaylists(selection, source: source, database: database)
            })
    }
}

/// Music 조각이 보는 라이브러리 핵심(앱: `LibraryStore`). 부를 때마다 지금 값을 읽는다
struct MusicLibraryHost {
    /// 지금 목록을 읽은 사본
    var snapshot: @MainActor () -> URL?
    /// 라이브러리를 읽거나 rekordbox에 쓰는 중(동기화 창의 새로고침·동기화 단추를 막는다)
    var isBusy: @MainActor () -> Bool
    /// 동기화를 쓴 뒤 쓴 선택을 곡 목록·사이드바에 넣는다(동기화 창을 연 사본을 함께 받는다)
    var adoptSynced: @MainActor (LoadLibrary.SyncedSelection, _ database: URL) -> Void

    /// 핵심이 붙기 전: 읽은 사본이 없고 아무것도 넣지 않는다
    static var none: Self { Self(snapshot: { nil }, isBusy: { true }, adoptSynced: { _, _ in }) }
}
