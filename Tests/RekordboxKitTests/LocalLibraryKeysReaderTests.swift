import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 갱신 상태가 로컬 곡과 짝짓는 키(`LocalLibraryKeys`)를 합성 로컬 사본에서 읽는다(`LocalLibraryKeysReader`, 픽스처만).
@Suite("로컬 짝짓기 키 읽기")
struct LocalLibraryKeysTests {
    @Test("로컬 스냅샷 사본에서 DB ID·곡 키·갱신 횟수를 읽는다(지운 곡 제외)")
    func localLibraryKeysLoad() throws {
        let fixture = try RekordboxFixture()
        var first = TrackSpec(id: "71")
        first.cueUpdated = "4"
        first.analysisUpdated = "5"
        first.trackInfoUpdated = "6"
        try fixture.add(first)
        try fixture.add(TrackSpec(id: "72"))
        try fixture.add(TrackSpec(id: "73"))
        try fixture.execute("UPDATE djmdProperty SET DBID = '424242'")
        try fixture.execute("UPDATE djmdContent SET MasterSongID = '801', FileNameL = 'a.mp3' WHERE ID = '71'")
        try fixture.execute("UPDATE djmdContent SET MasterSongID = '802', FileNameL = 'b.mp3', CueUpdated = NULL WHERE ID = '72'")
        try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '73'")
        let database = try CipherDatabase(path: fixture.database.path, key: .hex(RekordboxKey.derive()), mode: .readOnly)
        defer { database.close() }
        let keys = try LocalLibraryKeysReader.load(database: database)
        #expect(keys.localDBID == 424_242)
        let folderPath = TrackSpec(id: "71").folderPath
        #expect(Set(keys.tracks) == [UsbLocalTrackKey(contentID: "71", masterSongID: "801", fileNameL: "a.mp3", folderPath: folderPath),
                                     UsbLocalTrackKey(contentID: "72", masterSongID: "802", fileNameL: "b.mp3", folderPath: folderPath)])
        #expect(keys.counters["71"] == LocalTrackCounters(information: "6", analysis: "5", cue: "4"))
        #expect(keys.counters["72"]?.cue == nil)
        #expect(keys.counters["73"] == nil)
    }
}
