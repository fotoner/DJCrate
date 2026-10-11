@testable import DJCrate
import DJCApplication
import DJCDomain
import RekordboxKit
import Testing

@MainActor
@Suite("USB 동기화의 현재 목록과 예상 결과")
struct UsbSyncTargetDisplayTests {
    private func library() -> UsbLibrary {
        UsbLibrary(formats: [.oneLibrary], property: .init(), playlists: [
            UsbPlaylist(id: 7, name: "DJ", attribute: 1, presentIn: [.oneLibrary], sortOrder: [.oneLibrary: 0]),
            UsbPlaylist(id: 8, name: "목록", parentID: 7, presentIn: [.oneLibrary],
                        sortOrder: [.oneLibrary: 0], entries: [.oneLibrary: [2, 1, 2]]),
            UsbPlaylist(id: 9, name: "인텔리전트 목록", attribute: 4, presentIn: [.oneLibrary], sortOrder: [.oneLibrary: 1]),
        ])
    }

    @Test("로컬 선택이 없어도 이미 읽은 USB 목록을 처음부터 표시한다")
    func currentUsbIsVisibleWithoutAnySourceSelection() {
        let model = UsbSyncModel(volumeKey: "synthetic", library: library())
        #expect(model.selection.selectedIDs.isEmpty)
        // 동기화 후 미리 보기도 이은 적 없는 USB 목록을 그대로 남긴다(지우지 않는다).
        #expect(model.previewTree.map(\.id) == ["7", "9"])
        #expect(model.targetDisplay == .currentUsb)
        #expect(model.targetTree.map(\.name) == ["DJ", "인텔리전트 목록"])
        #expect(model.targetTree.first?.children?.first?.name == "목록")
        #expect(model.targetPlaylistCount == 2)

        model.clearSelection()
        #expect(model.targetTree.map(\.id) == ["7", "9"])
        #expect(model.targetPlaylistCount == 2)
    }

    @Test("모든 목록을 해제한 예상 결과는 이은 적 없는 USB 목록을 흐리게 남기고 지울 목록이 없다")
    func emptyPreviewDoesNotEraseTheCurrentUsbDisplay() {
        let model = UsbSyncModel(volumeKey: "synthetic", library: library())
        model.targetDisplay = .afterSync
        // 선택 파일 행으로 이은 목록이 없으니 동기화해도 USB 목록은 그대로 남는다(rekordbox 장치 트리의 회색).
        #expect(model.targetTree.map(\.id) == ["7", "9"])
        #expect(model.dimmedTargetIDs == ["7", "8", "9"])
        #expect(model.targetMarks.values.allSatisfy { $0 == .unlinked })
        #expect(model.deletedTargetSummary == nil)
        #expect(model.targetPlaylistCount == 0)
        #expect(model.targetEmptyMessage == "동기화할 목록을 선택하세요")

        model.targetDisplay = .currentUsb
        #expect(!model.targetTree.isEmpty)
        #expect(model.targetPlaylistCount == 2)
    }

    @Test("동기화를 끄면 현재 USB 목록으로 돌아간다")
    func disablingSyncReturnsToCurrentUsb() {
        let model = UsbSyncModel(volumeKey: "synthetic", library: library())
        model.targetDisplay = .afterSync
        model.syncPlaylists = false
        #expect(model.targetDisplay == .currentUsb)
        #expect(!model.targetTree.isEmpty)
    }

    @Test("목록 없는 USB와 아직 읽지 못한 USB를 구분한다")
    func knownEmptyAndUnreadUsbHaveDifferentMessages() {
        let empty = UsbSyncModel(volumeKey: "synthetic", library: .empty)
        #expect(empty.targetTree.isEmpty)
        #expect(empty.targetEmptyMessage == "USB에 재생 목록이 없습니다")
        let unread = UsbSyncModel(volumeKey: "synthetic")
        #expect(unread.targetEmptyMessage == "USB 재생 목록을 아직 읽지 못했습니다. 새로고침하세요")
    }

    /// 2026-10-08 실험 G5b: rekordbox는 "장치와 플레이리스트 동기화"가 꺼진 동안 체크를 바꿀 수 없었다.
    @Test("동기화가 꺼져 있으면 체크·전체 선택·선택 해제가 선택을 바꾸지 않는다")
    func selectionIsLockedWhileSyncIsOff() {
        let model = UsbSyncModel(volumeKey: "synthetic", library: library())
        model.syncPlaylists = false
        #expect(!model.canEditSelection)
        model.selectAllRekordbox()
        model.selectAllITunes()
        model.toggle(UsbSyncSource.rekordboxSelectionID)
        model.selectAll()
        #expect(model.selection.selectedIDs.isEmpty)
        model.syncPlaylists = true
        model.selectAllRekordbox()
        #expect(model.selection.selectedIDs.contains(UsbSyncSource.rekordboxSelectionID))
        model.syncPlaylists = false
        model.clearSelection()
        model.clearRekordboxSelection()
        #expect(model.selection.selectedIDs.contains(UsbSyncSource.rekordboxSelectionID))
    }

    @Test("동기화하지 않고 닫으면 바꾼 체크를 USB의 선택으로 되돌린다")
    func closingWithoutSyncDiscardsChangedChecks() {
        let model = UsbSyncModel(volumeKey: "synthetic", library: library())
        model.selectAllRekordbox()
        #expect(model.selectionDiffersFromUsb)
        model.discardUnsyncedSelection()
        #expect(model.selection == model.usbSelection && !model.selectionDiffersFromUsb)
    }
}

