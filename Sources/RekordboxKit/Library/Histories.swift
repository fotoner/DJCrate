import DJCDomain
import Foundation

extension RekordboxLibrary {
    static func loadHistories(_ db: CipherDatabase) throws -> [RekordboxHistory] {
        var entries: [String: [RekordboxHistory.Entry]] = [:]
        try db.query("""
            SELECT ID, HistoryID, ContentID, TrackNo FROM djmdSongHistory
            WHERE rb_local_deleted = 0 ORDER BY HistoryID, TrackNo, ID
            """) { row in
            guard let id = row.string(0), let history = row.string(1), let content = row.string(2) else { return }
            entries[history, default: []].append(.init(id: id, contentID: content, trackNumber: row.int(3) ?? 0))
        }
        var histories: [RekordboxHistory] = []
        try db.query("""
            SELECT ID, Name, NULLIF(DateCreated, '') FROM djmdHistory
            WHERE rb_local_deleted = 0 AND COALESCE(Attribute, 0) != 1
            ORDER BY NULLIF(DateCreated, '') DESC, Seq, ID
            """) { row in
            guard let id = row.string(0) else { return }
            histories.append(.init(id: id, name: row.string(1) ?? "", dateCreated: row.string(2), entries: entries[id] ?? []))
        }
        return histories
    }
}
