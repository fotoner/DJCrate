import DJCApplication
import DJCDomain
import Foundation

/// Music(iTunes) 목록 최신화: DB·곡 행을 읽은 뒤 Music 결과만 따로 결합한다. 언제 시작하고 어떤 결과를 버릴지는 유스케이스
/// `LibraryReadFlow`(읽기 세대·`ITunesRefreshCoordinator` 순서표)가, 채택 규칙은 `LoadLibrary.readMusic`이 정한다.
extension LibraryStore {
    /// iTunes 버튼은 명시한 DB를 벗어나지 않는다. 사본 모드에서는 현재 DB 옆 목록만 다시 읽는다.
    func refreshITunesPlaylists() async {
        await readFlow.refreshMusicPlaylists()
    }

    #if DEBUG
    /// 자가 테스트용: 사본 모드는 Music을 읽지 않으므로 멈춘 Music 최신화를 흉내 내 선택 창이 기다리는지 본다.
    func startSimulatedITunesRefresh(quiet: Bool = true, capture: @escaping @Sendable () -> ITunesLibrarySnapshot) -> Task<Void, Never>? {
        guard let snapshotURL else { return nil }
        return readFlow.startMusicRefresh(snapshot: snapshotURL, quiet: quiet, previous: nil,
                                          fallbackDirectory: snapshotURL.deletingLastPathComponent(),
                                          sourceDatabase: nil, capture: capture)
    }
    #endif

    /// 사본을 뜨는 동안 동기화 선택을 저장했다면, 뜨기 전에 붙든 이전 선택보다 현재 화면을 우선한다.
    func latestITunesFallback(_ previous: LoadedLibrary.ITunesFallback?) -> LoadedLibrary.ITunesFallback? {
        readFlow.latestMusicFallback(previous)
    }

    /// 이 사본에 곧 결과를 채택할 Music 최신화. 끝나기 전에는 선택 창이 낡은 목록으로 쓰지 않는다.
    func currentITunesRefresh(snapshot: URL?, revision: Int) -> Task<Void, Never>? {
        readFlow.currentMusicRefresh(snapshot: snapshot, revision: revision)
    }
}
