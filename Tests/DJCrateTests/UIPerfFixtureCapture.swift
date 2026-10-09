import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 화면 성능 측정용 합성 라이브러리(#129): 실사용과 비슷한 크기(곡 3천 개, 폴더 20개 아래 재생 목록 300개, 재생 기록 80개).
/// 로컬 곡은 모두 합성 음원 하나와 그리드·PWAV·PWV4 미리 보기를 쓰고, 아티스트·앨범·장르·키·코멘트를 돌려 가며 채운다.
/// 실데이터는 쓰지 않는다. `DJC_UI_PERF_FIXTURE=<폴더> swift test --filter UIPerfFixtureCapture`
/// `DJC_UI_PERF_CUE_NAMES=1`을 더하면 큐에 이름을 붙이고, `--ui-perf=play`가 재생하는 10초 언저리에 이름 있는 메모리 큐 5개를 둔다(확대 파형 글자 측정, #139).
struct UIPerfFixtureCapture {
    static let trackCount = 3000
    static let folderCount = 20
    static let playlistsPerFolder = 12
    static let rootPlaylistCount = 60
    static let historyCount = 80
    /// `DJC_UI_PERF_CUE_NAMES=1`이면 이름 없는 큐에 이름을 붙인다.
    static let namesCues = ProcessInfo.processInfo.environment["DJC_UI_PERF_CUE_NAMES"] != nil
    static let cueNames = ["Intro", "Build", "Drop", "Break", "Verse", "Hook", "Outro", "Vocal 1", "Bass in"]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_UI_PERF_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_UI_PERF_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        let seconds = 180
        let audio = try EditLayoutFixtureCapture.song(bpm: 128, first: 0.35, seconds: Double(seconds),
                                                      to: fixture.audio.appending(path: "ui-perf.wav"))
        try Self.names(into: fixture)

        func hot(_ slot: Int, _ second: Double) -> CueSpec {
            CueSpec(kind: slot < 3 ? slot + 1 : slot + 2, inMsec: Int(second * 1000))
        }
        var tracks: [TrackSpec] = []
        for index in 1...Self.trackCount {
            var track = TrackSpec(id: String(index))
            track.title = "합성 곡 \(index) " + ["Intro Mix", "Extended", "Dub", "Club Edit", "Radio"][index % 5]
            var shape: [CueSpec] = switch index % 4 {
            case 0: []
            case 1: [hot(0, 15), hot(1, 60), CueSpec(kind: 0, inMsec: 350), CueSpec(kind: 0, inMsec: 90_000)]
            case 2: (0..<8).map { hot($0, 5 + Double($0) * 21) } + [CueSpec(kind: 0, inMsec: 30_000)]
            default: [CueSpec.autoCue(at: 350)]
            }
            // `play` 측정은 10초부터 재생한다. 그 앞뒤에 이름 있는 메모리 큐를 두어 확대 파형에 큐 이름이 그려지게 한다.
            if Self.namesCues {
                shape += [(9.0, "Intro"), (11.2, "Build"), (12.4, "Break"), (13.6, "Drop"), (15.0, "Hook")].map { second, name in
                    var cue = CueSpec(kind: 0, inMsec: Int(second * 1000))
                    cue.comment = name
                    return cue
                }
            }
            track.cues = shape.enumerated().map { offset, cue in
                var cue = cue
                cue.id = String(index * 100 + offset)
                cue.uuid = UUID().uuidString.lowercased()
                // 확대 파형의 큐 이름 글자 비용을 재려면 이름이 있어야 한다(#139). 다른 측정 기준은 그대로 두려고 켤 때만 붙인다.
                if Self.namesCues, cue.comment == nil { cue.comment = Self.cueNames[(index + offset) % Self.cueNames.count] }
                return cue
            }
            track.bpm100 = 11_800 + (index * 37) % 1_800
            track.folderPath = root.appending(path: "audio/\(audio.lastPathComponent)").path
            track.fileType = 11
            track.length = seconds
            track.artistID = "a\(index % 300)"
            track.albumID = "al\(index % 600)"
            track.analysisDataPath = "/PIONEER/USBANLZ/perf\(index)/ANLZ0000.DAT"
            tracks.append(track)
        }
        try fixture.add(tracks: tracks)
        let beats = AnlzBuilder.beats(bpm: 128, first: 350, count: 380)
        for (index, track) in tracks.enumerated() {
            let (pwav, pwv4) = TrackListFixtureCapture.preview(seed: index)
            try fixture.putAnalysis(for: track, dat: AnlzBuilder.file([BeatGridTags.pqtz(beats), AnlzBuilder.pwav(pwav)]),
                                    ext: AnlzBuilder.file([AnlzBuilder.waveform("PWV4", entryBytes: 6, samples: pwv4)]))
        }
        // 임포트 날짜·장르·키·코멘트를 곡마다 돌려 가며 채운다(정렬·필터·검색이 실제처럼 섞이게).
        try fixture.execute("""
            UPDATE djmdContent SET
                created_at = date('2026-09-20', '-' || (CAST(ID AS INTEGER) % 1500) || ' days') || ' 00:00:00.000 +00:00',
                GenreID = 'g' || (CAST(ID AS INTEGER) % 24),
                KeyID = 'k' || (CAST(ID AS INTEGER) % 24),
                Commnt = CASE CAST(ID AS INTEGER) % 3 WHEN 0 THEN '' WHEN 1 THEN '합성 코멘트 peak ' || (CAST(ID AS INTEGER) % 50)
                    ELSE 'warm up / 합성 ' || (CAST(ID AS INTEGER) % 17) END
            """)
        try Self.playlists(into: fixture)
        try Self.histories(into: fixture)
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }

    /// 아티스트 300명·앨범 600개·장르 24개·키 24개
    static func names(into fixture: RekordboxFixture) throws {
        let db = try fixture.open()
        defer { db.close() }
        let stamp = CipherDatabase.Value.text("2026-01-01 00:00:00.000 +00:00")
        try db.execute("BEGIN")
        for n in 0..<300 {
            try db.run("INSERT INTO djmdArtist (ID, Name, created_at, updated_at) VALUES (?, ?, ?, ?)",
                       [.text("a\(n)"), .text("합성 아티스트 \(n)"), stamp, stamp])
        }
        for n in 0..<600 {
            try db.run("INSERT INTO djmdAlbum (ID, Name, AlbumArtistID, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                       [.text("al\(n)"), .text("합성 앨범 \(n)"), .text("a\(n % 300)"), stamp, stamp])
        }
        let genres = ["House", "Techno", "Tech House", "Deep House", "Progressive", "Trance", "Drum & Bass", "Breaks",
                      "Disco", "Nu Disco", "Electro", "Garage", "Dubstep", "Hip-Hop", "Pop", "Minimal",
                      "Afro House", "Melodic Techno", "Hard Techno", "Jungle", "Ambient", "Funk", "Soul", "J-Pop"]
        let keys = ["C", "Cm", "Db", "C#m", "D", "Dm", "Eb", "D#m", "E", "Em", "F", "Fm",
                    "F#", "F#m", "G", "Gm", "Ab", "G#m", "A", "Am", "Bb", "Bbm", "B", "Bm"]
        for (n, name) in genres.enumerated() {
            try db.run("INSERT INTO djmdGenre (ID, Name, created_at, updated_at) VALUES (?, ?, ?, ?)", [.text("g\(n)"), .text(name), stamp, stamp])
        }
        for (n, name) in keys.enumerated() {
            try db.run("INSERT INTO djmdKey (ID, ScaleName, Seq, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                       [.text("k\(n)"), .text(name), .int(n + 1), stamp, stamp])
        }
        try db.execute("COMMIT")
    }

    /// 폴더 20개(각 12목록) + 맨 위 목록 60개 = 목록 300개. 목록마다 곡 20~220개.
    static func playlists(into fixture: RekordboxFixture) throws {
        var specs: [PlaylistSpec] = []
        var number = 0
        func list(parent: String, seq: Int) -> PlaylistSpec {
            number += 1
            let size = 20 + (number * 53) % 200
            let start = (number * 131) % trackCount
            let ids = (0..<size).map { String((start + $0 * 7) % trackCount + 1) }
            return PlaylistSpec(id: String(10_000 + number), name: "합성 목록 \(number)", parentID: parent, seq: seq, contentIDs: ids)
        }
        for folder in 1...folderCount {
            let id = String(1_000 + folder)
            specs.append(PlaylistSpec(id: id, name: "합성 폴더 \(folder)", seq: folder, isFolder: true))
            for seq in 1...playlistsPerFolder { specs.append(list(parent: id, seq: seq)) }
        }
        for seq in 1...rootPlaylistCount { specs.append(list(parent: "root", seq: folderCount + seq)) }
        try fixture.add(playlists: specs)
    }

    /// 재생 기록 80개(각 25곡)
    static func histories(into fixture: RekordboxFixture) throws {
        let db = try fixture.open()
        defer { db.close() }
        let stamp = CipherDatabase.Value.text("2026-01-01 00:00:00.000 +00:00")
        try db.execute("BEGIN")
        for n in 1...historyCount {
            let id = "h\(n)"
            let date = String(format: "2026-%02d-%02d", 1 + (n / 28) % 9, 1 + n % 28)
            try db.run("""
                INSERT INTO djmdHistory (ID, Name, DateCreated, Seq, Attribute, ParentID, rb_local_deleted, created_at, updated_at)
                VALUES (?, ?, ?, ?, 0, 'root', 0, ?, ?)
                """, [.text(id), .text("합성 기록 \(n)"), .text(date), .int(n), stamp, stamp])
            for entry in 1...25 {
                try db.run("""
                    INSERT INTO djmdSongHistory (ID, HistoryID, ContentID, TrackNo, rb_local_deleted, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 0, ?, ?)
                    """, [.text("\(id)-\(entry)"), .text(id), .text(String((n * 97 + entry * 11) % trackCount + 1)), .int(entry), stamp, stamp])
            }
        }
        try db.execute("COMMIT")
    }
}
