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

    /// 종료를 기다리는 중이면 쓴 뒤 다시 읽기를 미룬다(#305). 읽지 않고 읽은 뒤 덱에 알릴 곡·쌓을 편집만 기억해 둔다(`reloadAfterWrite(written:playlistEdits:)`가 읽기 전에 하는 일).
    /// 쓰기 결과를 활동 기록에 먼저 남기고 종료하려는 것이다. 종료를 기다리지 않으면 아무것도 하지 않고 거짓이다.
    func postponeReloadForQuit(written: Set<String>, playlistEdits: [PlaylistEdit]) -> Bool {
        guard quitWait.isWaiting else { return false }
        writtenAwaitingReload.formUnion(written)
        playlists.playlistEditsAwaitingReload += playlistEdits
        reloadPostponedForQuit = true
        return true
    }

    /// 미룬 다시 읽기를 이어서 한다(한 번만). 종료를 기다리는 중이거나 쓰기 잠금이 걸려 있으면 하지 않는다: 그 둘이 풀릴 때 다시 부른다.
    /// 조건은 부르는 자리에서 바로 보고 작업을 만든다. 종료로 끝나는 길(`quitWait`가 아직 기다리는 중)에서는 읽기를 시작하지 않는다.
    @discardableResult
    func resumePostponedReload() -> Task<Void, Never>? {
        guard reloadPostponedForQuit, !quitWait.isWaiting, !libraryBusy else { return nil }
        reloadPostponedForQuit = false
        // 평소 쓴 뒤 다시 읽기처럼 쓰기 잠금 안에서 읽는다. 그동안 새 쓰기가 시작되지 않아, 다음 쓰기의 다시 읽기와 겹쳐
        // 옛 사본의 줄로 덱에 알리거나 그 쓰기의 다시 읽기 성공을 잘못 판정하지 않는다
        setWriteLock(true)
        writeStage = .reloadingLibrary
        return Task {
            _ = await reloadAfterWrite()
            writeStage = nil
            setWriteLock(false)
        }
    }

    /// 종료를 취소로 끝냈다(사용자가 취소했거나 시트에서 취소했다). Mac을 끄는 중 표시를 풀고, 종료를 기다리느라 미룬 다시 읽기를 이어서 한다.
    @discardableResult
    func quitCancelled() -> Task<Void, Never>? {
        isPoweringOff = false
        return resumePostponedReload()
    }

    /// 새 스냅샷을 읽은 뒤: 쓰거나 되돌린 곡을 덱에 알린다(옛 스냅샷을 새것으로 보지 않게 읽기가 성공한 뒤에만).
    func deliverWrittenAfterReload() {
        guard !writtenAwaitingReload.isEmpty else { return }
        let uuids = writtenAwaitingReload
        writtenAwaitingReload = []
        onRekordboxWritten?(uuids)
        // 쓰거나 되돌린 곡은 새 rekordbox 큐를 LINK로 내어 준다(#281)
        publishLinkCues(uuids)
    }
}
