@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import Testing

/// 곡 편집만 쓴 저장 백업으로 「저장 전으로 복원」해도 재생 목록 초안이 남는다(#295 E7). 그 백업에는 재생 목록 편집 기록(`playlist-edits.json`)도
/// 추가한 곡 기록(`track-report.json`)도 없다. 실제 관문이 합성 사본에 쓰고 되돌리며, 초안은 임시 폴더의 실제 디스크 저장소에 둔다.
@MainActor
@Suite("곡 편집 저장 백업 복원과 재생 목록 초안", .serialized, .enabled(if: LiveDraftHome.isIsolated))
struct RestoreKeepsPlaylistDraftTests {
    @Test func 곡_편집만_쓴_백업으로_복원해도_재생_목록_초안과_도장이_남는다() async throws {
        let rig = try await LibraryUndoAfterSaveTests.Rig(LibraryUndoAfterSaveTests.tracks, playlists: LibraryUndoAfterSaveTests.playlists)
        let store = rig.store, playlists = store.playlists
        // 재생 목록 초안 세 단계(저장하지 않고 남겨 둔다)
        playlists.renamePlaylist("1001", to: "새 가")
        playlists.renamePlaylist("1003", to: "새 다")
        playlists.addTracks([try rig.row(LibraryUndoAfterSaveTests.tracks[2])], toPlaylist: "1001")
        #expect(playlists.playlistDraft.steps.count == 3)
        let home = store.location.draftHome
        let draftFile = DraftLocations(home: home).playlist
        let stampFile = DraftStampStore.folder(home: home).appending(path: "playlist.json")
        let draftBytes = try Data(contentsOf: draftFile), stampBytes = try Data(contentsOf: stampFile)

        // 곡 편집 한 곡만 ⌘S로 쓴다(재생 목록은 묶음에 넣지 않는다). 사용자 사례는 큐 저장이었다: 같은 조건의 백업(재생 목록 편집·추가한 곡
        // 기록 없음)을 합성 사본에서 확실히 쓰이는 평점 저장으로 만든다
        let row = try rig.row(LibraryUndoAfterSaveTests.tracks[0])
        store.tags.applyTagEdits([(row, .rating, "4")])
        let written = await store.session.write(rows: [row], playlists: false)
        guard case .written = written else {
            Issue.record("곡 편집을 쓰지 못했다: \(written)")
            return
        }
        #expect(await waitForState(until: { !store.libraryBusy && store.writtenAwaitingReload.isEmpty }))
        let backup = try #require(try store.session.writeBackups().first(where: \.isWrite))
        #expect(!FileManager.default.fileExists(atPath: backup.url.appending(path: "playlist-edits.json").path), "재생 목록 편집 기록이 없는 백업이다")
        #expect(!FileManager.default.fileExists(atPath: backup.url.appending(path: "track-report.json").path), "추가한 곡 기록이 없는 백업이다")

        guard case .restored = await store.session.restore(backup, confirmed: true) else {
            Issue.record("복원하지 못했다")
            return
        }
        #expect(await waitForState(until: { !store.libraryBusy }))
        #expect(try Data(contentsOf: draftFile) == draftBytes, "playlist-drafts.json이 그대로다")
        #expect(try Data(contentsOf: stampFile) == stampBytes, "draft-stamps/playlist.json이 그대로다")
        #expect(playlists.playlistDraft.steps.count == 3)
    }
}
