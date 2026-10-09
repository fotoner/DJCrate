import DJCDomain
import Foundation

/// 로컬 스냅샷 사본에서 USB 짝짓기 키(`LocalLibraryKeys`)를 읽는다. rekordbox 표·칸 이름은 여기만 안다(#167: 유스케이스에서 내렸다)
public enum LocalLibraryKeysReader {
    /// 로컬 스냅샷 **사본**(읽기 전용으로 연 연결)에서 읽는다. 백그라운드 작업에서 부른다. 지운 곡은 뺀다
    public static func load(database: CipherDatabase) throws -> LocalLibraryKeys {
        var dbid: Int64?
        try database.query("SELECT DBID FROM djmdProperty") { row in
            if dbid == nil { dbid = row.string(0).flatMap { Int64($0) } }
        }
        guard let dbid else { throw DJCError.databaseOpenFailed(path: "djmdProperty", message: "DBID") }
        var tracks: [UsbLocalTrackKey] = []
        var counters: [String: LocalTrackCounters] = [:]
        var masterDBIDs: [String: Int64] = [:]
        try database.query("""
            SELECT ID, MasterSongID, FileNameL, TrackInfoUpdated, AnalysisUpdated, CueUpdated, FolderPath, MasterDBID FROM djmdContent
            WHERE rb_local_deleted = 0
            """) { row in
            guard let id = row.string(0) else { return }
            tracks.append(UsbLocalTrackKey(contentID: id, masterSongID: row.string(1) ?? "", fileNameL: row.string(2) ?? "",
                                           folderPath: row.string(6)))
            counters[id] = LocalTrackCounters(information: row.string(3), analysis: row.string(4), cue: row.string(5))
            // 쓰기 계획(`UsbEditPlanner.localKeys`)과 같은 정수 해석
            masterDBIDs[id] = UsbSQLiteCast.integer(row.string(7)) ?? 0
        }
        return LocalLibraryKeys(localDBID: dbid, tracks: tracks, counters: counters, masterDBIDs: masterDBIDs)
    }

    /// 스냅샷 사본 파일을 읽기 전용으로 열어 읽는다
    public static func load(snapshot: URL) throws -> LocalLibraryKeys {
        let database = try CipherDatabase(path: snapshot.path, key: .hex(RekordboxKey.derive()), mode: .readOnly)
        defer { database.close() }
        return try load(database: database)
    }
}
