import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

struct PlaylistRecoveryFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_PLAYLIST_RECOVERY_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_PLAYLIST_RECOVERY_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        for (index, title) in ["합성 곡 하나", "합성 곡 둘", "합성 곡 셋"].enumerated() {
            var track = TrackSpec(id: String(index + 1)); track.title = title
            try fixture.add(track)
        }
        try fixture.add(PlaylistSpec(id: "179", name: "합성 원래 목록", seq: 1, contentIDs: ["1", "2"]))
        let layout = PlaylistLayout(rekordbox: try RekordboxLibrary.load(snapshot: fixture.database).playlists)
        var draft = PlaylistDraft()
        try draft.append(.rename(playlist: .id("179"), name: "합성 내 목록"), rekordbox: layout)
        try draft.append(.addTracks(playlist: .id("179"), contentIDs: ["3"]), rekordbox: layout)
        try PlaylistDraftStore.save(draft)
        try fixture.execute("UPDATE djmdPlaylist SET Name = '합성 현재 목록' WHERE ID = '179'")
        try FileManager.default.copyItem(at: fixture.root, to: URL(filePath: path))
    }
}
