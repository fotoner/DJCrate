import DJCApplication
import DJCDomain
import Foundation

/// 쓰기·복원 뒤 다시 읽기(#175): 다시 읽기의 성공 여부를 돌려주고, 새 스냅샷을 읽은 뒤에만 쓴 곡을 덱에 알리고 되살린 재생 목록 편집을 쌓는다.
extension LibraryStore {
    /// 쓰기·복원 뒤 조용히 다시 읽는다. 새 스냅샷을 실제로 읽었는지 돌려준다(거절·실패·밀린 읽기는 거짓).
    func reloadAfterWrite() async -> Bool {
        let before = completedLoadCount
        await takeSnapshot(quiet: true, refreshITunes: false)
        return completedLoadCount > before
    }

    /// 새 스냅샷을 읽은 뒤: 쓰거나 되돌린 곡을 덱에 알린다(옛 스냅샷을 새것으로 보지 않게 읽기가 성공한 뒤에만).
    func deliverWrittenAfterReload() {
        guard !writtenAwaitingReload.isEmpty else { return }
        let uuids = writtenAwaitingReload
        writtenAwaitingReload = []
        onRekordboxWritten?(uuids)
    }

    /// 새 스냅샷을 읽은 뒤: 복원한 재생 목록 편집을 되돌린 rekordbox 상태에 다시 쌓는다(쌓지 못한 편집은 알린다).
    func restoreAwaitingPlaylistEdits() {
        guard !playlistEditsAwaitingReload.isEmpty else { return }
        let edits = playlistEditsAwaitingReload
        playlistEditsAwaitingReload = []
        let unrestored = restorePlaylistEdits(edits)
        if unrestored > 0 {
            playlistMessage = AppMessage(kind: .warning, text: String(ui: "재생 목록 편집 \(unrestored)건은 초안으로 되살리지 못했습니다."))
        }
    }
}
