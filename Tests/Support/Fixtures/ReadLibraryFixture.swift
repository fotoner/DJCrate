import DJCDomain
import Foundation
import RekordboxKit

/// 읽기 명령(`LibraryRead`)·CLI·앱 목록이 함께 쓰는 합성 라이브러리: 곡 둘(하나는 큐·루프·게인·분석 파일·키·아티스트·코멘트),
/// 지운 곡 하나, 폴더 안 목록(중복 항목·지운 곡 포함)과 빈 목록.
public func readLibraryFixture() throws -> RekordboxFixture {
    let fixture = try RekordboxFixture()
    var first = TrackSpec(id: "101", uuid: "track-101")
    first.title = "시험 Alpha"
    first.folderPath = "/synthetic/alpha.mp3"
    first.analysisDataPath = "/PIONEER/USBANLZ/test/ANLZ0000.DAT"
    var loop = CueSpec(id: "loop", kind: 1, inMsec: 1000)
    loop.outMsec = 3000; loop.activeLoop = 1; loop.beatLoopSize = 4 << 16 | 1
    first.cues = [CueSpec(id: "memory", inMsec: 500), loop]
    first.gain = RekordboxAutoGain.halves(0.5)
    try fixture.add(first)
    try fixture.putAnalysis(for: first, dat: AnlzBuilder.dat(beats: AnlzBuilder.beats(bpm: 128, first: 0, count: 16)), ext: nil)
    var second = TrackSpec(id: "102", uuid: "track-102")
    second.title = "시험 Beta"; second.bpm100 = 0; second.folderPath = "/synthetic/beta.mp3"
    try fixture.add(second)
    try fixture.add(TrackSpec(id: "103", uuid: "deleted"))
    try fixture.execute("UPDATE djmdContent SET rb_local_deleted = 1 WHERE ID = '103'")
    try fixture.insert("djmdKey", ["ID": .text("k1"), "ScaleName": .text("8A")])
    try fixture.insert("djmdArtist", ["ID": .text("a1"), "Name": .text("합성 아티스트")])
    try fixture.execute("UPDATE djmdContent SET KeyID = 'k1', ArtistID = 'a1', Commnt = 'TVA 시험 OP 1' WHERE ID = '101'")
    for (id, parent, name, attribute, seq) in [("f1", "root", "시험 폴더", 1, 1), ("p1", "f1", "시험 목록", 0, 1), ("p2", "root", "빈 목록", 0, 2)] {
        try fixture.insert("djmdPlaylist", ["ID": .text(id), "ParentID": .text(parent), "Name": .text(name), "Attribute": .int(attribute), "Seq": .int(seq)])
    }
    for (index, id) in ["102", "101", "101", "103"].enumerated() {
        try fixture.insert("djmdSongPlaylist", ["ID": .text("s\(index)"), "PlaylistID": .text("p1"), "ContentID": .text(id), "TrackNo": .int(index + 1)])
    }
    return fixture
}

/// `readLibraryFixture`의 두 곡을 중복 후보 한 묶음으로 만든 라이브러리(길이 2초 차, 소속·재생 기록이 다르다)
public func duplicateLibraryFixture() throws -> RekordboxFixture {
    let fixture = try readLibraryFixture()
    try fixture.execute("UPDATE djmdContent SET Title = '시험 alpha', ArtistID = 'a1', Length = 202, BitRate = 0, FolderPath = '/synthetic/copy.flac' WHERE ID = '102'")
    try fixture.execute("UPDATE djmdCue SET Comment = 'CUE(Auto)' WHERE ID = 'memory'")
    try fixture.insert("djmdSongPlaylist", ["ID": .text("second-list"), "PlaylistID": .text("p2"), "ContentID": .text("101"), "TrackNo": .int(1)])
    try fixture.insert("djmdSongPlaylist", ["ID": .text("deleted-entry"), "PlaylistID": .text("p2"), "ContentID": .text("102"), "TrackNo": .int(2), "rb_local_deleted": .int(1)])
    for index in 0..<3 {
        try fixture.insert("djmdSongHistory", ["ID": .text("play-\(index)"), "ContentID": .text("101"), "rb_local_deleted": .int(index == 2 ? 1 : 0)])
    }
    return fixture
}
