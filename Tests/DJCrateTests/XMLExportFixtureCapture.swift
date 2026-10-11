import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 라이브러리 XML 내보내기 화면 캡처(`--xml-export-capture=<폴더>`)용 합성 라이브러리(#72). 곡 제목은 모두 "합성 곡"으로 시작한다.
/// 사용: `DJC_XMLEXPORT_FIXTURE=<빈 폴더> swift test --filter XMLExportFixtureCapture` → 그 폴더를 `DJC_REKORDBOX_DIR`·`--db <폴더>/master.db`로 연다.
struct XMLExportFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_XMLEXPORT_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_XMLEXPORT_FIXTURE"] else { return }
        let root = URL(filePath: path), fixture = try RekordboxFixture()
        for (id, name) in [("ar1", "합성 아티스트 가"), ("ar2", "합성 아티스트 나"), ("ar3", "합성 아티스트 다")] {
            try fixture.insert("djmdArtist", ["ID": .text(id), "Name": .text(name)])
        }
        try fixture.insert("djmdGenre", ["ID": .text("g1"), "Name": .text("합성 장르")])
        try fixture.insert("djmdKey", ["ID": .text("k1"), "ScaleName": .text("8A")])
        var specs: [TrackSpec] = []
        for n in 1...12 {
            var spec = TrackSpec(id: String(910_000 + n), uuid: "xml-export-\(n)")
            spec.title = String(format: "합성 곡 %02d", n)
            spec.folderPath = "/Music/합성 곡 \(n).mp3"
            spec.length = 180 + n * 7
            spec.bpm100 = (118 + n * 4) * 100
            spec.analysisDataPath = "/PIONEER/USBANLZ/P001/\(String(format: "%08X", n))/ANLZ0000.DAT"
            spec.artistID = "ar\((n - 1) % 3 + 1)"
            if n % 2 == 0 { spec.cues = [.autoCue(at: 1000), CueSpec(id: "xc\(n)", kind: 1 + n % 3, inMsec: 20_000 + n * 1000)] }
            specs.append(spec)
        }
        var streaming = TrackSpec(id: "910100", uuid: "xml-export-stream")
        streaming.title = "합성 곡 스트리밍"
        streaming.folderPath = "apple-music:track:synthetic"
        specs.append(streaming)
        try fixture.add(tracks: specs)
        for spec in specs where spec.analysisDataPath != nil {
            let bpm = Double(spec.bpm100) / 100
            let beats = AnlzBuilder.beats(bpm: bpm, first: 40, count: Int(Double(spec.length) * bpm / 60))
            try fixture.putAnalysis(for: spec, dat: AnlzBuilder.dat(beats: beats), ext: AnlzBuilder.ext(beats: beats))
        }
        try fixture.execute("UPDATE djmdContent SET GenreID = 'g1', KeyID = 'k1', Commnt = '합성 코멘트' WHERE ID <> '910100'")
        for (id, name, parent, attribute, seq) in [("xf1", "합성 폴더", "root", 1, 1), ("xp1", "합성 목록 1", "xf1", 0, 1),
                                                   ("xp2", "합성 목록 2", "xf1", 0, 2), ("xp3", "합성 인텔리전트", "root", 4, 2)] {
            try fixture.insert("djmdPlaylist", ["ID": .text(id), "Name": .text(name), "ParentID": .text(parent),
                                                "Attribute": .int(attribute), "Seq": .int(seq)])
        }
        try fixture.execute("UPDATE djmdPlaylist SET SmartList = '<NODE/>' WHERE ID = 'xp3'")
        for (id, playlist, content, no) in [("xs1", "xp1", "910001", 1), ("xs2", "xp1", "910002", 2), ("xs3", "xp1", "910100", 3),
                                            ("xs4", "xp2", "910003", 1), ("xs5", "xp2", "910004", 2)] {
            try fixture.insert("djmdSongPlaylist", ["ID": .text(id), "PlaylistID": .text(playlist), "ContentID": .text(content), "TrackNo": .int(no)])
        }
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }
}
