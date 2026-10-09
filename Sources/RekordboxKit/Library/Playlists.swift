import DJCDomain
import Foundation

extension RekordboxLibrary {
    static func loadPlaylists(_ db: CipherDatabase) throws -> [RekordboxPlaylist] {
        var tracks: [String: [String]] = [:]
        var numbers: [String: [Int]] = [:]
        // 쓰기 모듈(`PlaylistTree.read`)과 같은 순서
        try db.query("""
            SELECT PlaylistID, ContentID, TrackNo FROM djmdSongPlaylist
            WHERE rb_local_deleted = 0 ORDER BY PlaylistID, TrackNo, ID
            """) { row in
            if let playlist = row.string(0), let content = row.string(1) {
                tracks[playlist, default: []].append(content)
                numbers[playlist, default: []].append(row.int(2) ?? 0)
            }
        }
        var playlists: [RekordboxPlaylist] = []
        try db.query("""
            SELECT ID, Seq, Name, Attribute, ParentID, SmartList FROM djmdPlaylist WHERE rb_local_deleted = 0
            """) { row in
            let id = row.string(0) ?? ""
            let attribute = row.int(3) ?? 0, smartList = row.string(5)
            let isSmart = attribute > 1 || !(smartList ?? "").isEmpty
            playlists.append(RekordboxPlaylist(
                id: id,
                name: row.string(2) ?? "",
                parentID: row.string(4) ?? "root",
                seq: row.int(1) ?? 0,
                isFolder: row.int(3) == 1,
                trackIDs: tracks[id] ?? [],
                trackNumbers: numbers[id] ?? [],
                isSmart: isSmart,
                smartSource: isSmart ? SmartPlaylistSource.reading(attribute: attribute, smartList: smartList) : nil
            ))
        }
        return playlists
    }
}
