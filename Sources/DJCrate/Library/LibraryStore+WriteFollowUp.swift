import DJCApplication
import DJCDomain
import Foundation

/// 쓰기·복원 뒤 다시 읽기(#175): 다시 읽기의 성공 여부를 돌려주고, 새 스냅샷을 읽은 뒤에만 쓴 곡을 덱에 알린다.
/// 되살린 재생 목록 편집은 같은 때 재생 목록 조각이 쌓는다(`PlaylistEditStore.restoreAwaitingPlaylistEdits`).
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
}
