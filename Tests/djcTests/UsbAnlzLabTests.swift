import RekordboxFixtures
@testable import djc
import Foundation
import RekordboxKit
import Testing

/// 실험 usb-anlz-check의 짝짓기. 곡·목록은 모두 지어낸 값이다.
@Suite("USB 분석 파일 실험 짝짓기")
struct UsbAnlzLabTests {
    let name = "시험 곡.mp3", size = 1_234_567

    /// 음원 이름·크기가 같은 곡 둘(분석 파일 자리만 다르다)
    func twins(_ fixture: RekordboxFixture) throws -> (TrackSpec, TrackSpec) {
        var first = TrackSpec(), second = TrackSpec()
        first.analysisDataPath = "/PIONEER/USBANLZ/aaa/0000-1111/ANLZ0000.DAT"
        second.analysisDataPath = "/PIONEER/USBANLZ/bbb/2222-3333/ANLZ0000.DAT"
        for track in [first, second] {
            try fixture.add(track)
            try fixture.execute("UPDATE djmdContent SET FileNameL = ?, FileSize = ? WHERE ID = ?",
                                [.text(name), .int(size), .text(track.id)])
        }
        return (first, second)
    }

    @Test("이름·크기가 같은 곡이 여럿이면 짝 후보가 여럿이고, 재생 목록을 주면 그 목록의 곡만 남는다")
    func playlistNarrowsCandidates() throws {
        let fixture = try RekordboxFixture()
        let (first, second) = try twins(fixture)
        let playlist = try fixture.add(PlaylistSpec(name: "시험 목록", seq: 1, contentIDs: [second.id]))
        let db = try CipherDatabase.diagnostic(path: fixture.database.path, key: RekordboxKey.derive())
        defer { db.close() }
        let key = UsbAnlzLab.key(name: name, size: Int64(size))

        #expect(try UsbAnlzLab.localTracks(db: db, playlistID: nil)[key]?.map(\.id).sorted() == [first.id, second.id].sorted())
        #expect(try UsbAnlzLab.localTracks(db: db, playlistID: playlist.id)[key]?.map(\.id) == [second.id])
        #expect(try UsbAnlzLab.localTracks(db: db, playlistID: "없는 목록").isEmpty)

        // 목록에서 지운 항목은 목록의 곡으로 보지 않는다
        try fixture.execute("UPDATE djmdSongPlaylist SET rb_local_deleted = 1 WHERE PlaylistID = ?", [.text(playlist.id)])
        #expect(try UsbAnlzLab.localTracks(db: db, playlistID: playlist.id)[key] == nil)
    }

    @Test("값을 받는 옵션(--playlist 포함)은 USB 폴더 인자로 세지 않는다")
    func optionValuesAreNotPositional() {
        #expect(UsbAnlzLab.positional(["usb-anlz-check", "--db", "d.db", "--playlist", "7", "--share", "s",
                                       "--snapshot-time", "2026-01-01T00:00:00Z", "/u"]) == ["/u"])
        #expect(UsbAnlzLab.positional(["usb-anlz-check", "/u", "--playlist", "7"]) == ["/u"])
    }
}
