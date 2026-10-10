import DJCApplication
import DJCDomain
import Foundation

/// iTunes 동기화 창: 목록 열기(캐시·진행 중인 조회 함께 쓰기)와 쓰기 전 확인·쓴 뒤 목록 사본은 유스케이스(`LibraryReadFlow`·`LoadLibrary`)가 한다.
/// 여기서는 창을 띄우고 쓴 선택을 화면 목록에 넣는다.
extension LibraryStore {
    /// 선택 창을 처음 열 때의 선택(동기화 원문에서 맨 위를 골랐는지 유스케이스가 본다)
    func iTunesInitialSelection(of source: ITunesLibrarySnapshot) -> ITunesSyncSelection {
        useCases.load.initialSelection(of: source)
    }

    func presentITunesSync() {
        iTunesSync = ITunesSyncModel()
        showingITunesSync = true
    }

    /// 사본 실행에서는 Music에 접근하지 않고 함께 캡처한 전체 목록만 쓴다.
    /// - Parameter captureITunes: Music 조회(주지 않으면 유스케이스의 Music 포트). 시험이 바꿔 넣는다
    func iTunesSyncSource(forceRefresh: Bool = false,
                          captureITunes: (@Sendable () -> ITunesLibrarySnapshot)? = nil) async -> ITunesLibrarySnapshot {
        await readFlow.syncCatalog(forceRefresh: forceRefresh, capture: captureITunes)
    }

    func syncITunesPlaylists(_ selection: ITunesSyncSelection, source: ITunesLibrarySnapshot, database: URL) async throws {
        // 쓰기는 반영 세션이 한다: 반영·복원과 같은 쓰기 대상에(명시한 사본 `--db`는 읽기 출처만 바꾼다), 덱은 잠그지 않는다.
        try await readFlow.syncMusic(selection, source: source, database: database, write: syncITunesWrite) { [self] synced in
            let selected = synced.selected, sameSource = synced.sameSource
            if synced.saveFailed {
                reportLibraryError(String(ui: "rekordbox 동기화는 완료했지만 사본을 저장하지 못했습니다. 저장 폴더를 확인한 뒤 새로고침하세요."))
            }
            // 개발 실행에서 `--db`로 쓰기 대상과 다른 폴더의 사본을 열었으면 그 사본에는 쓴 선택이 보이지 않는다. 화면은 그대로 두고 알린다.
            guard synced.visible else {
                toast = .notice(String(ui: "iTunes 동기화를 rekordbox에 썼습니다"),
                                String(ui: "지금 연 사본(--db)에는 보이지 않으니 --db 없이 다시 열어 확인하세요."))
                return
            }
            guard snapshotURL == database || sameSource else { return }
            iTunesSnapshot = selected
            iTunesLibrary = SyncedITunesLibrary(snapshot: selected, tracks: rows.map(\.track))
            if case let .itunesPlaylist(id) = sidebar, iTunesLibrary.index[id] == nil { sidebar = .filter(.all) }
            refreshBase()
            self.selection.formIntersection(Set(displayRows.map(\.id)))
        }
    }
}
