import Foundation

/// 곡 행의 파일 크기(`djmdContent.FileSize`). 파일 없는 곡의 새 위치 후보를 크기로 맞출 때 쓴다(#62).
/// 스냅샷 사본을 읽기 전용으로만 연다. 곡 모델(`Track`)에는 크기 칸이 없어 따로 읽는다.
public enum TrackFileSizes {
    /// ContentID → 바이트. 크기가 0이거나 비어 있는 곡은 뺀다(모르는 값).
    public static func load(snapshot: URL, trackIDs: Set<String>) throws -> [String: Int64] {
        guard !trackIDs.isEmpty else { return [:] }
        let db = try CipherDatabase(path: snapshot.path, key: RekordboxKey.derive())
        defer { db.close() }
        var sizes: [String: Int64] = [:]
        try db.query("SELECT ID, FileSize FROM djmdContent WHERE rb_local_deleted = 0 AND FileSize > 0") { row in
            if let id = row.string(0), trackIDs.contains(id), let size = row.int(1) { sizes[id] = Int64(size) }
        }
        return sizes
    }
}
