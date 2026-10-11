import DJCDomain
import Foundation

extension RekordboxLibrary {
    public static func load(snapshot: URL) throws -> RekordboxLibrary {
        let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())

        var tracks: [Track] = []
        try db.query("""
            SELECT c.ID, c.UUID, c.Title, a.Name, al.Name, g.Name, k.ScaleName,
                   c.BPM, c.Length, c.FolderPath, c.Commnt, c.created_at,
                   c.AnalysisDataPath, c.rb_local_deleted, c.ImagePath,
                   cp.Name, aa.Name, c.ReleaseYear, c.TrackNo, c.BitRate,
                   c.Rating, c.ColorID, c.rb_data_status
            FROM djmdContent c
            LEFT JOIN djmdArtist a ON a.ID = c.ArtistID
            LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID
            LEFT JOIN djmdArtist cp ON cp.ID = c.ComposerID
            LEFT JOIN djmdArtist aa ON aa.ID = al.AlbumArtistID
            LEFT JOIN djmdGenre g ON g.ID = c.GenreID
            LEFT JOIN djmdKey k ON k.ID = c.KeyID
            """) { row in
            let bpm = row.int(7) ?? 0
            tracks.append(Track(
                id: row.string(0) ?? "",
                uuid: row.string(1) ?? "",
                title: row.string(2) ?? "",
                artist: row.string(3),
                album: row.string(4),
                albumArtist: row.string(16),
                genre: row.string(5),
                composer: row.string(15),
                releaseYear: row.int(17).flatMap { $0 > 0 ? $0 : nil },
                trackNumber: row.int(18).flatMap { $0 > 0 ? $0 : nil },
                key: row.string(6),
                bpm: bpm > 0 ? Double(bpm) / 100 : nil,
                lengthSeconds: row.int(8) ?? 0,
                folderPath: row.string(9) ?? "",
                comment: row.string(10) ?? "",
                importedOn: row.string(11).map { String($0.prefix(10)) },
                analysisDataPath: row.string(12),
                imagePath: row.string(14),
                isDeleted: (row.int(13) ?? 0) != 0,
                bitrateKbps: row.int(19),
                rating: row.int(20) ?? 0,
                colorID: row.string(21),
                dataStatus: row.int(22)
            ))
        }

        var cues: [Cue] = []
        try db.query("""
            SELECT ContentID, Kind, InMsec, Comment, ColorTableIndex, ID, OutMsec, Color, ActiveLoop, BeatLoopSize
            FROM djmdCue WHERE rb_local_deleted = 0
            """) { row in
            cues.append(Cue(
                id: row.string(5) ?? "",
                contentID: row.string(0) ?? "",
                kind: row.int(1) ?? 0,
                inMsec: row.int(2) ?? 0,
                name: row.string(3) ?? "",
                colorTableIndex: row.int(4),
                outMsec: row.int(6) ?? 0,
                color: row.int(7),
                activeLoop: row.int(8) ?? 0,
                beatLoopSize: row.int(9) ?? 0
            ))
        }

        var playCounts: [String: Int] = [:]
        try db.query("""
            SELECT ContentID, count(*) FROM djmdSongHistory
            WHERE rb_local_deleted = 0 GROUP BY ContentID
            """) { row in
            if let id = row.string(0) { playCounts[id] = row.int(1) ?? 0 }
        }

        var library = RekordboxLibrary(allTracks: tracks, cues: cues, playCounts: playCounts,
                                       playlists: try loadPlaylists(db), histories: try loadHistories(db))
        // 오토게인: 게인·피크가 32비트 실수 하나를 16비트 두 칸(상위·하위)에 나눠 담겨 있다.
        var gains: [String: RekordboxAutoGain] = [:]
        try? db.query("SELECT ContentID, GainHigh, GainLow, PeakHigh, PeakLow FROM djmdMixerParam WHERE rb_local_deleted = 0") { r in
            guard let id = r.string(0) else { return }
            let gain = RekordboxAutoGain.float(high: r.int(1) ?? 0, low: r.int(2) ?? 0)
            let peak = RekordboxAutoGain.float(high: r.int(3) ?? 0, low: r.int(4) ?? 0)
            if gain > 0, gain.isFinite { gains[id] = RekordboxAutoGain(gain: Double(gain), peak: Double(peak)) }
        }
        library.autoGains = gains
        // 그림 초안의 base: rekordbox의 그림 바꾸기는 곡 행을 건드리지 않아 파일 행의 해시·크기·상태로 알아챈다(#66).
        var artworkFiles: [String: [ArtworkFileRow]] = [:]
        try? db.query("""
            SELECT ContentID, Path, Hash, Size, rb_data_status FROM contentFile
            WHERE substr(Path, 1, 17) = '/PIONEER/Artwork/' AND rb_local_deleted = 0
            """) { r in
            guard let id = r.string(0) else { return }
            artworkFiles[id, default: []].append(ArtworkFileRow(path: r.string(1) ?? "", hash: r.string(2), size: r.int(3), status: r.int(4)))
        }
        library.artworkFiles = artworkFiles
        // 곡 색 이름: 사용자가 rekordbox에서 바꿀 수 있어 라이브러리 값을 그대로 보인다(목록·고르기 순서는 SortKey)
        var colors: [TrackColor] = []
        try? db.query("SELECT ID, Commnt FROM djmdColor WHERE rb_local_deleted = 0 ORDER BY SortKey, ID") { r in
            guard let id = r.string(0), !id.isEmpty else { return }
            colors.append(TrackColor(id: id, name: r.string(1) ?? id))
        }
        library.colors = colors
        return library
    }
}
