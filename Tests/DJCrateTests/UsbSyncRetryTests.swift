@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Testing

@Suite("USB 동기화 재시도의 계획 입력 보호")
struct UsbSyncRetryTests {
    private func source(trackID: String = "A", status: ITunesLibrarySnapshot.Status = .ready) -> UsbSyncSource {
        UsbSyncSource.make(rekordbox: PlaylistLayout([
            (.init(id: "list", name: "목록", entries: [.init(trackNo: 1, contentID: trackID)]), 0),
        ]), iTunes: SyncedITunesLibrary(snapshot: .init(status: status), tracks: []))
    }

    private func inputs() -> UsbSyncPlanInputs {
        var library = UsbLibrary.empty
        library.formats = [.oneLibrary]
        library.playlists = [.init(id: 10, name: "목록", presentIn: [.oneLibrary], entries: [.oneLibrary: [1]])]
        return UsbSyncPlanInputs(database: URL(filePath: "/tmp/djc-synthetic/snapshot.db"),
                                 share: URL(filePath: "/tmp/djc-synthetic/share"), catalogRevision: 1,
                                 source: source(), volume: FakeUsbVolume.diskImageFAT32(name: "합성 USB"),
                                 library: library, usbBase: UsbEditTestData.base, localDBID: 42,
                                 matches: [1: "A", 2: "B"], badges: [:], bindings: [:],
                                 selection: .init(selectedIDs: ["list"]), syncPlaylists: true,
                                 nativeBaseFiles: [.oneLibrary: Data("원문".utf8)], nativeFingerprint: "원본 지문",
                                 nativePlaylistIDs: ["list": 10], nativeCanWrite: true, nativeIssues: [])
    }

    @Test("확인 취소 뒤 같은 선택의 곡 A → B 변경과 새 revision을 읽으면 옛 초안을 재사용하지 않는다")
    func cancelledPlanCannotRetryAfterSourceRefresh() throws {
        let before = inputs()
        let planned = try UsbSyncPlan.build(source: before.source, selection: before.selection, library: before.library,
                                           matches: before.matches, badges: before.badges, bindings: before.bindings)
        let savedEdits = planned.edits + [.syncSelection(draft: .init(localDBID: before.localDBID,
                                                                       sourceNodes: before.source.nativeNodes,
                                                                       selection: before.selection, enabled: true,
                                                                       playlistRefs: planned.playlistRefs,
                                                                       baseFiles: before.nativeBaseFiles))]
        let queued = UsbSyncQueuedPlan(edits: savedEdits, inputs: before)
        var after = before
        after.source = source(trackID: "B")
        after.catalogRevision += 1
        let next = try UsbSyncPlan.build(source: after.source, selection: after.selection, library: after.library,
                                        matches: after.matches, badges: after.badges, bindings: after.bindings)
        #expect(planned.edits != next.edits)
        #expect(queued.canReuse(edits: savedEdits, inputs: before))
        #expect(!queued.canReuse(edits: savedEdits, inputs: after))
        // 남아 있는 디스크 초안이나 무관한 편집을 새 계획으로 간주하지 않는다.
        #expect(!queued.canReuse(edits: savedEdits + [.playlist(edit: .rename(playlist: .id("10"), name: "별도 편집"))],
                                 inputs: before))
    }

    @Test("스냅샷 URL이 같아도 원본 값·읽기 상태·USB·native 원문 변화는 재사용을 막는다")
    func everyRelevantInputInvalidatesTheQueuedPlan() {
        let original = inputs()
        let edits: [UsbLibraryEdit] = [.syncPlaylist(playlist: .id("10"), localContentIDs: ["A"])]
        let queued = UsbSyncQueuedPlan(edits: edits, inputs: original)
        var changes: [UsbSyncPlanInputs] = []
        var changed = original
        changed.catalogRevision += 1; changes.append(changed)
        changed = original; changed.readEpoch += 1; changes.append(changed)
        changed = original; changed.source = source(trackID: "B"); changes.append(changed)
        changed = original; changed.source = source(status: .loading); changes.append(changed)
        changed = original; changed.library.playlists[0].name = "USB 변경"; changes.append(changed)
        changed = original; changed.usbBase.files.removeAll(); changes.append(changed)
        changed = original; changed.nativeBaseFiles[.oneLibrary] = Data("바뀐 원문".utf8); changes.append(changed)
        changed = original; changed.nativeFingerprint = "새 지문"; changes.append(changed)
        changed = original; changed.nativeCanWrite = false; changes.append(changed)
        changed = original; changed.nativeIssues = ["읽기 오류"]; changes.append(changed)
        changed = original; changed.nativePlaylistIDs = ["list": 20]; changes.append(changed)
        changed = original; changed.bindings = ["list": .init(usbID: 20, path: ["목록"], isFolder: false)]; changes.append(changed)
        changed = original; changed.matches = [2: "A"]; changes.append(changed)
        changed = original; changed.badges = [1: .localNewer([.analysis])]; changes.append(changed)
        changed = original; changed.selection = .init(); changes.append(changed)
        changed = original; changed.syncPlaylists = false; changes.append(changed)
        changed = original; changed.localDBID += 1; changes.append(changed)
        changed = original; changed.share = URL(filePath: "/tmp/djc-synthetic/other-share"); changes.append(changed)
        changed = original; changed.database = URL(filePath: "/tmp/djc-synthetic/other.db"); changes.append(changed)
        changed = original; changed.volume.name = "다른 USB"; changes.append(changed)
        for input in changes { #expect(!queued.canReuse(edits: edits, inputs: input)) }
    }
}
