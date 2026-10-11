import DJCApplication
import DJCDomain
import Foundation

/// iTunes 동기화: 창·목록 열기·쓰기는 Music 조각(`music`, `MusicLibraryStore`)과 유스케이스(`LibraryReadFlow`·`LoadLibrary`)가 한다.
/// 여기서는 조각이 보는 핵심(`musicHost`)을 잇고, 쓴 선택을 곡 목록·사이드바에 넣는다.
extension LibraryStore {
    /// Music 조각이 보는 핵심. 조각이 저장소를 붙들지 않게 약하게 잇는다(저장소가 조각을 든다)
    var musicHost: MusicLibraryHost {
        MusicLibraryHost(snapshot: { [weak self] in self?.snapshotURL },
                         isBusy: { [weak self] in self.map { $0.isLoading || $0.isWritingRekordbox } ?? true },
                         adoptSynced: { [weak self] in self?.adoptSyncedMusic($0, database: $1) })
    }

    /// 동기화를 쓴 뒤 쓴 선택을 화면 목록에 넣는다
    /// - Parameter database: 동기화 창을 연 사본
    func adoptSyncedMusic(_ synced: LoadLibrary.SyncedSelection, database: URL) {
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
        music.snapshot = selected
        music.library = SyncedITunesLibrary(snapshot: selected, tracks: rows.map(\.track))
        if case let .itunesPlaylist(id) = sidebar, music.library.index[id] == nil { sidebar = .filter(.all) }
        refreshBase()
        self.selection.formIntersection(Set(displayRows.map(\.id)))
    }
}
